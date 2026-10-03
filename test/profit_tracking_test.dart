import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/repository/Invoice_repository.dart';
import 'package:pharmacy_app/utils/invoice_discount.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'id_strategy_test.dart' show createV8Schema, seedMixedV8;

/// تتبّع الربح أوفلاين: متوسط الكلفة المرجّح، لقطة unit_cost، دفعات الصلاحية
/// المخفية (FEFO)، وتقرير الربح — نفس سيناريوهات pharmacy_data/tests.py.
const int pharmacyId = 1;

String inDays(int days) {
  final d = DateTime.now().add(Duration(days: days));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final helper = DatabaseHelper.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_profit_test');
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
    await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': inDays(0)},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return db;
  }

  Future<Map<String, Object?>> medicine(Database db, int id) async =>
      (await db.query('medicine', where: 'id = ?', whereArgs: [id])).single;

  Future<List<Map<String, Object?>>> batches(Database db, int id) =>
      db.query('medicine_batch', where: 'medicine_id = ?', whereArgs: [id], orderBy: 'expiry_date, id');

  Future<void> expectInvariant(Database db, int id) async {
    final total = (await batches(db, id)).fold<int>(0, (sum, b) => sum + (b['quantity'] as int));
    expect((await medicine(db, id))['quantity'], total, reason: 'quantity must equal sum of batches');
  }

  Future<int> addMedicine({int qty = 10, double buy = 500, double sell = 1000, int expiryDays = 60}) async {
    final wh = await helper.ensureMainWarehouse(pharmacyId);
    return helper.insertMedicine({
      'pharmacy_id': pharmacyId,
      'warehouse_id': wh,
      'trade_name': 'Panadol',
      'quantity': qty,
      'buy_price': buy,
      'sell_price': sell,
      'expiry_date': inDays(expiryDays),
    });
  }

  Future<void> sell(int medicineId, int qty, {double price = 1250, double discount = 0, String? number}) async {
    await helper.completeSale(
      invoice: {
        'pharmacy_id': pharmacyId,
        'invoice_number': number ?? await helper.generateInvoiceNumber(),
        'created_at': DateTime.now().toIso8601String(),
        'total_amount': qty * price,
        'discount': discount,
        'final_amount': qty * price - discount,
      },
      items: [
        {'medicine_id': medicineId, 'trade_name': 'Panadol', 'quantity': qty, 'unit_price': price, 'total_price': qty * price},
      ],
    );
  }

  Future<Map<String, num>> report() => helper.getProfitSummary(pharmacyId, start: inDays(-1), end: inDays(1));

  test('acceptance scenario offline: 10@500 + supply 20@750 -> avg 666.67, sell 30@1250 -> gross 17,500', () async {
    final db = await freshDb();
    final id = await addMedicine(qty: 10, buy: 500, sell: 1000, expiryDays: 60);
    expect((await medicine(db, id))['avg_cost'], 500);
    expect(await batches(db, id), hasLength(1));

    final later = inDays(400);
    await helper.supplyMedicine(medicineId: id, addedQuantity: 20, newExpiryDate: later, purchasePrice: 750, salePrice: 1250);
    final supplied = await medicine(db, id);
    expect(((supplied['avg_cost'] as num) * 100).round() / 100, 666.67);
    expect(supplied['quantity'], 30);
    expect(supplied['sell_price'], 1250);
    expect(await batches(db, id), hasLength(2));
    expect(supplied['expiry_date'], inDays(60)); // أقرب دفعة

    await sell(id, 10);
    expect((await batches(db, id)).map((b) => [b['expiry_date'], b['quantity']]), [
      [later, 20]
    ]); // FEFO: الأقرب انتهاءً استُنفدت أولاً
    await sell(id, 20);
    expect(await batches(db, id), isEmpty);
    await expectInvariant(db, id);

    final before = await report();
    expect(before['revenue'], 37500);
    expect((before['gross_profit']! - 17500).abs(), lessThanOrEqualTo(0.01));
    expect(before['items_without_cost'], 0);

    final costsBefore = (await db.query('invoice_item', orderBy: 'id')).map((r) => r['unit_cost']).toList();
    await helper.updateMedicine(id, {'sell_price': 2000});
    expect((await db.query('invoice_item', orderBy: 'id')).map((r) => r['unit_cost']).toList(), costsBefore);
    expect((await report())['gross_profit'], before['gross_profit']);
  });

  test('first supply without known cost requires a purchase price; prices must be > 0', () async {
    final db = await freshDb();
    final id = await addMedicine(qty: 0, buy: 0, sell: 100);
    expect((await medicine(db, id))['avg_cost'], isNull);

    await expectLater(helper.supplyMedicine(medicineId: id, addedQuantity: 5, salePrice: 100), throwsStateError);
    await expectLater(helper.supplyMedicine(medicineId: id, addedQuantity: 5, purchasePrice: 0, salePrice: 100), throwsStateError);
    await expectLater(helper.supplyMedicine(medicineId: id, addedQuantity: 5, purchasePrice: 50, salePrice: 0), throwsStateError);
    expect((await medicine(db, id))['quantity'], 0); // لا شيء حُفظ

    await helper.supplyMedicine(medicineId: id, addedQuantity: 5, purchasePrice: 50, salePrice: 100);
    // بلا سعر شراء بعد معرفة الكلفة (غير المالك): يُستخدم avg_cost الحالي.
    await helper.supplyMedicine(medicineId: id, addedQuantity: 5, salePrice: 100);
    final row = await medicine(db, id);
    expect([row['avg_cost'], row['quantity']], [50, 10]);
    await expectInvariant(db, id);
  });

  test('sales skip expired batches (POS sellable quantity), damage takes them first with cost snapshot', () async {
    final db = await freshDb();
    final id = await addMedicine(qty: 3, expiryDays: 200);
    await db.insert('medicine_batch', {
      'medicine_id': id, 'quantity': 4, 'expiry_date': inDays(-1), 'purchase_price': 500, 'created_at': inDays(-30),
    });
    await db.update('medicine', {'quantity': 7, 'expiry_date': inDays(-1)}, where: 'id = ?', whereArgs: [id]);

    final listed = (await helper.getMedicines(pharmacyId)).single;
    expect([listed['quantity'], listed['sellable_quantity']], [7, 3]);

    await expectLater(sell(id, 4), throwsStateError);
    expect((await medicine(db, id))['quantity'], 7); // المعاملة أُلغيت كاملة
    await sell(id, 3);
    expect((await medicine(db, id))['quantity'], 4);

    await helper.processDamageMedicine(medicineId: id, pharmacyId: pharmacyId, quantityToDamage: 4, reason: 'expired');
    expect((await db.query('damaged_medicine')).single['total_cost'], 2000);
    expect(await batches(db, id), isEmpty);
    await expectInvariant(db, id);
  });

  test('refund restores to the latest-expiry batch, keeps avg_cost and reverses profit', () async {
    final db = await freshDb();
    final id = await addMedicine(qty: 10, expiryDays: 30);
    await helper.supplyMedicine(medicineId: id, addedQuantity: 10, newExpiryDate: inDays(300), purchasePrice: 700, salePrice: 1000);
    await sell(id, 12, price: 1000, number: 'INV-000001');
    expect((await report())['gross_profit'], greaterThan(0));
    final avgBefore = (await medicine(db, id))['avg_cost'];

    final invoiceId = (await db.query('invoice')).single['id'] as int;
    await helper.refundInvoice(invoiceId);
    final row = await medicine(db, id);
    expect([row['avg_cost'], row['quantity']], [avgBefore, 20]);
    expect((await batches(db, id)).map((b) => [b['expiry_date'], b['quantity']]), [
      [inDays(300), 20]
    ]);
    expect((await report())['gross_profit'], 0);
  });

  test('net profit: discount share, expenses, damage cost; missing-cost lines excluded and counted', () async {
    final db = await freshDb();
    final id = await addMedicine(qty: 10, buy: 400, sell: 1000);
    await sell(id, 2, price: 1000, discount: 100);
    await sell(id, 1, price: 1000);
    final lastItem = (await db.query('invoice_item', orderBy: 'id DESC', limit: 1)).single['id'];
    await db.update('invoice_item', {'unit_cost': null}, where: 'id = ?', whereArgs: [lastItem]); // مبيعات قديمة
    await helper.addExpense({'pharmacy_id': pharmacyId, 'expense_type': 'rent', 'expense_date': inDays(0), 'amount': 50});
    await helper.processDamageMedicine(medicineId: id, pharmacyId: pharmacyId, quantityToDamage: 1, reason: 'broken');
    await helper.processDamageMedicine(medicineId: id, pharmacyId: pharmacyId, quantityToDamage: 1, reason: 'correction');

    final r = await report();
    expect(r['revenue'], 2900);
    expect(r['cost_of_goods_sold'], 800);
    expect(r['gross_profit'], 1100); // 2000 - 100 خصم - 800
    expect(r['damage_cost'], 400); // "تصحيح إدخال" مستبعد
    expect(r['net_profit'], 650); // 1100 - 50 - 400
    expect(r['items_without_cost'], 1);
  });

  test('transfer moves batches with their expiry/cost and weights the target avg_cost', () async {
    final db = await freshDb();
    final id = await addMedicine(qty: 10, buy: 500, expiryDays: 50);
    final second = await helper.addWarehouse(pharmacyId: pharmacyId, name: 'Second', maxWarehouses: 2);
    await helper.transferStock(sourceMedicineId: id, toWarehouseId: second, quantity: 4);

    final target = (await db.query('medicine', where: 'warehouse_id = ?', whereArgs: [second])).single;
    expect(target['avg_cost'], 500);
    expect((await batches(db, target['id'] as int)).map((b) => [b['quantity'], b['expiry_date'], b['purchase_price']]), [
      [4, inDays(50), 500]
    ]);
    await expectInvariant(db, id);
    await expectInvariant(db, target['id'] as int);
  });

  test('expiry alerts are per batch', () async {
    await freshDb();
    final id = await addMedicine(qty: 5, expiryDays: 300);
    await helper.supplyMedicine(medicineId: id, addedQuantity: 2, newExpiryDate: inDays(10), purchasePrice: 500, salePrice: 1000);
    final alerts = await helper.getExpiredMedicines(pharmacyId, daysAhead: 90);
    expect(alerts.map((a) => [a['quantity'], a['expiry_date']]), [
      [2, inDays(10)]
    ]);
  });

  test('online cache stores avg_cost, server batches and unit_cost; old servers fall back to medicine expiry', () async {
    final db = await freshDb();
    helper.setSessionMode(isOnline: true);
    await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [{'id': 1, 'name': 'Main', 'is_main': true}]);
    await helper.replaceMedicinesCache(pharmacyId: pharmacyId, serverItems: [
      {
        'id': 5, 'warehouse': 1, 'trade_name': 'Srv', 'quantity': 6, 'sell_price': '10.00', 'avg_cost': '6.6667',
        'expiry_date': inDays(-2),
        'batches': [
          {'id': 70, 'quantity': 2, 'expiry_date': inDays(-2), 'purchase_price': '5.0000'},
          {'id': 71, 'quantity': 4, 'expiry_date': inDays(100), 'purchase_price': '7.5000'},
        ],
      },
      // خادم أقدم / موظف: بلا batches ولا avg_cost.
      {'id': 6, 'warehouse': 1, 'trade_name': 'Old', 'quantity': 3, 'sell_price': '10.00', 'expiry_date': inDays(30)},
    ]);
    expect((await medicine(db, 5))['avg_cost'], 6.6667);
    expect((await batches(db, 5)).map((b) => b['server_id']), [70, 71]);
    expect((await medicine(db, 6))['avg_cost'], isNull);
    final listed = {for (final m in await helper.getMedicines(pharmacyId)) m['id']: m['sellable_quantity']};
    expect(listed, {5: 4, 6: 3});

    await helper.upsertMedicineFromServer(pharmacyId: pharmacyId, serverData: {
      'id': 5, 'warehouse': 1, 'trade_name': 'Srv', 'quantity': 1, 'sell_price': '10.00',
      'batches': [{'id': 71, 'quantity': 1, 'expiry_date': inDays(100)}],
    });
    expect((await batches(db, 5)).map((b) => b['quantity']), [1]);

    await helper.upsertInvoiceFromServer(pharmacyId: pharmacyId, serverData: {
      'id': 9, 'invoice_number': 'INV-000009', 'total_amount': '10.00', 'discount': '0.00', 'final_amount': '10.00',
      'created_at': DateTime.now().toIso8601String(), 'is_refunded': false,
      'items': [{'medicine': 5, 'trade_name': 'Srv', 'quantity': 1, 'unit_price': '10.00', 'total_price': '10.00', 'unit_cost': '6.6667'}],
    });
    expect((await db.query('invoice_item')).single['unit_cost'], 6.6667);
  });

  test('offline -> online migration payload carries avg_cost, batches, unit_cost and damage cost', () async {
    final db = await freshDb();
    final id = await addMedicine(qty: 10, buy: 500, expiryDays: 60);
    await helper.supplyMedicine(medicineId: id, addedQuantity: 5, newExpiryDate: inDays(200), purchasePrice: 800, salePrice: 1200);
    await sell(id, 1);
    await helper.processDamageMedicine(medicineId: id, pharmacyId: pharmacyId, quantityToDamage: 1, reason: 'broken');

    final payload = await helper.getOfflineMigrationPayload(pharmacyId);
    final med = (payload['medicines'] as List).single as Map;
    expect(med['avg_cost'], (await medicine(db, id))['avg_cost']);
    expect((med['batches'] as List).map((b) => b['quantity']), [8, 5]);
    expect(((payload['invoices'] as List).single['items'] as List).single['unit_cost'], 600);
    expect((payload['damaged_medicines'] as List).single['total_cost'], 600);
  });

  group('discounts', () {
    test('negative discount = no sale, offline (DB and repository) and online (before any network call)', () async {
      final db = await freshDb();
      final id = await addMedicine(qty: 5);
      await expectLater(sell(id, 1, price: 1000, discount: -10), throwsStateError);

      final item = {'medicine_id': id, 'trade_name': 'Panadol', 'quantity': 1, 'unit_price': 1000.0, 'total_price': 1000.0};
      for (final online in [false, true]) {
        await expectLater(
          InvoiceRepository.instance.checkout(
            pharmacyId: pharmacyId,
            isOnlineMode: online,
            invoice: {
              'pharmacy_id': pharmacyId, 'invoice_number': 'INV-000099', 'created_at': inDays(0),
              'total_amount': 1000, 'discount': -10, 'final_amount': 1010,
            },
            items: [Map<String, dynamic>.from(item)],
          ),
          throwsA(isA<InvoiceRepositoryException>()
              .having((e) => e.message, 'message', 'لا يمكن إتمام البيع: قيمة الخصم سالبة.')),
        );
      }
      expect(await db.query('invoice'), isEmpty);
      expect((await medicine(db, id))['quantity'], 5);
    });

    test('refunding a discounted invoice reverses exactly its own profit', () async {
      final db = await freshDb();
      final id = await addMedicine(qty: 10, buy: 400, sell: 1000);
      await sell(id, 2, price: 1000, discount: 150, number: 'INV-000001');
      final keep = (await report())['gross_profit']!;
      expect(keep, 1050); // 2000 - 150 - 800
      await sell(id, 3, price: 1000, discount: 75, number: 'INV-000002');
      expect((await report())['gross_profit'], keep + 1725); // 3000 - 75 - 1200

      final second = (await db.query('invoice', where: "invoice_number = 'INV-000002'")).single['id'] as int;
      await helper.refundInvoice(second);
      final r = await report();
      expect(r['gross_profit'], keep);
      expect(r['revenue'], 1850);
    });

    test('shared parity fixture: getProfitSummary gives exactly the numbers the server test expects', () async {
      final fixture = jsonDecode(File('test/fixtures/profit_parity.json').readAsStringSync()) as Map<String, dynamic>;
      final db = await freshDb();
      final wh = await helper.ensureMainWarehouse(pharmacyId);
      final today = inDays(0);

      final medicineIds = <String, int>{};
      for (final entry in (fixture['medicines'] as Map<String, dynamic>).entries) {
        medicineIds[entry.key] = await db.insert('medicine', {
          'pharmacy_id': pharmacyId, 'warehouse_id': wh, 'trade_name': entry.key, 'quantity': 0,
          'avg_cost': (entry.value as Map)['avg_cost'],
        });
      }
      for (final inv in (fixture['invoices'] as List).cast<Map<String, dynamic>>()) {
        final items = (inv['items'] as List).cast<Map<String, dynamic>>();
        final total = items.fold<num>(0, (sum, it) => sum + (it['unit_price'] as num) * (it['quantity'] as num));
        final discount = inv['discount'] as num;
        final invoiceId = await db.insert('invoice', {
          'pharmacy_id': pharmacyId, 'invoice_number': inv['number'], 'created_at': '${today}T10:00:00',
          'total_amount': total, 'discount': discount, 'final_amount': DatabaseHelper.roundMoney(total - discount),
          'is_refunded': inv['is_refunded'] == true ? 1 : 0,
        });
        for (final it in items) {
          await db.insert('invoice_item', {
            'invoice_id': invoiceId, 'trade_name': it['medicine'], 'medicine_id': medicineIds[it['medicine']],
            'quantity': it['quantity'], 'unit_price': it['unit_price'],
            'total_price': (it['unit_price'] as num) * (it['quantity'] as num), 'unit_cost': it['unit_cost'],
          });
        }
      }
      for (final amount in (fixture['expenses'] as List).cast<num>()) {
        await helper.addExpense({'pharmacy_id': pharmacyId, 'expense_type': 'x', 'expense_date': today, 'amount': amount});
      }
      for (final d in (fixture['damaged'] as List).cast<Map<String, dynamic>>()) {
        await db.insert('damaged_medicine', {
          'pharmacy_id': pharmacyId, 'medicine_id': medicineIds[d['medicine']], 'quantity_damaged': d['quantity'],
          'total_cost': d['total_cost'], 'reason': d['reason'], 'damaged_at': today,
        });
      }

      final summary = await helper.getProfitSummary(pharmacyId, start: today, end: today);
      (fixture['expected'] as Map<String, dynamic>).forEach((key, expected) {
        expect(summary[key], closeTo(expected as num, 0.0001), reason: key);
      });
      // خصم الفاتورة الثانية في الملف هو بالضبط ما تحسبه نقطة البيع لـ 12% من 1255.
      expect(InvoiceDiscount.compute(subtotal: 1255, type: InvoiceDiscount.percent, input: '12'), 150.60);
    });
  });

  test('v9 -> v10 upgrade: avg_cost from a positive buy_price, one batch per stocked medicine, unit_cost stays NULL', () async {
    final raw = await databaseFactoryFfi.openDatabase(DatabaseHelper.databasePathOverride!);
    await raw.execute('PRAGMA foreign_keys = ON');
    await createV8Schema(raw);
    await seedMixedV8(raw);
    await raw.insert('medicine', {
      'id': 40, 'pharmacy_id': 1, 'warehouse_id': 1, 'trade_name': 'Priced', 'quantity': 6, 'buy_price': 12.5,
      'expiry_date': '2030-01-01',
    });
    await raw.setVersion(8);
    await raw.close();

    final db = await helper.database; // v8 -> v9 -> v10
    expect(await db.getVersion(), 10);
    final priced = (await db.query('medicine', where: "trade_name = 'Priced'")).single;
    expect(priced['avg_cost'], 12.5);
    expect((await batches(db, priced['id'] as int)).map((b) => [b['quantity'], b['expiry_date'], b['purchase_price']]), [
      [6, '2030-01-01', 12.5]
    ]);
    expect((await db.query('medicine', where: "trade_name = 'Local A'")).single['avg_cost'], isNull); // buy_price 0
    final stocked = await db.query('medicine', where: 'quantity > 0');
    expect(await db.query('medicine_batch'), hasLength(stocked.length));
    expect((await db.query('invoice_item')).every((r) => r['unit_cost'] == null), isTrue);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });
}
