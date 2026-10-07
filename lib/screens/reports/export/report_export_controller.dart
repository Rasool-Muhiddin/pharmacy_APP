import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../../../models/report_period.dart';
import '../../../models/subscription_plan.dart';
import '../../../repository/reports_repository.dart';
import '../../../widgets/upgrade_required_dialog.dart';
import '../report_widgets.dart';
import 'report_excel_builder.dart';
import 'report_export_data.dart';
import 'report_pdf_builder.dart';

enum ReportExportFormat { excel, pdf }

extension on ReportExportFormat {
  String get extension => this == ReportExportFormat.excel ? 'xlsx' : 'pdf';
  String get typeLabel => this == ReportExportFormat.excel ? 'Excel' : 'PDF';
}

const String reportExportUpgradeMessage =
    'خطتك الحالية لا تتيح تصدير التقارير. هذه الميزة متاحة في الباقة الذهبية والماسية. تواصل مع الدعم للترقية.';

/// حفظ وفتح الملف — قابل للاستبدال في الاختبارات.
abstract class ReportFileSaver {
  /// مسار الحفظ من نافذة الحفظ الأصلية، أو null عند الإلغاء.
  Future<String?> pickPath(String suggestedName, ReportExportFormat format);

  Future<void> write(String path, Uint8List bytes);

  Future<void> open(String path);
}

class NativeReportFileSaver implements ReportFileSaver {
  const NativeReportFileSaver();

  @override
  Future<String?> pickPath(String suggestedName, ReportExportFormat format) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [XTypeGroup(label: format.typeLabel, extensions: [format.extension])],
    );
    if (location == null) return null;
    final path = location.path;
    return path.toLowerCase().endsWith('.${format.extension}') ? path : '$path.${format.extension}';
  }

  @override
  Future<void> write(String path, Uint8List bytes) => File(path).writeAsBytes(bytes, flush: true);

  @override
  Future<void> open(String path) => OpenFilex.open(path);
}

/// زر "تصدير" في رأس شاشة التقارير. يظهر دائماً؛ في Basic يعرض نافذة
/// الترقية ولا يصدّر شيئاً (القرار من الترخيص المحفوظ محلياً فيعمل أوفلاين).
class ReportExportButton extends StatelessWidget {
  const ReportExportButton({
    super.key,
    required this.entitlements,
    required this.repo,
    required this.period,
    required this.pharmacyName,
    this.saver = const NativeReportFileSaver(),
  });

  final SubscriptionEntitlements entitlements;
  final ReportsDataSource repo;
  final ReportPeriod period;
  final String pharmacyName;
  final ReportFileSaver saver;

  Future<void> _onPressed(BuildContext context) async {
    if (!entitlements.allows(AppFeature.reportExport)) {
      await showUpgradeRequiredDialog(context, message: reportExportUpgradeMessage);
      return;
    }
    final box = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = box.localToGlobal(Offset(0, box.size.height), ancestor: overlay);
    final format = await showMenu<ReportExportFormat>(
      context: context,
      position: RelativeRect.fromRect(topLeft & box.size, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(
          key: Key('export-excel'),
          value: ReportExportFormat.excel,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.grid_on, color: RC.green),
            title: Text('تصدير Excel (كل الأقسام)'),
          ),
        ),
        PopupMenuItem(
          key: Key('export-pdf'),
          value: ReportExportFormat.pdf,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.picture_as_pdf_outlined, color: RC.red),
            title: Text('تصدير PDF (ملخص)'),
          ),
        ),
      ],
    );
    if (format == null || !context.mounted) return;
    await exportReport(context, format: format, repo: repo, period: period, pharmacyName: pharmacyName, saver: saver);
  }

  @override
  Widget build(BuildContext context) {
    final locked = !entitlements.allows(AppFeature.reportExport);
    return Builder(
      builder: (context) => OutlinedButton.icon(
        key: const Key('reports-export'),
        onPressed: () => _onPressed(context),
        icon: Icon(locked ? Icons.lock_outline : Icons.file_download_outlined, size: 18),
        label: const Text('تصدير'),
        style: OutlinedButton.styleFrom(
          foregroundColor: locked ? const Color(0xFFD97706) : RC.tealDark,
          side: BorderSide(color: locked ? const Color(0xFFFCD34D) : RC.tealLight),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }
}

/// يسأل عن مكان الحفظ أولاً (الإلغاء لا يكلّف شيئاً)، ثم يجمع البيانات مع
/// مؤشر تقدم، ويبني الملف في isolate منفصل (compute) كي لا تتجمد الواجهة.
Future<void> exportReport(
  BuildContext context, {
  required ReportExportFormat format,
  required ReportsDataSource repo,
  required ReportPeriod period,
  required String pharmacyName,
  ReportFileSaver saver = const NativeReportFileSaver(),
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final name = pharmacyName.trim().isEmpty ? 'الصيدلية' : pharmacyName.trim();
  final suggested = reportFileName(name, period, format.extension);

  final String? path;
  try {
    path = await saver.pickPath(suggested, format);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('تعذر فتح نافذة الحفظ: $e'), backgroundColor: RC.red));
    return;
  }
  if (path == null || !context.mounted) return;

  final progress = ValueNotifier<double?>(0);
  final status = ValueNotifier<String>('جارٍ جمع بيانات التقرير...');
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: _ProgressDialog(progress: progress, status: status),
    ),
  );

  try {
    final data = await ReportExportData.collect(
      repo,
      period,
      pharmacyName: name,
      onProgress: (p) => progress.value = p * 0.8,
    );
    progress.value = null;
    status.value = 'جارٍ إنشاء ملف ${format.typeLabel}...';
    final Uint8List bytes;
    if (format == ReportExportFormat.excel) {
      bytes = await compute(buildReportExcel, data);
    } else {
      final regular = await rootBundle.load(reportPdfFontRegular);
      final bold = await rootBundle.load(reportPdfFontBold);
      bytes = await compute(
        buildReportPdf,
        ReportPdfInput(data, regular.buffer.asUint8List(), bold.buffer.asUint8List()),
      );
    }
    status.value = 'جارٍ حفظ الملف...';
    await saver.write(path, bytes);
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text('تم حفظ التقرير: ${path.split(RegExp(r'[\\/]')).last}'),
        backgroundColor: RC.green,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: 'فتح الملف', textColor: Colors.white, onPressed: () => saver.open(path!)),
      ),
    );
  } catch (e) {
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('تعذر تصدير التقرير: $e'), backgroundColor: RC.red));
  } finally {
    progress.dispose();
    status.dispose();
  }
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.progress, required this.status});

  final ValueListenable<double?> progress;
  final ValueListenable<String> status;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        key: const Key('export-progress'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, text, __) => Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 14),
            ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (_, value, __) => LinearProgressIndicator(value: value, color: RC.teal, minHeight: 6),
            ),
          ],
        ),
      ),
    );
  }
}
