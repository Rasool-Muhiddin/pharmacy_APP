import 'package:flutter/foundation.dart';

import 'api_http.dart';

/// يتحقق من إمكانية الوصول الفعلي للخادم (وليس فقط وجود شبكة محلية)،
/// عبر استدعاء خفيف لـ /api/health/. هذا مهم لأن جهازاً قد يكون
/// متصلاً بشبكة Wi-Fi دون أن يكون لديه إنترنت فعلي، أو قد يكون الخادم
/// نفسه متوقفاً رغم وجود إنترنت — كلا الحالتين يجب أن تُمنع فيهما الكتابة
/// في وضع الأونلاين وفق القرار المتفق عليه (لا كتابة بلا سيرفر).
class ConnectivityService {
  ConnectivityService._();

  static final ConnectivityService instance = ConnectivityService._();

  /// نفس متغير TERA_API_ROOT_URL المستخدم في كل خدمات البيانات
  /// (medicine/invoice/suppliers/...)، لضمان أن فحص الاتصال يستهدف نفس
  /// الخادم فعلياً. كان هذا الملف سابقاً يقرأ متغيراً مختلف الاسم
  /// (TERA_API_BASE_URL) لم يكن يُمرَّر عند البناء أبداً، فكان hasConnection()
  /// يفشل دائماً (يحاول الاتصال بـ 127.0.0.1 المحلي) حتى مع اتصال إنترنت
  /// فعلي وخادم يعمل — وهو ما كان يجعل شاشات القراءة تعرض الكاش المحلي
  /// الفارغ بدل مزامنة البيانات من السيرفر على أي جهاز غير جهاز التطوير.
  ///
  /// ملاحظة مهمة: health/ مسجّل في desktop_api/urls.py مباشرة تحت /api/
  /// (بدون بادئة /desktop/)، بعكس activate/login/latest-version التي هي
  /// فعلاً تحت /api/desktop/. لذلك رابط الفحص هنا يُبنى من _apiRootUrl
  /// مباشرة بلا إضافة '/desktop' — إضافتها سابقاً كانت تنتج رابطاً غير
  /// موجود (404) فتفشل hasConnection() دائماً حتى مع خادم يعمل بشكل صحيح.
  static const String _apiRootUrl = ApiHttp.rootUrl;

  /// نتيجة الفحص تُحفظ 30 ثانية (الناجحة) أو 5 ثوانٍ (الفاشلة) كي لا يسبق
  /// /health/ كل طلب. أي رد من الخادم يجدّدها ([markReachable])، وأي فشل
  /// شبكة يلغيها فوراً ([invalidate]) — كلاهما من ApiHttp تلقائياً.
  static const Duration onlineTtl = Duration(seconds: 30);
  static const Duration offlineTtl = Duration(seconds: 5);

  bool? _lastResult;
  DateTime? _checkedAt;
  Future<bool>? _inFlight;

  /// للكتابة فقط (منع التعديل بلا خادم). القراءة تطلب البيانات مباشرة
  /// وترجع للكاش المحلي عند فشل الشبكة.
  Future<bool> hasConnection({
    Duration timeout = const Duration(seconds: 5),
  }) {
    final last = _lastResult;
    final checkedAt = _checkedAt;
    if (last != null && checkedAt != null &&
        DateTime.now().difference(checkedAt) < (last ? onlineTtl : offlineTtl)) {
      return Future.value(last);
    }
    // فحوص متزامنة (عدة شاشات/أقسام) تتشارك طلباً واحداً.
    return _inFlight ??= _probe(timeout).whenComplete(() => _inFlight = null);
  }

  void markReachable() => _remember(true);

  /// للاختبارات: هل توجد نتيجة فحص محفوظة الآن.
  @visibleForTesting
  bool get hasCachedResult => _checkedAt != null;

  void invalidate() {
    _lastResult = null;
    _checkedAt = null;
  }

  void _remember(bool result) {
    _lastResult = result;
    _checkedAt = DateTime.now();
  }

  Future<bool> _probe(Duration timeout) async {
    try {
      final response = await ApiHttp.request('GET', '$_apiRootUrl/health/', timeout: timeout);
      final decoded = response.json;
      if (!response.isSuccess || decoded is! Map<String, dynamic> || decoded['ok'] != true) {
        _remember(false);
        return false;
      }
      ApiHttp.checkServerApiVersion(decoded);
      _remember(true);
      return true;
    } catch (_) {
      // أي فشل (شبكة، مهلة، TLS، رد غير متوقع...) يعني ببساطة أن الخادم غير
      // متاح الآن؛ لا داعي لتمييز نوع الفشل هنا.
      _remember(false);
      return false;
    }
  }
}
