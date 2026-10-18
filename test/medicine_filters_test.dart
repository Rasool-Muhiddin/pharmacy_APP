import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/repository/medicine_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// بحث وفلتر فئة شاشة المخزون (على الجدول المحلي في الوضعين — أونلاين هو
/// كاش كامل لمخزون الخادم بعد المزامنة).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pharmacyId = 1;
  const base = DatabaseHelper.localIdBase;
  late Directory tempDir;
  final helper = DatabaseHelper.instance;
  final repo = MedicineRepository.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_medicine_filters_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);

    final db = await helper.database;
    await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': '2026-10-01T00:00:00'});
    for (final (i, isMain) in [(0, 1), (1, 0)]) {
      await db.insert('warehouses', {'id': base + i, 'pharmacy_id': pharmacyId, 'name': 'W$i', 'is_main': isMain, 'created_at': '2026-10-01T00:00:00'});
    }
    final medicines = [
      ('Panadol', 'Paracetamol', 'tablet', 0, '111'),
      ('Panadol Syrup', 'Paracetamol', 'syrup', 0, '222'),
      ('Augmentin', 'Amoxicillin', 'tablet', 0, '333'),
      ('Bandage', null, null, 0, null),
      ('Ceftriaxone', 'Ceftriaxone', 'injection', 1, '444'),
    ];
    for (final (i, (name, scientific, category, warehouse, barcode)) in medicines.indexed) {
      await db.insert('medicine', {
        'id': base + i,
        'pharmacy_id': pharmacyId,
        'warehouse_id': base + warehouse,
        'trade_name': name,
        'scientific_name': scientific,
        'category': category,
        'barcode': barcode,
      });
    }
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<List<String>> names({String search = '', String? category, int? warehouseId = base}) async {
    final rows = await repo.getMedicines(
      pharmacyId: pharmacyId,
      isOnlineMode: false,
      warehouseId: warehouseId,
      search: search,
      category: category,
    );
    return [for (final r in rows) r['trade_name'] as String];
  }

  test('search matches trade name, scientific name or barcode', () async {
    expect(await names(search: 'pana'), ['Panadol', 'Panadol Syrup']);
    expect(await names(search: 'amoxi'), ['Augmentin']);
    expect(await names(search: '333'), ['Augmentin']);
    expect(await names(search: '  '), hasLength(4));
  });

  test('category filter combines with search and warehouse', () async {
    expect(await names(category: 'tablet'), ['Augmentin', 'Panadol']);
    expect(await names(category: 'tablet', search: 'pana'), ['Panadol']);
    expect(await names(category: ''), ['Bandage']);
    expect(await names(category: 'injection'), isEmpty);
    expect(await names(category: 'injection', warehouseId: base + 1), ['Ceftriaxone']);
  });

  test('categories list only what exists in the warehouse', () async {
    expect(await repo.getCategories(pharmacyId: pharmacyId, warehouseId: base), unorderedEquals(['tablet', 'syrup', '']));
    expect(await repo.getCategories(pharmacyId: pharmacyId), unorderedEquals(['tablet', 'syrup', '', 'injection']));
  });
}
