import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/purchase_list.dart';
import 'package:pharmacy_app/screens/missing_suppliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// شاشة المذاخر (أوفلاين): الفاتورة تفتح أصنافها مع الدفع/الاسترجاع، الفاتورة
/// اليدوية القديمة للدفع فقط، "رصيد لصالحك" واستلام الأموال، وكشف الحساب.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final helper = DatabaseHelper.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_suppliers_screen_test');
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

  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      final db = await helper.database;
      await db.insert('pharmacy_branch', {'id': 1, 'name': 'P', 'created_at': '2026-01-01'},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      final result = await helper.createPurchaseList(
        pharmacyId: 1,
        mode: PurchaseListMode.supplierList,
        warehouseId: await helper.ensureMainWarehouse(1),
        supplierName: 'مذخر الشفاء',
        invoiceNumber: 'F-1',
        paidAmount: 900,
        items: [
          {'trade_name': 'Panadol', 'quantity': 10, 'buy_price': 100, 'sell_price': 150, 'expiry_date': '2030-01-31'},
        ],
      );
      // استرجاع 3 × 100 = 300 مقابل متبقٍّ 100 → رصيد 200 لصالح الصيدلية.
      final item = (await helper.getPurchaseInvoiceItems(result['purchase_invoice_id'] as int)).single;
      await helper.returnPurchaseItems(pharmacyId: 1, purchaseInvoiceId: result['purchase_invoice_id'] as int, lines: [
        {'purchase_invoice_item_id': item['id'], 'quantity': 3},
      ]);
      final legacy = await helper.insertSupplier({'pharmacy_id': 1, 'name': 'مذخر قديم', 'created_at': '2026-01-01'});
      await db.insert('purchase_invoice', {
        'pharmacy_id': 1, 'supplier_id': legacy, 'invoice_number': 'M-1', 'total_amount': 500, 'paid_amount': 0,
        'remaining_debt': 500, 'created_at': '2026-01-02',
      });
    });
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await seed(tester);
    await tester.pumpWidget(const MaterialApp(home: MissingSuppliersScreen(pharmacyId: 1)));
    await settleIo(tester);
  }

  testWidgets('credit supplier: "رصيد لصالحك", invoice view with payment/return, refund, statement', (tester) async {
    await pumpScreen(tester);
    expect(find.text('رصيد لصالحك'), findsOneWidget);
    expect(find.text('500 د.ع'), findsOneWidget); // إجمالي الديون: المذخر القديم فقط، بلا طرح رصيد الآخر

    await tester.tap(find.text('عرض التفاصيل والفواتير').first);
    await settleIo(tester);
    expect(find.text('الإجراءات'), findsNothing);
    expect(find.text('استلام أموال من المذخر'), findsOneWidget);

    // النقر على الفاتورة يفتح أصنافها مع زرَّي الدفع والاسترجاع.
    await tester.tap(find.text('#F-1'));
    await settleIo(tester);
    expect(find.text('أصناف الفاتورة #F-1 — مذخر الشفاء'), findsOneWidget);
    expect(find.text('المسترجع'), findsOneWidget);
    expect(find.text('إضافة دفعة'), findsOneWidget);
    expect(find.text('إضافة استرجاع'), findsOneWidget);
    // المتبقي 0 (الفائض ذهب لرصيد المذخر): الدفع معطّل.
    final payButton = tester.widget<FilledButton>(find.ancestor(of: find.text('إضافة دفعة'), matching: find.byType(FilledButton)));
    expect(payButton.onPressed, isNull);
    await tester.tap(find.text('إضافة استرجاع'));
    await tester.pumpAndSettle();
    expect(find.text('مسترجع سابقاً: 3'), findsOneWidget);
    await tester.tap(find.byTooltip('إغلاق').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close_rounded).last);
    await tester.pumpAndSettle();

    // استلام جزء من الرصيد.
    await tester.tap(find.text('استلام أموال من المذخر'));
    await tester.pumpAndSettle();
    expect(find.text('رصيدك لدى المذخر: 200 د.ع'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'المبلغ المستلم'), '250');
    await tester.tap(find.text('تأكيد الاستلام'));
    await tester.pumpAndSettle();
    expect(find.text('المبلغ أكبر من رصيدك لدى المذخر.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'المبلغ المستلم'), '50');
    await tester.tap(find.text('تأكيد الاستلام'));
    await settleIo(tester);

    // كشف الحساب: الرصيد النهائي لصالح الصيدلية، والاسترجاع يُفتح لأدويته.
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('كشف حساب'));
    await settleIo(tester);
    expect(find.text('رصيد لصالحك: 150'), findsOneWidget);
    expect(find.text('استلام'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('Panadol × 3'), findsOneWidget);
  });

  testWidgets('old manual invoice: "لا توجد أصناف" and payment only', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('عرض التفاصيل والفواتير').last);
    await settleIo(tester);
    await tester.tap(find.text('#M-1'));
    await settleIo(tester);
    expect(find.text('لا توجد أصناف (فاتورة قديمة أُدخلت يدوياً).'), findsOneWidget);
    expect(find.text('إضافة دفعة'), findsOneWidget);
    expect(find.text('إضافة استرجاع'), findsNothing);

    await tester.tap(find.text('إضافة دفعة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'المبلغ المسدد'), '200');
    await tester.tap(find.text('تأكيد التسديد'));
    await settleIo(tester);
    expect(find.text('المتبقي: 300 د.ع'), findsOneWidget); // النافذة تتحدث بعد الدفع
  });
}
