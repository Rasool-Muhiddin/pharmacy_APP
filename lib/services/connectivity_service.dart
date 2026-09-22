import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// يتحقق من إمكانية الوصول الفعلي للخادم (وليس فقط وجود شبكة محلية)،
/// عبر استدعاء خفيف لـ /api/desktop/health/. هذا مهم لأن جهازاً قد يكون
/// متصلاً بشبكة Wi-Fi دون أن يكون لديه إنترنت فعلي، أو قد يكون الخادم
/// نفسه متوقفاً رغم وجود إنترنت — كلا الحالتين يجب أن تُمنع فيهما الكتابة
/// في وضع الأونلاين وفق القرار المتفق عليه (لا كتابة بلا سيرفر).
class ConnectivityService {
  ConnectivityService._();

  static final ConnectivityService instance = ConnectivityService._();

  /// نفس رابط الأساس المستخدم في DesktopApiService، لضمان أن فحص الاتصال
  /// يستهدف نفس الخادم فعلياً (وليس رابطاً مختلفاً قد لا يعكس الواقع).
  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000/api/desktop',
  );

  Future<bool> hasConnection({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;

    try {
      final request = await client
          .getUrl(Uri.parse('$_baseUrl/health/'))
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