import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/services/migration_api_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// تحويل أوفلاين → أونلاين لصيدلية معرّفها على الخادم 3 (نفس معرّفها المحلي،
/// لأن pharmacy_branch.id يُؤخذ من رد desktop_login). كل البيانات أُنشئت
/// أوفلاين، ثم دخل المالك أونلاين فلم يرَ سوى كاش الخادم (فارغ).
const int pharmacyId = 3;
const int otherPharmacyId = 9;
const int b = DatabaseHelper.localIdBase;
const String today = '2026-10-02T00:20:00';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final helper = DatabaseHelper.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_migration_test');
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
    for (final id in [pharmacyId, otherPharmacyId]) {
      await db.insert('pharmacy_branch', {'id': id, 'name': 'P$id', 'created_at': today});
    }
    return db;
  }

  /// بيانات أوفلاين نموذجية لـ [pharmacyId] + صف لصيدلية أخرى على نفس الجهاز.
  Future<void> seedOfflinePharmacy(Database db) async {
    final wh = await helper.ensureMainWarehouse(pharmacyId);
    final med = await helper.insertMedicine({'pharmacy_id': pharmacyId, 'warehouse_id': wh, 'trade_name': 'Panadol', 'quantity': 10});
    await helper.addExpense({'pharmacy_id': pharmacyId, 'expense_type': 'rent', 'expense_date': '2026-10-02', 'amount': 50});
    await helper.completeSale(
      invoice: {'pharmacy_id': pharmacyId, 'invoice_number': await helper.generateInvoiceNumber(), 'created_at': today},
      items: [{'medicine_id': med, 'trade_name': 'Panadol', 'quantity': 1, 'unit_price': 2, 'total_price': 2}],
    );
    final supplier = await db.insert('pharmacy_supplier', {'pharmacy_id': pharmacyId, 'name': 'S', 'created_at': today});
    await db.insert('purchase_invoice', {'pharmacy_id': pharmacyId, 'supplier_id': supplier, 'total_amount': 100, 'created_at': today});

    final otherWh = await helper.ensureMainWarehouse(otherPharmacyId);
    await helper.insertMedicine({'pharmacy_id': otherPharmacyId, 'warehouse_id': otherWh, 'trade_name': 'Other', 'quantity': 1});
  }

  group('offline -> online conversion of the same pharmacy id', () {
    test('online session hides offline rows until they are uploaded (the "empty account" symptom)', () async {
      final db = await freshDb();
      await seedOfflinePharmacy(db);
      // أول دخول أونلاين: المخزن الرئيسي للخادم يُخزَّن كاشاً، ولا أدوية بعد.
      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [{'id': 3, 'name': 'Main', 'is_main': true}]);

      helper.setSessionMode(isOnline: false);
      expect((await helper.getMedicines(pharmacyId)).map((m) => m['trade_name']), ['Panadol']);

      helper.setSessionMode(isOnline: true);
      expect(await helper.getMedicines(pharmacyId), isEmpty);
      expect(await helper.getInvoices(pharmacyId), isEmpty);

      // البيانات ليست مفقودة: هي محلية تنتظر الرفع، والاقتراح يجب أن يظهر.
      expect(await helper.hasLocalDataWorthMigrating(pharmacyId), isTrue);
    });

    test('payload carries every offline record of this pharmacy only, never server cache or other pharmacies', () async {
      final db = await freshDb();
      await seedOfflinePharmacy(db);
      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [{'id': 3, 'name': 'Main', 'is_main': true}]);

      final payload = await helper.getOfflineMigrationPayload(pharmacyId);

      expect(payload.containsKey('pharmacy_id'), isFalse); // الخادم يحددها من الـToken
      expect((payload['warehouses'] as List).map((w) => w['local_id']), [b]);
      expect((payload['medicines'] as List).map((m) => m['trade_name']), ['Panadol']);
      expect((payload['medicines'] as List).single['local_warehouse_id'], b);
      expect((payload['invoices'] as List).single['items'], hasLength(1));
      expect((payload['expenses'] as List), hasLength(1));
      expect((payload['suppliers'] as List), hasLength(1));
      expect((payload['purchase_invoices'] as List), hasLength(1));
      // كل سجل في الحمولة ينتمي فعلاً لهذه الصيدلية محلياً.
      for (final m in payload['medicines'] as List) {
        final row = (await db.query('medicine', where: 'id = ?', whereArgs: [m['local_id']])).single;
        expect(row['pharmacy_id'], pharmacyId);
      }
    });

    test('expenses-only (or sales-only) offline data still triggers the upload suggestion', () async {
      await freshDb();
      expect(await helper.hasLocalDataWorthMigrating(pharmacyId), isFalse);
      await helper.addExpense({'pharmacy_id': pharmacyId, 'expense_type': 'rent', 'expense_date': '2026-10-02', 'amount': 50});
      expect(await helper.hasLocalDataWorthMigrating(pharmacyId), isTrue);
      expect(await helper.hasLocalDataWorthMigrating(otherPharmacyId), isFalse);
    });

    test('server cache rows alone are not offline data', () async {
      await freshDb();
      await helper.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: [{'id': 3, 'name': 'Main', 'is_main': true}]);
      expect(await helper.hasLocalDataWorthMigrating(pharmacyId), isFalse);
    });
  });

  group('shouldOfferMigration', () {
    test('migrated flag without online data (production state of the reported account) still offers upload', () {
      // ردّ الخادم الأحدث على تلك الحالة.
      expect(
        MigrationApiService.shouldOfferMigration(
            {'migrated': false, 'has_existing_online_data': false, 'can_migrate': true}),
        isTrue,
      );
      // can_migrate هو الحاسم حتى لو أرسل خادم ما migrated=true.
      expect(
        MigrationApiService.shouldOfferMigration(
            {'migrated': true, 'has_existing_online_data': false, 'can_migrate': true}),
        isTrue,
      );
    });

    test('real online data blocks the suggestion', () {
      expect(
        MigrationApiService.shouldOfferMigration(
            {'migrated': true, 'has_existing_online_data': true, 'can_migrate': false}),
        isFalse,
      );
    });

    test('older servers without can_migrate keep the previous behaviour', () {
      expect(MigrationApiService.shouldOfferMigration({'migrated': false, 'has_existing_online_data': false}), isTrue);
      expect(MigrationApiService.shouldOfferMigration({'migrated': true, 'has_existing_online_data': false}), isFalse);
      expect(MigrationApiService.shouldOfferMigration({'migrated': false, 'has_existing_online_data': true}), isFalse);
    });
  });
}
