import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/purchase_list.dart';
import 'package:pharmacy_app/screens/missing_suppliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// شاشة المذاخر (أوفلاين): الملخص، الفلاتر والبحث، لوحة التفاصيل وتبويباتها،
/// الفاتورة تفتح أصنافها مع الدفع/الاسترجاع، "رصيد لصالحك" واستلام الأموال،
/// كشف الحساب، تصحيح الاسم، وعدم ظهور الهاتف إطلاقاً.
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

  Future<void> seedBranch(WidgetTester tester) async {
    await tester.runAsync(() async {
      final db = await helper.database;
      await db.insert('pharmacy_branch', {'id': 1, 'name': 'P', 'created_at': '2026-01-01'},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  /// "مذخر الشفاء": رصيد 200 لصالح الصيدلية، "مذخر قديم": دين 500 (فاتورة يدوية)،
  /// "مذخر مسدد": بلا فواتير، وبرقم هاتف مخزَّن لا يجب أن يظهر.
  Future<void> seed(WidgetTester tester) async {
    await seedBranch(tester);
    await tester.runAsync(() async {
      final db = await helper.database;
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
      await helper.insertSupplier(
          {'pharmacy_id': 1, 'name': 'مذخر مسدد', 'phone': '07701234567', 'created_at': '2026-01-01'});
    });
  }

  Future<void> pumpScreen(WidgetTester tester, {Size size = const Size(1600, 1100), bool seeded = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    if (seeded) {
      await seed(tester);
    } else {
      await seedBranch(tester);
    }
    await tester.pumpWidget(const MaterialApp(home: MissingSuppliersScreen(pharmacyId: 1)));
    await settleIo(tester);
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  Future<void> openSupplier(WidgetTester tester, String name) async {
    await tapVisible(tester, find.text(name).first);
    await settleIo(tester);
    expect(find.byKey(const Key('supplier-details-name')), findsOneWidget);
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tapVisible(tester, find.text(label));
    await settleIo(tester);
  }

  Finder inCard(String key, String text) =>
      find.descendant(of: find.byKey(Key(key)), matching: find.text(text));

  double rowY(WidgetTester tester, String name) => tester.getTopLeft(find.text(name).first).dy;

  testWidgets('empty state when there are no suppliers; no add-supplier button', (tester) async {
    await pumpScreen(tester, seeded: false);
    expect(find.text('المذاخر والمشتريات'), findsOneWidget);
    expect(find.text('لا توجد مذاخر بعد'), findsOneWidget);
    expect(find.text('تُضاف المذاخر تلقائياً عند إدخال قائمة مذخر من شاشة المخزن'), findsOneWidget);
    expect(find.textContaining('إضافة مذخر'), findsNothing);
    expect(inCard('summary-count', '0'), findsOneWidget);
  });

  testWidgets('summary cards, balance badges, filter chips, search and sort', (tester) async {
    await pumpScreen(tester);
    expect(find.textContaining('إضافة مذخر'), findsNothing);
    // إجمالي الديون: المذخر القديم فقط، بلا طرح رصيد الآخر.
    expect(inCard('summary-debt', '500 د.ع'), findsOneWidget);
    expect(inCard('summary-credit', '200 د.ع'), findsOneWidget);
    expect(inCard('summary-month', '1,000 د.ع'), findsOneWidget); // F-1 أُدخلت اليوم، M-1 قديمة
    expect(inCard('summary-count', '3'), findsOneWidget);

    expect(find.text('دين 500'), findsOneWidget);
    expect(find.text('رصيد لصالحك 200'), findsOneWidget);
    expect(find.text('مسدد'), findsOneWidget);

    // الترتيب الافتراضي بالدين: الدين أولاً ثم المسدد ثم الرصيد لصالحنا.
    expect(rowY(tester, 'مذخر قديم'), lessThan(rowY(tester, 'مذخر مسدد')));
    expect(rowY(tester, 'مذخر مسدد'), lessThan(rowY(tester, 'مذخر الشفاء')));

    await tester.tap(find.byKey(const Key('supplier-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ترتيب حسب الاسم').last);
    await tester.pumpAndSettle();
    expect(rowY(tester, 'مذخر الشفاء'), lessThan(rowY(tester, 'مذخر قديم')));
    expect(rowY(tester, 'مذخر قديم'), lessThan(rowY(tester, 'مذخر مسدد')));

    await tester.tap(find.byKey(const Key('supplier-filter-debt')));
    await tester.pumpAndSettle();
    expect(find.text('مذخر قديم'), findsOneWidget);
    expect(find.text('مذخر الشفاء'), findsNothing);
    expect(find.text('مذخر مسدد'), findsNothing);

    await tester.tap(find.byKey(const Key('supplier-filter-credit')));
    await tester.pumpAndSettle();
    expect(find.text('مذخر الشفاء'), findsOneWidget);
    expect(find.text('مذخر قديم'), findsNothing);

    await tester.tap(find.byKey(const Key('supplier-filter-all')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('supplier-search')), 'قديم');
    await tester.pumpAndSettle();
    expect(find.text('مذخر قديم'), findsOneWidget);
    expect(find.text('مذخر الشفاء'), findsNothing);

    await tester.enterText(find.byKey(const Key('supplier-search')), 'لا يوجد');
    await tester.pumpAndSettle();
    expect(find.text('لا توجد مذاخر مطابقة.'), findsOneWidget);
  });

  testWidgets('supplier details: tabs for invoices, statement and purchased items', (tester) async {
    await pumpScreen(tester);
    await openSupplier(tester, 'مذخر الشفاء');
    expect(find.text('الفواتير'), findsOneWidget);
    expect(find.text('#F-1'), findsOneWidget);
    expect(find.text('مسددة'), findsOneWidget);

    await openTab(tester, 'كشف الحساب');
    expect(find.text('البيان'), findsOneWidget);
    expect(find.text('رصيد لصالحك: 200'), findsOneWidget);

    await openTab(tester, 'الأصناف المشتراة');
    expect(find.text('Panadol'), findsOneWidget);
    expect(find.text('عدد الأصناف: 1'), findsOneWidget);

    // مذخر آخر يعود لتبويب الفواتير.
    await openSupplier(tester, 'مذخر قديم');
    expect(find.text('#M-1'), findsOneWidget);
    expect(find.text('غير مسددة'), findsOneWidget);

    await tester.tap(find.byKey(const Key('supplier-details-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('supplier-details-name')), findsNothing);
  });

  testWidgets('credit supplier: invoice view with payment/return, refund, statement', (tester) async {
    await pumpScreen(tester);
    await openSupplier(tester, 'مذخر الشفاء');
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
    await tester.tap(find.byTooltip('إغلاق').last);
    await tester.pumpAndSettle();
    expect(find.text('أصناف الفاتورة #F-1 — مذخر الشفاء'), findsNothing);

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
    expect(find.text('رصيد لصالحك 150'), findsWidgets);

    // كشف الحساب: الرصيد النهائي لصالح الصيدلية، والاسترجاع يُفتح لأدويته.
    await openTab(tester, 'كشف الحساب');
    expect(find.text('رصيد لصالحك: 150'), findsOneWidget);
    expect(find.text('استلام'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('Panadol × 3'), findsOneWidget);
  });

  testWidgets('old manual invoice: "لا توجد أصناف" and payment only', (tester) async {
    await pumpScreen(tester);
    await openSupplier(tester, 'مذخر قديم');
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

  testWidgets('edit dialog has only the name field and keeps names unique', (tester) async {
    await pumpScreen(tester);
    await openSupplier(tester, 'مذخر مسدد');
    await tester.tap(find.byKey(const Key('supplier-edit')));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(find.text('تعديل اسم المذخر'), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.byType(TextField)), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('اسم المذخر')), findsOneWidget);
    expect(find.textContaining('هاتف'), findsNothing);

    final field = find.byKey(const Key('supplier-name-field'));
    await tester.enterText(field, '   ');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(find.text('اسم المذخر مطلوب.'), findsOneWidget);

    await tester.enterText(field, 'مذخر قديم');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(find.text('يوجد مذخر آخر بنفس الاسم.'), findsOneWidget);

    await tester.enterText(field, '  مذخر النور ');
    await tester.tap(find.text('حفظ'));
    await settleIo(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('مذخر النور'), findsWidgets);
    expect(find.text('مذخر مسدد'), findsNothing);

    // الاسم فقط يتغيّر؛ الهاتف المخزَّن يبقى كما هو في القاعدة.
    final row = await tester.runAsync(() async =>
        (await (await helper.database).query('pharmacy_supplier', where: 'name = ?', whereArgs: ['مذخر النور'])).single);
    expect(row!['phone'], '07701234567');
  });

  testWidgets('the supplier phone number never appears on the screen', (tester) async {
    await pumpScreen(tester);
    void expectNoPhone() {
      expect(find.textContaining('0770'), findsNothing);
      expect(find.textContaining('هاتف'), findsNothing);
      expect(find.textContaining('☎'), findsNothing);
    }

    expectNoPhone();
    await openSupplier(tester, 'مذخر مسدد');
    expectNoPhone();
    for (final tab in ['كشف الحساب', 'الأصناف المشتراة', 'الفواتير']) {
      await openTab(tester, tab);
      expectNoPhone();
    }
    await tester.tap(find.byKey(const Key('supplier-edit')));
    await tester.pumpAndSettle();
    expectNoPhone();
  });

  for (final size in const [Size(1366, 768), Size(1920, 1080), Size(800, 700), Size(420, 800)]) {
    testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      await pumpScreen(tester, size: size);
      expect(tester.takeException(), isNull);

      await openSupplier(tester, 'مذخر الشفاء');
      for (final tab in ['كشف الحساب', 'الأصناف المشتراة', 'الفواتير']) {
        await openTab(tester, tab);
        expect(tester.takeException(), isNull, reason: tab);
      }
      await tapVisible(tester, find.text('#F-1'));
      await settleIo(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('إغلاق').last);
      await tester.pumpAndSettle();

      final narrow = size.width < 1100;
      // على النوافذ الضيقة تُفتح التفاصيل كصفحة كاملة بزر رجوع.
      expect(find.byKey(const Key('supplier-details-back')), narrow ? findsOneWidget : findsNothing);
      await tapVisible(tester, find.byKey(Key(narrow ? 'supplier-details-back' : 'supplier-details-close')));
      await tester.pumpAndSettle();
      expect(find.text('ملخص المذاخر'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
