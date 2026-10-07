import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/models/report_period.dart';
import 'package:pharmacy_app/models/subscription_plan.dart';
import 'package:pharmacy_app/screens/reports/export/report_excel_builder.dart';
import 'package:pharmacy_app/screens/reports/export/report_export_controller.dart';
import 'package:pharmacy_app/screens/reports/export/report_export_data.dart';
import 'package:pharmacy_app/screens/reports/export/report_pdf_builder.dart';
import 'package:pharmacy_app/screens/reports_screen.dart';

import 'reports_screen_test.dart' show FakeReports, fixedNow;

/// FakeReports + تجزئة حقيقية للفواتير والراكدة لاختبار جلب كل الصفحات.
class PagedFakeReports extends FakeReports {
  PagedFakeReports({this.invoiceCount = 450, this.refundCount = 3, this.stagnantCount = 15});

  final int invoiceCount;
  final int refundCount;
  final int stagnantCount;
  final List<int?> pageSizes = [];

  Map<String, dynamic> _page(int total, int page, int? pageSize, Map<String, dynamic> Function(int i) row,
      Map<String, dynamic> extra) {
    pageSizes.add(pageSize);
    final size = pageSize ?? 50;
    final from = (page - 1) * size;
    final to = (from + size).clamp(0, total);
    return {
      'count': total,
      'page': page,
      'page_size': size,
      ...extra,
      'results': [for (var i = from; i < to; i++) row(i)],
    };
  }

  @override
  Future<Map<String, dynamic>> invoices(ReportPeriod period,
      {int page = 1, int? pageSize, String query = '', String seller = '', bool refunded = false}) async {
    calls.add('invoices:$page:$pageSize:$refunded');
    final total = refunded ? refundCount : invoiceCount;
    return _page(total, page, pageSize, (i) => {
          'id': i + 1,
          'invoice_number': '${refunded ? 'REF' : 'INV'}-${(i + 1).toString().padLeft(6, '0')}',
          'created_at': '2026-10-0${1 + i % 7}T1${i % 10}:30:00',
          'total_amount': 1000.0,
          'discount': i.isEven ? 100.0 : 0.0,
          'final_amount': i.isEven ? 900.0 : 1000.0,
          'seller_name': i.isEven ? 'علي' : 'Sara',
          'is_refunded': refunded,
        }, {'total_amount': total * 950.0});
  }

  @override
  Future<Map<String, dynamic>> stagnant(ReportPeriod period, {int page = 1, int? pageSize}) async {
    calls.add('stagnant:$page:$pageSize');
    return _page(stagnantCount, page, pageSize, (i) => {
          'medicine_id': 100 + i,
          'trade_name': i == 0 ? 'أموكسيسيلين 500' : 'Stagnant item $i',
          'category': 'tablet',
          'quantity': 10 + i,
          'stock_value': 5000.0 - i * 100,
          'last_sale': i.isEven ? null : '2026-08-1${i % 10}',
        }, {'total_value': 60000.0});
  }
}

class RecordingSaver implements ReportFileSaver {
  final List<String> picked = [];
  final Map<String, Uint8List> written = {};

  @override
  Future<String?> pickPath(String suggestedName, ReportExportFormat format) async {
    picked.add(suggestedName);
    return null;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async => written[path] = bytes;

  @override
  Future<void> open(String path) async {}
}

final period = ReportPeriod.custom(DateTime(2026, 10, 1), DateTime(2026, 10, 7));

Future<ReportExportData> collect(PagedFakeReports fake) =>
    ReportExportData.collect(fake, period, pharmacyName: 'صيدلية الشفاء', now: fixedNow);

Future<void> pumpScreen(WidgetTester tester, PagedFakeReports fake, SubscriptionEntitlements ent, RecordingSaver saver) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: ReportsScreen(
      pharmacyId: 1,
      isOnlineMode: false,
      repository: fake,
      clock: () => fixedNow,
      entitlements: ent,
      pharmacyName: 'صيدلية الشفاء',
      exportSaver: saver,
    ),
  ));
  await tester.pumpAndSettle();
}

List<List<CellValue?>> values(Sheet sheet) => [for (final r in sheet.rows) [for (final c in r) c?.value]];

String text(CellValue? v) => v is TextCellValue ? v.value.text ?? '' : '';

/// خلية رقمية حقيقية (لا نص). القارئ يعيد الأعداد الصحيحة كـ IntCellValue
/// حتى لو كُتبت DoubleCellValue.
double numOf(CellValue? v) => switch (v) {
      IntCellValue(:final value) => value.toDouble(),
      DoubleCellValue(:final value) => value,
      _ => fail('expected a numeric cell, got $v (${v.runtimeType})'),
    };

/// صف الورقة الذي خليته الأولى نص [label].
List<CellValue?> rowOf(Sheet sheet, String label) => values(sheet).firstWhere((r) => r.isNotEmpty && text(r.first) == label);

void main() {
  setUp(ReportPeriod.resetSessionForTesting);

  group('plan gating', () {
    test('report_export is a Gold/Diamond feature, merged with Basic features from the license payload', () {
      expect(SubscriptionEntitlements.basic().allows(AppFeature.reportExport), isFalse);
      expect(SubscriptionEntitlements.basic().isLocked(AppFeature.reportExport), isTrue);
      for (final plan in ['gold', 'diamond']) {
        expect(SubscriptionEntitlements.fromLicense({'plan': plan}).allows(AppFeature.reportExport), isTrue);
      }
      // صيغة الخادم الجديدة: features = خصائص الباقة فوق Basic فقط.
      final basic = SubscriptionEntitlements.fromLicense({'plan': 'basic', 'features': <String>[]});
      expect(basic.allows(AppFeature.reports), isTrue);
      expect(basic.allows(AppFeature.reportExport), isFalse);
      final gold = SubscriptionEntitlements.fromLicense({'plan': 'gold', 'features': ['multi_warehouse', 'report_export']});
      expect(gold.allows(AppFeature.pointOfSale), isTrue);
      expect(gold.allows(AppFeature.reportExport), isTrue);
    });

    testWidgets('Basic: export button shows the upgrade dialog and generates nothing', (tester) async {
      final fake = PagedFakeReports();
      final saver = RecordingSaver();
      await pumpScreen(tester, fake, SubscriptionEntitlements.basic(), saver);
      final callsBefore = List<String>.from(fake.calls);

      await tester.tap(find.byKey(const Key('reports-export')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('upgrade-required-dialog')), findsOneWidget);
      expect(find.text(reportExportUpgradeMessage), findsOneWidget);
      expect(find.text('تصدير Excel (كل الأقسام)'), findsNothing);

      await tester.tap(find.text('حسناً'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('upgrade-required-dialog')), findsNothing);
      expect(saver.picked, isEmpty);
      expect(saver.written, isEmpty);
      expect(fake.calls, callsBefore);
      expect(fake.pageSizes.whereType<int>(), isEmpty);
    });

    for (final plan in ['gold', 'diamond']) {
      testWidgets('$plan: export button opens the export menu', (tester) async {
        final fake = PagedFakeReports();
        final saver = RecordingSaver();
        await pumpScreen(tester, fake, SubscriptionEntitlements.fromLicense({'plan': plan}), saver);

        await tester.tap(find.byKey(const Key('reports-export')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('upgrade-required-dialog')), findsNothing);
        expect(find.text('تصدير Excel (كل الأقسام)'), findsOneWidget);
        expect(find.text('تصدير PDF (ملخص)'), findsOneWidget);

        // اختيار Excel يفتح نافذة الحفظ بالاسم الافتراضي؛ الإلغاء لا يولّد شيئاً.
        await tester.tap(find.text('تصدير Excel (كل الأقسام)'));
        await tester.pumpAndSettle();
        expect(saver.picked, ['تقرير_صيدلية_الشفاء_2026-10-01_2026-10-07.xlsx']);
        expect(saver.written, isEmpty);
      });
    }
  });

  group('data collection', () {
    test('fetches every page of invoices, refunds and stagnant items', () async {
      final fake = PagedFakeReports();
      final d = await collect(fake);
      expect(d.invoices.rows, hasLength(450));
      expect(d.invoices.capped, isFalse);
      expect(d.refunds.rows, hasLength(3));
      expect(d.stagnant.rows, hasLength(15));
      expect(fake.calls.where((c) => c.startsWith('invoices:') && c.endsWith(':false')), hasLength(3)); // 200+200+50
      expect(d.inventory['days'], 90);
    });

    test('caps long lists at 10,000 rows', () async {
      final d = await collect(PagedFakeReports(invoiceCount: 10050));
      expect(d.invoices.rows, hasLength(ReportExportData.rowCap));
      expect(d.invoices.count, 10050);
      expect(d.invoices.capped, isTrue);
    });
  });

  group('Excel', () {
    test('sheets, RTL, numeric/date cells and key totals round-trip', () async {
      final d = await collect(PagedFakeReports());
      final bytes = buildReportExcel(d);
      final book = Excel.decodeBytes(bytes);

      expect(book.tables.keys.toList(), reportExcelSheets);
      for (final name in reportExcelSheets) {
        expect(book.tables[name]!.isRTL, isTrue, reason: name);
      }

      final summary = book.tables['ملخص']!;
      expect(text(rowOf(summary, 'الصيدلية')[1]), 'صيدلية الشفاء');
      expect(rowOf(summary, 'الفترة')[1], const DateCellValue(year: 2026, month: 10, day: 1));
      final netSales = rowOf(summary, 'صافي المبيعات');
      expect(numOf(netSales[1]), 4400);
      final netSalesCell = summary.rows.firstWhere((r) => r.isNotEmpty && text(r.first?.value) == 'صافي المبيعات')[1]!;
      expect(netSalesCell.cellStyle?.numberFormat.formatCode, '#,##0 "د.ع"');
      expect(numOf(netSales[2]), 2200);
      expect(numOf(netSales[3]), closeTo(1.0, 1e-9)); // +100%
      expect(numOf(rowOf(summary, 'عدد الفواتير')[1]), 2);
      expect(numOf(rowOf(summary, 'الخصومات')[1]), -100);
      expect(numOf(rowOf(summary, 'صافي الربح')[1]), 1350);

      final sales = book.tables['المبيعات']!;
      final invoiceRows = values(sales).where((r) => r.isNotEmpty && text(r.first).startsWith('INV-')).toList();
      expect(invoiceRows, hasLength(450));
      expect(invoiceRows.first[1], isA<DateTimeCellValue>());
      final finalSum = invoiceRows.fold<double>(0, (s, r) => s + numOf(r[5]));
      expect(finalSum, 225 * 900.0 + 225 * 1000.0);
      expect(values(sales).where((r) => r.isNotEmpty && text(r.first).startsWith('REF-')), hasLength(3));
      expect(values(sales).any((r) => r.isNotEmpty && text(r.first).startsWith('ملاحظة')), isFalse);

      final items = values(book.tables['الأصناف']!);
      final top = items.firstWhere((r) => r.length > 1 && text(r[1]) == 'Panadol Extra Long Name 500mg');
      expect(numOf(top[0]), 1);
      expect(numOf(top[2]), 3);
      expect(numOf(top[5]), closeTo(1733.33, 1e-6));
      expect(numOf(top[6]), closeTo(1733.33 / 2933.33, 1e-9));
      // كل الراكدة (لا الصفحة الأولى فقط).
      expect(items.where((r) => r.isNotEmpty && text(r.first).startsWith('Stagnant item')), hasLength(14));
    });

    test('capped list gets a note row', () async {
      final d = await collect(PagedFakeReports(invoiceCount: 10050));
      final book = Excel.decodeBytes(buildReportExcel(d));
      final rows = values(book.tables['المبيعات']!);
      expect(rows.where((r) => r.isNotEmpty && text(r.first).startsWith('INV-')), hasLength(10000));
      expect(rows.any((r) => r.isNotEmpty && text(r.first).contains('من أصل 10050')), isTrue);
    });
  });

  group('PDF', () {
    Future<(Uint8List, List<String>)> build(PagedFakeReports fake) async {
      final d = await collect(fake);
      final input = ReportPdfInput(
        d,
        await File(reportPdfFontRegular).readAsBytes(),
        await File(reportPdfFontBold).readAsBytes(),
      );
      final logs = <String>[];
      final bytes = await runZoned(
        () => buildReportPdf(input),
        zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => logs.add(line)),
      );
      return (bytes, logs);
    }

    int pageCount(Uint8List bytes) => RegExp(r'/Type\s*/Page(?![s\w])').allMatches(String.fromCharCodes(bytes)).length;

    test('non-empty A4 summary with the Arabic font and no missing glyphs', () async {
      final (bytes, logs) = await build(PagedFakeReports());
      final raw = String.fromCharCodes(bytes);
      expect(bytes.length, greaterThan(10000));
      expect(raw.startsWith('%PDF'), isTrue);
      expect(pageCount(bytes), inInclusiveRange(1, 4));
      expect(raw, contains('Tajawal'));
      expect(raw, isNot(contains('Helvetica')));
      expect(logs.where((l) => l.contains('Unable to find a font')), isEmpty, reason: logs.join('\n'));
      expect(logs, isEmpty, reason: logs.join('\n'));
    });

    test('summary stays short even with many invoices/stagnant items', () async {
      final (bytes, logs) = await build(PagedFakeReports(invoiceCount: 3000, stagnantCount: 500));
      expect(pageCount(bytes), inInclusiveRange(1, 4));
      expect(logs, isEmpty, reason: logs.join('\n'));
    });
  });
}
