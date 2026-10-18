// ignore_for_file: invalid_use_of_visible_for_testing_member — أداة تُشغَّل عبر flutter test وتستخدم خطافات القاعدة المخصصة للاختبار (مسار بديل/إعادة فتح).
// قياس زمن الشاشات الرئيسية على بيانات التوليد.
//
// 1) مستوى الاستعلام: نفس استدعاءات المستودع/القاعدة التي تنفّذها كل شاشة،
//    كل استدعاء 5 مرات: الأول (بارد) والوسيط (دافئ).
// 2) مستوى الشاشة: فتح الشاشة الحقيقية حتى يختفي مؤشر التحميل. بيئة flutter
//    test بلا رسم فعلي (GPU) فالأرقام تقريبية لكنها تكشف ما هو بطيء نسبياً.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/report_period.dart';
import 'package:pharmacy_app/models/subscription_plan.dart';
import 'package:pharmacy_app/repository/Invoice_repository.dart';
import 'package:pharmacy_app/repository/medicine_repository.dart';
import 'package:pharmacy_app/repository/suppliers_repository.dart';
import 'package:pharmacy_app/repository/warehouse_repository.dart';
import 'package:pharmacy_app/screens/damaged_screen.dart';
import 'package:pharmacy_app/screens/dashboard_screen.dart';
import 'package:pharmacy_app/screens/inventory_screen.dart';
import 'package:pharmacy_app/screens/missing_suppliers.dart';
import 'package:pharmacy_app/screens/pos_screen.dart';
import 'package:pharmacy_app/screens/reports/report_widgets.dart';
import 'package:pharmacy_app/screens/reports/reports_screen.dart';
import 'package:pharmacy_app/screens/sales_history_screen.dart';
import 'package:pharmacy_app/services/reports_local_service.dart';

import 'load_test_common.dart';

class _Result {
  final String group;
  final String name;
  final double coldMs;
  final double warmMs;
  final String detail;
  _Result(this.group, this.name, this.coldMs, this.warmMs, this.detail);

  Map<String, dynamic> toJson() => {'group': group, 'name': name, 'cold_ms': coldMs, 'warm_ms': warmMs, 'detail': detail};
}

void measureScreens({required void Function(String) log, required Future<void> Function() open}) {
  final results = <_Result>[];
  const pid = LoadTestConfig.pharmacyId;

  Future<void> time(String group, String name, Future<Object?> Function() run, {int runs = 5}) async {
    final samples = <double>[];
    var detail = '';
    for (var i = 0; i < runs; i++) {
      final w = Stopwatch()..start();
      final value = await run();
      samples.add(w.elapsedMicroseconds / 1000);
      if (i == 0) {
        detail = switch (value) {
          final List l => '${l.length} rows',
          final InvoicePage p => '${p.rows.length} rows${p.hasMore ? '+' : ''}',
          final Map m when m['count'] != null => 'count ${m['count']}',
          _ => '',
        };
      }
    }
    final warm = samples.skip(1).toList()..sort();
    results.add(_Result(group, name, samples.first, warm.isEmpty ? samples.first : warm[warm.length ~/ 2], detail));
  }

  test('query-level timings', () async {
    LoadTestConfig.validate();
    await open();
    final helper = DatabaseHelper.instance;
    final db = await helper.database;
    final meds = MedicineRepository.instance;
    final invoices = InvoiceRepository.instance;
    final mainWarehouse = await WarehouseRepository.instance.getMainWarehouseId(pharmacyId: pid, isOnlineMode: false);

    // نصوص بحث واقعية من البيانات نفسها.
    final top = (await db.rawQuery('''
      SELECT ii.trade_name, COUNT(*) c FROM invoice_item ii JOIN invoice i ON i.id = ii.invoice_id
      WHERE i.pharmacy_id = ? GROUP BY ii.trade_name ORDER BY c DESC LIMIT 1
    ''', [pid])).first['trade_name'] as String;
    final term = top.substring(0, 4).toLowerCase();
    final barcode = (await db.rawQuery("SELECT barcode FROM medicine WHERE pharmacy_id = ? AND barcode LIKE '200%' LIMIT 1", [pid])).first['barcode'] as String;
    final category = (await meds.getCategories(pharmacyId: pid, warehouseId: mainWarehouse)).firstWhere((c) => c == 'tablet', orElse: () => '');
    final lastInvoice = (await db.rawQuery('SELECT invoice_number FROM invoice WHERE pharmacy_id = ? ORDER BY id DESC LIMIT 1', [pid])).first['invoice_number'] as String;
    final numberTerm = lastInvoice.substring(0, lastInvoice.length - 2);
    final sellers = await invoices.getSellers(pharmacyId: pid, isOnlineMode: false);
    log('Search terms: medicine "$term" (from "$top"), barcode $barcode, invoice "$numberTerm", category $category');

    // المخزون
    await time('Inventory', 'open: all items (main warehouse)', () => meds.getMedicines(pharmacyId: pid, isOnlineMode: false, warehouseId: mainWarehouse));
    await time('Inventory', 'categories dropdown', () => meds.getCategories(pharmacyId: pid, warehouseId: mainWarehouse));
    await time('Inventory', 'search "$term"', () => meds.getMedicines(pharmacyId: pid, isOnlineMode: false, syncFromServer: false, warehouseId: mainWarehouse, search: term));
    await time('Inventory', 'search + category', () => meds.getMedicines(pharmacyId: pid, isOnlineMode: false, syncFromServer: false, warehouseId: mainWarehouse, search: term, category: category));
    await time('Inventory', 'barcode search', () => meds.getMedicines(pharmacyId: pid, isOnlineMode: false, syncFromServer: false, warehouseId: mainWarehouse, search: barcode));

    // سجل المبيعات
    Future<InvoicePage> page({String search = '', String? seller, bool? refunded, bool? hasDiscount, DateTime? start, DateTime? end}) =>
        invoices.getInvoicesPage(pharmacyId: pid, isOnlineMode: false, search: search, seller: seller, refunded: refunded, hasDiscount: hasDiscount, start: start, end: end);
    final now = DateTime.now();
    await time('Sales History', 'open: first page', () => page());
    await time('Sales History', 'sellers dropdown', () => invoices.getSellers(pharmacyId: pid, isOnlineMode: false));
    await time('Sales History', 'search invoice number "$numberTerm"', () => page(search: numberTerm));
    await time('Sales History', 'search medicine name "$term"', () => page(search: term));
    await time('Sales History', 'seller filter', () => page(seller: sellers.first));
    await time('Sales History', 'status = refunded', () => page(refunded: true));
    await time('Sales History', 'with discount', () => page(hasDiscount: true));
    await time('Sales History', 'date range (last 30 days)', () => page(start: now.subtract(const Duration(days: 30)), end: now));
    await time('Sales History', 'all filters + medicine search', () => page(search: term, seller: sellers.first, refunded: false, hasDiscount: true, start: now.subtract(const Duration(days: 180)), end: now));
    await time('Sales History', 'all filters, no match (scans all)', () => page(search: 'zzzz', seller: sellers.first, refunded: true, hasDiscount: true));
    await time('Sales History', 'load more (page 20)', () => invoices.getInvoicesPage(pharmacyId: pid, isOnlineMode: false, page: 20));

    // التقارير
    final reports = ReportsLocalService();
    for (final entry in {
      '1 month': ReportPeriod.custom(now.subtract(const Duration(days: 29)), now),
      '12 months': ReportPeriod.custom(now.subtract(const Duration(days: 364)), now),
    }.entries) {
      final p = entry.value;
      final g = 'Reports ${entry.key}';
      await time(g, 'KPIs + alerts (cards)', () => reports.kpis(pid, p), runs: 3);
      await time(g, 'overview: trend', () => reports.trend(pid, p), runs: 3);
      await time(g, 'overview: categories', () => reports.categories(pid, p), runs: 3);
      await time(g, 'overview: peak hours', () => reports.hours(pid, p), runs: 3);
      await time(g, 'sales: invoices page', () => reports.invoices(pid, p), runs: 3);
      await time(g, 'sales: sellers', () => reports.sellers(pid, p), runs: 3);
      await time(g, 'items: top/below cost', () => reports.items(pid, p), runs: 3);
      await time(g, 'items: stagnant', () => reports.stagnant(pid, p), runs: 3);
      await time(g, 'purchases & suppliers', () => reports.purchases(pid, p), runs: 3);
      await time(g, 'expenses & losses', () => reports.losses(pid, p), runs: 3);
    }
    await time('Reports (current state)', 'inventory tab (90 days)', () => reports.inventory(pid, days: 90), runs: 3);

    // الرئيسية
    await time('Dashboard', 'medicine count', () => helper.medicineCountByPharmacy(pid));
    await time('Dashboard', 'today sales/count', () => invoices.getTodayStats(pharmacyId: pid, isOnlineMode: false));
    await time('Dashboard', 'expiry warnings (90 days)', () => helper.getExpiredMedicines(pid, daysAhead: 90));
    await time('Dashboard', 'low stock (main warehouse)', () => helper.getLowStockMedicines(pid, warehouseId: mainWarehouse));

    // التالف
    await time('Damaged', 'open: list', () => meds.getDamagedMedicines(pharmacyId: pid, isOnlineMode: false));
    await time('Damaged', 'search "$term"', () => meds.getDamagedMedicines(pharmacyId: pid, isOnlineMode: false, syncFromServer: false, search: term));
    await time('Damaged', 'dialog medicine search "$term"', () => meds.searchMedicinesForPicker(pharmacyId: pid, isOnlineMode: false, query: term));
    await time('Damaged', 'dialog medicine search "a" (broad)', () => meds.searchMedicinesForPicker(pharmacyId: pid, isOnlineMode: false, query: 'a'));

    // نقطة البيع
    await time('POS', 'open: load sellable medicines', () => helper.getMedicines(pid, warehouseId: mainWarehouse));
    await time('POS', 'recent invoices (20)', () => invoices.getRecentInvoices(pharmacyId: pid, isOnlineMode: false));
    await time('POS', 'barcode scan lookup', () => helper.getMedicineByBarcode(barcode, warehouseId: mainWarehouse));
    await time('POS', 'next invoice number (per checkout)', () => helper.generateInvoiceNumber());
    final all = await helper.getMedicines(pid, warehouseId: mainWarehouse);
    await time('POS', 'type-ahead filter (in memory)', () async => all
        .where((m) => '${m['trade_name']} ${m['scientific_name']} ${m['barcode']}'.toLowerCase().contains(term))
        .toList());

    // المذاخر
    final suppliers = SuppliersRepository.instance;
    await time('Suppliers', 'open: suppliers + balances', () => suppliers.getSuppliersWithFinancials(pharmacyId: pid, isOnlineMode: false));
    final busiest = (await db.rawQuery('SELECT supplier_id, COUNT(*) c FROM purchase_invoice WHERE pharmacy_id = ? GROUP BY supplier_id ORDER BY c DESC LIMIT 1', [pid])).first['supplier_id'] as int;
    await time('Suppliers', 'busiest supplier: invoices', () => suppliers.getPurchaseInvoicesBySupplier(isOnlineMode: false, supplierId: busiest));
    await time('Suppliers', 'busiest supplier: statement', () => suppliers.getSupplierStatementOfAccount(supplierId: busiest, isOnlineMode: false));
  }, timeout: Timeout.none);

  // ---------------------------------------------------------------------------
  // مستوى الشاشة
  // ---------------------------------------------------------------------------

  Future<void> screen(WidgetTester tester, String name, Widget child, {Future<void> Function()? after, String? afterName}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // GoogleFonts (الرئيسية والشريط) ينزّل الخط من الإنترنت؛ flutter test يرد بـ400
    // فيفشل الاختبار. بلا شبكة: الطلب يبقى معلقاً والخط الاحتياطي يُستخدم.
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _NoNetworkOverrides();
    addTearDown(() => HttpOverrides.global = previousOverrides);
    bool loading() =>
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty || find.byType(SkeletonBlock).evaluate().isNotEmpty;
    Future<double> waitLoaded() async {
      final w = Stopwatch()..start();
      // أول إطار ثم انتظار انتهاء التحميل (حتى 120 ثانية).
      await tester.pump();
      while (w.elapsed.inSeconds < 120) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
        if (!loading()) {
          // تأكيد: إطاران متتاليان بلا تحميل.
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
          if (!loading()) break;
        }
      }
      return w.elapsedMicroseconds / 1000;
    }

    await tester.runAsync(open);
    final w = Stopwatch()..start();
    await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: child))));
    await waitLoaded();
    final ms = w.elapsedMicroseconds / 1000;
    results.add(_Result('Screen open', name, ms, ms, ''));
    if (after != null) {
      final w2 = Stopwatch()..start();
      await after();
      await waitLoaded();
      final ms2 = w2.elapsedMicroseconds / 1000;
      results.add(_Result('Screen open', afterName!, ms2, ms2, ''));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(DatabaseHelper.resetForTesting);
  }

  final basic = SubscriptionEntitlements.basic();
  // مرتان: الأولى تشمل كلفة أول فتح للقاعدة وأول بناء ويدجت في الجلسة (تسخين).
  testWidgets('screen: Dashboard', (t) => screen(t, 'Dashboard (first screen of the run)', const DashboardScreen(pharmacyId: pid)), timeout: Timeout.none);
  testWidgets('screen: Dashboard again', (t) => screen(t, 'Dashboard (warm)', const DashboardScreen(pharmacyId: pid)), timeout: Timeout.none);
  testWidgets('screen: Inventory', (t) => screen(
        t,
        'Inventory',
        InventoryScreen(pharmacyId: pid, entitlements: basic),
        // نفس الشاشة بعد بحث يُبقي ~5 صفوف: يفصل كلفة الاستعلام عن رسم الجدول.
        afterName: 'Inventory: re-render after search (5 rows, incl. 300ms debounce)',
        after: () async {
          await t.enterText(find.byType(TextField).first, 'sino');
          await t.pump(const Duration(milliseconds: 310));
        },
      ), timeout: Timeout.none);
  testWidgets('screen: POS', (t) => screen(t, 'POS', const PosScreen(pharmacyId: pid, userId: 7)), timeout: Timeout.none);
  testWidgets('screen: Sales History', (t) => screen(t, 'Sales History', const SalesHistoryScreen(pharmacyId: pid)), timeout: Timeout.none);
  testWidgets('screen: Damaged', (t) => screen(t, 'Damaged', const DamagedScreen(pharmacyId: pid, isOnlineMode: false)), timeout: Timeout.none);
  testWidgets('screen: Suppliers', (t) => screen(t, 'Suppliers', MissingSuppliersScreen(pharmacyId: pid, entitlements: basic)), timeout: Timeout.none);

  // تفاصيل أكثر مذخر فواتيراً: فتحه (تبويب الفواتير) ثم كشف الحساب والأصناف المشتراة.
  Future<String> busiestSupplierName(WidgetTester t) async => (await t.runAsync(() async {
        final db = await DatabaseHelper.instance.database;
        return (await db.rawQuery('''
          SELECT s.name FROM purchase_invoice pi JOIN pharmacy_supplier s ON s.id = pi.supplier_id
          WHERE pi.pharmacy_id = ? GROUP BY s.id ORDER BY COUNT(*) DESC LIMIT 1
        ''', [pid])).first['name'] as String;
      }))!;
  for (final tab in [null, 'كشف الحساب', 'الأصناف المشتراة']) {
    final label = tab == null ? 'Suppliers: open busiest supplier (invoices tab)' : 'Suppliers: busiest supplier → $tab';
    testWidgets('screen: $label', (t) => screen(
          t,
          'Suppliers (list)',
          MissingSuppliersScreen(pharmacyId: pid, entitlements: basic),
          afterName: label,
          after: () async {
            await t.tap(find.text(await busiestSupplierName(t)).first);
            await t.pump();
            if (tab != null) {
              for (var i = 0; i < 40; i++) {
                await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
                await t.pump();
              }
              await t.tap(find.text(tab).first);
              await t.pump();
            }
          },
        ), timeout: Timeout.none);
  }
  testWidgets('screen: Reports', (t) {
    ReportPeriod.resetSessionForTesting();
    return screen(
      t,
      'Reports (this month, overview tab)',
      ReportsScreen(pharmacyId: pid, isOnlineMode: false, entitlements: basic),
      afterName: 'Reports: switch to "this year"',
      after: () async {
        await t.tap(find.byKey(const Key('preset-thisYear')));
        await t.pump();
      },
    );
  }, timeout: Timeout.none);

  tearDownAll(() {
    final buffer = StringBuffer()..writeln('\n=== Load-test measurements (ms) ===');
    String? group;
    for (final r in results) {
      if (r.group != group) buffer.writeln('\n[${group = r.group}]');
      final flag = r.warmMs > 1000 || r.coldMs > 1000 ? '  <-- SLOW' : '';
      buffer.writeln('  ${r.name.padRight(46)} cold ${r.coldMs.toStringAsFixed(1).padLeft(9)}  warm ${r.warmMs.toStringAsFixed(1).padLeft(9)}  ${r.detail}$flag');
    }
    stdout.writeln(buffer);
    final out = File('${File(LoadTestConfig.stateFile).parent.path}${Platform.pathSeparator}load_test_measurements_${stamp(DateTime.now())}.json');
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert([for (final r in results) r.toJson()]));
    stdout.writeln('Saved: ${out.path}');
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
