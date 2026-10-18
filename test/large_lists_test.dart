import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/purchase_list.dart';
import 'package:pharmacy_app/models/subscription_plan.dart';
import 'package:pharmacy_app/screens/dashboard_screen.dart';
import 'package:pharmacy_app/screens/inventory_screen.dart';
import 'package:pharmacy_app/screens/inventory_table.dart';
import 'package:pharmacy_app/screens/missing_suppliers.dart';
import 'package:pharmacy_app/screens/sales_history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// قوائم كبيرة: الصفوف تُبنى عند ظهورها فقط، الكتابة في بحث المخزون لا تعيد بناء
/// الجدول، الرئيسية تعرض أول 20 تحذيراً مع "عرض الكل"، وتبويبات المذخر على دفعات.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pid = 1;
  const base = DatabaseHelper.localIdBase;
  late Directory tempDir;
  final helper = DatabaseHelper.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_large_lists_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// الرئيسية تستخدم GoogleFonts الذي ينزّل الخط من الإنترنت؛ flutter test يرد
  /// على أي طلب بـ400 فيفشل التحميل كخطأ غير ملتقط أثناء الاختبار. هنا لا شبكة
  /// إطلاقاً: الطلبات لا تكتمل أبداً، فيبقى الخط الاحتياطي بلا أخطاء.
  void withoutNetwork() {
    final previous = HttpOverrides.current;
    HttpOverrides.global = _NoNetworkOverrides();
    addTearDown(() => HttpOverrides.global = previous);
  }

  void view(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// [count] صنفاً في المخزن الرئيسي، كلها بكمية 5 (نواقص) وصلاحية خلال 90 يوماً.
  Future<void> seedMedicines(WidgetTester tester, int count) async {
    await tester.runAsync(() async {
      final db = await helper.database;
      await db.insert('pharmacy_branch', {'id': pid, 'name': 'P', 'created_at': '2026-01-01'});
      final warehouse = await helper.ensureMainWarehouse(pid);
      final expiry = DateTime.now().add(const Duration(days: 40)).toIso8601String().substring(0, 10);
      final batch = db.batch();
      for (var i = 0; i < count; i++) {
        batch.insert('medicine', {
          'id': base + i,
          'pharmacy_id': pid,
          'warehouse_id': warehouse,
          'trade_name': 'Med ${i.toString().padLeft(4, '0')}',
          'category': 'tablet',
          'quantity': 5,
          'sell_price': 1000,
          'expiry_date': expiry,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  Finder inventoryRows() => find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('inventory-row-'));

  testWidgets('Inventory: only visible rows are built; typing does not rebuild the table', (tester) async {
    view(tester);
    await seedMedicines(tester, 400);
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: InventoryScreen(pharmacyId: pid, entitlements: SubscriptionEntitlements.basic()),
      ),
    ));
    await settle(tester);

    expect(tester.widget<InventoryTable>(find.byType(InventoryTable)).medicines, hasLength(400));
    final built = inventoryRows().evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(40)); // الظاهر فقط، لا 400

    final before = tester.widget<InventoryTable>(find.byType(InventoryTable));
    await tester.enterText(find.byType(TextField).first, 'Med 01');
    await tester.pump(const Duration(milliseconds: 100));
    // قبل انتهاء مهلة البحث: نفس ويدجت الجدول (لم يُعَد بناء الشاشة) وزر المسح ظاهر.
    expect(identical(tester.widget<InventoryTable>(find.byType(InventoryTable)), before), isTrue);
    expect(find.text('مسح الفلاتر'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    final after = tester.widget<InventoryTable>(find.byType(InventoryTable));
    expect(identical(after, before), isFalse);
    expect(after.medicines, hasLength(100)); // Med 0100 … Med 0199
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dashboard: top 20 most urgent rows with "عرض الكل"', (tester) async {
    view(tester);
    withoutNetwork();
    await seedMedicines(tester, 30);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(body: DashboardScreen(pharmacyId: pid, onShowAllStockAlerts: () => opened++)),
      ),
    ));
    await settle(tester);

    expect(find.text('Med 0000'), findsNWidgets(2)); // في الجدولين
    expect(find.text('Med 0019'), findsNWidgets(2));
    expect(find.text('Med 0020'), findsNothing);
    expect(find.text('يعرض 20 من 30 — الأكثر إلحاحاً أولاً'), findsNWidgets(2));
    for (final key in ['dashboard-show-all-low-stock', 'dashboard-show-all-expiry']) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
    }
    expect(opened, 2);
  });

  testWidgets('Dashboard without reports access: count only, no link', (tester) async {
    view(tester);
    withoutNetwork();
    await seedMedicines(tester, 25);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: DashboardScreen(pharmacyId: pid))));
    await settle(tester);
    expect(find.text('يعرض 20 من 25 — الأكثر إلحاحاً أولاً'), findsNWidgets(2));
    expect(find.text('عرض الكل'), findsNothing);
  });

  testWidgets('Sales History: only visible invoice rows are built', (tester) async {
    view(tester);
    await tester.runAsync(() async {
      final db = await helper.database;
      await db.insert('pharmacy_branch', {'id': pid, 'name': 'P', 'created_at': '2026-01-01'});
      for (var i = 0; i < 120; i++) {
        await db.insert('invoice', {
          'id': base + i,
          'pharmacy_id': pid,
          'invoice_number': 'INV-${i.toString().padLeft(6, '0')}',
          'total_amount': 1000,
          'final_amount': 1000,
          'created_at': '2026-10-01T10:${(i % 60).toString().padLeft(2, '0')}:00',
        });
      }
    });
    await tester.pumpWidget(const MaterialApp(home: SalesHistoryScreen(pharmacyId: pid)));
    await settle(tester);
    final built = find.text('تفاصيل الفاتورة').evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(50)); // صفحة من 50 محمّلة، والظاهر منها فقط مبني
    expect(find.text('تحميل المزيد'), findsNothing); // في آخر القائمة، غير مبني بعد
  });

  testWidgets('Supplier tabs: 100 rows at a time; statement keeps the carried balance', (tester) async {
    view(tester);
    await tester.runAsync(() async {
      final db = await helper.database;
      await db.insert('pharmacy_branch', {'id': pid, 'name': 'P', 'created_at': '2026-01-01'});
      final warehouse = await helper.ensureMainWarehouse(pid);
      final result = await helper.createPurchaseList(
        pharmacyId: pid,
        mode: PurchaseListMode.supplierList,
        warehouseId: warehouse,
        supplierName: 'مذخر كبير',
        invoiceNumber: 'B-1',
        items: [
          for (var i = 0; i < 130; i++)
            {'trade_name': 'Item ${i.toString().padLeft(3, '0')}', 'quantity': 1, 'buy_price': 1000, 'sell_price': 1500, 'expiry_date': '2030-01-31'},
        ],
      );
      // 110 دفعة × 1000 → 111 حركة في كشف الحساب (فاتورة + دفعات).
      for (var i = 0; i < 110; i++) {
        await helper.addPurchaseInvoicePayment(
          pharmacyId: pid,
          supplierId: result['supplier_id'] as int,
          purchaseInvoiceId: result['purchase_invoice_id'] as int,
          amount: 1000,
        );
      }
    });
    await tester.pumpWidget(MaterialApp(home: MissingSuppliersScreen(pharmacyId: pid, entitlements: SubscriptionEntitlements.basic())));
    await settle(tester);
    await tester.tap(find.text('مذخر كبير').first);
    await settle(tester);

    // الأصناف المشتراة: 100 ثم "عرض المزيد".
    await tester.tap(find.byKey(const Key('supplier-tab-items')));
    await settle(tester);
    expect(find.text('Item 099'), findsOneWidget);
    expect(find.text('Item 100'), findsNothing);
    final more = find.byKey(const Key('supplier-items-more'));
    expect(find.descendant(of: more, matching: find.text('عرض المزيد (يُعرض 100 من 130)')), findsOneWidget);
    await tester.ensureVisible(more);
    await tester.tap(more);
    await settle(tester);
    expect(find.text('Item 129'), findsOneWidget);
    expect(find.byKey(const Key('supplier-items-more')), findsNothing);

    // كشف الحساب: آخر 100 حركة + رصيد ما قبلها (فاتورة 130,000 − 10 دفعات أقدم = 120,000 عليك).
    await tester.ensureVisible(find.byKey(const Key('supplier-tab-statement')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('supplier-tab-statement')));
    await settle(tester);
    expect(find.textContaining('رصيد ما قبل الحركات المعروضة (11 حركة أقدم)'), findsOneWidget);
    expect(find.text('عليك 120,000'), findsOneWidget); // الرصيد المرحَّل = رصيد آخر حركة مخفية
    expect(find.text('عليك 119,000'), findsOneWidget); // أول حركة معروضة (دفعة 11)
    await tester.ensureVisible(find.byKey(const Key('statement-show-all')));
    await tester.tap(find.byKey(const Key('statement-show-all')));
    await settle(tester);
    expect(find.textContaining('رصيد ما قبل الحركات المعروضة'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _NoNetworkOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _HangingHttpClient();
}

/// كل طلب يبقى معلقاً (لا رد ولا خطأ)؛ أي استدعاء آخر يُتجاهل.
class _HangingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => Completer<HttpClientRequest>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
