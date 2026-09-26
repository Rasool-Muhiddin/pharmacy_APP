import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  static const String _apiRootUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  Future<bool> hasConnection({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;

    try {
      final request = await client
          .getUrl(Uri.parse('$_apiRootUrl/health/'))
          .timeout(timeout);

      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(timeout);
      final responseText = await utf8.decoder.bind(response).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }

      final decoded = jsonDecode(responseText);
      return decoded is Map<String, dynamic> && decoded['ok'] == true;
    } catch (_) {
      // أي فشل (SocketException، TimeoutException، خطأ TLS، رد غير متوقع...)
      // يعني ببساطة أن الخادم غير متاح الآن؛ لا داعي لتمييز نوع الفشل هنا.
      return false;
    } finally {
      client.close(force: true);
    }
  }
}