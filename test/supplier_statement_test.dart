import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/purchase_list.dart';
import 'package:pharmacy_app/models/supplier_statement.dart';
import 'package:pharmacy_app/screens/reports/export/report_pdf_builder.dart';
import 'package:pharmacy_app/screens/supplier_statement_export.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// كشف حساب المذخر المحاسبي (lib/models/supplier_statement.dart): الترتيب،
/// الرصيد الافتتاحي والفترات، الرصيد الختامي = رصيد المذخر، وأعمار الديون.
/// تطابق الخادم على سيناريو مشترك: supplier_returns_db_test.dart + tests_supplier_returns.py.
void main() {
  Map<String, dynamic> row(String type, Object id, String at, num debtAdded,
          {num? amount, int? invoiceId, String? number, String? invoiceAt, num? total, int items = 0}) =>
      {
        'id': id,
        'transaction_type': type,
        'date_time': at,
        'debt_added': debtAdded,
        'amount': amount ?? debtAdded.abs(),
        'purchase_invoice_id': invoiceId ?? (type == 'invoice' ? id : null),
        'invoice_number': number,
        'invoice_created_at': invoiceAt,
        if (type == 'invoice') 'total_amount': total ?? debtAdded,
        if (type == 'invoice') 'item_count': items,
      };

  group('ordering', () {
    test('an invoice comes before its own credit application and "paid now" payment at the same moment', () {
      const t = '2026-03-01T10:00:00.000';
      // الترتيب الخام كما يصل (الأحدث أولاً، والدفعة قبل فاتورتها).
      final entries = statementEntries([
        row('payment', 7, t, -400, invoiceId: 3, number: '88', invoiceAt: t),
        row('credit_applied', 2, t, 0, amount: 600, invoiceId: 3, number: '88', invoiceAt: t),
        row('invoice', 3, t, 1000, number: '88', items: 12),
      ]);
      expect(entries.map((e) => e.type), [
        StatementEntryType.invoice,
        StatementEntryType.creditApplied,
        StatementEntryType.payment,
      ]);
      expect(entries.map((e) => e.balance), [1000, 1000, 600]);
      expect(entries.first.description, 'فاتورة شراء رقم 88 — 12 صنف');
      expect(entries[1].description, 'خصم من رصيد سابق على فاتورة رقم 88: 600 د.ع');
      expect(entries.last.description, 'دفعة على فاتورة رقم 88');
    });

    test('a back-dated return never appears before its invoice (no credit that never existed)', () {
      final entries = statementEntries([
        row('invoice', 1, '2026-03-01T15:00:00', 1000, number: 'A'),
        // تاريخ الاسترجاع المختار = منتصف نفس اليوم، قبل وقت إدخال الفاتورة.
        row('return', 9, '2026-03-01T12:00:00', -300, invoiceId: 1, number: 'A', invoiceAt: '2026-03-01T15:00:00'),
      ]);
      expect(entries.map((e) => e.type), [StatementEntryType.invoice, StatementEntryType.purchaseReturn]);
      expect(entries.every((e) => e.balance >= 0), isTrue);
    });

    test('server rows (UTC timestamps, decimal strings) give the same statement as local rows', () {
      final local = statementEntries([
        row('invoice', 1, '2026-03-01T13:00:00.000', 1000, number: 'S-1'),
        row('payment', 1, '2026-03-01T13:00:00.000', -1000, invoiceId: 1, number: 'S-1', invoiceAt: '2026-03-01T13:00:00.000'),
      ]);
      final utc = DateTime(2026, 3, 1, 13).toUtc().toIso8601String();
      final server = statementEntries([
        {
          'id': 1, 'transaction_type': 'payment', 'date_time': utc, 'amount': '1000.00', 'debt_added': '-1000.00',
          'purchase_invoice_id': 1, 'invoice_number': 'S-1', 'invoice_created_at': utc,
        },
        {
          'id': 1, 'transaction_type': 'invoice', 'date_time': utc, 'amount': '1000.00', 'debt_added': '1000.00',
          'purchase_invoice_id': 1, 'invoice_number': 'S-1', 'invoice_created_at': utc, 'total_amount': '1000.00',
          'item_count': 0,
        },
      ]);
      String flat(List<StatementEntry> e) =>
          e.map((x) => '${x.type} ${x.at} ${x.invoiceNumber} ${x.increase} ${x.decrease} ${x.balance}').join('\n');
      expect(flat(server), flat(local));
    });

    test('old server without invoice link fields still builds a statement', () {
      final entries = statementEntries([
        {'id': 4, 'transaction_type': 'invoice', 'reference': 'فاتورة بدون رقم', 'date_time': '2026-01-01', 'amount': 50, 'debt_added': 50},
        {'id': 5, 'transaction_type': 'payment', 'reference': 'تسديد دفعة', 'date_time': '2026-01-02', 'amount': 20, 'debt_added': -20},
      ]);
      expect(entries.first.description, 'فاتورة شراء رقم #4');
      expect(entries.last.description, 'دفعة للمذخر');
      expect(entries.last.balance, 30);
    });
  });

  group('periods and opening balance', () {
    final rows = [
      row('invoice', 1, '2025-11-10T09:00:00', 1000, number: '1'),
      row('payment', 1, '2025-12-20T09:00:00', -400, invoiceId: 1, number: '1', invoiceAt: '2025-11-10T09:00:00'),
      row('invoice', 2, '2026-01-15T09:00:00', 2500, number: '2'),
      row('return', 3, '2026-02-03T09:00:00', -500, invoiceId: 2, number: '2', invoiceAt: '2026-01-15T09:00:00'),
      row('refund', 4, '2026-02-25T09:00:00', 100),
      row('payment', 5, '2026-03-02T09:00:00', -1000, invoiceId: 2, number: '2', invoiceAt: '2026-01-15T09:00:00'),
    ];
    final now = DateTime(2026, 3, 10);

    test('opening + movements = closing for every period', () {
      final all = buildSupplierStatement(rows, const StatementPeriod.all());
      expect(all.showOpening, isFalse);
      expect(all.opening, 0);
      expect(all.closing, 1700);

      final periods = [
        for (final p in StatementPreset.values.where((p) => p != StatementPreset.custom))
          StatementPeriod.fromPreset(p, now: now),
        StatementPeriod.custom(DateTime(2025, 12, 1), DateTime(2026, 1, 31)),
        StatementPeriod.custom(DateTime(2026, 2, 1), DateTime(2026, 2, 28)),
        StatementPeriod.custom(DateTime(2024, 1, 1), DateTime(2024, 12, 31)),
      ];
      for (final period in periods) {
        final s = buildSupplierStatement(rows, period);
        expect(s.opening + s.totalIncrease - s.totalDecrease, closeTo(s.closing, 0.001), reason: period.label);
        // الختامي = رصيد آخر حركة قبل نهاية الفترة.
        final before = statementEntries(rows).where((e) => period.endExclusive == null || e.at.isBefore(period.endExclusive!));
        expect(s.closing, closeTo(before.isEmpty ? 0 : before.last.balance, 0.001), reason: period.label);
      }

      final feb = buildSupplierStatement(rows, StatementPeriod.custom(DateTime(2026, 2, 1), DateTime(2026, 2, 28)));
      expect(feb.showOpening, isTrue);
      expect(feb.opening, 3100); // 1000 − 400 + 2500
      expect(feb.entries.map((e) => e.type), [StatementEntryType.purchaseReturn, StatementEntryType.refund]);
      expect(feb.totalIncrease, 100);
      expect(feb.totalDecrease, 500);
      expect(feb.closing, 2700);

      final thisMonth = buildSupplierStatement(rows, StatementPeriod.fromPreset(StatementPreset.thisMonth, now: now));
      expect(thisMonth.opening, 2700);
      expect(thisMonth.entries.single.decrease, 1000);
      final last3 = StatementPeriod.fromPreset(StatementPreset.last3Months, now: now);
      expect(last3.start, DateTime(2026, 1, 1));
      expect(buildSupplierStatement(rows, last3).opening, 600);

      final empty = buildSupplierStatement(rows, StatementPeriod.custom(DateTime(2024, 1, 1), DateTime(2024, 12, 31)));
      expect(empty.entries, isEmpty);
      expect(empty.closing, 0);
    });

    test('balance words: عليك / لك / مسدد', () {
      expect(balanceWords(1250), 'عليك 1,250');
      expect(balanceWords(-300), 'لك 300');
      expect(balanceWords(0.0004), 'مسدد');
    });
  });

  test('aging buckets: open remainders by invoice age, partial payments count only what is left', () {
    final today = DateTime(2026, 6, 30);
    String daysAgo(int d) => today.subtract(Duration(days: d)).toIso8601String().substring(0, 10);
    final buckets = computeAging([
      {'invoice_date': daysAgo(0), 'remaining_amount': 100},
      {'invoice_date': daysAgo(30), 'remaining_amount': 200},
      {'invoice_date': daysAgo(31), 'remaining_amount': 300}, // جزئية: المتبقي فقط
      {'invoice_date': '', 'created_at': '${daysAgo(60)}T10:00:00', 'remaining_amount': 400},
      {'invoice_date': daysAgo(61), 'remaining_amount': 500},
      {'invoice_date': daysAgo(90), 'remaining_amount': 600},
      {'invoice_date': daysAgo(91), 'remaining_amount': 700},
      {'invoice_date': daysAgo(400), 'remaining_amount': 800},
      {'invoice_date': daysAgo(200), 'remaining_amount': 0}, // مسددة: لا تُحسب
    ], today: today);
    expect(buckets.map((b) => b.label), ['0–30 يوم', '31–60 يوم', '61–90 يوم', 'أكثر من 90 يوم']);
    expect(buckets.map((b) => b.amount), [300, 700, 1100, 1500]);
    expect(buckets.map((b) => b.count), [2, 2, 2, 2]);
  });

  test('PDF: opening, movements with return items, closing and aging, all glyphs in the Arabic font', () async {
    final rows = [
      row('invoice', 1, '2026-01-10T09:00:00', 2000, number: '88', items: 12),
      row('payment', 2, '2026-02-10T09:00:00', -500, invoiceId: 1, number: '88', invoiceAt: '2026-01-10T09:00:00'),
      {
        ...row('return', 3, '2026-03-05T09:00:00', -300, invoiceId: 1, number: '88', invoiceAt: '2026-01-10T09:00:00'),
        'items': [
          {'trade_name': 'Panadol 500', 'quantity': 3, 'credited_quantity': 2, 'credit_amount': 300},
        ],
      },
      row('refund', 4, '2026-03-06T09:00:00', 100),
    ];
    final statement = buildSupplierStatement(rows, StatementPeriod.custom(DateTime(2026, 2, 1), DateTime(2026, 3, 31)));
    final data = SupplierStatementPdfData.from(
      statement,
      pharmacyName: 'صيدلية الشفاء',
      supplierName: 'مذخر النور',
      aging: computeAging([
        {'invoice_date': '2026-01-10', 'remaining_amount': 1200},
      ], today: DateTime(2026, 3, 31)),
      now: DateTime(2026, 3, 31, 10),
    );
    expect(data.rows.first.last, 'عليك 2,000'); // الرصيد الافتتاحي
    expect(data.rows.last, ['', '', '', 'الإجمالي', '100', '800', 'عليك 1,300']);
    expect(data.closingText, 'الرصيد الختامي: عليك 1,300');
    expect(data.rows[2][3], contains('Panadol 500 × 3 (1 بلا رصيد)'));
    expect(data.fileName, 'كشف_حساب_مذخر_النور_2026-03-31.pdf');

    final logs = <String>[];
    final bytes = await runZoned(
      () async => buildSupplierStatementPdf(SupplierStatementPdfInput(
        data,
        await File(reportPdfFontRegular).readAsBytes(),
        await File(reportPdfFontBold).readAsBytes(),
      )),
      zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => logs.add(line)),
    );
    final raw = String.fromCharCodes(bytes);
    expect(raw.startsWith('%PDF'), isTrue);
    expect(raw, contains('Tajawal'));
    expect(logs, isEmpty, reason: logs.join('\n'));
  });

  group('local database', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    late Directory tempDir;
    final helper = DatabaseHelper.instance;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pharmacy_supplier_statement_test');
      DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
      await DatabaseHelper.resetForTesting();
      helper.setSessionMode(isOnline: false);
      final db = await helper.database;
      await db.insert('pharmacy_branch', {'id': 1, 'name': 'P', 'created_at': '2026-01-01'},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    });

    tearDown(() async {
      await DatabaseHelper.resetForTesting();
      await tempDir.delete(recursive: true);
    });

    Future<Map<String, dynamic>> list(String number, double paid, {int qty = 10}) async => helper.createPurchaseList(
          pharmacyId: 1,
          mode: PurchaseListMode.supplierList,
          warehouseId: await helper.ensureMainWarehouse(1),
          supplierName: 'مذخر',
          invoiceNumber: number,
          paidAmount: paid,
          items: [
            {'trade_name': 'Med $number', 'quantity': qty, 'buy_price': 100, 'sell_price': 150, 'expiry_date': '2030-01-31'},
          ],
        );

    test('a list saved with "paid now": the payment row follows its invoice, no intermediate credit', () async {
      final result = await list('88', 400);
      final rows = await helper.getSupplierStatementOfAccount(result['supplier_id'] as int);
      // نفس اللحظة تماماً للفاتورة ودفعتها.
      expect(rows.map((r) => r['date_time']).toSet(), hasLength(1));
      final entries = statementEntries(rows);
      expect(entries.map((e) => e.description), ['فاتورة شراء رقم 88 — 1 صنف', 'دفعة على فاتورة رقم 88']);
      expect(entries.map((e) => e.balance), [1000, 600]);
      expect(entries.every((e) => e.balance >= 0), isTrue);
    });

    test('closing balance = supplier balance with payments, returns, credit, refunds and old manual data', () async {
      final first = await list('1', 0);
      final supplierId = first['supplier_id'] as int;
      final invoiceId = first['purchase_invoice_id'] as int;
      final item = (await helper.getPurchaseInvoiceItems(invoiceId)).single;
      await helper.addPurchaseInvoicePayment(pharmacyId: 1, supplierId: supplierId, purchaseInvoiceId: invoiceId, amount: 250);
      // 8 × 100 = 800 مقابل متبقٍّ 750 → 50 رصيد لصالح الصيدلية.
      await helper.returnPurchaseItems(pharmacyId: 1, purchaseInvoiceId: invoiceId, lines: [
        {'purchase_invoice_item_id': item['id'], 'quantity': 8},
      ]);
      await helper.receiveSupplierRefund(pharmacyId: 1, supplierId: supplierId, amount: 20);
      await list('2', 100, qty: 5); // يُخصم الرصيد المتبقي 30 تلقائياً
      final db = await helper.database;
      // بيانات قديمة: فاتورة يدوية مدفوع منها 200 بلا سطر دفعة، ودفعة غير مرتبطة.
      await db.insert('purchase_invoice', {
        'pharmacy_id': 1, 'supplier_id': supplierId, 'invoice_number': 'M-1', 'total_amount': 500, 'paid_amount': 200,
        'remaining_debt': 300, 'created_at': '2026-01-02T08:00:00',
      });
      await db.insert('supplier_payment', {
        'pharmacy_id': 1, 'supplier_id': supplierId, 'amount_paid': 50, 'paid_at': '2026-01-03T08:00:00',
      });

      final statement = buildSupplierStatement(
          await helper.getSupplierStatementOfAccount(supplierId), const StatementPeriod.all());
      final balance = ((await helper.getSuppliersWithFinancials(1)).single['balance'] as num).toDouble();
      expect(statement.closing, closeTo(balance, 0.001));
      expect(statement.entries.last.balance, closeTo(balance, 0.001));
      final descriptions = statement.entries.map((e) => e.description).toList();
      expect(descriptions, containsAll([
        'دفعة عند إدخال فاتورة رقم M-1',
        'دفعة للمذخر',
        'استرجاع أصناف من فاتورة رقم 1 (1 صنف)',
        'خصم من رصيد سابق على فاتورة رقم 2: 30 د.ع',
        'استلام أموال من المذخر',
      ]));
      final credit = statement.entries.singleWhere((e) => e.type == StatementEntryType.creditApplied);
      expect(credit.increase - credit.decrease, 0);
      // "خصم من رصيد سابق" لا يغيّر الرصيد الجاري.
      final i = statement.entries.indexOf(credit);
      expect(credit.balance, statement.entries[i - 1].balance);
    });
  });
}
