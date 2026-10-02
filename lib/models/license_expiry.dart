/// اقتراب انتهاء الترخيص، محسوباً من license.expires_at نفسه الذي يفرضه
/// DesktopAuthStorage._checkAccountLicense (يرفض الجلسة المحفوظة والدخول
/// الأوفلاين بعد تجاوزه) — لا نظام صلاحية منفصل. القيمة هي آخر ما حفظه
/// الجهاز من الخادم عند آخر دخول أونلاين، فتعمل بلا إنترنت (Basic أوفلاين).
///
/// يطابق DesktopLicense.is_valid في الخادم حرفياً (شق التاريخ؛ شق status
/// يفحصه _checkAccountLicense):
///   lifetime → لا ينتهي أبداً مهما كان expires_at المحفوظ معه.
///   annual/trial (وأي نوع آخر) → صالح فقط إن وُجد expires_at و now <= expires_at؛
///   بلا تاريخ (أو بتاريخ غير مقروء) يُعدّ غير صالح كما في الخادم.
class LicenseExpiry {
  /// قيمة license.type للترخيص مدى الحياة (DesktopLicense.LIFETIME).
  static const String lifetimeType = 'lifetime';

  /// يظهر التحذير عندما يتبقى هذا العدد من الأيام أو أقل.
  static const int warningDays = 10;

  /// بالتوقيت المحلي، أو null إن لم يكن للترخيص تاريخ انتهاء صالح.
  final DateTime? expiresAt;

  /// ترخيص مدى الحياة: لا ينتهي أبداً.
  final bool neverExpires;

  /// ترخيص بتاريخ انتهاء (annual/trial).
  const LicenseExpiry(DateTime this.expiresAt) : neverExpires = false;

  /// لا ينتهي أبداً (مدى الحياة) — والقيمة الافتراضية حيث لا ترخيص معروف.
  const LicenseExpiry.none()
      : expiresAt = null,
        neverExpires = true;

  /// annual/trial بلا expires_at صالح: غير صالح في الخادم (expires_at is None).
  const LicenseExpiry.missingDate()
      : expiresAt = null,
        neverExpires = false;

  factory LicenseExpiry.fromLicense(Map<String, dynamic> license) {
    if (license['type'] == lifetimeType) return const LicenseExpiry.none();
    final text = license['expires_at'];
    final parsed = text is String ? DateTime.tryParse(text) : null;
    if (parsed == null) return const LicenseExpiry.missingDate();
    return LicenseExpiry(parsed.toLocal());
  }

  /// غير صالح زمنياً: الخادم يقبل ما دام expires_at >= now، ويرفض غير
  /// lifetime بلا تاريخ.
  bool isExpired(DateTime now) {
    if (neverExpires) return false;
    final end = expiresAt;
    return end == null || now.isAfter(end);
  }

  /// أيام التقويم المتبقية حتى يوم الانتهاء (0 = ينتهي اليوم)، أو null إن لم
  /// يكن للترخيص تاريخ انتهاء أو تجاوزه بالفعل (عندها يتولى القفل الحالي).
  int? daysRemaining(DateTime now) {
    final end = expiresAt?.toLocal();
    final current = now.toLocal();
    if (end == null || isExpired(now)) return null; // مدى الحياة، أو منتهٍ/بلا تاريخ (القفل يتولاه)
    // تواريخ UTC مجردة كي لا يُنقص التوقيت الصيفي يوماً من الفرق.
    final endDay = DateTime.utc(end.year, end.month, end.day);
    final today = DateTime.utc(current.year, current.month, current.day);
    return endDay.difference(today).inDays;
  }

  bool shouldWarn(DateTime now) {
    final days = daysRemaining(now);
    return days != null && days <= warningDays;
  }
}
