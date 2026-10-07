import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/subscription_plan.dart';
import '../models/supplier_statement.dart';
import '../widgets/upgrade_required_dialog.dart';
import 'reports/export/report_export_controller.dart';
import 'reports/export/report_pdf_builder.dart';
import 'reports/report_widgets.dart';

/// كشف حساب المذخر جاهزاً للطباعة (نصوص فقط، ليُمرَّر إلى compute()).
class SupplierStatementPdfData {
  const SupplierStatementPdfData({
    required this.pharmacyName,
    required this.supplierName,
    required this.periodLabel,
    required this.generatedAt,
    required this.rows,
    required this.boldRows,
    required this.closingText,
    required this.aging,
  });

  factory SupplierStatementPdfData.from(
    SupplierStatement statement, {
    required String pharmacyName,
    required String supplierName,
    required List<AgingBucket>? aging,
    DateTime? now,
  }) {
    String money(double v) => v.abs() < 0.001 ? '' : statementAmount(v);
    final rows = <List<String>>[];
    final bold = <int>{};
    if (statement.showOpening) {
      bold.add(rows.length);
      rows.add(['', '', '', 'الرصيد الافتتاحي', '', '', balanceWords(statement.opening)]);
    }
    for (final e in statement.entries) {
      final items = e.itemLines;
      rows.add([
        DateFormat('yyyy/MM/dd').format(e.at),
        e.typeLabel,
        e.invoiceNumber ?? '',
        items.isEmpty ? e.description : '${e.description}\n${items.map((l) => '• $l').join('\n')}',
        money(e.increase),
        money(e.decrease),
        balanceWords(e.balance),
      ]);
    }
    bold.add(rows.length);
    rows.add([
      '',
      '',
      '',
      'الإجمالي',
      statementAmount(statement.totalIncrease),
      statementAmount(statement.totalDecrease),
      balanceWords(statement.closing),
    ]);
    return SupplierStatementPdfData(
      pharmacyName: pharmacyName,
      supplierName: supplierName,
      periodLabel: statement.period.label,
      generatedAt: now ?? DateTime.now(),
      rows: rows,
      boldRows: bold,
      closingText: 'الرصيد الختامي: ${balanceWords(statement.closing)}',
      aging: aging == null
          ? null
          : [for (final b in aging) [b.label, '${b.count}', '${statementAmount(b.amount)} د.ع']],
    );
  }

  final String pharmacyName;
  final String supplierName;
  final String periodLabel;
  final DateTime generatedAt;
  final List<List<String>> rows;
  final Set<int> boldRows;
  final String closingText;

  /// null = لا دين على الصيدلية (لا تُطبع أعمار الديون).
  final List<List<String>>? aging;

  String get fileName {
    final safe = supplierName.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return 'كشف_حساب_${safe}_${DateFormat('yyyy-MM-dd').format(generatedAt)}.pdf';
  }
}

class SupplierStatementPdfInput {
  const SupplierStatementPdfInput(this.data, this.regularFont, this.boldFont);

  final SupplierStatementPdfData data;
  final Uint8List regularFont;
  final Uint8List boldFont;
}

const _teal = PdfColor.fromInt(0xFF117A65);
const _muted = PdfColor.fromInt(0xFF64748B);
const _headerBg = PdfColor.fromInt(0xFFE8F8F5);

/// A4 عمودي بنفس أسلوب ملخص التقارير: رأس (الصيدلية، المذخر، الفترة، تاريخ
/// الإنشاء)، الحركات بين الرصيد الافتتاحي والختامي، ثم أعمار الديون.
Future<Uint8List> buildSupplierStatementPdf(SupplierStatementPdfInput input) {
  final d = input.data;
  final doc = pw.Document(title: d.fileName, author: d.pharmacyName, creator: 'Tera Pharmacy');
  doc.addPage(
    pw.MultiPage(
      pageTheme: reportPdfPageTheme(input.regularFont, input.boldFont),
      footer: (context) => reportPdfFooter(context, d.pharmacyName),
      build: (context) => [
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(color: _headerBg, borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('كشف حساب المذخر: ${d.supplierName}',
                  style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _teal)),
              pw.SizedBox(height: 4),
              pw.Text(d.pharmacyName, style: const pw.TextStyle(fontSize: 11)),
              pw.Text('الفترة: ${d.periodLabel}', style: const pw.TextStyle(fontSize: 10)),
              pw.Text('تاريخ الإنشاء: ${DateFormat('yyyy/MM/dd HH:mm').format(d.generatedAt)}',
                  style: const pw.TextStyle(fontSize: 9, color: _muted)),
            ],
          ),
        ),
        reportPdfSection('الحركات'),
        reportPdfTable(
          const ['التاريخ', 'نوع الحركة', 'رقم المستند', 'البيان', 'يزيد الدين (+)', 'ينقص الدين (−)', 'الرصيد'],
          d.rows,
          flex: const [3, 3, 2, 7, 3, 3, 4],
          boldRows: d.boldRows,
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(d.closingText, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _teal)),
        ),
        if (d.aging != null) ...[
          reportPdfSection('أعمار الديون (المتبقي من الفواتير المفتوحة)'),
          reportPdfTable(const ['عمر الفاتورة', 'عدد الفواتير', 'المبلغ'], d.aging!, flex: const [3, 2, 3]),
        ],
      ],
    ),
  );
  return doc.save();
}

/// زر/إجراء "طباعة PDF": نفس قيد تصدير التقارير (الذهبية والماسية؛ Basic يرى
/// نافذة الترقية ولا يُنشأ شيء).
Future<void> exportSupplierStatementPdf(
  BuildContext context, {
  required SubscriptionEntitlements entitlements,
  required SupplierStatementPdfData Function() data,
  ReportFileSaver saver = const NativeReportFileSaver(),
}) async {
  if (!entitlements.allows(AppFeature.reportExport)) {
    await showUpgradeRequiredDialog(context, message: reportExportUpgradeMessage);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final pdfData = data();
  final String? path;
  try {
    path = await saver.pickPath(pdfData.fileName, ReportExportFormat.pdf);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('تعذر فتح نافذة الحفظ: $e'), backgroundColor: RC.red));
    return;
  }
  if (path == null) return;
  try {
    final regular = await rootBundle.load(reportPdfFontRegular);
    final bold = await rootBundle.load(reportPdfFontBold);
    final bytes = await compute(
      buildSupplierStatementPdf,
      SupplierStatementPdfInput(pdfData, regular.buffer.asUint8List(), bold.buffer.asUint8List()),
    );
    await saver.write(path, bytes);
    messenger.showSnackBar(
      SnackBar(
        content: Text('تم حفظ كشف الحساب: ${path.split(RegExp(r'[\\/]')).last}'),
        backgroundColor: RC.green,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: 'فتح الملف', textColor: Colors.white, onPressed: () => saver.open(path!)),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('تعذر إنشاء ملف PDF: $e'), backgroundColor: RC.red));
  }
}
