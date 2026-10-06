import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/purchase_list.dart';
import 'package:pharmacy_app/repository/medicine_repository.dart';
import 'package:pharmacy_app/repository/suppliers_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'id_strategy_test.dart' show createV8Schema, seedMixedV8;

/// قائمة المذخر / الرصيد الافتتاحي أوفلاين (DatabaseHelper.createPurchaseList):
/// نفس سيناريوهات backend/pharmacy_data/tests_purchase_list.py، وترقية v10 → v11.
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
    tempDir = await Directory.systemTemp.createTemp('pharmacy_purchase_list_test');
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

  Future<int> mainWarehouse() => helper.ensureMainWarehouse(pharmacyId);

  Future<Map<String, Object?>> medicineNamed(Database db, String name) async =>
      (await db.query('medicine', where: 'trade_name = ?', whereArgs: [name])).single;

  Future<List<Map<String, Object?>>> batchesOf(Database db, int medicineId) =>
      db.query('medicine_batch', where: 'medicine_id = ?', whereArgs: [medicineId], orderBy: 'id');

  Future<void> expectInvariant(Database db, int medicineId) async {
    final total = (await batchesOf(db, medicineId)).fold<int>(0, (s, b) => s + (b['quantity'] as int));
    final row = (await db.query('medicine', where: 'id = ?', whereArgs: [medicineId])).single;
    expect(row['quantity'], total, reason: 'quantity must equal sum of batches');
  }

  Future<int> addExisting({String name = 'Panadol', int qty = 10, double buy = 500, double sell = 1000, String? barcode}) async {
    return helper.insertMedicine({
      'pharmacy_id': pharmacyId,
      'warehouse_id': await mainWarehouse(),
      'trade_name': name,
      'quantity': qty,
      'buy_price': buy,
      'sell_price': sell,
      'expiry_date': inDays(30),
      'barcode': barcode,
    });
  }

  Map<String, dynamic> line(String name, {int qty = 10, num? buy = 1000, num? sell = 1500, int bonus = 0, String? barcode}) => {
        'trade_name': name,
        'quantity': qty,
        'bonus_quantity': bonus,
        'is_free': false,
        'buy_price': buy,
        'sell_price': sell,
        'expiry_date': inDays(365),
        if (barcode != null) 'barcode': barcode,
      };

  Map<String, dynamic> freeLine(String name, int bonus, {num? sell}) => {
        'trade_name': name,
        'quantity': 0,
        'bonus_quantity': bonus,
        'is_free': true,
        'sell_price': sell,
        'expiry_date': inDays(365),
      };

  Future<Map<String, dynamic>> postList(
    List<Map<String, dynamic>> items, {
    String supplierName = 'مذخر الشفاء',
    int? supplierId,
    String invoiceNumber = 'F-100',
    double paid = 0,
    int? warehouseId,
  }) async {
    return helper.createPurchaseList(
      pharmacyId: pharmacyId,
      mode: PurchaseListMode.supplierList,
      warehouseId: warehouseId ?? await mainWarehouse(),
      items: items,
      supplierId: supplierId,
      supplierName: supplierId == null ? supplierName : null,
      invoiceNumber: invoiceNumber,
      invoiceDate: inDays(0),
      paidAmount: paid,
    );
  }

  Future<double> supplierDebt(String name) async {
    final rows = await helper.getSuppliersWithFinancials(pharmacyId);
    return (rows.firstWhere((r) => r['name'] == name)['remaining_debt'] as num).toDouble();
  }

  /// الرصيد التراكمي لكشف الحساب (كما يحسبه _computeRunningBalance في الشاشة).
  Future<double> statementBalance(int supplierId) async {
    final rows = await helper.getSupplierStatementOfAccount(supplierId);
    return rows.fold<double>(0, (s, r) => s + (r['debt_added'] as num).toDouble());
  }

  Future<void> sell(int medicineId, String name, int qty, double price) async {
    await helper.completeSale(
      invoice: {
        'pharmacy_id': pharmacyId,
        'invoice_number': await helper.generateInvoiceNumber(),
        'created_at': DateTime.now().toIso8601String(),
        'total_amount': qty * price,
        'discount': 0,
        'final_amount': qty * price,
      },
      items: [
        {'medicine_id': medicineId, 'trade_name': name, 'quantity': qty, 'unit_price': price, 'total_price': qty * price},
      ],
    );
  }

  Future<Map<String, num>> report() => helper.getProfitSummary(pharmacyId, start: inDays(-1), end: inDays(1));

  Matcher throwsLineError(int? line) =>
      throwsA(isA<PurchaseListException>().having((e) => e.line, 'line', line));

  group('pure rules (shared with the server)', () {
    test('effective unit cost and line total', () {
      expect(effectiveUnitCost(paidQty: 10, bonusQty: 2, buyPrice: 1000), 833.3333);
      expect(effectiveUnitCost(paidQty: 0, bonusQty: 5, buyPrice: 1000), 0);
      expect(effectiveUnitCost(paidQty: 4, bonusQty: 0, buyPrice: 250), 250);
      expect(() => effectiveUnitCost(paidQty: 0, bonusQty: 0, buyPrice: 1), throwsA(isA<PurchaseListException>()));
      expect(purchaseLineTotal(paidQty: 10, buyPrice: 1000), 10000);
    });

    test('line validation mirrors purchase_list._validate_line', () {
      final ok = line('A');
      expect(validatePurchaseLine(ok, PurchaseListMode.supplierList, isNew: true), isNull);
      expect(validatePurchaseLine({...ok, 'quantity': 0}, PurchaseListMode.supplierList, isNew: true), isNotNull);
      expect(validatePurchaseLine({...ok, 'buy_price': 0}, PurchaseListMode.supplierList, isNew: true), isNotNull);
      expect(validatePurchaseLine({...ok, 'sell_price': null}, PurchaseListMode.supplierList, isNew: false), isNotNull);
      expect(validatePurchaseLine({...ok, 'expiry_date': ''}, PurchaseListMode.supplierList, isNew: true), isNotNull);
      // مجاني: لصنف موجود سعر البيع اختياري، ولصنف جديد إلزامي.
      expect(validatePurchaseLine(freeLine('A', 2), PurchaseListMode.supplierList, isNew: false), isNull);
      expect(validatePurchaseLine(freeLine('A', 2), PurchaseListMode.supplierList, isNew: true), isNotNull);
      expect(validatePurchaseLine({...freeLine('A', 2), 'quantity': 1}, PurchaseListMode.supplierList, isNew: false), isNotNull);
      expect(validatePurchaseLine(freeLine('A', 0, sell: 5), PurchaseListMode.supplierList, isNew: true), isNotNull);
      // رصيد افتتاحي: سعر شراء 0 مقبول (غير معروف)، والبونص/المجاني مرفوضان.
      expect(validatePurchaseLine(line('A', buy: 0), PurchaseListMode.openingStock, isNew: true), isNull);
      expect(validatePurchaseLine(line('A', bonus: 1), PurchaseListMode.openingStock, isNew: true), isNotNull);
      expect(validatePurchaseLine(freeLine('A', 2, sell: 5), PurchaseListMode.openingStock, isNew: true), isNotNull);
    });

    test('totals exclude bonus and free lines from the invoice total', () {
      final totals = PurchaseListTotals.of([line('A', bonus: 2), line('B', qty: 4, buy: 250), freeLine('C', 3)]);
      expect(totals.itemCount, 3);
      expect(totals.paidQuantity, 14);
      expect(totals.bonusQuantity, 5);
      expect(totals.freeItemCount, 1);
      expect(totals.invoiceTotal, 11000);
    });

    test('expiry input accepts month/year shortcuts', () {
      expect(normalizeExpiryInput('2027-05-31'), '2027-05-31');
      expect(normalizeExpiryInput('2027-05'), '2027-05-31');
      expect(normalizeExpiryInput('05/2027'), '2027-05-31');
      expect(normalizeExpiryInput('2/28'), '2028-02-29');
      expect(normalizeExpiryInput('31/12/2026'), '2026-12-31');
      expect(normalizeExpiryInput('2027-02-30'), isNull);
      expect(normalizeExpiryInput('13/2027'), isNull);
      expect(normalizeExpiryInput('abc'), isNull);
    });
  });

  test('shared parity fixture: same stock, costs, invoice and profit as the server', () async {
    final scenario = (jsonDecode(File('test/fixtures/profit_parity.json').readAsStringSync())
        as Map<String, dynamic>)['purchase_list'] as Map<String, dynamic>;
    final db = await freshDb();
    final spec = scenario['existing'] as Map<String, dynamic>;
    await addExisting(
      name: spec['trade_name'] as String,
      qty: spec['quantity'] as int,
      buy: (spec['buy_price'] as num).toDouble(),
      sell: (spec['sell_price'] as num).toDouble(),
    );
    final lines = (scenario['lines'] as List)
        .cast<Map<String, dynamic>>()
        .map((l) => {...l..remove('note'), 'expiry_date': inDays(365)})
        .toList();
    final result = await postList(lines);
    final expected = scenario['expected'] as Map<String, dynamic>;

    final invoice = (await db.query('purchase_invoice', where: 'id = ?', whereArgs: [result['purchase_invoice_id']])).single;
    expect(invoice['total_amount'], expected['invoice_total']);
    expect(invoice['item_count'], expected['item_count']);
    final items = await db.query('purchase_invoice_item', orderBy: 'id');
    expect(items.map((i) => i['line_total']), (expected['line_totals'] as List).map((v) => (v as num).toDouble()));
    expect(items.map((i) => i['effective_unit_cost']),
        (expected['effective_unit_costs'] as List).map((v) => (v as num).toDouble()));
    expect(await supplierDebt('مذخر الشفاء'), expected['invoice_total']);

    for (final entry in (expected['medicines'] as Map<String, dynamic>).entries) {
      final exp = entry.value as Map<String, dynamic>;
      final med = await medicineNamed(db, entry.key);
      expect(med['quantity'], exp['quantity'], reason: entry.key);
      expect(med['avg_cost'], closeTo(exp['avg_cost'] as num, 0.00001), reason: entry.key);
      expect(med['buy_price'], exp['buy_price'], reason: entry.key);
      expect(med['sell_price'], exp['sell_price'], reason: entry.key);
      final costs = (await batchesOf(db, med['id'] as int)).map((b) => (b['purchase_price'] as num).toDouble()).toList()
        ..sort();
      expect(costs, (exp['batch_costs'] as List).map((c) => (c as num).toDouble()).toList(), reason: entry.key);
      await expectInvariant(db, med['id'] as int);
    }

    for (final sale in (scenario['sale'] as List).cast<Map<String, dynamic>>()) {
      final med = await medicineNamed(db, sale['medicine'] as String);
      await sell(med['id'] as int, sale['medicine'] as String, sale['quantity'] as int, (med['sell_price'] as num).toDouble());
    }
    final r = await report();
    (expected['profit'] as Map<String, dynamic>).forEach((key, value) {
      expect(r[key], closeTo(value as num, 0.0001), reason: key);
    });
  });

  test('new + existing items with bonus: stock, batches linked to supplier/invoice, invoice and debt', () async {
    final db = await freshDb();
    final existingId = await addExisting(qty: 10, buy: 500, sell: 1000);
    final result = await postList([
      line('panadol', qty: 10, buy: 1000, sell: 1500, bonus: 2), // نفس الاسم بحالة أحرف مختلفة
      line('Brufen', qty: 4, buy: 250, sell: 400, barcode: '999'),
    ]);

    final invoiceId = result['purchase_invoice_id'] as int;
    final supplierId = result['supplier_id'] as int;
    final invoice = (await db.query('purchase_invoice', where: 'id = ?', whereArgs: [invoiceId])).single;
    expect(invoice['total_amount'], 11000); // البونص خارج الإجمالي
    expect(invoice['item_count'], 2);
    expect(invoice['source'], PurchaseInvoiceSource.inventoryList);
    expect(invoice['invoice_date'], inDays(0));
    expect(invoice['remaining_debt'], 11000);

    final existing = (await db.query('medicine', where: 'id = ?', whereArgs: [existingId])).single;
    expect(existing['quantity'], 22);
    expect(existing['avg_cost'], 681.8182);
    expect(existing['sell_price'], 1500);
    expect(existing['buy_price'], 1000);
    final linked = (await batchesOf(db, existingId)).last;
    expect(linked['quantity'], 12);
    expect(linked['purchase_price'], 833.3333);
    expect(linked['supplier_id'], supplierId);
    expect(linked['purchase_invoice_id'], invoiceId);
    expect(linked['source'], BatchSource.purchaseList);
    await expectInvariant(db, existingId);

    final brufen = await medicineNamed(db, 'Brufen');
    expect([brufen['quantity'], brufen['avg_cost'], brufen['barcode']], [4, 250, '999']);
    expect(await db.query('medicine'), hasLength(2)); // لا تكرار للصنف الموجود

    final item = (await db.query('purchase_invoice_item', where: 'medicine_id = ?', whereArgs: [existingId])).single;
    expect([item['quantity'], item['bonus_quantity'], item['line_total']], [10, 2, 10000]);
    expect(await supplierDebt('مذخر الشفاء'), 11000);
    expect(await statementBalance(supplierId), 11000);

    // نافذة الدفعات: المذخر ورقم الفاتورة.
    final shown = (await helper.getMedicineBatches(existingId)).firstWhere((b) => b['purchase_invoice_id'] == invoiceId);
    expect([shown['supplier_name'], shown['invoice_number']], ['مذخر الشفاء', 'F-100']);
    // عرض الأصناف.
    final listed = await helper.getPurchaseInvoiceItems(invoiceId);
    expect(listed.map((i) => i['trade_name']), ['Panadol', 'Brufen']);
    expect((await helper.getSupplierPurchasedItems(supplierId)).first['invoice_number'], 'F-100');
  });

  test('same barcode is a supply to the existing item, not a duplicate', () async {
    final db = await freshDb();
    final id = await addExisting(name: 'X', qty: 1, buy: 10, sell: 20, barcode: '123');
    await postList([line('Other name', qty: 3, buy: 10, sell: 25, barcode: '123')]);
    expect(await db.query('medicine'), hasLength(1));
    final row = (await db.query('medicine', where: 'id = ?', whereArgs: [id])).single;
    expect([row['quantity'], row['trade_name']], [4, 'X']);
  });

  test('free line on an existing item: cost 0 in the average, invoice and debt unchanged, profit correct', () async {
    final db = await freshDb();
    final id = await addExisting(qty: 10, buy: 500, sell: 1000);
    final result = await postList([freeLine('Panadol', 5)]);
    final med = (await db.query('medicine', where: 'id = ?', whereArgs: [id])).single;
    expect(med['quantity'], 15);
    expect(med['avg_cost'], 333.3333);
    expect([med['buy_price'], med['sell_price']], [500, 1000]);
    final batch = (await batchesOf(db, id)).last;
    expect([batch['quantity'], batch['purchase_price'], batch['purchase_invoice_id']], [5, 0, result['purchase_invoice_id']]);
    final invoice = (await db.query('purchase_invoice')).single;
    expect([invoice['total_amount'], invoice['item_count']], [0, 1]);
    expect((await db.query('purchase_invoice_item')).single['quantity'], 0);
    expect(await supplierDebt('مذخر الشفاء'), 0);

    await sell(id, 'Panadol', 3, 1000);
    final r = await report();
    expect(r['cost_of_goods_sold'], 1000); // 3 × 333.3333
    expect(r['gross_profit'], 2000);
  });

  test('free line for a new item requires a sell price and creates it at known cost 0', () async {
    final db = await freshDb();
    await expectLater(postList([freeLine('Sample', 2)]), throwsLineError(0));
    expect(await db.query('medicine'), isEmpty);
    await postList([freeLine('Sample', 2, sell: 300)]);
    final med = await medicineNamed(db, 'Sample');
    expect([med['quantity'], med['avg_cost'], med['buy_price']], [2, 0, 0]);
    expect((await db.query('purchase_invoice')).single['total_amount'], 0);
  });

  test('initial payment creates a supplier payment; debt and statement balance agree', () async {
    final db = await freshDb();
    final result = await postList([line('A', qty: 10, buy: 100)], paid: 400);
    final invoiceId = result['purchase_invoice_id'] as int;
    final supplierId = result['supplier_id'] as int;
    final invoice = (await db.query('purchase_invoice')).single;
    expect([invoice['paid_amount'], invoice['remaining_debt']], [400, 600]);
    expect((await db.query('supplier_payment')).single['amount_paid'], 400);
    expect(await supplierDebt('مذخر الشفاء'), 600);
    expect(await statementBalance(supplierId), 600);

    await helper.addPurchaseInvoicePayment(
        pharmacyId: pharmacyId, supplierId: supplierId, purchaseInvoiceId: invoiceId, amount: 100);
    final itemId = (await db.query('purchase_invoice_item')).single['id'];
    await helper.returnPurchaseItems(pharmacyId: pharmacyId, purchaseInvoiceId: invoiceId, lines: [
      {'purchase_invoice_item_id': itemId, 'quantity': 1, 'unit_price': 50},
    ]);
    expect(await supplierDebt('مذخر الشفاء'), 450);
    expect(await statementBalance(supplierId), 450); // لا خصم مزدوج للدفعات/الاسترجاعات
  });

  test('no payment -> no supplier_payment row; overpayment rolls everything back', () async {
    final db = await freshDb();
    await postList([line('A')]);
    expect(await db.query('supplier_payment'), isEmpty);
    await expectLater(postList([line('B', qty: 1, buy: 100)], invoiceNumber: 'F-2', paid: 101), throwsLineError(null));
    expect(await db.query('medicine', where: "trade_name = 'B'"), isEmpty);
    expect(await db.query('purchase_invoice'), hasLength(1));
  });

  test('duplicate invoice number per supplier is rejected; typed existing name reuses the supplier', () async {
    final db = await freshDb();
    final first = await postList([line('A')]);
    await expectLater(postList([line('B')], supplierId: first['supplier_id'] as int), throwsLineError(null));
    await expectLater(postList([line('B')]), throwsLineError(null)); // نفس الاسم = نفس المذخر
    expect(await db.query('pharmacy_supplier'), hasLength(1));
    expect(await db.query('medicine', where: "trade_name = 'B'"), isEmpty);
    await postList([line('B')], supplierName: 'مذخر آخر'); // نفس الرقم لمذخر آخر
    await expectLater(postList([line('C')], invoiceNumber: '  '), throwsLineError(null));
    // الفهرس الفريد نفسه يمنع التكرار حتى لو تجاوز أحدٌ الفحص.
    await expectLater(
      db.insert('purchase_invoice', {
        'pharmacy_id': pharmacyId, 'supplier_id': first['supplier_id'], 'invoice_number': 'F-100', 'created_at': inDays(0),
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('a failing line rolls back everything and reports its index', () async {
    final db = await freshDb();
    final id = await addExisting(qty: 10, buy: 500, sell: 1000);
    await expectLater(
      postList([line('Panadol', qty: 5), line('Fresh', qty: 5), line('Broken', qty: 5, sell: 0)],
          supplierName: 'مذخر جديد', paid: 100),
      throwsLineError(2),
    );
    final med = (await db.query('medicine', where: 'id = ?', whereArgs: [id])).single;
    expect([med['quantity'], med['avg_cost']], [10, 500]);
    expect(await batchesOf(db, id), hasLength(1));
    expect(await db.query('medicine'), hasLength(1));
    for (final table in ['pharmacy_supplier', 'purchase_invoice', 'purchase_invoice_item', 'supplier_payment']) {
      expect(await db.query(table), isEmpty, reason: table);
    }
  });

  test('repository offline path saves through the same transaction', () async {
    final db = await freshDb();
    await SuppliersRepository.instance.createPurchaseList(
      pharmacyId: pharmacyId,
      isOnlineMode: false,
      warehouseId: await mainWarehouse(),
      invoiceNumber: 'R-1',
      supplierName: 'S',
      items: [line('A', qty: 2, buy: 50, sell: 80)],
      paidAmount: 20,
    );
    expect((await db.query('purchase_invoice')).single['paid_amount'], 20);
    await expectLater(
      SuppliersRepository.instance.createPurchaseList(
        pharmacyId: pharmacyId,
        isOnlineMode: false,
        warehouseId: await mainWarehouse(),
        invoiceNumber: 'R-2',
        supplierName: 'S',
        items: [line('B'), line('C', qty: 0)],
      ),
      throwsLineError(1),
    );
  });

  test('opening stock: stock and avg cost updated, no supplier, invoice, payment or debt', () async {
    final db = await freshDb();
    final id = await addExisting(qty: 10, buy: 500, sell: 1000);
    await MedicineRepository.instance.createOpeningStock(
      pharmacyId: pharmacyId,
      isOnlineMode: false,
      warehouseId: await mainWarehouse(),
      items: [line('Panadol', qty: 10, buy: 700, sell: 1200), line('Unknown cost', qty: 3, buy: 0, sell: 50)],
    );
    final med = (await db.query('medicine', where: 'id = ?', whereArgs: [id])).single;
    expect([med['quantity'], med['avg_cost'], med['sell_price']], [20, 600, 1200]);
    final opening = (await batchesOf(db, id)).last;
    expect([opening['source'], opening['supplier_id'], opening['purchase_invoice_id'], opening['purchase_price']],
        [BatchSource.openingStock, null, null, 700]);
    final unknown = await medicineNamed(db, 'Unknown cost');
    expect([unknown['quantity'], unknown['avg_cost']], [3, null]); // سعر شراء 0 = كلفة غير معروفة
    expect((await batchesOf(db, unknown['id'] as int)).single['purchase_price'], isNull);
    for (final table in ['pharmacy_supplier', 'purchase_invoice', 'purchase_invoice_item', 'supplier_payment']) {
      expect(await db.query(table), isEmpty, reason: table);
    }
    expect((await helper.getMedicineBatches(id)).last['source'], BatchSource.openingStock);

    await expectLater(
      helper.createPurchaseList(
        pharmacyId: pharmacyId,
        mode: PurchaseListMode.openingStock,
        warehouseId: await mainWarehouse(),
        items: [line('OK'), line('Bonus', bonus: 1)],
      ),
      throwsLineError(1),
    );
    expect(await db.query('medicine', where: "trade_name = 'OK'"), isEmpty);
  });

  test('stock transfer keeps the batch supplier/invoice link', () async {
    final db = await freshDb();
    final result = await postList([line('A', qty: 5)]);
    final source = await medicineNamed(db, 'A');
    final second = await helper.addWarehouse(pharmacyId: pharmacyId, name: 'Second', maxWarehouses: 2);
    await helper.transferStock(sourceMedicineId: source['id'] as int, toWarehouseId: second, quantity: 2);
    final target = (await db.query('medicine', where: 'warehouse_id = ?', whereArgs: [second])).single;
    final moved = (await batchesOf(db, target['id'] as int)).single;
    expect([moved['supplier_id'], moved['purchase_invoice_id'], moved['source']],
        [result['supplier_id'], result['purchase_invoice_id'], BatchSource.purchaseList]);
  });

  test('deleting a medicine keeps the invoice line (SET NULL + trade name snapshot)', () async {
    final db = await freshDb();
    await postList([line('A')]);
    final med = await medicineNamed(db, 'A');
    await db.delete('medicine', where: 'id = ?', whereArgs: [med['id']]);
    final item = (await db.query('purchase_invoice_item')).single;
    expect([item['medicine_id'], item['trade_name']], [null, 'A']);
  });

  test('online cache keeps the server batch source as text', () async {
    final db = await freshDb();
    helper.setSessionMode(isOnline: true);
    await db.insert('warehouses', {
      'id': 1, 'pharmacy_id': pharmacyId, 'name': 'Main', 'is_main': 1, 'created_at': inDays(0), 'last_synced_at': inDays(0),
    });
    await helper.upsertMedicineFromServer(pharmacyId: pharmacyId, serverData: {
      'id': 7, 'warehouse': 1, 'trade_name': 'A', 'quantity': 5, 'buy_price': '10.00', 'sell_price': '20.00',
      'batches': [
        {'id': 70, 'quantity': 3, 'expiry_date': inDays(90), 'purchase_price': '8.3333', 'source': 'purchase_list',
         'supplier': 4, 'supplier_name': 'S', 'purchase_invoice': 9, 'purchase_invoice_number': 'F1'},
        {'id': 71, 'quantity': 2, 'expiry_date': inDays(99), 'purchase_price': null, 'source': 'opening_stock',
         'supplier': null, 'supplier_name': null, 'purchase_invoice': null, 'purchase_invoice_number': null},
      ],
    });
    final batches = await helper.getMedicineBatches(7);
    expect(batches.map((b) => [b['supplier_name'], b['invoice_number'], b['source']]), [
      ['S', 'F1', 'purchase_list'],
      [null, null, 'opening_stock'],
    ]);
    // صفوف الكاش لا تشير لمذخر/فاتورة محليين (معرّفات الخادم مختلفة).
    expect((await db.query('medicine_batch')).every((b) => b['supplier_id'] == null && b['purchase_invoice_id'] == null),
        isTrue);
  });

  test('offline migration payload carries purchase items (with bonus) and batch links', () async {
    await freshDb();
    final result = await postList([line('A', qty: 10, buy: 1000, bonus: 2), freeLine('Gift', 3, sell: 10)]);
    await helper.createPurchaseList(
      pharmacyId: pharmacyId,
      mode: PurchaseListMode.openingStock,
      warehouseId: await mainWarehouse(),
      items: [line('Shelf', qty: 1, buy: 0, sell: 5)],
    );
    final payload = await helper.getOfflineMigrationPayload(pharmacyId);
    final invoice = (payload['purchase_invoices'] as List).single as Map<String, dynamic>;
    expect(invoice['local_id'], result['purchase_invoice_id']);
    expect([invoice['source'], invoice['item_count'], invoice['invoice_date']], ['inventory_list', 2, inDays(0)]);
    final items = (invoice['items'] as List).cast<Map<String, dynamic>>();
    expect(items.map((i) => [i['trade_name'], i['quantity'], i['bonus_quantity'], i['line_total']]), [
      ['A', 10, 2, 10000.0],
      ['Gift', 0, 3, 0.0],
    ]);
    final medicines = (payload['medicines'] as List).cast<Map<String, dynamic>>();
    final a = medicines.firstWhere((m) => m['trade_name'] == 'A');
    final batch = (a['batches'] as List).single as Map<String, dynamic>;
    expect([batch['source'], batch['local_supplier_id'], batch['local_purchase_invoice_id'], batch['purchase_price']],
        ['purchase_list', result['supplier_id'], result['purchase_invoice_id'], 833.3333]);
    final shelf = medicines.firstWhere((m) => m['trade_name'] == 'Shelf');
    expect(((shelf['batches'] as List).single as Map)['source'], 'opening_stock');
  });

  group('database upgrade', () {
    /// قاعدة v10 كما على أجهزة العملاء: مخطط v8 + إضافات v9/v10، بلا أعمدة v11.
    Future<void> createV10(Database raw) async {
      await createV8Schema(raw);
      await raw.execute('ALTER TABLE medicine ADD COLUMN avg_cost REAL');
      await raw.execute('ALTER TABLE invoice_item ADD COLUMN unit_cost REAL');
      await raw.execute('ALTER TABLE damaged_medicine ADD COLUMN total_cost REAL');
      await raw.execute('''
        CREATE TABLE medicine_batch(
          id INTEGER PRIMARY KEY AUTOINCREMENT, medicine_id INTEGER NOT NULL,
          quantity INTEGER NOT NULL CHECK(quantity >= 0), expiry_date TEXT, purchase_price REAL,
          created_at TEXT NOT NULL, server_id INTEGER,
          FOREIGN KEY(medicine_id) REFERENCES medicine(id) ON DELETE CASCADE
        )
      ''');
    }

    test('v10 -> v11: new columns and table, duplicate invoice numbers renamed, old rows keep working', () async {
      final raw = await databaseFactoryFfi.openDatabase(DatabaseHelper.databasePathOverride!);
      await createV10(raw);
      await raw.insert('pharmacy_branch', {'id': 1, 'name': 'P', 'created_at': inDays(0)});
      await raw.insert('warehouses', {'id': 1000000000001, 'pharmacy_id': 1, 'name': 'Main', 'is_main': 1, 'created_at': inDays(0)});
      await raw.insert('medicine', {
        'id': 1000000000001, 'pharmacy_id': 1, 'warehouse_id': 1000000000001, 'trade_name': 'Old', 'quantity': 4,
        'buy_price': 10, 'sell_price': 20, 'avg_cost': 10,
      });
      await raw.insert('medicine_batch',
          {'medicine_id': 1000000000001, 'quantity': 4, 'purchase_price': 10, 'created_at': inDays(-5)});
      await raw.insert('pharmacy_supplier', {'id': 1, 'pharmacy_id': 1, 'name': 'S'});
      await raw.insert('pharmacy_supplier', {'id': 2, 'pharmacy_id': 1, 'name': 'S2'});
      for (final row in [
        {'id': 1, 'supplier_id': 1, 'invoice_number': '7', 'created_at': '2026-01-01'},
        {'id': 2, 'supplier_id': 1, 'invoice_number': '7-2', 'created_at': '2026-01-02'},
        {'id': 3, 'supplier_id': 1, 'invoice_number': '7', 'created_at': '2026-01-03'},
        {'id': 4, 'supplier_id': 1, 'invoice_number': '7', 'created_at': '2026-01-04'},
        {'id': 5, 'supplier_id': 2, 'invoice_number': '7', 'created_at': '2026-01-05'},
        {'id': 6, 'supplier_id': 1, 'invoice_number': '', 'created_at': '2026-01-06'},
        {'id': 7, 'supplier_id': 1, 'invoice_number': '', 'created_at': '2026-01-07'},
      ]) {
        await raw.insert('purchase_invoice', {...row, 'pharmacy_id': 1, 'total_amount': 100, 'paid_amount': 40, 'remaining_debt': 60});
      }
      await raw.setVersion(10);
      await raw.close();

      final db = await helper.database; // v10 -> v11
      expect(await db.getVersion(), 12);
      final numbers = await db.query('purchase_invoice', columns: ['id', 'invoice_number', 'source', 'item_count'], orderBy: 'id');
      expect(numbers.map((r) => r['invoice_number']), ['7', '7-2', '7-3', '7-4', '7', '', '']);
      expect(numbers.every((r) => r['source'] == 'manual' && r['item_count'] == 0), isTrue);
      final oldBatch = (await db.query('medicine_batch')).single;
      expect([oldBatch['source'], oldBatch['supplier_id'], oldBatch['purchase_invoice_id']], [null, null, null]);
      expect(await db.query('purchase_invoice_item'), isEmpty);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      // الفواتير اليدوية القديمة تبقى تُعرض وتُحسب في الدين كما كانت.
      helper.setSessionMode(isOnline: false);
      expect(await helper.getPurchaseInvoiceItems(1), isEmpty);
      expect((await helper.getPurchaseInvoicesBySupplier(1)), hasLength(6));
      final debts = await helper.getSuppliersWithFinancials(1);
      expect(debts.firstWhere((s) => s['id'] == 1)['remaining_debt'], 360);
      expect(await statementBalance(1), 360); // 6 × (100 − 40 مدفوعة بلا سطر دفعة)

      // والقائمة الجديدة تعمل فوق القاعدة المرقّاة: توريد للصنف القديم.
      await postList([line('old', qty: 2, buy: 12, sell: 25)], supplierId: 1, invoiceNumber: 'N-1', warehouseId: 1000000000001);
      final old = (await db.query('medicine', where: "trade_name = 'Old'")).single;
      expect(old['quantity'], 6);
      await expectLater(
        postList([line('X')], supplierId: 1, invoiceNumber: '7', warehouseId: 1000000000001),
        throwsLineError(null),
      );
    });

    test('v8 -> v11 full chain: batches table created whole, columns not added twice', () async {
      final raw = await databaseFactoryFfi.openDatabase(DatabaseHelper.databasePathOverride!);
      await raw.execute('PRAGMA foreign_keys = ON');
      await createV8Schema(raw);
      await seedMixedV8(raw);
      await raw.setVersion(8);
      await raw.close();

      final db = await helper.database;
      expect(await db.getVersion(), 12);
      final columns = (await db.rawQuery('PRAGMA table_info(medicine_batch)')).map((c) => c['name']).toList();
      for (final column in ['source', 'supplier_id', 'purchase_invoice_id', 'supplier_name', 'invoice_number']) {
        expect(columns.where((c) => c == column), hasLength(1), reason: column);
      }
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    });

    test('fresh install schema matches the upgraded one', () async {
      final db = await freshDb();
      final batchColumns = (await db.rawQuery('PRAGMA table_info(medicine_batch)')).map((c) => c['name']).toSet();
      expect(batchColumns, containsAll(['source', 'supplier_id', 'purchase_invoice_id', 'supplier_name', 'invoice_number']));
      final invoiceColumns = (await db.rawQuery('PRAGMA table_info(purchase_invoice)')).map((c) => c['name']).toSet();
      expect(invoiceColumns, containsAll(['invoice_date', 'source', 'item_count']));
      final indexes = (await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'")).map((r) => r['name']);
      expect(indexes, contains('idx_purchase_invoice_number_supplier'));
    });
  });
}
