import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/screens/sales_history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// شاشة سجل المبيعات (أوفلاين): البحث الحي، فلاتر البائع/الحالة/الخصم معاً،
/// مسح الفلاتر، وعدم تجاوز شريط الفلاتر لعرض الشاشة.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pharmacyId = 1;
  const base = DatabaseHelper.localIdBase;
  late Directory tempDir;
  final helper = DatabaseHelper.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_sales_history_test');
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
    await db.insert('users', {'id': 5, 'username': 'sara', 'password': '', 'full_name': 'Sara'});
    await db.insert('user_profile', {'id': 5, 'user_id': 5, 'pharmacy_id': pharmacyId, 'is_owner': 0});
    await db.insert('warehouses', {'id': base, 'pharmacy_id': pharmacyId, 'name': 'Main', 'is_main': 1, 'created_at': '2026-10-01T00:00:00'});
    await db.insert('medicine', {'id': base, 'pharmacy_id': pharmacyId, 'warehouse_id': base, 'trade_name': 'Med'});
    // 1: Sara بخصم، 2: Sara مسترجعة، 3: بلا بائع، 4: بلا بائع فيها Panadol.
    final invoices = [(1, 5, 500, 0, 'Med'), (2, 5, 0, 1, 'Med'), (3, null, 0, 0, 'Med'), (4, null, 0, 0, 'Panadol')];
    for (final (n, cashier, discount, refunded, item) in invoices) {
      await db.insert('invoice', {
        'id': base + n,
        'pharmacy_id': pharmacyId,
        'invoice_number': 'INV-00000$n',
        'cashier_id': cashier,
        'total_amount': 1000,
        'discount': discount,
        'final_amount': 1000 - discount,
        'is_refunded': refunded,
        'created_at': '2026-10-0${n}T10:00:00',
      });
      await db.insert('invoice_item', {
        'invoice_id': base + n,
        'medicine_id': base,
        'trade_name': item,
        'quantity': 1,
        'unit_price': 1000,
        'total_price': 1000,
      });
    }
  }

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
    await tester.pumpWidget(const MaterialApp(home: SalesHistoryScreen(pharmacyId: pharmacyId)));
    await settleIo(tester);
  }

  Future<void> pick(WidgetTester tester, String current, String option) async {
    await tester.tap(find.text(current).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await settleIo(tester);
  }

  Finder invoice(int n) => find.text('INV-00000$n');

  testWidgets('live search, combined filters and clear', (tester) async {
    await pumpScreen(tester);
    for (var n = 1; n <= 4; n++) {
      expect(invoice(n), findsOneWidget);
    }
    expect(find.text('مسح الفلاتر'), findsNothing);

    // بحث حي باسم الدواء بلا ضغط Enter (بعد مهلة 300ms).
    await tester.enterText(find.byType(TextField), 'panadol');
    await tester.pump(const Duration(milliseconds: 350));
    await settleIo(tester);
    expect(invoice(4), findsOneWidget);
    expect(invoice(1), findsNothing);

    await tester.tap(find.text('مسح الفلاتر'));
    await settleIo(tester);
    expect(invoice(1), findsOneWidget);

    // بائع "غير محدد" (فواتير بلا بائع) ثم Sara + مكتملة + بخصم.
    await pick(tester, 'كل البائعين', 'غير محدد');
    expect(invoice(3), findsOneWidget);
    expect(invoice(4), findsOneWidget);
    expect(invoice(1), findsNothing);
    await pick(tester, 'غير محدد', 'Sara');
    expect(invoice(1), findsOneWidget);
    expect(invoice(2), findsOneWidget);
    await pick(tester, 'كل الحالات', 'مسترجعة');
    expect(invoice(2), findsOneWidget);
    expect(invoice(1), findsNothing);
    await pick(tester, 'الخصم: الكل', 'بخصم');
    expect(find.text('لا توجد فواتير مطابقة للبحث والفلاتر'), findsOneWidget);

    await tester.tap(find.text('مسح الفلاتر'));
    await settleIo(tester);
    for (var n = 1; n <= 4; n++) {
      expect(invoice(n), findsOneWidget);
    }
    expect(find.text('كل البائعين'), findsOneWidget);
    expect(find.text('مسح الفلاتر'), findsNothing);
  });

  for (final size in const [Size(1366, 768), Size(1100, 700), Size(800, 700)]) {
    testWidgets('filter bar has no overflow at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      await pumpScreen(tester, size: size);
      await pick(tester, 'كل البائعين', 'غير محدد');
      await pick(tester, 'كل الحالات', 'مكتملة');
      await pick(tester, 'الخصم: الكل', 'بدون خصم');
      expect(find.text('مسح الفلاتر'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
