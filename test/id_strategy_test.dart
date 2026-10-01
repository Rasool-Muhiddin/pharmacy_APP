import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/subscription_plan.dart';
import 'package:pharmacy_app/repository/Invoice_repository.dart';
import 'package:pharmacy_app/repository/expense_repository.dart';
import 'package:pharmacy_app/repository/medicine_repository.dart';
import 'package:pharmacy_app/repository/warehouse_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// استراتيجية المعرّفات: الصفوف المحلية (أوفلاين) >= localIdBase، صفوف كاش
/// الخادم < localIdBase. هذه الاختبارات تتحقق أن المزامنة لا تكتب أبداً فوق
/// بيانات محلية، وأن الترقية تنقل البيانات القائمة بأمان، وأن القراءة والرفع
/// والكتابة الأونلاين تحترم المصدر.
const int pharmacyId = 1;
const int b = DatabaseHelper.localIdBase;
const String today = '2026-10-01T10:00:00';

/// مخطط v8 كما هو على أجهزة العملاء قبل هذا الإصلاح (invoice_number UNIQUE،
/// والمعرّفات المحلية وكاش الخادم في نفس النطاق).
Future<void> createV8Schema(Database db) async {
  await db.execute('CREATE TABLE pharmacy_branch(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL)');
  await db.execute('CREATE TABLE user_profile(id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, pharmacy_id INTEGER NOT NULL, is_owner INTEGER NOT NULL DEFAULT 0, FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id))');
  await db.execute('CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE, password TEXT NOT NULL, full_name TEXT)');
  await db.execute('CREATE TABLE warehouses(id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, name TEXT NOT NULL, is_main INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, last_synced_at TEXT, FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id))');
  await db.execute('''
    CREATE TABLE medicine(
      id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, warehouse_id INTEGER NOT NULL,
      trade_name TEXT NOT NULL, scientific_name TEXT, category TEXT, quantity INTEGER NOT NULL DEFAULT 0 CHECK(quantity >= 0),
      buy_price REAL NOT NULL DEFAULT 0, sell_price REAL NOT NULL DEFAULT 0, expiry_date TEXT, shelf_location TEXT,
      is_damaged INTEGER DEFAULT 0, barcode TEXT, last_synced_at TEXT,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id), FOREIGN KEY(warehouse_id) REFERENCES warehouses(id))
  ''');
  await db.execute('CREATE TABLE pharmacy_supplier(id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, name TEXT NOT NULL, phone TEXT, created_at TEXT, FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id))');
  await db.execute('''
    CREATE TABLE invoice(
      id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, invoice_number TEXT NOT NULL UNIQUE,
      cashier_id INTEGER, cashier_name_synced TEXT, total_amount REAL NOT NULL DEFAULT 0, discount REAL NOT NULL DEFAULT 0,
      final_amount REAL NOT NULL DEFAULT 0, created_at TEXT NOT NULL, is_refunded INTEGER NOT NULL DEFAULT 0, last_synced_at TEXT,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id), FOREIGN KEY(cashier_id) REFERENCES user_profile(id))
  ''');
  await db.execute('''
    CREATE TABLE invoice_item(
      id INTEGER PRIMARY KEY AUTOINCREMENT, invoice_id INTEGER NOT NULL, trade_name TEXT NOT NULL, medicine_id INTEGER NOT NULL,
      quantity INTEGER NOT NULL, unit_price REAL NOT NULL, total_price REAL NOT NULL,
      FOREIGN KEY(invoice_id) REFERENCES invoice(id) ON DELETE CASCADE, FOREIGN KEY(medicine_id) REFERENCES medicine(id))
  ''');
  await db.execute('''
    CREATE TABLE damaged_medicine(
      id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, medicine_id INTEGER NOT NULL,
      quantity_damaged INTEGER NOT NULL, reason TEXT, notes TEXT, damaged_at TEXT NOT NULL,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id), FOREIGN KEY(medicine_id) REFERENCES medicine(id))
  ''');
  await db.execute('CREATE TABLE master_medicines(id INTEGER PRIMARY KEY AUTOINCREMENT, trade_name TEXT NOT NULL, scientific_name TEXT, category TEXT)');
  await db.execute('CREATE TABLE purchase_invoice(id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, supplier_id INTEGER NOT NULL, invoice_number TEXT, total_amount REAL NOT NULL DEFAULT 0, paid_amount REAL NOT NULL DEFAULT 0, remaining_debt REAL NOT NULL DEFAULT 0, created_at TEXT NOT NULL)');
  await db.execute('CREATE TABLE supplier_payment(id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, supplier_id INTEGER NOT NULL, purchase_invoice_id INTEGER, amount_paid REAL NOT NULL, notes TEXT, paid_at TEXT NOT NULL)');
  await db.execute('CREATE TABLE purchase_invoice_return(id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, supplier_id INTEGER NOT NULL, purchase_invoice_id INTEGER NOT NULL, amount_returned REAL NOT NULL, notes TEXT, returned_at TEXT NOT NULL)');
  await db.execute("CREATE TABLE expense(id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, expense_type TEXT NOT NULL, expense_date TEXT NOT NULL, amount REAL NOT NULL CHECK(amount > 0), notes TEXT NOT NULL DEFAULT '', last_synced_at TEXT)");
  await db.execute('''
    CREATE TABLE stock_transfers(
      id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, from_warehouse_id INTEGER, to_warehouse_id INTEGER,
      from_warehouse_name TEXT NOT NULL DEFAULT '', to_warehouse_name TEXT NOT NULL DEFAULT '', trade_name TEXT NOT NULL, barcode TEXT,
      quantity INTEGER NOT NULL CHECK(quantity > 0), transferred_at TEXT NOT NULL, notes TEXT,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(from_warehouse_id) REFERENCES warehouses(id) ON DELETE SET NULL,
      FOREIGN KEY(to_warehouse_id) REFERENCES warehouses(id) ON DELETE SET NULL)
  ''');
  await db.execute('CREATE INDEX idx_invoice_number ON invoice(invoice_number);');
  await db.execute('CREATE INDEX idx_invoice_date ON invoice(created_at);');
}

/// جهاز صيدلية كانت أوفلاين ثم دخلت أونلاين: بيانات محلية بمعرّفات صغيرة +
/// كاش خادم بمعرّفات صغيرة أيضاً في نفس الجداول.
Future<void> seedMixedV8(Database db) async {
  const synced = '2026-09-30T00:00:00';
  await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': today});
  await db.insert('users', {'id': 5, 'username': 'owner', 'password': '', 'full_name': 'Owner'});
  await db.insert('user_profile', {'id': 5, 'user_id': 5, 'pharmacy_id': pharmacyId, 'is_owner': 1});
  // مخازن: 1 و2 محليان، 7 كاش خادم.
  await db.insert('warehouses', {'id': 1, 'pharmacy_id': pharmacyId, 'name': 'Local Main', 'is_main': 1, 'created_at': today});
  await db.insert('warehouses', {'id': 2, 'pharmacy_id': pharmacyId, 'name': 'Local Second', 'is_main': 0, 'created_at': today});
  await db.insert('warehouses', {'id': 7, 'pharmacy_id': pharmacyId, 'name': 'Server Main', 'is_main': 1, 'created_at': today, 'last_synced_at': synced});
  // أدوية: 1 و2 محليان، 3 كاش خادم.
  await db.insert('medicine', {'id': 1, 'pharmacy_id': pharmacyId, 'warehouse_id': 1, 'trade_name': 'Local A', 'quantity': 5, 'barcode': 'L-1'});
  await db.insert('medicine', {'id': 2, 'pharmacy_id': pharmacyId, 'warehouse_id': 2, 'trade_name': 'Local B', 'quantity': 4});
  await db.insert('medicine', {'id': 3, 'pharmacy_id': pharmacyId, 'warehouse_id': 7, 'trade_name': 'Server C', 'quantity': 9, 'last_synced_at': synced});
  // فواتير: 1 محلية، 2 كاش خادم.
  await db.insert('invoice', {'id': 1, 'pharmacy_id': pharmacyId, 'invoice_number': 'INV-000001', 'cashier_id': 5, 'final_amount': 10, 'created_at': today});
  await db.insert('invoice_item', {'invoice_id': 1, 'trade_name': 'Local A', 'medicine_id': 1, 'quantity': 1, 'unit_price': 10, 'total_price': 10});
  await db.insert('invoice', {'id': 2, 'pharmacy_id': pharmacyId, 'invoice_number': 'INV-000777', 'final_amount': 30, 'created_at': today, 'last_synced_at': synced});
  await db.insert('invoice_item', {'invoice_id': 2, 'trade_name': 'Server C', 'medicine_id': 3, 'quantity': 1, 'unit_price': 30, 'total_price': 30});
  // تالف: 1 محلي (دواء محلي)، 2 كاش خادم (دواء خادم).
  await db.insert('damaged_medicine', {'id': 1, 'pharmacy_id': pharmacyId, 'medicine_id': 1, 'quantity_damaged': 1, 'damaged_at': '2026-10-01'});
  await db.insert('damaged_medicine', {'id': 2, 'pharmacy_id': pharmacyId, 'medicine_id': 3, 'quantity_damaged': 2, 'damaged_at': '2026-10-01'});
  // مصروفات: 1 محلي، 2 كاش خادم.
  await db.insert('expense', {'id': 1, 'pharmacy_id': pharmacyId, 'expense_type': 'rent', 'expense_date': '2026-10-01', 'amount': 100});
  await db.insert('expense', {'id': 2, 'pharmacy_id': pharmacyId, 'expense_type': 'power', 'expense_date': '2026-10-01', 'amount': 50, 'last_synced_at': synced});
  await db.insert('stock_transfers', {'pharmacy_id': pharmacyId, 'from_warehouse_id': 1, 'to_warehouse_id': 2, 'from_warehouse_name': 'Local Main', 'to_warehouse_name': 'Local Second', 'trade_name': 'Local B', 'quantity': 4, 'transferred_at': today});
}

Map<String, dynamic> serverMedicine(int id, int warehouse, {String name = 'Srv', int qty = 1}) => {
      'id': id,
      'warehouse': warehouse,
      'trade_name': name,
      'quantity': qty,
      'buy_price': '1.00',
      'sell_price': '2.00',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final helper = DatabaseHelper.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_id_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<Database> openV8Fixture() async {
    final raw = await databaseFactoryFfi.openDatabase(DatabaseHelper.databasePathOverride!);
    await raw.execute('PRAGMA foreign_keys = ON');
    await createV8Schema(raw);
    await seedMixedV8(raw);
    await raw.setVersion(8);
    await raw.close();
    return helper.database; // يشغّل الترقية إلى v9
  }

  Future<Database> freshDb() async {
    final db = await helper.database;
    await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': today},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return db;
  }

  Future<Map<String, Object?>?> row(Database db, String table, int id) async {
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.single;
  }

  group('v8 -> v9 upgrade of a device with mixed offline + server-cache data', () {
    test('local rows move to the local range with every reference; server rows untouched', () async {
      final db = await openV8Fixture();

      // المخازن
      expect((await row(db, 'warehouses', b + 1))!['name'], 'Local Main');
      expect((await row(db, 'warehouses', b + 2))!['name'], 'Local Second');
      expect((await row(db, 'warehouses', 7))!['name'], 'Server Main');
      expect(await row(db, 'warehouses', 1), isNull);

      // الأدوية ومخازنها
      final localA = (await row(db, 'medicine', b + 1))!;
      expect(localA['trade_name'], 'Local A');
      expect(localA['warehouse_id'], b + 1);
      expect((await row(db, 'medicine', b + 2))!['warehouse_id'], b + 2);
      final serverC = (await row(db, 'medicine', 3))!;
      expect(serverC['trade_name'], 'Server C');
      expect(serverC['warehouse_id'], 7);

      // الفواتير وأصنافها
      expect((await row(db, 'invoice', b + 1))!['invoice_number'], 'INV-000001');
      expect((await row(db, 'invoice', 2))!['invoice_number'], 'INV-000777');
      final items = await db.query('invoice_item', orderBy: 'invoice_id');
      expect(items.map((i) => [i['invoice_id'], i['medicine_id']]), [
        [2, 3],
        [b + 1, b + 1],
      ]);

      // التالف والمصروفات وسجل النقل
      expect((await row(db, 'damaged_medicine', b + 1))!['medicine_id'], b + 1);
      expect((await row(db, 'damaged_medicine', 2))!['medicine_id'], 3);
      expect((await row(db, 'expense', b + 1))!['expense_type'], 'rent');
      expect((await row(db, 'expense', 2))!['expense_type'], 'power');
      final transfer = (await db.query('stock_transfers')).single;
      expect([transfer['from_warehouse_id'], transfer['to_warehouse_id']], [b + 1, b + 2]);

      // سلامة القيود وعودة تفعيلها
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect((await db.rawQuery('PRAGMA foreign_keys')).single.values.single, 1);
      expect(await db.rawQuery('PRAGMA integrity_check'), [
        {'integrity_check': 'ok'}
      ]);
    });

    test('after upgrade: new local rows get local ids and a server sync cannot overwrite them', () async {
      final db = await openV8Fixture();

      for (final table in DatabaseHelper.sharedOriginTables) {
        final seq = (await db.rawQuery('SELECT seq FROM sqlite_sequence WHERE name = ?', [table])).single['seq'] as int;
        // seq = آخر معرّف مستخدم؛ الصف المحلي التالي يأخذ seq + 1 >= localIdBase.
        expect(seq + 1, greaterThanOrEqualTo(b), reason: table);
      }
      final newLocal = await helper.insertMedicine({
        'pharmacy_id': pharmacyId, 'warehouse_id': b + 1, 'trade_name': 'New Local', 'quantity': 1,
      });
      expect(newLocal, greaterThan(b + 2));

      // الخادم يرسل معرّفات 1 و2 (كانت تطابق الأدوية المحلية قبل الإصلاح).
      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [
        {'id': 7, 'name': 'Server Main', 'is_main': true},
      ]);
      await helper.replaceMedicinesCache(pharmacyId: pharmacyId, serverItems: [
        serverMedicine(1, 7, name: 'Server One', qty: 11),
        serverMedicine(2, 7, name: 'Server Two', qty: 22),
        serverMedicine(3, 7, name: 'Server C', qty: 9),
      ]);
      expect((await row(db, 'medicine', b + 1))!['trade_name'], 'Local A');
      expect((await row(db, 'medicine', b + 1))!['quantity'], 5);
      expect((await row(db, 'medicine', b + 2))!['trade_name'], 'Local B');
      expect((await row(db, 'medicine', 1))!['trade_name'], 'Server One');
      expect((await row(db, 'medicine', newLocal))!['trade_name'], 'New Local');
    });

    test('offline invoice numbering continues from local invoices only', () async {
      await openV8Fixture();
      // الفاتورة الخادم INV-000777 لا تؤثر على ترقيم هذا الجهاز.
      expect(await helper.generateInvoiceNumber(), 'INV-000002');
    });

    test('migration payload contains only local rows, with remapped local ids', () async {
      await openV8Fixture();
      expect(await helper.hasLocalDataWorthMigrating(pharmacyId), isTrue);
      final payload = await helper.getOfflineMigrationPayload(pharmacyId);

      expect((payload['warehouses'] as List).map((w) => w['local_id']), [b + 1, b + 2]);
      expect((payload['medicines'] as List).map((m) => [m['local_id'], m['local_warehouse_id']]), [
        [b + 1, b + 1],
        [b + 2, b + 2],
      ]);
      final invoices = payload['invoices'] as List;
      expect(invoices.map((i) => i['invoice_number']), ['INV-000001']);
      expect((invoices.single['items'] as List).single['local_medicine_id'], b + 1);
      expect((payload['damaged_medicines'] as List).single['local_medicine_id'], b + 1);
      expect((payload['expenses'] as List).single['expense_type'], 'rent');
      expect((payload['stock_transfers'] as List).single['local_to_warehouse_id'], b + 2);
    });

    test('reads are scoped by session mode: no duplicates, no mixing', () async {
      await openV8Fixture();

      helper.setSessionMode(isOnline: false);
      expect((await helper.getMedicines(pharmacyId)).map((m) => m['trade_name']), ['Local A', 'Local B']);
      expect((await helper.getInvoices(pharmacyId)).map((i) => i['invoice_number']), ['INV-000001']);
      expect((await helper.getExpenses(pharmacyId: pharmacyId)).map((e) => e['expense_type']), ['rent']);
      expect(await helper.medicineCountByPharmacy(pharmacyId), 2);
      expect(await helper.searchMedicines(pharmacyId, 'Server'), isEmpty);
      expect(await helper.getMedicineByBarcode('L-1'), isNotNull);

      helper.setSessionMode(isOnline: true);
      expect((await helper.getMedicines(pharmacyId)).map((m) => m['trade_name']), ['Server C']);
      expect((await helper.getInvoices(pharmacyId)).map((i) => i['invoice_number']), ['INV-000777']);
      expect((await helper.getExpenses(pharmacyId: pharmacyId)).map((e) => e['expense_type']), ['power']);
      expect(await helper.medicineCountByPharmacy(pharmacyId), 1);
      expect(await helper.searchMedicines(pharmacyId, 'Local'), isEmpty);
      expect(await helper.getMedicineByBarcode('L-1'), isNull);
    });
  });

  group('fresh install', () {
    test('local inserts in every shared table start at localIdBase', () async {
      final db = await freshDb();
      final wh = await helper.ensureMainWarehouse(pharmacyId);
      final med = await helper.insertMedicine({'pharmacy_id': pharmacyId, 'warehouse_id': wh, 'trade_name': 'A', 'quantity': 3});
      final exp = await helper.addExpense({'pharmacy_id': pharmacyId, 'expense_type': 't', 'expense_date': '2026-10-01', 'amount': 1});
      await helper.completeSale(
        invoice: {'pharmacy_id': pharmacyId, 'invoice_number': await helper.generateInvoiceNumber(), 'created_at': today},
        items: [{'medicine_id': med, 'trade_name': 'A', 'quantity': 1, 'unit_price': 1, 'total_price': 1}],
      );
      await helper.processDamageMedicine(medicineId: med, pharmacyId: pharmacyId, quantityToDamage: 1, reason: 'broken');

      expect(wh, b);
      expect(med, b);
      expect(exp, b);
      expect((await db.query('invoice')).single['id'], b);
      expect((await db.query('invoice')).single['invoice_number'], 'INV-000001');
      expect((await db.query('damaged_medicine')).single['id'], b);
    });

    test('server invoice with the same number as a local invoice syncs fully (items included)', () async {
      final db = await freshDb();
      final wh = await helper.ensureMainWarehouse(pharmacyId);
      final med = await helper.insertMedicine({'pharmacy_id': pharmacyId, 'warehouse_id': wh, 'trade_name': 'A', 'quantity': 3});
      await helper.completeSale(
        invoice: {'pharmacy_id': pharmacyId, 'invoice_number': 'INV-000001', 'created_at': today},
        items: [{'medicine_id': med, 'trade_name': 'A', 'quantity': 1, 'unit_price': 1, 'total_price': 1}],
      );

      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [{'id': 1, 'name': 'S', 'is_main': true}]);
      await helper.replaceMedicinesCache(pharmacyId: pharmacyId, serverItems: [serverMedicine(1, 1)]);
      await helper.replaceInvoicesCache(pharmacyId: pharmacyId, serverItems: [
        {
          'id': 1,
          'invoice_number': 'INV-000001',
          'created_at': today,
          'total_amount': '2.00',
          'discount': '0.00',
          'final_amount': '2.00',
          'cashier_display_name': 'Server cashier',
          'items': [
            {'medicine': 1, 'trade_name': 'Srv', 'quantity': 1, 'unit_price': '2.00', 'total_price': '2.00'},
          ],
        },
      ]);

      final invoices = await db.query('invoice', orderBy: 'id');
      expect(invoices.map((i) => [i['id'], i['invoice_number']]), [
        [1, 'INV-000001'],
        [b, 'INV-000001'],
      ]);
      expect((await db.query('invoice_item', where: 'invoice_id = 1')).single['medicine_id'], 1);
      expect((await db.query('invoice_item', where: 'invoice_id = ?', whereArgs: [b])).single['medicine_id'], med);

      // الفرادة ما زالت مفروضة داخل كل مصدر.
      expect(
        () => db.insert('invoice', {'pharmacy_id': pharmacyId, 'invoice_number': 'INV-000001', 'created_at': today}),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('server ids in the local range are rejected and nothing is written', () async {
      final db = await freshDb();
      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [{'id': 1, 'name': 'S', 'is_main': true}]);

      await expectLater(
        helper.replaceMedicinesCache(pharmacyId: pharmacyId, serverItems: [serverMedicine(5, 1), serverMedicine(b + 3, 1)]),
        throwsStateError,
      );
      expect(await db.query('medicine'), isEmpty); // المعاملة أُلغيت كاملة
      await expectLater(
        helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [{'id': b, 'name': 'X', 'is_main': false}]),
        throwsStateError,
      );
      await expectLater(
        helper.upsertExpenseFromServer(pharmacyId: pharmacyId, serverData: {'id': b, 'expense_type': 'x', 'expense_date': '2026-10-01', 'amount': '1'}),
        throwsStateError,
      );
    });

    test('repeated syncs are idempotent and never touch local rows', () async {
      final db = await freshDb();
      final wh = await helper.ensureMainWarehouse(pharmacyId);
      final local = await helper.insertMedicine({'pharmacy_id': pharmacyId, 'warehouse_id': wh, 'trade_name': 'Mine', 'quantity': 8});
      for (var i = 0; i < 3; i++) {
        await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [{'id': 1, 'name': 'S', 'is_main': true}]);
        await helper.replaceMedicinesCache(pharmacyId: pharmacyId, serverItems: [serverMedicine(1, 1, qty: 4), serverMedicine(2, 1)]);
      }
      expect(await db.query('medicine'), hasLength(3));
      expect((await row(db, 'medicine', local))!['quantity'], 8);
      // صف خادم حُذف على الخادم يُزال، والمحلي يبقى.
      await helper.replaceMedicinesCache(pharmacyId: pharmacyId, serverItems: [serverMedicine(1, 1, qty: 4)]);
      expect((await db.query('medicine', orderBy: 'id')).map((m) => m['id']), [1, local]);
    });
  });

  group('online writes refuse local (not yet uploaded) records before any network call', () {
    setUp(() => helper.setSessionMode(isOnline: true));
    final gold = SubscriptionEntitlements.fromLicense({'plan': 'gold'});

    test('medicine, invoice, expense and warehouse repositories', () async {
      await freshDb();
      const localId = b + 1;
      await expectLater(
        MedicineRepository.instance.updateMedicine(pharmacyId: pharmacyId, isOnlineMode: true, id: localId, data: {'quantity': 1}),
        throwsA(isA<MedicineRepositoryException>().having((e) => e.message, 'message', contains('محلي'))),
      );
      await expectLater(
        MedicineRepository.instance.deleteMedicine(isOnlineMode: true, id: localId),
        throwsA(isA<MedicineRepositoryException>()),
      );
      await expectLater(
        MedicineRepository.instance.damageMedicine(pharmacyId: pharmacyId, isOnlineMode: true, medicineId: localId, quantityToDamage: 1, reason: 'x'),
        throwsA(isA<MedicineRepositoryException>()),
      );
      await expectLater(
        MedicineRepository.instance.addMedicine(pharmacyId: pharmacyId, isOnlineMode: true, data: {'trade_name': 'x', 'warehouse_id': localId}),
        throwsA(isA<MedicineRepositoryException>()),
      );
      await expectLater(
        InvoiceRepository.instance.refund(pharmacyId: pharmacyId, isOnlineMode: true, invoiceId: localId),
        throwsA(isA<InvoiceRepositoryException>()),
      );
      await expectLater(
        InvoiceRepository.instance.checkout(
          pharmacyId: pharmacyId,
          isOnlineMode: true,
          invoice: {'discount': 0},
          items: [{'medicine_id': localId, 'quantity': 1}],
        ),
        throwsA(isA<InvoiceRepositoryException>()),
      );
      await expectLater(
        ExpenseRepository.instance.deleteExpense(isOnlineMode: true, id: localId, pharmacyId: pharmacyId),
        throwsA(isA<ExpenseRepositoryException>()),
      );
      await expectLater(
        WarehouseRepository.instance.transferStock(
          pharmacyId: pharmacyId, isOnlineMode: true, entitlements: gold,
          medicineId: localId, toWarehouseId: 1, quantity: 1,
        ),
        throwsA(isA<WarehouseRepositoryException>()),
      );
    });
  });
}
