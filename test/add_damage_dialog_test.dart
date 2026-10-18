import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/damage_reasons.dart';
import 'package:pharmacy_app/repository/medicine_repository.dart';
import 'package:pharmacy_app/screens/add_damage_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// نافذة "نقل دواء إلى التوالف": اختيار الدواء بالبحث (لا تحميل للمخزون كاملاً)،
/// حد النتائج، تجاهل النتائج القديمة، وقائمة أسباب واحدة مع زر "إتلاف" في المخزن.
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
    tempDir = await Directory.systemTemp.createTemp('pharmacy_add_damage_dialog_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> seed() async {
    final db = await helper.database;
    await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': '2026-10-01T00:00:00'});
    await db.insert('warehouses', {'id': base, 'pharmacy_id': pharmacyId, 'name': 'الرئيسي', 'is_main': 1, 'created_at': '2026-10-01T00:00:00'});
    await db.insert('warehouses', {'id': base + 1, 'pharmacy_id': pharmacyId, 'name': 'المخزن 2', 'is_main': 0, 'created_at': '2026-10-01T00:00:00'});
    var id = base;
    Future<void> med(String name, {String? scientific, String? barcode, int qty = 10, int warehouse = base}) =>
        db.insert('medicine', {
          'id': id++,
          'pharmacy_id': pharmacyId,
          'warehouse_id': warehouse,
          'trade_name': name,
          'scientific_name': scientific,
          'barcode': barcode,
          'quantity': qty,
          'buy_price': 100,
          'sell_price': 200,
          'avg_cost': 100,
        });
    await med('Panadol', scientific: 'Paracetamol', barcode: '6281001');
    await med('Co-Panadol', scientific: 'Paracetamol');
    await med('Panadol Night', qty: 0); // بلا كمية: لا يُتلف
    await med('Augmentin', scientific: 'Amoxicillin', barcode: '5000123');
    await med('Panadol', warehouse: base + 1, qty: 4);
    for (var i = 1; i <= 25; i++) {
      await med('Vitamin ${i.toString().padLeft(2, '0')}');
    }
  }

  Future<List<String>> pick(String query) async {
    final rows = await repo.searchMedicinesForPicker(pharmacyId: pharmacyId, isOnlineMode: false, query: query);
    return [for (final r in rows) '${r['trade_name']}@${r['warehouse_name']}'];
  }

  test('picker search: name/scientific/barcode, in-stock only, prefix first, limited', () async {
    await seed();
    expect(await pick(''), isEmpty);
    expect(await pick('pana'), ['Panadol@الرئيسي', 'Panadol@المخزن 2', 'Co-Panadol@الرئيسي']);
    expect(await pick('amoxi'), ['Augmentin@الرئيسي']);
    expect(await pick('5000'), ['Augmentin@الرئيسي']);
    final vitamins = await pick('vitamin');
    expect(vitamins, hasLength(MedicineRepository.pickerLimit));
    expect(vitamins.first, 'Vitamin 01@الرئيسي');
  });

  test('one shared reason list includes expired', () {
    expect(damageReasons.keys, containsAll(['broken', 'spoiled', 'withdrawn', 'expired', 'correction', 'other']));
  });

  test('dashboard low stock covers only the given (main) warehouse', () async {
    await seed();
    final all = await helper.getLowStockMedicines(pharmacyId);
    final main = await helper.getLowStockMedicines(pharmacyId, warehouseId: base);
    expect(all.map((m) => m['warehouse_id']), contains(base + 1));
    expect(main, isNotEmpty);
    expect(main.every((m) => m['warehouse_id'] == base), isTrue);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<ValueNotifier<String?>> openDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(seed);
    final result = ValueNotifier<String?>(null);
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async =>
                  result.value = await showAddDamageDialog(context, pharmacyId: pharmacyId, isOnlineMode: false),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  Finder results() => find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
      (w.key as ValueKey<String>).value.startsWith('damage-result-'));

  testWidgets('no inventory is shown until the pharmacist types; debounced search', (tester) async {
    await openDialog(tester);
    expect(results(), findsNothing);
    expect(find.text('Panadol'), findsNothing);

    await tester.enterText(find.byKey(const Key('damage-medicine-search')), 'pana');
    await tester.pump(const Duration(milliseconds: 100));
    expect(results(), findsNothing); // قبل انتهاء مهلة 300ms
    await tester.pump(const Duration(milliseconds: 250));
    await settleIo(tester);
    expect(results(), findsNWidgets(3));
    expect(find.text('Panadol Night'), findsNothing); // بلا كمية
    expect(find.textContaining('المخزن: المخزن 2'), findsOneWidget);

    // نص أحدث يلغي البحث السابق: لا تظهر نتائج "pana" بعد كتابة "aug".
    await tester.enterText(find.byKey(const Key('damage-medicine-search')), 'pan');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byKey(const Key('damage-medicine-search')), 'aug');
    await tester.pump(const Duration(milliseconds: 350));
    await settleIo(tester);
    expect(results(), findsOneWidget);
    expect(find.text('Augmentin'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('damage-medicine-search')), 'vitamin');
    await tester.pump(const Duration(milliseconds: 350));
    await settleIo(tester);
    expect(find.textContaining('تُعرض أول ${MedicineRepository.pickerLimit} نتيجة'), findsOneWidget);
  });

  testWidgets('pick a medicine, choose "انتهاء الصلاحية" and record the damage', (tester) async {
    final result = await openDialog(tester);
    // حفظ بلا اختيار دواء مرفوض برسالة واضحة.
    await tester.tap(find.byKey(const Key('damage-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('الرجاء اختيار الدواء من نتائج البحث.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('damage-medicine-search')), 'augm');
    await tester.pump(const Duration(milliseconds: 350));
    await settleIo(tester);
    await tester.tap(find.text('Augmentin'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('damage-selected-medicine')), findsOneWidget);

    // الأسباب = القائمة المشتركة كاملة.
    await tester.tap(find.byKey(const Key('damage-reason')));
    await tester.pumpAndSettle();
    for (final label in damageReasons.values) {
      expect(find.text(label), findsWidgets);
    }
    await tester.tap(find.text('انتهاء الصلاحية').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('damage-quantity')), '11');
    await tester.tap(find.byKey(const Key('damage-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('أكبر من المتوفر في المخزن (10)'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('damage-quantity')), '3');
    await tester.tap(find.byKey(const Key('damage-confirm')));
    await settleIo(tester);
    expect(result.value, contains('تم نقل (3 قطعة) من دواء (Augmentin)'));

    final rows = await tester.runAsync(() async {
      final db = await helper.database;
      return db.rawQuery('''
        SELECT dm.reason, dm.quantity_damaged, m.quantity FROM damaged_medicine dm JOIN medicine m ON m.id = dm.medicine_id
      ''');
    });
    expect(rows, [
      {'reason': 'expired', 'quantity_damaged': 3, 'quantity': 7},
    ]);
  });
}
