import 'package:flutter/material.dart';
import '../database/db_helper.dart';
import '../services/migration_api_service.dart';

const Map<String, String> _kStageLabels = {
  'suppliers': 'الموردون',
  'medicines': 'الأدوية',
  'purchase_invoices': 'فواتير الشراء',
  'invoices': 'فواتير البيع',
  'damaged_medicines': 'الأدوية التالفة',
  'expenses': 'المصاريف',
};

/// نقطة 5: تحويل صيدلية أوفلاين إلى أونلاين عبر رفع أولي شامل من جهاز
/// المالك — يشمل كل شيء بلا استثناء (موردون، مخزون، فواتير شراء بدفعاتها
/// ومرتجعاتها، فواتير بيع بعناصرها الكاملة، تالف، مصاريف)، ضمن معاملة
/// ذرّية واحدة على السيرفر (راجع MigrationViewSet).
///
/// ⚠️ لا حذف لأي بيانات محلية بعد النجاح — النسخة المحلية في جهاز المالك
/// تبقى كما هي، وتُستخدم كقراءة/كاش لاحقاً مثل أي جهاز آخر للصيدلية.
class OfflineMigrationScreen extends StatefulWidget {
  final int pharmacyId;

  const OfflineMigrationScreen({super.key, required this.pharmacyId});

  @override
  State<OfflineMigrationScreen> createState() => _OfflineMigrationScreenState();
}

class _OfflineMigrationScreenState extends State<OfflineMigrationScreen> {
  bool _isUploading = false;
  Map<String, dynamic>? _result;
  String? _error;
  int _overallDone = 0;
  int _overallTotal = 0;
  String _currentStage = '';

  Future<void> _startUpload() async {
    setState(() {
      _isUploading = true;
      _error = null;
      _overallDone = 0;
      _overallTotal = 0;
      _currentStage = '';
    });

    try {
      final payload = await DatabaseHelper.instance.getOfflineMigrationPayload(widget.pharmacyId);

      final result = await MigrationApiService.instance.uploadOfflineData(
        payload,
        onProgress: (done, total, stage) {
          if (!mounted) return;
          setState(() {
            _overallDone = done;
            _overallTotal = total;
            _currentStage = stage;
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _result = result;
        _isUploading = false;
      });
    } on MigrationApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isUploading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'حدث خطأ غير متوقع: $e';
        _isUploading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F6F9),
        appBar: AppBar(
          title: const Text('تحويل الصيدلية إلى أونلاين'),
          backgroundColor: const Color(0xFF0D9488),
          foregroundColor: Colors.white,
          automaticallyImplyLeading: !_isUploading,
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              width: 500,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 20, offset: const Offset(0, 5)),
                ],
              ),
              child: _result != null
                  ? _buildSuccessView()
                  : (_isUploading ? _buildProgressView() : _buildIntroView()),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIntroView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.cloud_upload_rounded, color: Color(0xFF0D9488), size: 40),
        const SizedBox(height: 16),
        const Text(
          'رفع بياناتك المحلية إلى السيرفر',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
        ),
        const SizedBox(height: 10),
        const Text(
          'سيُرفع كل شيء بلا استثناء: الموردون، المخزون الكامل، كل فواتير '
          'الشراء بدفعاتها ومرتجعاتها، كل فواتير البيع التاريخية بعناصرها، '
          'كل سجلات الإتلاف، وكل المصاريف — دفعة واحدة ضمن معاملة واحدة '
          'على السيرفر.',
          style: TextStyle(fontSize: 13, color: Color(0xFF6B7280), height: 1.6),
        ),
        const SizedBox(height: 8),
        const Text(
          '✓ بياناتك المحلية لن تُحذف بعد الرفع — تبقى كما هي.\n'
          '⚠️ لا يمكن تكرار هذه العملية بعد نجاحها.',
          style: TextStyle(fontSize: 12, color: Color(0xFF9A3412), fontWeight: FontWeight.bold, height: 1.6),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(8)),
            child: Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 13)),
          ),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0D9488),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _startUpload,
            child: const Text('ابدأ الرفع الآن', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('لاحقاً', style: TextStyle(color: Color(0xFF6B7280))),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressView() {
    final fraction = _overallTotal > 0 ? _overallDone / _overallTotal : null;
    final stageLabel = _kStageLabels[_currentStage] ?? _currentStage;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'جارٍ الرفع... لا تُغلق التطبيق',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
        ),
        const SizedBox(height: 20),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 10,
            backgroundColor: const Color(0xFFE5E7EB),
            color: const Color(0xFF0D9488),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _overallTotal > 0
              ? 'تم رفع $_overallDone من $_overallTotal سجلاً'
              : 'جارٍ التحضير...',
          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
        ),
        if (stageLabel.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('المرحلة الحالية: $stageLabel', style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
        ],
      ],
    );
  }

  Widget _buildSuccessView() {
    final r = _result!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A), size: 40),
        const SizedBox(height: 16),
        const Text(
          'تم الرفع بنجاح',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
        ),
        const SizedBox(height: 12),
        _summaryRow('الموردون', '${r['suppliers_created']}'),
        _summaryRow('الأدوية', '${r['medicines_created']}'),
        _summaryRow('فواتير الشراء', '${r['purchase_invoices_created']}'),
        _summaryRow('دفعات الموردين', '${r['supplier_payments_created']}'),
        _summaryRow('مرتجعات الشراء', '${r['purchase_invoice_returns_created']}'),
        _summaryRow('فواتير البيع', '${r['invoices_created']}'),
        _summaryRow('عناصر فواتير البيع', '${r['invoice_items_created']}'),
        _summaryRow('سجلات التالف', '${r['damaged_records_created']}'),
        _summaryRow('المصاريف', '${r['expenses_created']}'),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0D9488),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('متابعة', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _summaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1F2937), fontSize: 13)),
        ],
      ),
    );
  }
}