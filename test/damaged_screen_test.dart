import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/repository/medicine_repository.dart';
import 'package:pharmacy_app/screens/damaged_screen.dart';
import 'package:pharmacy_app/widgets/stat_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// شاشة التوالف (أوفلاين): البحث بالاسم/السبب/الملاحظات على مستوى المستودع،
/// والبحث الحي في الشاشة، وخط الثيم الموحَّد، وعدم تجاوز العرض.
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
    tempDir = await Directory.systemTemp.createTemp('pharmacy_damaged_screen_test');
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
    await db.insert('warehouses', {'id': base, 'pharmacy_id': pharmacyId, 'name': 'Main', 'is_main': 1, 'created_at': '2026-10-01T00:00:00'});
    final medicines = [('Panadol', 'Paracetamol', 1000.0), ('Augmentin', 'Amoxicillin', 5000.0)];
    for (final (i, (name, scientific, price)) in medicines.indexed) {
      await db.insert('medicine', {
        'id': base + i,
        'pharmacy_id': pharmacyId,
        'warehouse_id': base,
        'trade_name': name,
        'scientific_name': scientific,
        'quantity': 50,
        // سعر شراء آخر مختلف عن المتوسط المرجّح: الخسارة تتبع الكلفة لا السعر.
        'buy_price': price * 3,
        'avg_cost': price,
      });
    }
    await helper.processDamageMedicine(
        medicineId: base, pharmacyId: pharmacyId, quantityToDamage: 2, reason: 'broken', notes: 'سقط من الرف');
    await helper.processDamageMedicine(
        medicineId: base + 1, pharmacyId: pharmacyId, quantityToDamage: 3, reason: 'spoiled', notes: 'رطوبة المخزن');
    await helper.processDamageMedicine(
        medicineId: base + 1, pharmacyId: pharmacyId, quantityToDamage: 1, reason: 'correction');
  }

  Future<List<String>> search(String text) async {
    final rows = await repo.getDamagedMedicines(pharmacyId: pharmacyId, isOnlineMode: false, search: text);
    return [for (final r in rows) '${r['trade_name']}/${r['reason']}'];
  }

  test('loss is the damage-time cost, same expression the reports sum', () async {
    await seed();
    final db = await helper.database;
    // سجل قديم بلا total_cost: الكمية × avg_cost (كما في damageCostSql والخادم).
    await db.insert('damaged_medicine', {
      'id': base + 99,
      'pharmacy_id': pharmacyId,
      'medicine_id': base,
      'quantity_damaged': 4,
      'reason': 'other',
      'damaged_at': '2026-10-01',
    });
    final rows = await repo.getDamagedMedicines(pharmacyId: pharmacyId, isOnlineMode: false);
    final losses = {for (final r in rows) '${r['trade_name']}/${r['reason']}': r['loss']};
    expect(losses, {
      'Panadol/other': 4000,
      'Augmentin/correction': 5000,
      'Augmentin/spoiled': 15000,
      'Panadol/broken': 2000,
    });
    final reportTotal = (await db.rawQuery('''
      SELECT SUM(${DatabaseHelper.damageCostSql}) AS t
      FROM damaged_medicine dm LEFT JOIN medicine m ON m.id = dm.medicine_id
      WHERE COALESCE(dm.reason, '') != 'correction'
    ''')).first['t'];
    expect(reportTotal, 21000);
  });

  test('search matches medicine names, reason label or key, and notes', () async {
    await seed();
    expect(await search(''), hasLength(3));
    expect(await search('pana'), ['Panadol/broken']);
    expect(await search('amoxi'), ['Augmentin/correction', 'Augmentin/spoiled']);
    // السبب بنصه العربي كما يُعرض (المخزَّن مفتاح إنجليزي) أو بمفتاحه.
    expect(await search('سوء خزن'), ['Augmentin/spoiled']);
    expect(await search('كسر'), ['Panadol/broken']);
    expect(await search('correction'), ['Augmentin/correction']);
    expect(await search('رطوبة'), ['Augmentin/spoiled']);
    expect(await search('nothing'), isEmpty);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(WidgetTester tester, {Size size = const Size(1600, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(seed);
    await tester.pumpWidget(const MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: DamagedScreen(pharmacyId: pharmacyId, isOnlineMode: false),
      ),
    ));
    await settleIo(tester);
  }

  Finder card(String text) => find.descendant(of: find.byType(StatCard), matching: find.text(text));

  testWidgets('live search filters without Enter, updates cards, and clears', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Panadol'), findsOneWidget);
    expect(find.text('Augmentin'), findsNWidgets(2));
    // الخسائر: 2 × 1000 + 3 × 5000 (التصحيح لا يُحتسب).
    expect(card('17,000 د.ع'), findsOneWidget);
    expect(find.text('مسح الفلاتر'), findsNothing);

    await tester.enterText(find.byType(TextField), 'سوء');
    await tester.pump(const Duration(milliseconds: 100));
    // قبل انتهاء مهلة 300ms لا يتغير شيء.
    expect(find.text('Panadol'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    await settleIo(tester);
    expect(find.text('Panadol'), findsNothing);
    expect(find.text('Augmentin'), findsOneWidget);
    expect(card('15,000 د.ع'), findsOneWidget);
    expect(card('1 عملية إتلاف'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 350));
    await settleIo(tester);
    expect(find.text('لا توجد سجلات إتلاف مطابقة للبحث.'), findsOneWidget);

    await tester.tap(find.text('مسح الفلاتر'));
    await settleIo(tester);
    expect(find.text('Panadol'), findsOneWidget);
    expect(card('3 عملية إتلاف'), findsOneWidget);
  });

  test('no hardcoded Tajawal font family in the UI: text inherits the theme font', () {
    // 'Tajawal' غير مسجّل كعائلة خط في pubspec (ملفاته لتقارير PDF فقط، تُحمَّل
    // بمسارها في report_pdf_builder)، فكان fontFamily: 'Tajawal' يسقط إلى خط النظام.
    final offenders = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && RegExp(r"fontFamily:\s*'Tajawal'").hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(offenders, isEmpty);
  });

  for (final size in const [Size(1366, 768), Size(1100, 700), Size(800, 700)]) {
    testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      await pumpScreen(tester, size: size);
      await tester.enterText(find.byType(TextField), 'Augmentin');
      await tester.pump(const Duration(milliseconds: 350));
      await settleIo(tester);
      expect(find.byType(StatCard), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }
}
