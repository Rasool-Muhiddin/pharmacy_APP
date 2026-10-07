import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/purchase_list.dart';
import 'package:pharmacy_app/screens/purchase_return_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/text_fit.dart';

/// نافذة "إضافة استرجاع" فعلياً (أوفلاين): التحديد، الحدود، الرصيد الحي، الحفظ.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final helper = DatabaseHelper.instance;
  late int invoiceId;
  late List<Map<String, dynamic>> items;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_return_dialog_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  /// I/O القاعدة حقيقي داخل الوقت الوهمي للاختبار: كل await يحتاج وقتاً حقيقياً ثم pump.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpDialog(WidgetTester tester, void Function(bool) onClosed,
      {Size size = const Size(1600, 1000), ThemeData? theme}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await helper.database;
      await db.insert('pharmacy_branch', {'id': 1, 'name': 'P', 'created_at': '2026-01-01'},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      final result = await helper.createPurchaseList(
        pharmacyId: 1,
        mode: PurchaseListMode.supplierList,
        warehouseId: await helper.ensureMainWarehouse(1),
        supplierName: 'S',
        invoiceNumber: 'F-1',
        paidAmount: 9000,
        items: [
          {'trade_name': 'Panadol', 'quantity': 10, 'bonus_quantity': 2, 'buy_price': 1000, 'sell_price': 1500,
           'expiry_date': '2030-01-31'},
          {'trade_name': 'Gift', 'quantity': 0, 'bonus_quantity': 3, 'is_free': true, 'sell_price': 100,
           'expiry_date': '2030-01-31'},
        ],
      );
      invoiceId = result['purchase_invoice_id'] as int;
      items = await helper.getPurchaseInvoiceItems(invoiceId);
    });
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => onClosed(await showPurchaseReturnDialog(
                context,
                pharmacyId: 1,
                isOnlineMode: false,
                invoice: {'id': invoiceId, 'invoice_number': 'F-1'},
                items: items,
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('tick, limits, live credit (paid units only), save', (tester) async {
    bool? result;
    await pumpDialog(tester, (saved) => result = saved);
    expect(find.text('مشترى: 10 + بونص 2'), findsOneWidget);
    expect(find.text('مشترى: مجاني 3'), findsOneWidget);
    expect(find.text('إضافة استرجاع — فاتورة #F-1'), findsOneWidget);

    // التحديد يملأ الكمية بالحد الأقصى (12)، والرصيد للمدفوع فقط (10 × 1000).
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('الحد الأقصى: 12'), findsOneWidget);
    expect(find.text('الرصيد: 10,000'), findsOneWidget);
    expect(find.text('10 وحدة مدفوعة + 2 بونص بلا رصيد'), findsOneWidget);

    // تعديل الكمية والسعر يحدّث الرصيد والإجمالي حياً.
    await tester.enterText(field('الكمية المسترجعة'), '4');
    await tester.enterText(field('سعر الاسترجاع للوحدة'), '900');
    await tester.pump();
    expect(find.text('الرصيد: 3,600'), findsOneWidget);
    expect(find.textContaining('3,600'), findsWidgets);

    // المجاني: لا حقل سعر، ورصيده 0.
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
    expect(field('سعر الاسترجاع للوحدة'), findsOneWidget);
    expect(find.text('الرصيد: 0'), findsOneWidget);

    // فوق الحد: يُمنع في النافذة قبل الإرسال.
    await tester.enterText(field('الكمية المسترجعة').first, '13');
    await tester.tap(find.text('حفظ الاسترجاع'));
    await tester.pumpAndSettle();
    expect(find.text('أقصى كمية يمكن استرجاعها 12.'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(field('الكمية المسترجعة').first, '4');
    expect(field('ملاحظات (اختياري)'), findsNothing); // الملاحظات أُزيلت من الواجهة
    await tester.tap(find.text('حفظ الاسترجاع'));
    await settleIo(tester);
    expect(result, isTrue);

    await tester.runAsync(() async {
      final db = await helper.database;
      final ret = (await db.query('purchase_invoice_return')).single;
      // 4 × 900 = 3600: 1000 تسدّد المتبقي، والفائض 2600 رصيد لصالح الصيدلية.
      expect([ret['amount_returned'], ret['excess_credit']], [3600, 2600]);
      expect((await db.query('purchase_invoice_return_item')).map((r) => [r['trade_name'], r['quantity'], r['credit_amount']]),
          [['Panadol', 4, 3600], ['Gift', 3, 0]]);
      final supplier = (await helper.getSuppliersWithFinancials(1)).single;
      expect([supplier['balance'], supplier['available_credit']], [-2600, 2600]);
      expect((await db.query('medicine', where: "trade_name = 'Panadol'")).single['quantity'], 8);
    });
  });

  testWidgets('nothing selected cannot be saved', (tester) async {
    bool? result;
    await pumpDialog(tester, (saved) => result = saved);
    await tester.tap(find.text('حفظ الاسترجاع'));
    await tester.pumpAndSettle();
    expect(find.text('اختر صنفاً واحداً على الأقل لاسترجاعه.'), findsOneWidget);
    expect(result, isNull);
  });

  group('layout: no text is cut', () {
    // أصغر نافذة للحوار 640 عرضاً (+ هامش 16 من كل جهة).
    final sizes = {...laptopSizes, 'minimum dialog': const Size(672, 560)};
    for (final entry in sizes.entries) {
      testWidgets('selected paid + free lines at ${entry.key}', (tester) async {
        await tester.runAsync(loadAppFont);
        await pumpDialog(tester, (_) {}, size: entry.value, theme: appTheme());
        // الشرح أعلى النافذة يلتف إن لزم؛ الباقي سطر واحد كامل.
        const wrapping = ['حدد الأدوية المسترجعة'];
        void expectNothingCut(String where) {
          expect(tester.takeException(), isNull, reason: '$where: overflow');
          expect(cutTexts(tester, find.byType(PurchaseReturnDialog), multiLine: wrapping), isEmpty, reason: where);
        }

        expectNothingCut('${entry.key}: nothing selected');
        await tester.tap(find.byType(Checkbox).first);
        await tester.tap(find.byType(Checkbox).last);
        await tester.pumpAndSettle();
        await tester.enterText(field('الكمية المسترجعة').first, '12');
        await tester.enterText(field('سعر الاسترجاع للوحدة'), '1250.50');
        await tester.pump();
        expect(find.text('10 وحدة مدفوعة + 2 بونص بلا رصيد'), findsOneWidget);
        expect(find.text('تاريخ الاسترجاع'), findsOneWidget);
        expect(find.text('حفظ الاسترجاع'), findsOneWidget);
        expectNothingCut('${entry.key}: selected');
      });
    }
  });
}
