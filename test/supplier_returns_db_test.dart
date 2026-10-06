import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/purchase_list.dart';
import 'package:pharmacy_app/models/purchase_return.dart';
import 'package:pharmacy_app/repository/suppliers_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'id_strategy_test.dart' show createV8Schema;

/// استرجاع الأصناف للمذخر ورصيد الصيدلية لديه أوفلاين — نفس سيناريوهات
/// backend/pharmacy_data/tests_supplier_returns.py، وترقية v11 → v12.
const int pharmacyId = 1;
const String supplierName = 'مذخر الشفاء';

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
    tempDir = await Directory.systemTemp.createTemp('pharmacy_supplier_returns_test');
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

  Map<String, dynamic> line(String name, {int qty = 10, num? buy = 1000, num? sell = 1500, int bonus = 0}) => {
        'trade_name': name,
        'quantity': qty,
        'bonus_quantity': bonus,
        'is_free': false,
        'buy_price': buy,
        'sell_price': sell,
        'expiry_date': inDays(365),
      };

  Map<String, dynamic> freeLine(String name, int bonus, {num? sell = 10}) => {
        'trade_name': name,
        'quantity': 0,
        'bonus_quantity': bonus,
        'is_free': true,
        'sell_price': sell,
        'expiry_date': inDays(365),
      };

  Future<Map<String, dynamic>> postList(List<Map<String, dynamic>> items,
      {String supplier = supplierName, String invoice = 'F-100', double paid = 0}) async {
    return helper.createPurchaseList(
      pharmacyId: pharmacyId,
      mode: PurchaseListMode.supplierList,
      warehouseId: await helper.ensureMainWarehouse(pharmacyId),
      items: items,
      supplierName: supplier,
      invoiceNumber: invoice,
      invoiceDate: inDays(0),
      paidAmount: paid,
    );
  }

  Future<int> invoiceId(Database db, String number) async =>
      (await db.query('purchase_invoice', where: 'invoice_number = ?', whereArgs: [number])).single['id'] as int;

  Future<int> itemId(Database db, String number, String name) async => (await db.rawQuery('''
        SELECT pii.id FROM purchase_invoice_item pii JOIN purchase_invoice pi ON pi.id = pii.purchase_invoice_id
        WHERE pi.invoice_number = ? AND pii.trade_name = ?''', [number, name])).single['id'] as int;

  Future<Map<String, dynamic>> doReturn(Database db, String number, List<(String, int, num?)> lines,
      {String? notes, DateTime? date}) async {
    return helper.returnPurchaseItems(
      pharmacyId: pharmacyId,
      purchaseInvoiceId: await invoiceId(db, number),
      lines: [
        for (final (name, qty, price) in lines)
          {'purchase_invoice_item_id': await itemId(db, number, name), 'quantity': qty, 'unit_price': price},
      ],
      notes: notes,
      returnDate: date,
    );
  }

  Future<Map<String, dynamic>> figures([String name = supplierName]) async =>
      (await helper.getSuppliersWithFinancials(pharmacyId)).firstWhere((s) => s['name'] == name);

  Future<int> supplierId([String name = supplierName]) async => (await figures(name))['id'] as int;

  Future<double> statementBalance([String name = supplierName]) async {
    final rows = await helper.getSupplierStatementOfAccount(await supplierId(name));
    return DatabaseHelper.roundMoney(rows.fold<double>(0, (s, r) => s + (r['debt_added'] as num).toDouble()));
  }

  Future<void> expectBalance(num expected, [String name = supplierName]) async {
    final f = await figures(name);
    expect(f['balance'], closeTo(expected, 0.001), reason: 'balance');
    expect(f['remaining_debt'], closeTo(expected > 0 ? expected : 0, 0.001));
    expect(f['credit_balance'], closeTo(expected < 0 ? -expected : 0, 0.001));
    expect(await statementBalance(name), closeTo(expected, 0.001), reason: 'statement final balance == supplier balance');
  }

  Future<double> remaining(String number) async {
    final rows = await helper.getPurchaseInvoicesBySupplier(await supplierIdOf(number));
    return (rows.firstWhere((r) => r['invoice_number'] == number)['remaining_amount'] as num).toDouble();
  }

  Future<int> stockOf(Database db, String name) async =>
      (await db.query('medicine', where: 'trade_name = ?', whereArgs: [name])).single['quantity'] as int;

  Matcher throwsLine(int? line) => throwsA(isA<PurchaseListException>().having((e) => e.line, 'line', line));

  group('pure rules', () {
    test('returnable quantity and paid-units-first credit', () {
      expect(returnableQuantity(paidQty: 10, bonusQty: 2, alreadyReturned: 4, currentStock: 20), 8);
      expect(returnableQuantity(paidQty: 10, bonusQty: 2, alreadyReturned: 4, currentStock: 3), 3);
      expect(returnableQuantity(paidQty: 1, bonusQty: 0, alreadyReturned: 1, currentStock: 9), 0);
      expect(creditedUnits(paidQty: 10, alreadyReturned: 4, quantity: 8), 6);
      expect(creditedUnits(paidQty: 0, alreadyReturned: 0, quantity: 3), 0);
      expect(returnLineCredit(paidQty: 10, alreadyReturned: 0, quantity: 4, unitPrice: 750), 3000);
    });
  });

  test('shared parity scenario: same balances, credit, remainders and stock as the server', () async {
    final steps = ((jsonDecode(File('test/fixtures/profit_parity.json').readAsStringSync()) as Map)['supplier_returns']
        as Map)['steps'] as List;
    final db = await freshDb();
    final names = <String, String>{};
    for (final step in steps.cast<Map<String, dynamic>>()) {
      final exp = step['expect'] as Map<String, dynamic>;
      switch (step['op']) {
        case 'list':
          final lines = <Map<String, dynamic>>[];
          for (final l in (step['lines'] as List).cast<Map<String, dynamic>>()) {
            names[l['key'] as String] = l['trade_name'] as String;
            lines.add({...l..remove('key'), 'expiry_date': inDays(365)});
          }
          await postList(lines, invoice: step['invoice'] as String, paid: (step['paid'] as num).toDouble());
        case 'return':
          final result = await doReturn(db, step['invoice'] as String, [
            for (final l in (step['lines'] as List).cast<Map<String, dynamic>>())
              (names[l['key']]!, l['quantity'] as int, l['unit_price'] as num?),
          ]);
          expect(result['amount_returned'], exp['return_credit']);
          expect(result['excess_credit'], exp['return_excess']);
        case 'refund':
          await helper.receiveSupplierRefund(
              pharmacyId: pharmacyId, supplierId: await supplierId(), amount: (step['amount'] as num).toDouble());
      }
      await expectBalance(exp['balance'] as num);
      expect((await figures())['available_credit'], closeTo(exp['available_credit'] as num, 0.001), reason: '$step');
      for (final entry in ((exp['remaining'] as Map?) ?? {}).entries) {
        expect(await remaining(entry.key as String), closeTo(entry.value as num, 0.001), reason: '$step ${entry.key}');
      }
      for (final entry in ((exp['stock'] as Map?) ?? {}).entries) {
        expect(await stockOf(db, entry.key as String), entry.value, reason: '$step ${entry.key}');
      }
      for (final entry in ((exp['credit_applied'] as Map?) ?? {}).entries) {
        final rows = await db.rawQuery(
            'SELECT COALESCE(SUM(amount), 0) AS t FROM supplier_credit_application WHERE purchase_invoice_id = ?',
            [await invoiceId(db, entry.key as String)]);
        expect(rows.single['t'], closeTo(entry.value as num, 0.001));
      }
    }
    expect((await db.query('medicine', where: "trade_name = 'A'")).single['avg_cost'], 833.3333);
  });

  test('return within limits reduces stock and debt; invoice batches are taken first', () async {
    final db = await freshDb();
    final medicineId = await helper.insertMedicine({
      'pharmacy_id': pharmacyId, 'warehouse_id': await helper.ensureMainWarehouse(pharmacyId), 'trade_name': 'A',
      'quantity': 5, 'buy_price': 800, 'sell_price': 1200, 'expiry_date': inDays(30),
    });
    await postList([line('A', qty: 10, buy: 1000)]);
    await doReturn(db, 'F-100', [('A', 3, null)], notes: 'تالف بالشحن');
    expect(await stockOf(db, 'A'), 12);
    final invoice = await invoiceId(db, 'F-100');
    final batches = await db.query('medicine_batch', where: 'medicine_id = ?', whereArgs: [medicineId]);
    expect(batches.firstWhere((b) => b['purchase_invoice_id'] == invoice)['quantity'], 7);
    expect(batches.firstWhere((b) => b['purchase_invoice_id'] == null)['quantity'], 5);
    expect(await remaining('F-100'), 7000);
    await expectBalance(7000);
    final ret = (await db.query('purchase_invoice_return')).single;
    expect([ret['amount_returned'], ret['excess_credit'], ret['notes']], [3000, 0, 'تالف بالشحن']);
    final retLine = (await db.query('purchase_invoice_return_item')).single;
    expect([retLine['quantity'], retLine['credited_quantity'], retLine['unit_return_price'], retLine['credit_amount']],
        [3, 3, 1000, 3000]);
    final items = await helper.getPurchaseInvoiceItems(invoice);
    expect([items.single['returned_quantity'], items.single['current_stock']], [3, 12]);
    // بعد نفاد دفعة الفاتورة يكمل الخصم من دفعات الصنف الأخرى.
    await doReturn(db, 'F-100', [('A', 7, null)]);
    expect(await db.query('medicine_batch', where: 'medicine_id = ?', whereArgs: [medicineId]), hasLength(1));
    // كشف الحساب: سطر استرجاع واحد بمجموعه وأدويته.
    final rows = await helper.getSupplierStatementOfAccount(await supplierId());
    final returnRows = rows.where((r) => r['transaction_type'] == 'return').toList();
    expect(returnRows, hasLength(2));
    expect((returnRows.last['items'] as List).single['trade_name'], 'A');
  });

  test('return above stock or above bought-minus-returned is rejected', () async {
    final db = await freshDb();
    await postList([line('A', qty: 10, bonus: 2)]);
    final medicine = (await db.query('medicine')).single;
    await helper.completeSale(invoice: {
      'pharmacy_id': pharmacyId, 'invoice_number': 'INV-1', 'created_at': DateTime.now().toIso8601String(),
      'total_amount': 7500, 'discount': 0, 'final_amount': 7500,
    }, items: [
      {'medicine_id': medicine['id'], 'trade_name': 'A', 'quantity': 5, 'unit_price': 1500, 'total_price': 7500},
    ]);
    await expectLater(doReturn(db, 'F-100', [('A', 8, null)]), throwsLine(0)); // المخزون 7
    await doReturn(db, 'F-100', [('A', 7, null)]);
    await postList([line('A', qty: 20)], invoice: 'F-200');
    await expectLater(doReturn(db, 'F-100', [('A', 6, null)]), throwsLine(0)); // المتبقي من السطر 5
    await doReturn(db, 'F-100', [('A', 5, null)]);
    await expectLater(doReturn(db, 'F-100', [('A', 1, null)]), throwsLine(0));
    await expectLater(doReturn(db, 'F-100', [('A', 0, null)]), throwsLine(0));
  });

  test('edited price is used; returning paid + bonus credits only the paid units', () async {
    final db = await freshDb();
    await postList([line('A', qty: 10, bonus: 2)]);
    expect((await doReturn(db, 'F-100', [('A', 4, 750)]))['amount_returned'], 3000);
    expect((await doReturn(db, 'F-100', [('A', 8, null)]))['amount_returned'], 6000);
    final last = (await db.query('purchase_invoice_return_item', orderBy: 'id DESC', limit: 1)).single;
    expect([last['quantity'], last['credited_quantity']], [8, 6]);
  });

  test('free-line returns give zero credit', () async {
    final db = await freshDb();
    await postList([line('A', qty: 1, buy: 100), freeLine('Gift', 4)]);
    expect((await doReturn(db, 'F-100', [('Gift', 4, 999)]))['amount_returned'], 0);
    expect(await stockOf(db, 'Gift'), 0);
    await expectBalance(100);
  });

  test('excess settles other open invoices first, then becomes credit', () async {
    final db = await freshDb();
    await postList([line('A', qty: 10, buy: 100)], invoice: 'OLD');
    await postList([line('B', qty: 10, buy: 100)], invoice: 'NEW', paid: 1000);
    await expectBalance(1000);
    final result = await doReturn(db, 'NEW', [('B', 10, 150)]);
    expect(result['excess_credit'], 1500);
    expect(await remaining('OLD'), 0);
    expect((await figures())['available_credit'], 500);
    await expectBalance(-500);
    final app = (await db.query('supplier_credit_application')).single;
    expect([app['purchase_invoice_id'], app['amount'], app['notes']],
        [await invoiceId(db, 'OLD'), 1000, SupplierCreditNote.fromReturn]);
  });

  test('credit is applied to the next list (full and partial) and caps paid-now', () async {
    final db = await freshDb();
    await postList([line('A', qty: 10, buy: 1000)], paid: 9500);
    await doReturn(db, 'F-100', [('A', 3, null)]); // 3000 مقابل متبقٍّ 500
    await expectBalance(-2500);
    expect(await remaining('F-100'), 0);
    await expectLater(postList([line('B', qty: 1, buy: 1000)], invoice: 'F-2', paid: 1), throwsLine(null));
    expect(await db.query('medicine', where: "trade_name = 'B'"), isEmpty);
    await postList([line('B', qty: 1, buy: 1000)], invoice: 'F-2'); // خصم كامل 1000
    expect(await remaining('F-2'), 0);
    await expectBalance(-1500);
    await postList([line('C', qty: 1, buy: 2000)], invoice: 'F-3', paid: 300); // 1500 من الرصيد + 300 نقداً
    expect(await remaining('F-3'), 200);
    expect((await figures())['available_credit'], 0);
    await expectBalance(200);
    final rows = await helper.getSupplierStatementOfAccount(await supplierId());
    final applied = rows.where((r) => r['transaction_type'] == 'credit_applied').toList();
    expect(applied, hasLength(2));
    expect(applied.every((r) => r['debt_added'] == 0 && (r['reference'] as String).contains(SupplierCreditNote.previous)),
        isTrue);
  });

  test('receive refund reduces credit and can never exceed it', () async {
    final db = await freshDb();
    await postList([line('A', qty: 10, buy: 100)], paid: 1000);
    final id = await supplierId();
    Future<void> receive(double amount) =>
        helper.receiveSupplierRefund(pharmacyId: pharmacyId, supplierId: id, amount: amount, notes: 'نقداً');
    await expectLater(receive(1), throwsA(isA<PurchaseListException>()));
    await doReturn(db, 'F-100', [('A', 4, null)]);
    await expectBalance(-400);
    await expectLater(receive(401), throwsA(isA<PurchaseListException>()));
    await expectLater(receive(0), throwsA(isA<PurchaseListException>()));
    await receive(150);
    await expectBalance(-250);
    expect((await figures())['available_credit'], 250);
    await receive(250);
    await expectBalance(0);
    final rows = await helper.getSupplierStatementOfAccount(id);
    expect(rows.where((r) => r['transaction_type'] == 'refund'), hasLength(2));
  });

  test('total suppliers debt does not net one supplier credit against another debt', () async {
    final db = await freshDb();
    await postList([line('A', qty: 10, buy: 100)], paid: 1000);
    await doReturn(db, 'F-100', [('A', 4, null)]); // رصيد 400 لصالحنا
    await postList([line('B', qty: 10, buy: 100)], supplier: 'آخر', invoice: 'X');
    expect(await helper.getTotalSuppliersDebt(pharmacyId), 1000);
  });

  test('old amount-only returns and manual invoices still work', () async {
    final db = await freshDb();
    final sid = await helper.insertSupplier({'pharmacy_id': pharmacyId, 'name': 'قديم', 'created_at': inDays(0)});
    final manual = await db.insert('purchase_invoice', {
      'pharmacy_id': pharmacyId, 'supplier_id': sid, 'invoice_number': 'M1', 'total_amount': 1000, 'paid_amount': 200,
      'remaining_debt': 800, 'created_at': inDays(-3),
    });
    await db.insert('purchase_invoice_return', {
      'pharmacy_id': pharmacyId, 'supplier_id': sid, 'purchase_invoice_id': manual, 'amount_returned': 100,
      'returned_at': inDays(-2),
    });
    await expectBalance(700, 'قديم');
    expect(await helper.getPurchaseInvoiceItems(manual), isEmpty);
    await helper.addPurchaseInvoicePayment(pharmacyId: pharmacyId, supplierId: sid, purchaseInvoiceId: manual, amount: 700);
    await expectLater(
      helper.addPurchaseInvoicePayment(pharmacyId: pharmacyId, supplierId: sid, purchaseInvoiceId: manual, amount: 1),
      throwsArgumentError,
    );
    await expectBalance(0, 'قديم');
    final returnRow = (await helper.getSupplierStatementOfAccount(sid)).firstWhere((r) => r['transaction_type'] == 'return');
    expect(returnRow['items'], isEmpty);
  });

  test('a failing line rolls back the whole return', () async {
    final db = await freshDb();
    await postList([line('A', qty: 5, buy: 100), line('B', qty: 5, buy: 100)]);
    await expectLater(doReturn(db, 'F-100', [('A', 2, null), ('B', 9, null)]), throwsLine(1));
    expect([await stockOf(db, 'A'), await stockOf(db, 'B')], [5, 5]);
    expect(await db.query('purchase_invoice_return'), isEmpty);
    expect(await db.query('purchase_invoice_return_item'), isEmpty);
    await expectBalance(1000);
    final item = await itemId(db, 'F-100', 'A');
    await expectLater(
      helper.returnPurchaseItems(pharmacyId: pharmacyId, purchaseInvoiceId: await invoiceId(db, 'F-100'), lines: [
        {'purchase_invoice_item_id': item, 'quantity': 1},
        {'purchase_invoice_item_id': item, 'quantity': 1},
      ]),
      throwsLine(1),
    );
    await expectLater(doReturn(db, 'F-100', [('A', 1, -1)]), throwsLine(0));
    await db.delete('medicine', where: "trade_name = 'B'");
    await expectLater(doReturn(db, 'F-100', [('B', 1, null)]), throwsLine(0));
    await expectLater(doReturn(db, 'F-100', [('A', 1, null)], date: DateTime.now().add(const Duration(days: 2))),
        throwsLine(null));
  });

  test('another pharmacy\'s invoice or supplier is rejected', () async {
    final db = await freshDb();
    await postList([line('A', qty: 5, buy: 100)]);
    await expectLater(
      helper.returnPurchaseItems(pharmacyId: 2, purchaseInvoiceId: await invoiceId(db, 'F-100'), lines: [
        {'purchase_invoice_item_id': await itemId(db, 'F-100', 'A'), 'quantity': 1},
      ]),
      throwsA(isA<PurchaseListException>()),
    );
    await expectLater(
      helper.receiveSupplierRefund(pharmacyId: 2, supplierId: await supplierId(), amount: 1),
      throwsA(isA<PurchaseListException>()),
    );
    expect(await db.query('purchase_invoice_return'), isEmpty);
  });

  test('repository offline path and migration payload carry returns, credit and refunds', () async {
    final db = await freshDb();
    await postList([line('A', qty: 10, buy: 100)], paid: 1000);
    await SuppliersRepository.instance.returnPurchaseItems(
      pharmacyId: pharmacyId,
      isOnlineMode: false,
      purchaseInvoiceId: await invoiceId(db, 'F-100'),
      lines: [
        {'purchase_invoice_item_id': await itemId(db, 'F-100', 'A'), 'quantity': 4, 'unit_price': 100},
      ],
    );
    await postList([line('B', qty: 2, buy: 100)], invoice: 'F-2'); // 200 من الرصيد
    await SuppliersRepository.instance
        .receiveSupplierRefund(pharmacyId: pharmacyId, isOnlineMode: false, supplierId: await supplierId(), amount: 50);
    await expectBalance(-150);

    final payload = await helper.getOfflineMigrationPayload(pharmacyId);
    final invoices = (payload['purchase_invoices'] as List).cast<Map<String, dynamic>>();
    final f1 = invoices.firstWhere((i) => i['invoice_number'] == 'F-100');
    final ret = (f1['returns'] as List).single as Map<String, dynamic>;
    expect([ret['amount_returned'], ret['excess_credit']], [400, 400]);
    final retLine = (ret['items'] as List).single as Map<String, dynamic>;
    final itemPayload = (f1['items'] as List).single as Map<String, dynamic>;
    expect(retLine['local_purchase_invoice_item_id'], itemPayload['local_id']);
    expect(retLine['quantity'], 4);
    final f2 = invoices.firstWhere((i) => i['invoice_number'] == 'F-2');
    expect(((f2['credit_applications'] as List).single as Map)['amount'], 200);
    expect(((payload['supplier_refunds'] as List).single as Map)['amount'], 50);
  });

  group('database upgrade', () {
    /// قاعدة v11 كما على أجهزة العملاء الآن (قبل الاسترجاع بالأصناف).
    Future<void> createV11(Database raw) async {
      await createV8Schema(raw);
      await raw.execute('ALTER TABLE medicine ADD COLUMN avg_cost REAL');
      await raw.execute('ALTER TABLE invoice_item ADD COLUMN unit_cost REAL');
      await raw.execute('ALTER TABLE damaged_medicine ADD COLUMN total_cost REAL');
      await raw.execute('''
        CREATE TABLE medicine_batch(
          id INTEGER PRIMARY KEY AUTOINCREMENT, medicine_id INTEGER NOT NULL, quantity INTEGER NOT NULL,
          expiry_date TEXT, purchase_price REAL, created_at TEXT NOT NULL, server_id INTEGER, source TEXT,
          supplier_id INTEGER, purchase_invoice_id INTEGER, supplier_name TEXT, invoice_number TEXT)
      ''');
      await raw.execute('ALTER TABLE purchase_invoice ADD COLUMN invoice_date TEXT');
      await raw.execute("ALTER TABLE purchase_invoice ADD COLUMN source TEXT NOT NULL DEFAULT 'manual'");
      await raw.execute('ALTER TABLE purchase_invoice ADD COLUMN item_count INTEGER NOT NULL DEFAULT 0');
      // جدول الاسترجاع بقيد v11 القديم (amount_returned > 0).
      await raw.execute('DROP TABLE purchase_invoice_return');
      await raw.execute('''
        CREATE TABLE purchase_invoice_return(
          id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, supplier_id INTEGER NOT NULL,
          purchase_invoice_id INTEGER NOT NULL, amount_returned REAL NOT NULL CHECK(amount_returned > 0),
          notes TEXT, returned_at TEXT NOT NULL)
      ''');
      await raw.execute('''
        CREATE TABLE purchase_invoice_item(
          id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, purchase_invoice_id INTEGER NOT NULL,
          medicine_id INTEGER, trade_name TEXT NOT NULL, quantity INTEGER NOT NULL DEFAULT 0,
          bonus_quantity INTEGER NOT NULL DEFAULT 0, buy_price REAL NOT NULL DEFAULT 0,
          effective_unit_cost REAL NOT NULL DEFAULT 0, sell_price REAL NOT NULL DEFAULT 0, expiry_date TEXT,
          line_total REAL NOT NULL DEFAULT 0)
      ''');
    }

    test('v11 -> v12: every supplier balance unchanged, old negative remainders become credit', () async {
      final raw = await databaseFactoryFfi.openDatabase(DatabaseHelper.databasePathOverride!);
      await createV11(raw);
      await raw.insert('pharmacy_branch', {'id': 1, 'name': 'P', 'created_at': inDays(0)});
      for (final s in [
        {'id': 1, 'name': 'سالب مع فواتير مفتوحة'},
        {'id': 2, 'name': 'سالب فقط'},
        {'id': 3, 'name': 'عادي'},
      ]) {
        await raw.insert('pharmacy_supplier', {...s, 'pharmacy_id': 1});
      }
      Future<void> invoice(int id, int supplier, String number, num total, num paid, String date, List<num> returns) async {
        await raw.insert('purchase_invoice', {
          'id': id, 'pharmacy_id': 1, 'supplier_id': supplier, 'invoice_number': number, 'total_amount': total,
          'paid_amount': paid, 'remaining_debt': total - paid, 'created_at': date,
        });
        for (var i = 0; i < returns.length; i++) {
          await raw.insert('purchase_invoice_return', {
            'pharmacy_id': 1, 'supplier_id': supplier, 'purchase_invoice_id': id, 'amount_returned': returns[i],
            'returned_at': '${date}T1$i:00:00', // الأحدث = آخر استرجاع في القائمة
          });
        }
      }

      await invoice(1, 1, 'A', 1000, 900, '2026-01-01', [150, 200]); // متبقٍّ −250
      await invoice(2, 1, 'B', 500, 400, '2026-01-10', []); // مفتوحة 100
      await invoice(3, 1, 'C', 300, 0, '2026-01-20', []); // مفتوحة 300
      await invoice(4, 2, 'D', 100, 100, '2026-02-01', [40]); // متبقٍّ −40
      await raw.insert('supplier_payment', {
        'pharmacy_id': 1, 'supplier_id': 2, 'purchase_invoice_id': 4, 'amount_paid': 100, 'paid_at': '2026-02-01',
      });
      await invoice(5, 3, 'E', 700, 100, '2026-03-01', [50]); // عادي 550
      // دفعة قديمة غير مرتبطة بفاتورة تبقى محسوبة.
      await raw.insert('supplier_payment', {
        'pharmacy_id': 1, 'supplier_id': 3, 'purchase_invoice_id': null, 'amount_paid': 30, 'paid_at': '2026-03-02',
      });
      await raw.setVersion(11);

      // الرصيد قبل الترقية بالصيغة القديمة: الفواتير − المدفوع − المرتجع − الدفعات غير المرتبطة.
      final before = <int, double>{};
      for (final sid in [1, 2, 3]) {
        final r = (await raw.rawQuery('''
          SELECT
            COALESCE((SELECT SUM(total_amount - paid_amount) FROM purchase_invoice WHERE supplier_id = ?), 0)
            - COALESCE((SELECT SUM(amount_returned) FROM purchase_invoice_return WHERE supplier_id = ?), 0)
            - COALESCE((SELECT SUM(amount_paid) FROM supplier_payment WHERE supplier_id = ? AND purchase_invoice_id IS NULL), 0)
            AS b''', [sid, sid, sid])).single['b'] as num;
        before[sid] = r.toDouble();
      }
      await raw.close();

      final db = await helper.database; // v11 -> v12
      expect(await db.getVersion(), 13);
      final after = {for (final s in await helper.getSuppliersWithFinancials(1)) s['id'] as int: s};
      for (final sid in [1, 2, 3]) {
        expect((after[sid]!['balance'] as num).toDouble(), closeTo(before[sid]!, 0.001), reason: 'supplier $sid');
        final rows = await helper.getSupplierStatementOfAccount(sid);
        final statement = rows.fold<double>(0, (s, r) => s + (r['debt_added'] as num).toDouble());
        expect(statement, closeTo(before[sid]!, 0.001), reason: 'statement $sid');
      }
      expect(before, {1: 150.0, 2: -40.0, 3: 520.0});
      final remainders = {
        for (final sid in [1, 2, 3])
          for (final inv in await helper.getPurchaseInvoicesBySupplier(sid))
            inv['invoice_number']: (inv['remaining_amount'] as num).toDouble(),
      };
      expect(remainders, {'A': 0.0, 'B': 0.0, 'C': 150.0, 'D': 0.0, 'E': 550.0});
      expect(after[1]!['available_credit'], 0);
      expect(after[2]!['available_credit'], 40);
      final excess = await db.query('purchase_invoice_return', where: 'purchase_invoice_id = 1', orderBy: 'id');
      expect(excess.map((r) => r['excess_credit']), [50, 200]); // الأحدث أولاً
      expect(await db.query('purchase_invoice_return'), hasLength(4)); // لا حذف
      expect((await db.query('purchase_invoice', where: 'id = 3')).single['remaining_debt'], 150);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      // القيد الجديد يقبل استرجاعاً بقيمة 0 (بونص/مجاني فقط)، والجداول الجديدة موجودة.
      await db.insert('purchase_invoice_return', {
        'pharmacy_id': 1, 'supplier_id': 3, 'purchase_invoice_id': 5, 'amount_returned': 0, 'returned_at': inDays(0),
      });
      for (final table in ['purchase_invoice_return_item', 'supplier_credit_application', 'supplier_refund']) {
        expect(await db.query(table, limit: 1), isA<List>(), reason: table);
      }
    });

    test('fresh install has the v12 schema', () async {
      final db = await freshDb();
      final columns = (await db.rawQuery('PRAGMA table_info(purchase_invoice_return)')).map((c) => c['name']);
      expect(columns, contains('excess_credit'));
      final tables = (await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")).map((r) => r['name']);
      expect(tables, containsAll(['purchase_invoice_return_item', 'supplier_credit_application', 'supplier_refund']));
    });
  });
}

/// معرّف مذخر فاتورة برقمها (للاختبارات).
Future<int> supplierIdOf(String invoiceNumber) async {
  final db = await DatabaseHelper.instance.database;
  return (await db.query('purchase_invoice', where: 'invoice_number = ?', whereArgs: [invoiceNumber])).single['supplier_id']
      as int;
}
