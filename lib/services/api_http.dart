import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'connectivity_service.dart';

/// فشل نقل أو رد غير JSON. استثناءات كل خدمة API ترث منه، فيكفي
/// `e is ApiHttpException && e.isNetworkError` لمعرفة أن الخادم لم يُبلَغ.
class ApiHttpException implements Exception {
  final String message;
  final int? statusCode;

  /// فشل شبكة (لا اتصال، انقطاع، مهلة، TLS) — لا رد HTTP من الخادم.
  final bool isNetworkError;

  const ApiHttpException(this.message, {this.statusCode, this.isNetworkError = false});

  @override
  String toString() => message;
}

/// رد JSON مفكوك: [json] = null عند جسم فارغ (مثل 204 بعد الحذف).
class ApiHttpResponse {
  final int statusCode;
  final dynamic json;

  const ApiHttpResponse(this.statusCode, this.json);

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// فشل اتصال؛ [sent] = هل كُتب الطلب على الاتصال (فقد يكون الخادم نفّذه).
class _ConnectionFailure implements Exception {
  final Object error;
  final bool sent;

  const _ConnectionFailure(this.error, {required this.sent});
}

/// طبقة النقل المشتركة لكل خدمات API (medicine/invoice/suppliers/reports/...):
/// عميل HTTP واحد يُعاد استخدام اتصالاته (keep-alive: مصافحة TLS واحدة بدل
/// واحدة لكل طلب)، المهل، أخطاء الشبكة، وفك JSON. معالجة 401 والرسائل
/// الخاصة بكل endpoint تبقى في الخدمة نفسها.
class ApiHttp {
  ApiHttp._();

  /// مثال بناء نسخة الإنتاج:
  /// --dart-define=TERA_API_ROOT_URL=https://pharmacy-api.tera-software1.com/api
  static const String rootUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  /// إصدار واجهة الخادم الذي يتوقعه هذا التطبيق (api_version في /api/health/).
  /// ارفعه مع API_VERSION في backend/tera_backend/settings.py عند إضافة
  /// endpoints يعتمد عليها التطبيق.
  static const int expectedServerApiVersion = 3;

  static const String timeoutMessage = 'انتهت مهلة الاتصال بالخادم.';
  static const String socketMessage = 'تعذر الاتصال بالإنترنت أو بالخادم.';
  static const String handshakeMessage = 'تعذر إنشاء اتصال آمن بالخادم.';
  static const String unsupportedFeatureMessage = 'الخادم لا يدعم هذه الميزة بعد — يرجى تحديث الخادم';
  static const String writeNotSentMessage =
      'لا يوجد اتصال بالخادم حالياً — لم يُحفظ أي تعديل. تحقق من الاتصال وحاول مرة أخرى.';
  static const String writeUnknownMessage =
      'انقطع الاتصال بالخادم أثناء الحفظ — قد يكون التعديل حُفظ. حدّث الشاشة للتأكد قبل إعادة المحاولة.';
  static const String writeTimeoutMessage =
      'انتهت مهلة الاتصال بالخادم — قد يكون التعديل حُفظ. حدّث الشاشة للتأكد قبل إعادة المحاولة.';

  /// أقل من مهلة إبقاء الاتصال لدى Cloudflare/Nginx بكثير، فنغلق الاتصال
  /// الخامل قبل أن يغلقه الطرف الآخر (يقلّ احتمال إعادة استخدام اتصال ميت).
  static const Duration idleTimeout = Duration(seconds: 20);

  /// فشل شبكة من أي خدمة API (الخادم لم يُبلَغ أو لم يرد).
  static bool isNetworkError(Object error) => error is ApiHttpException && error.isNetworkError;

  static HttpClient _client = _newClient();

  static HttpClient _newClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = idleTimeout;

  /// يتخلّى عن كل الاتصالات الخاملة (بعد اكتشاف اتصال ميت، أو بين الاختبارات).
  /// الطلبات الجارية على العميل القديم تكتمل عادياً.
  static void resetConnections() {
    _client.close();
    _client = _newClient();
  }

  static Future<ApiHttpResponse> request(
    String method,
    String url, {
    String? token,
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final isRead = method == 'GET';
    try {
      try {
        return await _attempt(method, url, token: token, body: body, timeout: timeout);
      } on _ConnectionFailure catch (failure) {
        // إعادة محاولة واحدة على اتصال جديد: القراءة دائماً، والكتابة فقط
        // إن فشل الاتصال قبل إرسال الطلب (فالخادم لم يستلمه قطعاً). لا
        // إعادة إرسال أعمى لـ checkout أو أي كتابة قد تكون نُفّذت.
        // مهلة إنشاء الاتصال لا تُعاد (ستتكرر غالباً فتضاعف الانتظار).
        if ((!isRead && failure.sent) || failure.error is TimeoutException) rethrow;
        debugPrint('[ApiHttp] retrying $method $url on a fresh connection after: ${failure.error}');
        resetConnections();
        return await _attempt(method, url, token: token, body: body, timeout: timeout);
      }
    } on _ConnectionFailure catch (failure) {
      ConnectivityService.instance.invalidate();
      if (isRead) {
        final error = failure.error;
        throw ApiHttpException(
          error is HandshakeException ? handshakeMessage : (error is TimeoutException ? timeoutMessage : socketMessage),
          isNetworkError: true,
        );
      }
      throw ApiHttpException(failure.sent ? writeUnknownMessage : writeNotSentMessage, isNetworkError: true);
    } on TimeoutException {
      ConnectivityService.instance.invalidate();
      throw ApiHttpException(isRead ? timeoutMessage : writeTimeoutMessage, isNetworkError: true);
    }
  }

  static Future<ApiHttpResponse> _attempt(
    String method,
    String url, {
    required String? token,
    required Map<String, dynamic>? body,
    required Duration timeout,
  }) async {
    final HttpClientRequest request;
    try {
      request = await _client.openUrl(method, Uri.parse(url)).timeout(const Duration(seconds: 25));
    } on SocketException catch (e) {
      throw _ConnectionFailure(e, sent: false);
    } on HandshakeException catch (e) {
      throw _ConnectionFailure(e, sent: false);
    } on TimeoutException catch (e) {
      throw _ConnectionFailure(e, sent: false);
    }

    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Token $token');
    }
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');

    final HttpClientResponse response;
    final String text;
    try {
      if (body != null) {
        request.headers.contentType = ContentType.json;
        // يقرأ خادم Django المحلي Content-Length ولا يدعم طلبات chunked.
        final bodyBytes = utf8.encode(jsonEncode(body));
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
      }
      response = await request.close().timeout(timeout);
      text = await utf8.decoder.bind(response).join().timeout(timeout);
    } on SocketException catch (e) {
      throw _ConnectionFailure(e, sent: true);
    } on HttpException catch (e) {
      // "Connection closed before full header was received": اتصال خامل
      // أغلقه الطرف الآخر، أو انقطاع بعد الإرسال.
      throw _ConnectionFailure(e, sent: true);
    } on HandshakeException catch (e) {
      throw _ConnectionFailure(e, sent: false);
    }

    if (response.statusCode < 500) {
      ConnectivityService.instance.markReachable();
    }
    return ApiHttpResponse(response.statusCode, decodeJson(response.statusCode, text, url));
  }

  /// يفك JSON، أو يرمي رسالة تذكر رمز الحالة إن لم يكن الرد JSON (صفحة
  /// HTML من Nginx/Cloudflare/Django): 404 هنا = endpoint غير موجود على
  /// خادم أقدم من التطبيق.
  static dynamic decodeJson(int statusCode, String text, String url) {
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      throw ApiHttpException(nonJsonMessage(statusCode, url), statusCode: statusCode);
    }
  }

  static String nonJsonMessage(int statusCode, String url) {
    debugPrint('[ApiHttp] non-JSON response: HTTP $statusCode $url');
    if (statusCode == 404) return unsupportedFeatureMessage;
    if (statusCode >= 500) return 'خطأ في الخادم (رمز $statusCode)';
    return 'استجابة غير صالحة من الخادم (رمز $statusCode).';
  }

  static bool _versionChecked = false;

  /// يسجّل تحذيراً واضحاً (مرة واحدة لكل جلسة) إن كان الخادم أقدم من التطبيق.
  /// [health] = رد /api/health/.
  static void checkServerApiVersion(Map<String, dynamic> health) {
    if (_versionChecked) return;
    _versionChecked = true;
    final version = health['api_version'];
    if (version is! int || version < expectedServerApiVersion) {
      debugPrint(
        '[ApiHttp] WARNING: server at $rootUrl reports api_version=${version ?? 'missing'}, '
        'app expects >= $expectedServerApiVersion. The server is older than this app — '
        'deploy the latest backend or some features will fail with HTTP 404.',
      );
    }
  }
}
