import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/screens/pos_screen.dart';
import 'package:pharmacy_app/widgets/cart_quantity_field.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// نقطة البيع بعد إعادة التصميم (أوفلاين): المسح بالباركود، كتابة الكمية مباشرة
/// (مقصوصة للمخزون)، تحديث الإجماليات حياً، وإتمام البيع — بلا تغيير في السلوك.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final helper = DatabaseHelper.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_pos_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpPos(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await helper.database;
      await db.insert('pharmacy_branch', {'id': 1, 'name': 'P', 'created_at': '2026-01-01'},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      // حساب الكاشير (userId: 1) — completeSale يتحقق منه.
      await db.insert('users', {'id': 1, 'username': 'cashier', 'password': 'x'});
      await db.insert('user_profile', {'id': 1, 'user_id': 1, 'pharmacy_id': 1});
      await helper.insertMedicine({
        'pharmacy_id': 1, 'warehouse_id': await helper.ensureMainWarehouse(1), 'trade_name': 'Panadol',
        'barcode': '111', 'quantity': 6, 'buy_price': 500, 'sell_price': 1000, 'expiry_date': '2030-01-01',
      });
    });
    await tester.pumpWidget(const MaterialApp(home: PosScreen(pharmacyId: 1, userId: 1)));
    await settleIo(tester);
  }

  Finder searchField() => find.byWidgetPredicate((w) => w is TextField && w.autofocus);

  String qtyText(WidgetTester tester) => tester
      .widget<TextField>(find.descendant(of: find.byType(CartQuantityField), matching: find.byType(TextField)))
      .controller!
      .text;

  testWidgets('scan, type quantity (capped at stock), live totals, checkout', (tester) async {
    await pumpPos(tester, const Size(1500, 1000));
    expect(find.text('ملخص الفاتورة'), findsOneWidget);
    expect(find.text('امسح الباركود أو ابحث بالاسم لإضافة الأدوية للفاتورة.'), findsOneWidget);

    // مسح الباركود (Enter): الصنف يُضاف والتركيز يعود لحقل البحث.
    await tester.enterText(searchField(), '111');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleIo(tester);
    expect(find.text('Panadol'), findsOneWidget);
    expect(qtyText(tester), '1');
    final searchFocus = tester.widget<TextField>(searchField()).focusNode!;
    expect(searchFocus.hasFocus, isTrue);

    // كتابة الكمية مباشرة: تتحدث الإجماليات حياً.
    final qtyField = find.descendant(of: find.byType(CartQuantityField), matching: find.byType(TextField));
    await tester.enterText(qtyField, '4');
    await tester.pump();
    expect(find.text('4,000 د.ع'), findsWidgets); // إجمالي السطر والمجموع والصافي

    // فوق المخزون (6): يُقصّ للمتاح مع رسالة قصيرة.
    await tester.enterText(qtyField, '9');
    await tester.pump();
    expect(qtyText(tester), '6');
    expect(find.text('الحد الأقصى المتوفر بالمخزن هو 6 قطعة.'), findsOneWidget);
    expect(find.text('6,000 د.ع'), findsWidgets);

    // فارغ ثم Enter: يعود للقيمة السابقة، والتركيز يعود لحقل الباركود.
    await tester.enterText(qtyField, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(qtyText(tester), '6');
    expect(searchFocus.hasFocus, isTrue);

    // زر − ما زال يعمل.
    await tester.tap(find.byTooltip('إنقاص'));
    await tester.pump();
    expect(qtyText(tester), '5');

    await tester.tap(find.text('إتمام البيع'));
    await settleIo(tester);
    await settleIo(tester); // completeSale + إعادة تحميل الأصناف: عدة جولات I/O
    await tester.runAsync(() async {
      final db = await helper.database;
      final invoice = (await db.query('invoice')).single;
      expect(invoice['final_amount'], 5000);
      expect((await db.query('invoice_item')).single['quantity'], 5);
      expect((await db.query('medicine')).single['quantity'], 1);
    });
    expect(find.byType(CartQuantityField), findsNothing); // السلة فُرّغت
  });

  testWidgets('narrow window stacks the summary under the cart without overflow', (tester) async {
    await pumpPos(tester, const Size(900, 1100));
    await tester.enterText(searchField(), '111');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleIo(tester);
    expect(find.text('Panadol'), findsOneWidget);
    expect(find.text('إتمام البيع'), findsOneWidget);
  });
}
