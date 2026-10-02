import 'dart:async';

import 'package:flutter/material.dart';

import '../models/license_expiry.dart';

/// شريط تحذير صغير غير قابل للإغلاق أعلى المحتوى عند بقاء
/// [LicenseExpiry.warningDays] يوماً أو أقل على انتهاء الترخيص. لا يمنع أي
/// استخدام؛ يختفي تلقائياً بعد التجديد (تاريخ أبعد يصل مع دخول أونلاين) أو
/// بعد الانتهاء (يتولى القفل الحالي في DesktopAuthStorage الأمر).
class LicenseExpiryBanner extends StatefulWidget {
  final LicenseExpiry expiry;

  /// للاختبارات فقط: مصدر الوقت الحالي.
  final DateTime Function() clock;

  const LicenseExpiryBanner({
    super.key,
    required this.expiry,
    this.clock = DateTime.now,
  });

  @override
  State<LicenseExpiryBanner> createState() => _LicenseExpiryBannerState();
}

class _LicenseExpiryBannerState extends State<LicenseExpiryBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // التطبيق قد يبقى مفتوحاً أياماً: يُعاد الحساب دورياً ليتحدّث عدد الأيام
    // ويظهر الشريط/يختفي دون إعادة تشغيل.
    if (widget.expiry.expiresAt != null) {
      _timer = Timer.periodic(const Duration(minutes: 15), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _remainingText(int days) {
    if (days == 0) return 'ينتهي اليوم';
    if (days == 1) return 'ينتهي غداً';
    if (days == 2) return 'ينتهي خلال يومين';
    return 'ينتهي خلال $days أيام';
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final days = widget.expiry.daysRemaining(widget.clock());
    if (days == null || days > LicenseExpiry.warningDays) {
      return const SizedBox.shrink();
    }

    return Container(
      key: const ValueKey('license-expiry-banner'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFDBA74)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFC2410C), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'اشتراكك (ترخيص البرنامج) ${_remainingText(days)} '
              '(${_date(widget.expiry.expiresAt!.toLocal())}). '
              'يرجى التواصل مع الدعم الفني لتجديده. بعد التجديد سجّل الخروج ثم '
              'سجّل الدخول مع اتصال بالإنترنت لتحديث الترخيص.',
              style: const TextStyle(fontSize: 13, color: Color(0xFF9A3412), fontWeight: FontWeight.w600, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
