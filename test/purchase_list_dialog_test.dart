import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/screens/purchase_list_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// تدفّق نافذة "إضافة قائمة مذخر" فعلياً (أوفلاين): كتابة الاسم، الحقول،
/// Enter لإنهاء الصنف، المجاني، ثم الحفظ — وأن الحفظ يصل للقاعدة كاملاً.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final helper = DatabaseHelper.instance;
  late int warehouseId;
  late int branchWarehouseId;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_dialog_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  /// استدعاءات القاعدة I/O حقيقي داخل منطقة الوقت الوهمي للاختبار: كل await
  /// يحتاج وقتاً حقيقياً يمر ثم pump لمتابعة الكود بعده.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> pumpDialog(WidgetTester tester, {required void Function(bool) onClosed}) async {
    // نافذة سطح مكتب واقعية (النافذة 90% منها).
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final db = await helper.database;
      await db.insert('pharmacy_branch', {'id': 1, 'name': 'P', 'created_at': '2026-01-01'},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      warehouseId = await helper.ensureMainWarehouse(1);
      await helper.insertMedicine({
        'pharmacy_id': 1, 'warehouse_id': warehouseId, 'trade_name': 'Panadol', 'quantity': 10,
        'buy_price': 500, 'sell_price': 1000, 'expiry_date': '2030-01-01',
      });
      await helper.insertMedicine({
        'pharmacy_id': 1, 'warehouse_id': warehouseId, 'trade_name': 'Amoxil', 'barcode': '6221',
        'scientific_name': 'Amoxicillin', 'category': 'syrup', 'quantity': 4,
        'buy_price': 2000, 'sell_price': 3000, 'expiry_date': '2030-01-01',
      });
      // صنف في مخزن آخر فقط (للمسح من مخزن غير المختار).
      branchWarehouseId = await helper.addWarehouse(pharmacyId: 1, name: 'الفرع', maxWarehouses: 5);
      await helper.insertMedicine({
        'pharmacy_id': 1, 'warehouse_id': branchWarehouseId, 'trade_name': 'Augmentin', 'barcode': 'AUG-1g',
        'scientific_name': 'Co-amoxiclav', 'category': 'tablet', 'quantity': 2,
        'buy_price': 4000, 'sell_price': 6000, 'expiry_date': '2030-01-01',
      });
    });
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final saved = await showPurchaseListDialog(
                  context,
                  pharmacyId: 1,
                  isOnlineMode: false,
                  warehouses: [
                    {'id': warehouseId, 'name': 'المخزن الرئيسي', 'is_main': 1},
                  ],
                  initialWarehouseId: warehouseId,
                  allowWarehouseChoice: false,
                  masterMedicines: const [
                    {'trade_name': 'Brufen 400', 'scientific_name': 'Ibuprofen', 'category': 'tablet'},
                  ],
                  categories: const {'tablet': 'حبوب / كبسول', 'syrup': 'شراب / معلق'},
                );
                onClosed(saved);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    // تحميل المذاخر وأصناف المخزن من القاعدة (I/O حقيقي).
    await settleIo(tester);
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  // حقل الباركود في سطر الصنف الجديد (آخر سطر دائماً).
  Finder barcodeField() => field('الباركود').last;

  bool focused(WidgetTester tester, Finder finder) => tester.widget<TextField>(finder).focusNode!.hasFocus;

  String text(WidgetTester tester, Finder finder) => tester.widget<TextField>(finder).controller!.text;

  Future<void> scan(WidgetTester tester, String code) async {
    await tester.enterText(barcodeField(), code);
    await tester.testTextInput.receiveAction(TextInputAction.next); // الماسح يرسل Enter
    await tester.pumpAndSettle();
  }

  Future<void> fillHeader(WidgetTester tester, String invoice) async {
    await tester.enterText(field('المذخر * (ابحث أو اكتب اسماً جديداً)'), 'مذخر');
    await tester.enterText(field('رقم فاتورة المذخر *'), invoice);
    await tester.pump();
  }

  group('barcode-first entry', () {
    testWidgets('scanning an existing barcode fills the item, focuses quantity, edited prices are saved',
        (tester) async {
      bool? result;
      await pumpDialog(tester, onClosed: (saved) => result = saved);
      expect(focused(tester, barcodeField()), isTrue); // الباركود أول حقل ويأخذ التركيز
      await fillHeader(tester, 'B-1');

      await scan(tester, ' 6221 ');
      expect(find.text('صنف موجود'), findsOneWidget);
      expect(text(tester, field('الباركود').first), '6221'); // بلا مسافات
      expect(find.widgetWithText(TextField, 'Amoxil'), findsOneWidget);
      expect(text(tester, field('الاسم العلمي')), 'Amoxicillin');
      expect(tester.widget<DropdownButtonFormField<String>>(find.byType(DropdownButtonFormField<String>)).initialValue,
          'syrup');
      expect(text(tester, field('سعر البيع *')), '3000');
      expect(text(tester, field('سعر الشراء *')), '2000');
      expect(focused(tester, field('الكمية المدفوعة *')), isTrue);
      // الحقول المعبّأة قابلة للتعديل.
      expect(tester.widget<TextField>(field('الاسم العلمي')).enabled ?? true, isTrue);

      expect(find.text('سيُطبَّق سعر البيع الجديد على كل مخزون هذا الصنف'), findsNothing);
      await tester.enterText(field('الكمية المدفوعة *'), '5');
      await tester.enterText(field('سعر الشراء *'), '2200');
      await tester.enterText(field('سعر البيع *'), '3500');
      await tester.pump();
      expect(find.text('سيُطبَّق سعر البيع الجديد على كل مخزون هذا الصنف'), findsOneWidget);
      await tester.enterText(field('الصلاحية *'), '2029-06');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('6221'), findsOneWidget); // السطر المطوي يعرض الباركود
      expect(focused(tester, barcodeField()), isTrue); // الصنف التالي يبدأ بالباركود

      await tester.tap(find.text('حفظ القائمة والفاتورة'));
      await settleIo(tester);
      expect(result, isTrue);
      await tester.runAsync(() async {
        final db = await helper.database;
        final amoxil = (await db.query('medicine', where: "trade_name = 'Amoxil'")).single;
        expect([amoxil['quantity'], amoxil['sell_price']], [9, 3500]);
        final item = (await db.query('purchase_invoice_item')).single;
        expect([item['buy_price'], item['quantity'], item['line_total']], [2200, 5, 11000]);
      });
    });

    testWidgets('unknown barcode keeps the code and focuses trade name', (tester) async {
      await pumpDialog(tester, onClosed: (_) {});
      await scan(tester, 'XY-900');
      expect(find.text('صنف موجود'), findsNothing);
      expect(text(tester, barcodeField()), 'XY-900');
      expect(text(tester, field('اسم الصنف الأول')), '');
      expect(focused(tester, field('اسم الصنف الأول')), isTrue);

      await tester.enterText(field('اسم الصنف الأول'), 'Brand new');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect(find.text('صنف جديد'), findsOneWidget);
      expect(text(tester, field('الباركود').first), 'XY-900');
    });

    testWidgets('empty barcode + Enter focuses trade name and keeps the name flow', (tester) async {
      await pumpDialog(tester, onClosed: (_) {});
      await scan(tester, '');
      expect(focused(tester, field('اسم الصنف الأول')), isTrue);
      await tester.enterText(field('اسم الصنف الأول'), 'panadol');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect(find.text('صنف موجود'), findsOneWidget); // كشف الصنف بالاسم كما قبل
    });

    testWidgets('barcode from another warehouse prefills but is a new item here; edits are saved', (tester) async {
      bool? result;
      await pumpDialog(tester, onClosed: (saved) => result = saved);
      await fillHeader(tester, 'B-2');
      await scan(tester, 'AUG-1g');
      expect(find.text('صنف جديد في هذا المخزن'), findsOneWidget);
      expect(find.text('صنف موجود'), findsNothing);
      expect(text(tester, field('الاسم العلمي')), 'Co-amoxiclav');
      expect(text(tester, field('سعر البيع *')), '6000');
      expect(focused(tester, field('الكمية المدفوعة *')), isTrue);

      await tester.enterText(find.widgetWithText(TextField, 'Augmentin'), 'Augmentin 1g');
      await tester.enterText(field('الاسم العلمي'), 'Amoxicillin/Clavulanate');
      await tester.enterText(field('الكمية المدفوعة *'), '3');
      await tester.enterText(field('سعر البيع *'), '6500');
      await tester.enterText(field('الصلاحية *'), '2028-01');
      await tester.pump();

      await tester.tap(find.text('حفظ القائمة والفاتورة'));
      await settleIo(tester);
      expect(result, isTrue);
      await tester.runAsync(() async {
        final db = await helper.database;
        final created = (await db.query('medicine', where: 'warehouse_id = ? AND barcode = ?',
                whereArgs: [warehouseId, 'AUG-1g']))
            .single;
        expect([created['trade_name'], created['scientific_name'], created['quantity'], created['sell_price']],
            ['Augmentin 1g', 'Amoxicillin/Clavulanate', 3, 6500]);
        final original = (await db.query('medicine', where: 'warehouse_id = ?', whereArgs: [branchWarehouseId])).single;
        expect([original['trade_name'], original['quantity'], original['sell_price']], ['Augmentin', 2, 6000]);
      });
    });

    testWidgets('scanning a barcode already in the list focuses that row instead of adding one', (tester) async {
      await pumpDialog(tester, onClosed: (_) {});
      await scan(tester, '6221');
      await tester.enterText(field('الكمية المدفوعة *'), '2');
      await tester.enterText(field('الصلاحية *'), '2029-06');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(field('الكمية المدفوعة *'), findsNothing); // مطوي

      await scan(tester, '6221');
      expect(find.text('هذا الصنف موجود في القائمة'), findsOneWidget);
      expect(find.text('صنف موجود'), findsOneWidget); // سطر واحد فقط
      expect(focused(tester, field('الكمية المدفوعة *')), isTrue); // السطر الموجود مفتوح
      expect(text(tester, field('الكمية المدفوعة *')), '2');
      expect(text(tester, barcodeField()), ''); // السطر الجديد فارغ
    });

    testWidgets('picking an existing item by name after an unknown scan asks before assigning the barcode',
        (tester) async {
      await pumpDialog(tester, onClosed: (_) {});
      await scan(tester, 'P-77');
      await tester.enterText(field('اسم الصنف الأول'), 'panadol');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
      expect(find.textContaining('موجود في المخزن بلا باركود'), findsOneWidget);
      await tester.tap(find.text('نعم، استخدم P-77'));
      await tester.pumpAndSettle();
      expect(find.text('صنف موجود'), findsOneWidget);
      expect(text(tester, field('الباركود').first), 'P-77');
    });
  });

  testWidgets('supplier list: existing item with bonus + free new item, saved in one go', (tester) async {
    bool? result;
    await pumpDialog(tester, onClosed: (saved) => result = saved);
    expect(find.text('إضافة قائمة مذخر'), findsOneWidget);

    await tester.enterText(field('المذخر * (ابحث أو اكتب اسماً جديداً)'), 'مذخر الشفاء');
    await tester.pump();
    expect(find.text('مذخر جديد — سيُنشأ عند الحفظ'), findsOneWidget);
    expect(field('هاتف المذخر (اختياري)'), findsNothing); // أُزيل من الواجهة
    await tester.enterText(field('رقم فاتورة المذخر *'), 'F-1');

    // الصنف 1: موجود في المخزن (نفس الاسم) + بونص.
    await tester.enterText(field('اسم الصنف الأول'), 'panadol');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(find.text('صنف موجود'), findsOneWidget);
    expect(field('موقع الرف'), findsNothing); // أُزيل من الواجهة
    expect(find.text('أخرى'), findsNothing); // القائمة مغلقة؛ الخيارات الجديدة تُختبر عبر medicineCategories
    await tester.enterText(field('الكمية المدفوعة *'), '10');
    await tester.enterText(field('بونص (مجاني)'), '2');
    await tester.enterText(field('سعر الشراء *'), '1000');
    await tester.enterText(field('سعر البيع *'), '1500');
    await tester.enterText(field('الصلاحية *'), '05/2028');
    await tester.pump();
    expect(find.text('2028-05-31'), findsOneWidget); // معاينة الصلاحية المفهومة
    expect(find.textContaining('كلفة الوحدة الفعلية 833'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done); // Enter في الصلاحية ينهي الصنف
    await tester.pumpAndSettle();
    expect(find.text('10 (+2)'), findsOneWidget); // السطر المطوي

    // الصنف 2: جديد ومجاني.
    await tester.enterText(field('الصنف التالي: اسم الصنف'), 'Sample X');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(find.text('صنف جديد'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'مجاني'));
    await tester.pumpAndSettle();
    await tester.enterText(field('الكمية المجانية *'), '3');
    await tester.enterText(field('سعر البيع *'), '250');
    await tester.enterText(field('الصلاحية *'), '2029-01');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // التذييل: البونص والمجاني خارج الإجمالي.
    expect(find.text('2'), findsWidgets);
    expect(find.text('أصناف مجانية: '), findsOneWidget);
    await tester.enterText(field('المدفوع الآن (اختياري)'), '4000');
    await tester.pump();

    await tester.tap(find.text('حفظ القائمة والفاتورة'));
    await settleIo(tester);
    expect(result, isTrue);

    await tester.runAsync(() async {
      final db = await helper.database;
      final invoice = (await db.query('purchase_invoice')).single;
      expect([invoice['invoice_number'], invoice['total_amount'], invoice['paid_amount'], invoice['item_count']],
          ['F-1', 10000, 4000, 2]);
      final panadol = (await db.query('medicine', where: "trade_name = 'Panadol'")).single;
      expect([panadol['quantity'], panadol['sell_price']], [22, 1500]);
      final sample = (await db.query('medicine', where: "trade_name = 'Sample X'")).single;
      expect([sample['quantity'], sample['avg_cost'], sample['expiry_date']], [3, 0, '2029-01-31']);
      expect((await db.query('supplier_payment')).single['amount_paid'], 4000);
    });
  });

  testWidgets('invalid line is highlighted and nothing is saved', (tester) async {
    bool? result;
    await pumpDialog(tester, onClosed: (saved) => result = saved);
    await tester.enterText(field('المذخر * (ابحث أو اكتب اسماً جديداً)'), 'S');
    await tester.enterText(field('رقم فاتورة المذخر *'), 'F-2');
    await tester.enterText(field('اسم الصنف الأول'), 'Brufen');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Brufen 400')); // من القاموس
    await tester.pumpAndSettle();
    await tester.enterText(field('الكمية المدفوعة *'), '5');
    await tester.enterText(field('سعر البيع *'), '400');
    await tester.enterText(field('الصلاحية *'), '2028-03');

    await tester.tap(find.text('حفظ القائمة والفاتورة'));
    await settleIo(tester);
    expect(find.text('سعر الشراء يجب أن يكون أكبر من صفر.'), findsOneWidget);
    expect(result, isNull); // النافذة ما زالت مفتوحة
    await tester.runAsync(() async {
      final db = await helper.database;
      expect(await db.query('purchase_invoice'), isEmpty);
      expect(await db.query('medicine', where: "trade_name = 'Brufen 400'"), isEmpty);
    });
  });

  testWidgets('opening stock mode hides supplier, bonus and free controls', (tester) async {
    bool? result;
    await pumpDialog(tester, onClosed: (saved) => result = saved);
    await tester.tap(find.text('رصيد افتتاحي'));
    await tester.pumpAndSettle();
    expect(field('رقم فاتورة المذخر *'), findsNothing);
    await tester.enterText(field('اسم الصنف الأول'), 'Shelf item');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilterChip, 'مجاني'), findsNothing);
    expect(field('بونص (مجاني)'), findsNothing);
    await tester.enterText(field('الكمية *'), '7');
    await tester.enterText(field('سعر الشراء (0 = غير معروف)'), '0');
    await tester.enterText(field('سعر البيع *'), '90');
    await tester.enterText(field('الصلاحية *'), '2027-12-31');
    await tester.tap(find.text('حفظ الرصيد الافتتاحي'));
    await settleIo(tester);
    expect(result, isTrue);
    await tester.runAsync(() async {
      final db = await helper.database;
      final med = (await db.query('medicine', where: "trade_name = 'Shelf item'")).single;
      expect([med['quantity'], med['avg_cost']], [7, null]);
      expect(await db.query('purchase_invoice'), isEmpty);
    });
  });
}
