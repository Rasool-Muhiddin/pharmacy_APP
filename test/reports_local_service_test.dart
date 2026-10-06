import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/report_period.dart';
import 'package:pharmacy_app/services/reports_local_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// تقارير الوضع الأوفلاين (ReportsLocalService): نفس سيناريو
/// test/fixtures/reports_parity.json الذي يعيده backend/pharmacy_data/tests_reports.py
/// على نقاط /api/reports/* — الرقمان يجب أن يتطابقا.
const int pharmacyId = 1;

double n(Object? v) => ((v as num) * 100).round() / 100;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final helper = DatabaseHelper.instance;
  final now = DateTime.now();
  final today = dateOnly(now);
  final service = ReportsLocalService(clock: () => now);
  final fixture = jsonDecode(File('test/fixtures/reports_parity.json').readAsStringSync()) as Map<String, dynamic>;
  final expected = fixture['expected'] as Map<String, dynamic>;

  String day(int offset) => dayKey(addDays(today, offset));
  String at(int offset, [int hour = 12]) => '${day(offset)}T${hour.toString().padLeft(2, '0')}:00:00.000';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_reports_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<Database> freshDb() async {
    final db = await helper.database;
    await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': day(0)},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return db;
  }

  /// يبني بيانات الـfixture ويعيد {اسم: medicine_id}.
  Future<Map<String, int>> loadFixture() async {
    final db = await freshDb();
    final wh = await helper.ensureMainWarehouse(pharmacyId);
    final suppliers = <String, int>{
      for (final name in fixture['suppliers'] as List)
        name as String: await db.insert('pharmacy_supplier', {'pharmacy_id': pharmacyId, 'name': name, 'created_at': at(-30)}),
    };
    final sellers = <String, int>{};
    for (final name in (fixture['sellers'] as List).cast<String>()) {
      final userId = await db.insert('users', {'username': name.toLowerCase(), 'password': 'x', 'full_name': name});
      sellers[name] = await db.insert('user_profile', {'user_id': userId, 'pharmacy_id': pharmacyId, 'is_owner': 0});
    }
    final medicines = <String, int>{};
    for (final entry in (fixture['medicines'] as Map<String, dynamic>).entries) {
      final spec = entry.value as Map<String, dynamic>;
      final batches = (spec['batches'] as List).cast<Map<String, dynamic>>();
      final id = await db.insert('medicine', {
        'pharmacy_id': pharmacyId,
        'warehouse_id': wh,
        'trade_name': entry.key,
        'category': spec['category'],
        'quantity': batches.fold<int>(0, (s, b) => s + (b['quantity'] as int)),
        'buy_price': spec['buy_price'],
        'sell_price': spec['sell_price'],
        'avg_cost': spec['avg_cost'],
      });
      for (final b in batches) {
        await db.insert('medicine_batch', {
          'medicine_id': id,
          'quantity': b['quantity'],
          'expiry_date': day(b['expiry_offset'] as int),
          'purchase_price': b['purchase_price'],
          'supplier_id': suppliers[b['supplier']],
          'created_at': at(-30),
        });
      }
      medicines[entry.key] = id;
    }
    for (final inv in (fixture['invoices'] as List).cast<Map<String, dynamic>>()) {
      final items = (inv['items'] as List).cast<Map<String, dynamic>>();
      final total = items.fold<num>(0, (s, it) => s + (it['unit_price'] as num) * (it['quantity'] as num));
      final invoiceId = await db.insert('invoice', {
        'pharmacy_id': pharmacyId,
        'invoice_number': inv['number'],
        'cashier_id': sellers[inv['seller']],
        'total_amount': total,
        'discount': inv['discount'],
        'final_amount': total - (inv['discount'] as num),
        'created_at': at(inv['day_offset'] as int, inv['hour'] as int),
        'is_refunded': inv['is_refunded'] == true ? 1 : 0,
      });
      for (final it in items) {
        await db.insert('invoice_item', {
          'invoice_id': invoiceId,
          'trade_name': it['medicine'],
          'medicine_id': medicines[it['medicine']],
          'quantity': it['quantity'],
          'unit_price': it['unit_price'],
          'total_price': (it['unit_price'] as num) * (it['quantity'] as num),
          'unit_cost': it['unit_cost'],
        });
      }
    }
    for (final e in (fixture['expenses'] as List).cast<Map<String, dynamic>>()) {
      await db.insert('expense', {
        'pharmacy_id': pharmacyId,
        'expense_type': e['type'],
        'expense_date': day(e['day_offset'] as int),
        'amount': e['amount'],
      });
    }
    for (final d in (fixture['damaged'] as List).cast<Map<String, dynamic>>()) {
      await db.insert('damaged_medicine', {
        'pharmacy_id': pharmacyId,
        'medicine_id': medicines[d['medicine']],
        'quantity_damaged': d['quantity'],
        'total_cost': d['total_cost'],
        'reason': d['reason'],
        'damaged_at': day(d['day_offset'] as int),
      });
    }
    for (final p in (fixture['purchase_invoices'] as List).cast<Map<String, dynamic>>()) {
      final supplierId = suppliers[p['supplier']]!;
      final payments = (p['payments'] as List).cast<Map<String, dynamic>>();
      final invoiceId = await db.insert('purchase_invoice', {
        'pharmacy_id': pharmacyId,
        'supplier_id': supplierId,
        'invoice_number': p['number'],
        'total_amount': p['total'],
        'paid_amount': payments.fold<num>(0, (s, x) => s + (x['amount'] as num)),
        'created_at': at(p['day_offset'] as int),
      });
      for (final x in payments) {
        await db.insert('supplier_payment', {
          'pharmacy_id': pharmacyId,
          'supplier_id': supplierId,
          'purchase_invoice_id': invoiceId,
          'amount_paid': x['amount'],
          'paid_at': at(x['day_offset'] as int),
        });
      }
      for (final x in (p['returns'] as List).cast<Map<String, dynamic>>()) {
        await db.insert('purchase_invoice_return', {
          'pharmacy_id': pharmacyId,
          'supplier_id': supplierId,
          'purchase_invoice_id': invoiceId,
          'amount_returned': x['amount'],
          'returned_at': at(x['day_offset'] as int),
        });
      }
    }
    return medicines;
  }

  final periodSpec = fixture['period'] as Map<String, dynamic>;
  final period = ReportPeriod.custom(
      addDays(today, periodSpec['start_offset'] as int), addDays(today, periodSpec['end_offset'] as int));

  void expectFigures(Map<String, dynamic> actual, Map<String, dynamic> exp) {
    for (final e in exp.entries) {
      expect(n(actual[e.key]), n(e.value), reason: e.key);
    }
  }

  group('parity with reports_parity.json', () {
    late Map<String, int> medicines;
    setUp(() async => medicines = await loadFixture());

    test('kpis: current, previous period of equal length, alerts', () async {
      final data = await service.kpis(pharmacyId, period);
      expect(data['previous_start'], day(-13));
      expect(data['previous_end'], day(-7));
      final exp = expected['kpis'] as Map<String, dynamic>;
      expectFigures(data['current'], exp['current']);
      expectFigures(data['previous'], exp['previous']);
      expectFigures(data['alerts'], exp['alerts']);
    });

    test('net profit equals getProfitSummary (the existing net_profit rule)', () async {
      final current = (await service.kpis(pharmacyId, period))['current'] as Map<String, dynamic>;
      final profit = await helper.getProfitSummary(pharmacyId, start: period.startKey, end: period.endKey);
      for (final key in ['gross_profit', 'net_profit', 'cost_of_goods_sold', 'damage_cost']) {
        expect(n(profit[key]), n(current[key]), reason: key);
      }
    });

    test('trend buckets', () async {
      final data = await service.trend(pharmacyId, period);
      final exp = expected['trend'] as Map<String, dynamic>;
      expect(data['bucket'], exp['bucket']);
      final points = {for (final p in data['points'] as List) p['key']: p};
      final byOffset = exp['points_by_offset'] as Map<String, dynamic>;
      expect(points.length, byOffset.length);
      for (final e in byOffset.entries) {
        final point = points[day(int.parse(e.key))]!;
        expect(n(point['net_sales']), n(e.value[0]), reason: 'net ${e.key}');
        expect(n(point['gross_profit']), n(e.value[1]), reason: 'gross ${e.key}');
      }
    });

    test('categories and hours', () async {
      final categories = (await service.categories(pharmacyId, period))['categories'] as List;
      expect(
        categories.map((c) => [c['category'], n(c['net_sales']), c['quantity']]).toList(),
        (expected['categories'] as List).map((c) => [c['category'], n(c['net_sales']), c['quantity']]).toList(),
      );
      final hours = (await service.hours(pharmacyId, period))['hours'] as List;
      expect(hours, hasLength(24));
      final expHours = expected['hours'] as Map<String, dynamic>;
      for (final h in hours) {
        final exp = expHours['${h['hour']}'] ?? [0, 0];
        expect(h['invoices_count'], exp[0]);
        expect(n(h['net_sales']), n(exp[1]));
      }
    });

    test('items: sorting, profit, sold below cost', () async {
      final exp = expected['items'] as Map<String, dynamic>;
      for (final sort in ['qty', 'revenue', 'profit']) {
        final data = await service.items(pharmacyId, period, sort: sort);
        expect((data['items'] as List).map((i) => i['trade_name']).toList(), exp[sort], reason: sort);
      }
      final data = await service.items(pharmacyId, period);
      final rows = {for (final i in data['items'] as List) i['trade_name']: i as Map<String, dynamic>};
      for (final e in (exp['rows'] as Map<String, dynamic>).entries) {
        expectFigures(rows[e.key]!, e.value);
      }
      final below = data['below_cost'] as List;
      final expBelow = (exp['below_cost'] as List).cast<Map<String, dynamic>>();
      expect(below, hasLength(expBelow.length));
      for (var i = 0; i < below.length; i++) {
        expect(below[i]['medicine_id'], medicines[expBelow[i]['medicine']]);
        expectFigures(below[i], Map.of(expBelow[i])..remove('medicine'));
      }
    });

    test('stagnant: tied-up value and last sale date', () async {
      final data = await service.stagnant(pharmacyId, period);
      final exp = expected['stagnant'] as Map<String, dynamic>;
      expect(data['count'], exp['count']);
      expect(n(data['total_value']), n(exp['total_value']));
      final results = data['results'] as List;
      for (final (i, e) in (exp['results'] as List).indexed) {
        expect(results[i]['trade_name'], e['medicine']);
        expect(results[i]['quantity'], e['quantity']);
        expect(results[i]['category'], e['category']);
        expect(n(results[i]['stock_value']), n(e['stock_value']));
        expect(results[i]['last_sale'], day(e['last_sale_offset'] as int));
      }
    });

    test('inventory current state', () async {
      final exp = expected['inventory'] as Map<String, dynamic>;
      final data = await service.inventory(pharmacyId, days: exp['days'] as int);
      for (final key in ['stock_cost_value', 'stock_sell_value', 'expected_profit', 'expiring_value', 'expired_value']) {
        expect(n(data[key]), n(exp[key]), reason: key);
      }
      for (final listKey in ['expiring', 'expired']) {
        final actual = data[listKey] as List;
        final rows = exp[listKey] as List;
        expect(actual, hasLength(rows.length));
        for (var i = 0; i < rows.length; i++) {
          expect(actual[i]['trade_name'], rows[i]['medicine']);
          expect(actual[i]['quantity'], rows[i]['quantity']);
          expect(actual[i]['supplier_name'], rows[i]['supplier_name']);
          expect(actual[i]['expiry_date'], day(rows[i]['expiry_offset'] as int));
          expect(n(actual[i]['value']), n(rows[i]['value']));
        }
      }
      expect((data['low_stock'] as List).map((m) => m['trade_name']).toList(), exp['low_stock']);
      expect(data['low_stock_threshold'], kLowStockThreshold);
    });

    test('purchases for the period and current supplier debt', () async {
      final data = await service.purchases(pharmacyId, period);
      final exp = expected['purchases'] as Map<String, dynamic>;
      for (final key in ['purchases_total', 'returns_total', 'payments_total', 'refunds_received', 'total_debt', 'total_credit']) {
        expect(n(data[key]), n(exp[key]), reason: key);
      }
      expect(data['invoices_count'], exp['invoices_count']);
      expect(
        (data['by_supplier'] as List).map((s) => [s['name'], s['invoices_count'], n(s['total']), n(s['returns'])]).toList(),
        (exp['by_supplier'] as List).map((s) => [s['name'], s['invoices_count'], n(s['total']), n(s['returns'])]).toList(),
      );
      expect(
        (data['top_debtors'] as List).map((d) => [d['name'], n(d['debt'])]).toList(),
        (exp['top_debtors'] as List).map((d) => [d['name'], n(d['debt'])]).toList(),
      );
    });

    test('losses by type and reason; unrecorded expiry shown separately', () async {
      final data = await service.losses(pharmacyId, period);
      final exp = expected['losses'] as Map<String, dynamic>;
      for (final key in ['expenses_total', 'damage_total', 'expired_recorded', 'expired_not_disposed_value']) {
        expect(n(data[key]), n(exp[key]), reason: key);
      }
      expect(
        (data['expenses_by_type'] as List).map((e) => [e['type'], n(e['total']), e['count']]).toList(),
        (exp['expenses_by_type'] as List).map((e) => [e['type'], n(e['total']), e['count']]).toList(),
      );
      expect(
        (data['damage_by_reason'] as List).map((d) => [d['reason'], n(d['total']), d['quantity'], d['count']]).toList(),
        (exp['damage_by_reason'] as List).map((d) => [d['reason'], n(d['total']), d['quantity'], d['count']]).toList(),
      );
    });

    test('invoices: search, seller filter, refunded list; sellers summary', () async {
      final exp = expected['invoices'] as Map<String, dynamic>;
      final cases = <String, Future<Map<String, dynamic>>>{
        'all': service.invoices(pharmacyId, period),
        'seller_ali': service.invoices(pharmacyId, period, seller: 'Ali'),
        'search_000002': service.invoices(pharmacyId, period, query: '000002'),
        'refunded': service.invoices(pharmacyId, period, refunded: true),
      };
      for (final e in cases.entries) {
        final data = await e.value;
        expect(data['count'], exp[e.key]['count'], reason: e.key);
        expect((data['results'] as List).map((i) => i['invoice_number']).toList(), exp[e.key]['numbers'], reason: e.key);
      }
      final all = await service.invoices(pharmacyId, period);
      expect(n(all['total_amount']), n(exp['all']['total_amount']));
      expect((all['results'] as List).first['seller_name'], 'Ali');
      final sellers = (await service.sellers(pharmacyId, period))['sellers'] as List;
      expect(
        sellers.map((s) => [s['seller_name'], s['invoices_count'], n(s['net_sales'])]).toList(),
        (expected['sellers'] as List).map((s) => [s['seller_name'], s['invoices_count'], n(s['net_sales'])]).toList(),
      );
    });

    test('invoice details keep a sold line whose medicine was deleted (LEFT JOIN)', () async {
      final db = await helper.database;
      final invoiceId = ((await service.invoices(pharmacyId, period))['results'] as List).first['id'] as int;
      await db.execute('PRAGMA foreign_keys = OFF');
      await db.delete('medicine', where: 'id = ?', whereArgs: [medicines['B']]);
      await db.execute('PRAGMA foreign_keys = ON');
      final items = await service.invoiceItems(invoiceId);
      expect(items.map((i) => i['trade_name']), containsAll(['A', 'B']));
      final top = await service.items(pharmacyId, period);
      expect((top['items'] as List).map((i) => i['trade_name']), contains('B'));
    });
  });

  group('behaviour', () {
    Future<void> invoice(String number, int offset, num amount, {int hour = 12}) async {
      final db = await freshDb();
      await db.insert('invoice', {
        'pharmacy_id': pharmacyId,
        'invoice_number': number,
        'total_amount': amount,
        'discount': 0,
        'final_amount': amount,
        'created_at': at(offset, hour),
        'is_refunded': 0,
      });
    }

    test('days are inclusive, start of first day to end of last day', () async {
      await invoice('EARLY', 0, 100, hour: 0);
      await invoice('LATE', 0, 100, hour: 23);
      final todayPeriod = ReportPeriod.custom(today, today);
      expect((await service.periodFigures(pharmacyId, today, today))['invoices_count'], 2);
      expect((await service.periodFigures(pharmacyId, addDays(today, -1), addDays(today, -1)))['invoices_count'], 0);
      expect(((await service.invoices(pharmacyId, todayPeriod))['results'] as List), hasLength(2));
    });

    test('previous period comparison has equal length', () async {
      await invoice('NOW', -2, 300);
      await invoice('BEFORE', -12, 200);
      await invoice('TOO-OLD', -20, 999);
      final data = await service.kpis(pharmacyId, ReportPeriod.custom(addDays(today, -9), today));
      expect(data['previous_start'], day(-19));
      expect(n(data['current']['net_sales']), 300);
      expect(n(data['previous']['net_sales']), 200);
    });

    test('invoices are paginated', () async {
      for (var i = 0; i < 7; i++) {
        await invoice('INV-$i', -(i % 3), 100);
      }
      final p = ReportPeriod.custom(addDays(today, -5), today);
      final page1 = await service.invoices(pharmacyId, p, page: 1, pageSize: 3);
      final page3 = await service.invoices(pharmacyId, p, page: 3, pageSize: 3);
      expect(page1['count'], 7);
      expect(page1['results'], hasLength(3));
      expect(page3['results'], hasLength(1));
      expect((await service.invoices(pharmacyId, p, pageSize: 10000))['page_size'], ReportsLocalService.maxPageSize);
    });

    test('server cache rows are ignored offline (originFilter)', () async {
      final db = await freshDb();
      await db.insert('invoice', {
        'id': 5, // نطاق معرّفات الخادم
        'pharmacy_id': pharmacyId,
        'invoice_number': 'SERVER',
        'total_amount': 999,
        'final_amount': 999,
        'created_at': at(0),
        'is_refunded': 0,
      });
      await invoice('LOCAL', 0, 100);
      expect(n((await service.periodFigures(pharmacyId, today, today))['net_sales']), 100);
    });
  });
}
