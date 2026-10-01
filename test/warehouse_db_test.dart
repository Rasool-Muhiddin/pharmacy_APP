import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/subscription_plan.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const int pharmacyId = 1;

/// مخطط v6 كما كان على أجهزة العملاء قبل تعدد المخازن (barcode UNIQUE، بلا
/// warehouse_id، بلا جداول مخازن).
Future<void> createV6Schema(Database db) async {
  await db.execute('CREATE TABLE pharmacy_branch(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL)');
  await db.execute('CREATE TABLE user_profile(id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, pharmacy_id INTEGER NOT NULL, is_owner INTEGER NOT NULL DEFAULT 0, FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id))');
  await db.execute('CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE, password TEXT NOT NULL, full_name TEXT)');
  await db.execute('''
    CREATE TABLE medicine(
      id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, trade_name TEXT NOT NULL,
      scientific_name TEXT, category TEXT, quantity INTEGER NOT NULL DEFAULT 0 CHECK(quantity >= 0),
      buy_price REAL NOT NULL DEFAULT 0, sell_price REAL NOT NULL DEFAULT 0, expiry_date TEXT,
      shelf_location TEXT, is_damaged INTEGER DEFAULT 0, barcode TEXT UNIQUE, last_synced_at TEXT,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id))
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
      id INTEGER PRIMARY KEY AUTOINCREMENT, invoice_id INTEGER NOT NULL, trade_name TEXT NOT NULL,
      medicine_id INTEGER NOT NULL, quantity INTEGER NOT NULL, unit_price REAL NOT NULL, total_price REAL NOT NULL,
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
  await db.execute('CREATE INDEX idx_barcode ON medicine(barcode);');
  await db.execute('CREATE INDEX idx_trade_name ON medicine(trade_name);');
  await db.execute('CREATE INDEX idx_scientific_name ON medicine(scientific_name);');
}

Future<void> seedSale(Database db) async {
  final now = DateTime.now().toIso8601String();
  await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': now});
  await db.insert('medicine', {'id': 10, 'pharmacy_id': pharmacyId, 'trade_name': 'Panadol', 'quantity': 5, 'barcode': '111'});
  await db.insert('invoice', {'id': 1, 'pharmacy_id': pharmacyId, 'invoice_number': 'INV-000001', 'created_at': now});
  await db.insert('invoice_item', {'invoice_id': 1, 'trade_name': 'Panadol', 'medicine_id': 10, 'quantity': 1, 'unit_price': 1, 'total_price': 1});
}

Future<Database> openFixture(String path, int version, Future<void> Function(Database) build) async {
  final db = await databaseFactoryFfi.openDatabase(path);
  await db.execute('PRAGMA foreign_keys = ON');
  await build(db);
  await db.setVersion(version);
  await db.close();
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final helper = DatabaseHelper.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_db_test');
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
    await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': DateTime.now().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return db;
  }

  Future<int> addMedicine(Database db, int warehouseId, String name, int qty, {String? barcode}) {
    return db.insert('medicine', {
      'pharmacy_id': pharmacyId,
      'warehouse_id': warehouseId,
      'trade_name': name,
      'quantity': qty,
      'barcode': barcode,
    });
  }

  Future<int?> qtyOf(Database db, int id) async {
    final rows = await db.query('medicine', columns: ['quantity'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first['quantity'] as int;
  }

  group('upgrades', () {
    test('v6 -> v9 keeps sales history (FK), assigns main warehouse, moves ids to the local range', () async {
      await openFixture(DatabaseHelper.databasePathOverride!, 6, (db) async {
        await createV6Schema(db);
        await seedSale(db);
      });

      final db = await helper.database;
      // المعرّف المحلي القديم 10 أصبح 10 + localIdBase، ومعه مرجع الفاتورة.
      const localMed = DatabaseHelper.localIdBase + 10;
      final medicine = (await db.query('medicine', where: 'id = ?', whereArgs: [localMed])).single;
      final mainId = await helper.getMainWarehouseId(pharmacyId, syncedOnly: false);
      expect(mainId, isNotNull);
      expect(medicine['warehouse_id'], mainId);
      expect((await db.query('invoice_item')).single['medicine_id'], localMed);
      expect((await db.query('invoice_item')).single['invoice_id'], DatabaseHelper.localIdBase + 1);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      // القيود أُعيد تفعيلها بعد الترقية (onOpen)
      expect((await db.rawQuery('PRAGMA foreign_keys')).single.values.single, 1);
      expect(await db.rawQuery("SELECT 1 FROM sqlite_master WHERE name = 'pharmacy_links'"), isEmpty);
      // سجل النقل بالمخطط الجديد يعمل بعد الترقية
      final w2 = await helper.addWarehouse(pharmacyId: pharmacyId, name: 'W2', maxWarehouses: 2);
      await helper.transferStock(sourceMedicineId: localMed, toWarehouseId: w2, quantity: 5);
      expect(await qtyOf(db, localMed), 0); // له سجل مبيعات فيبقى بكمية صفر
    });

    test('v7 -> v9 migrates old stock_transfers and drops pharmacy_links', () async {
      await openFixture(DatabaseHelper.databasePathOverride!, 7, (db) async {
        final now = DateTime.now().toIso8601String();
        // مخطط v7 = مخطط v6 + جداول المخازن/الربط/النقل + medicine.warehouse_id.
        await createV6Schema(db);
        await db.execute('ALTER TABLE medicine ADD COLUMN warehouse_id INTEGER');
        await db.execute('CREATE TABLE warehouses(id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id INTEGER NOT NULL, name TEXT NOT NULL, is_main INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id))');
        await db.execute('CREATE TABLE pharmacy_links(id INTEGER PRIMARY KEY AUTOINCREMENT, pharmacy_id_a INTEGER NOT NULL, pharmacy_id_b INTEGER NOT NULL, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE stock_transfers(id INTEGER PRIMARY KEY AUTOINCREMENT, from_warehouse_id INTEGER NOT NULL, to_warehouse_id INTEGER NOT NULL, trade_name TEXT NOT NULL, barcode TEXT, quantity INTEGER NOT NULL CHECK(quantity > 0), transferred_at TEXT NOT NULL, notes TEXT, FOREIGN KEY(from_warehouse_id) REFERENCES warehouses(id), FOREIGN KEY(to_warehouse_id) REFERENCES warehouses(id))');
        await db.execute('CREATE INDEX idx_stock_transfers_from ON stock_transfers(from_warehouse_id);');
        await db.execute('CREATE INDEX idx_stock_transfers_to ON stock_transfers(to_warehouse_id);');
        await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': now});
        await db.insert('warehouses', {'id': 1, 'pharmacy_id': pharmacyId, 'name': 'Main', 'is_main': 1, 'created_at': now});
        await db.insert('warehouses', {'id': 2, 'pharmacy_id': pharmacyId, 'name': 'Second', 'is_main': 0, 'created_at': now});
        await db.insert('pharmacy_links', {'pharmacy_id_a': 1, 'pharmacy_id_b': 2, 'created_at': now});
        await db.insert('stock_transfers', {'from_warehouse_id': 1, 'to_warehouse_id': 2, 'trade_name': 'X', 'quantity': 3, 'transferred_at': now});
      });

      final db = await helper.database;
      expect(await db.rawQuery("SELECT 1 FROM sqlite_master WHERE name IN ('pharmacy_links', 'stock_transfers_v7')"), isEmpty);
      final transfers = await helper.getStockTransfers(pharmacyId);
      expect(transfers, hasLength(1));
      expect(transfers.single['from_warehouse_name'], 'Main');
      expect(transfers.single['to_warehouse_name'], 'Second');
      final columns = (await db.rawQuery('PRAGMA table_info(warehouses)')).map((c) => c['name']);
      expect(columns, contains('last_synced_at'));
    });
  });

  group('offline warehouses', () {
    test('limit, unique names and main-warehouse protection', () async {
      await freshDb();
      final mainId = await helper.ensureMainWarehouse(pharmacyId);
      expect(await helper.ensureMainWarehouse(pharmacyId), mainId); // لا رئيسي ثانٍ

      await helper.addWarehouse(pharmacyId: pharmacyId, name: 'W2', maxWarehouses: 3);
      expect(() => helper.addWarehouse(pharmacyId: pharmacyId, name: ' w2 ', maxWarehouses: 3), throwsStateError);
      await helper.addWarehouse(pharmacyId: pharmacyId, name: 'W3', maxWarehouses: 3);
      expect(() => helper.addWarehouse(pharmacyId: pharmacyId, name: 'W4', maxWarehouses: 3), throwsStateError);
      expect(() => helper.deleteWarehouse(mainId), throwsStateError);
      expect(await helper.getWarehouses(pharmacyId), hasLength(3));
    });

    test('transfer merges by barcode, creates rows, removes empty unreferenced source', () async {
      final db = await freshDb();
      final mainId = await helper.ensureMainWarehouse(pharmacyId);
      final w2 = await helper.addWarehouse(pharmacyId: pharmacyId, name: 'W2', maxWarehouses: 2);
      final src = await addMedicine(db, w2, 'A', 10, barcode: '111');
      final dst = await addMedicine(db, mainId, 'A', 3, barcode: '111');
      final noBarcode = await addMedicine(db, w2, 'B', 4);

      await helper.transferStock(sourceMedicineId: src, toWarehouseId: mainId, quantity: 4);
      expect(await qtyOf(db, src), 6);
      expect(await qtyOf(db, dst), 7);

      await helper.transferStock(sourceMedicineId: src, toWarehouseId: mainId, quantity: 6);
      expect(await qtyOf(db, src), isNull);
      expect(await qtyOf(db, dst), 13);

      await helper.transferStock(sourceMedicineId: noBarcode, toWarehouseId: mainId, quantity: 4);
      final created = await db.query('medicine', where: 'warehouse_id = ? AND trade_name = ?', whereArgs: [mainId, 'B']);
      expect(created.single['quantity'], 4);

      expect(() => helper.transferStock(sourceMedicineId: dst, toWarehouseId: w2, quantity: 99), throwsStateError);
      expect(() => helper.transferStock(sourceMedicineId: dst, toWarehouseId: mainId, quantity: 1), throwsStateError);
      expect(await helper.getStockTransfers(pharmacyId), hasLength(3));
    });

    test('cannot transfer to another pharmacy warehouse', () async {
      final db = await freshDb();
      await db.insert('pharmacy_branch', {'id': 2, 'name': 'Other', 'created_at': DateTime.now().toIso8601String()});
      final mainId = await helper.ensureMainWarehouse(pharmacyId);
      final otherMain = await helper.ensureMainWarehouse(2);
      final med = await addMedicine(db, mainId, 'A', 5);
      expect(() => helper.transferStock(sourceMedicineId: med, toWarehouseId: otherMain, quantity: 1), throwsStateError);
    });

    test('delete warehouse: rejects stock, keeps transfer history', () async {
      final db = await freshDb();
      final mainId = await helper.ensureMainWarehouse(pharmacyId);
      final w2 = await helper.addWarehouse(pharmacyId: pharmacyId, name: 'W2', maxWarehouses: 2);
      final med = await addMedicine(db, w2, 'A', 2);

      expect(() => helper.deleteWarehouse(w2), throwsStateError);
      await helper.transferStock(sourceMedicineId: med, toWarehouseId: mainId, quantity: 2);
      await helper.deleteWarehouse(w2);

      expect(await helper.getWarehouses(pharmacyId), hasLength(1));
      final history = await helper.getStockTransfers(pharmacyId);
      expect(history.single['from_warehouse_id'], isNull);
      expect(history.single['from_warehouse_name'], 'W2');
    });

    test('migration payload carries warehouses and medicine warehouse refs', () async {
      final db = await freshDb();
      final mainId = await helper.ensureMainWarehouse(pharmacyId);
      final w2 = await helper.addWarehouse(pharmacyId: pharmacyId, name: 'W2', maxWarehouses: 2);
      final med = await addMedicine(db, w2, 'A', 2);
      await helper.transferStock(sourceMedicineId: med, toWarehouseId: mainId, quantity: 1);

      final payload = await helper.getOfflineMigrationPayload(pharmacyId);
      final warehouses = payload['warehouses'] as List;
      expect(warehouses.map((w) => w['is_main']), containsAll([true, false]));
      final medicines = payload['medicines'] as List;
      expect(medicines.map((m) => m['local_warehouse_id']).toSet(), {mainId, w2});
      expect((payload['stock_transfers'] as List).single['local_to_warehouse_id'], mainId);
    });
  });

  group('online cache', () {
    setUp(() => helper.setSessionMode(isOnline: true));

    Map<String, dynamic> serverMed(int id, int warehouse, int qty) => {
          'id': id,
          'warehouse': warehouse,
          'trade_name': 'M$id',
          'quantity': qty,
          'buy_price': '1.00',
          'sell_price': '2.00',
          'barcode': null,
        };

    test('medicines are cached with their warehouse; stale synced rows removed; local rows kept', () async {
      final db = await freshDb();
      // صف أوفلاين قديم لم يُرفع بعد — يجب ألا يُمس.
      final localMain = await helper.ensureMainWarehouse(pharmacyId);
      final localMed = await addMedicine(db, localMain, 'Local', 9);

      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [
        {'id': 500, 'name': 'Main', 'is_main': true},
        {'id': 501, 'name': 'Second', 'is_main': false},
      ]);
      expect(await helper.getMainWarehouseId(pharmacyId, syncedOnly: true), 500);
      expect((await helper.getWarehouses(pharmacyId, syncedOnly: true)).map((w) => w['id']), [500, 501]);

      await helper.replaceMedicinesCache(pharmacyId: pharmacyId, serverItems: [
        serverMed(900, 500, 5),
        serverMed(901, 501, 7),
      ]);
      expect(await helper.getMedicines(pharmacyId, warehouseId: 501), hasLength(1));
      expect(await qtyOf(db, 901), 7);

      // 901 نُقل بالكامل على الخادم (حُذف هناك) → يُزال من الكاش
      await helper.replaceMedicinesCache(pharmacyId: pharmacyId, serverItems: [serverMed(900, 500, 12)]);
      expect(await qtyOf(db, 901), isNull);
      expect(await qtyOf(db, 900), 12);
      expect(await qtyOf(db, localMed), 9);

      // مخزن حُذف على الخادم يُزال من الكاش (فارغ الآن)
      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [
        {'id': 500, 'name': 'Main', 'is_main': true},
      ]);
      expect((await helper.getWarehouses(pharmacyId, syncedOnly: true)).map((w) => w['id']), [500]);
      // المخزن المحلي القديم لا يزال موجوداً
      expect(await helper.getWarehouses(pharmacyId), hasLength(1));
    });

    test('server warehouse ids never touch local (offline) warehouses', () async {
      final db = await freshDb();
      // مخزنان أوفلاين (1 رئيسي، 2 إضافي) لم يُرفعا بعد، مع صنف وسجل نقل.
      final localMain = await helper.ensureMainWarehouse(pharmacyId);
      final localSecond = await helper.addWarehouse(pharmacyId: pharmacyId, name: 'Local Second', maxWarehouses: 2);
      final med = await addMedicine(db, localMain, 'Offline', 8);
      await helper.transferStock(sourceMedicineId: med, toWarehouseId: localSecond, quantity: 3);
      expect(DatabaseHelper.isLocalId(localMain) && DatabaseHelper.isLocalId(localSecond), isTrue);

      // الخادم يعطي مخزنه الرئيسي المعرّف 2 (مثلاً من ترحيل 0008).
      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [
        {'id': 2, 'name': 'Server Main', 'is_main': true},
      ]);

      final local = await helper.getWarehouses(pharmacyId);
      expect(local.map((w) => w['name']), ['المخزن الرئيسي', 'Local Second']);
      final movedId = local.firstWhere((w) => w['name'] == 'Local Second')['id'] as int;
      expect(movedId, localSecond); // لم يتغير شيء محلياً
      expect((await db.query('medicine', where: 'warehouse_id = ?', whereArgs: [movedId])).single['quantity'], 3);
      expect((await helper.getStockTransfers(pharmacyId)).single['to_warehouse_id'], movedId);
      expect(await helper.getMainWarehouseId(pharmacyId, syncedOnly: true), 2);
      expect((await helper.getWarehouses(pharmacyId, syncedOnly: true)).single['name'], 'Server Main');
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      // حمولة الرفع الأولي لا تزال تحمل المخزن المحلي وأصنافه.
      final payload = await helper.getOfflineMigrationPayload(pharmacyId);
      expect((payload['warehouses'] as List).map((w) => w['local_id']), containsAll([localMain, movedId]));
      expect((payload['medicines'] as List).map((m) => m['local_warehouse_id']), contains(movedId));
    });

    test('applyServerTransfer updates destination and removes or zeroes the source', () async {
      final db = await freshDb();
      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [
        {'id': 500, 'name': 'Main', 'is_main': true},
        {'id': 501, 'name': 'Second', 'is_main': false},
      ]);
      await helper.replaceMedicinesCache(pharmacyId: pharmacyId, serverItems: [serverMed(900, 501, 4)]);

      await helper.applyServerTransfer(pharmacyId: pharmacyId, response: {
        'source': null,
        'source_deleted': true,
        'source_id': 900,
        'destination': serverMed(950, 500, 4),
      });
      expect(await qtyOf(db, 900), isNull);
      final dest = (await db.query('medicine', where: 'id = 950')).single;
      expect(dest['warehouse_id'], 500);
      expect(dest['quantity'], 4);

      await helper.applyServerTransfer(pharmacyId: pharmacyId, response: {
        'source': serverMed(950, 500, 1),
        'source_deleted': false,
        'source_id': 950,
        'destination': serverMed(960, 501, 3),
      });
      expect(await qtyOf(db, 950), 1);
      expect(await qtyOf(db, 960), 3);
    });
  });

  group('entitlements', () {
    test('maxWarehouses follows plan and server value', () {
      expect(SubscriptionEntitlements.fromLicense({'plan': 'basic', 'max_warehouses': 5}).maxWarehouses, 1);
      expect(SubscriptionEntitlements.fromLicense({'plan': 'gold'}).maxWarehouses, 2);
      expect(SubscriptionEntitlements.fromLicense({'plan': 'gold', 'max_warehouses': 4}).maxWarehouses, 4);
      expect(SubscriptionEntitlements.fromLicense({'plan': 'diamond', 'max_warehouses': 3}).maxWarehouses, 3);
      expect(SubscriptionEntitlements.fromLicense({'plan': 'gold'}).isLocked(AppFeature.multiWarehouse), isFalse);
      expect(SubscriptionEntitlements.basic().isLocked(AppFeature.multiWarehouse), isTrue);
    });
  });
}
