import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DesktopApiException implements Exception {
  final String message;
  final int? statusCode;

  const DesktopApiException(
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => message;
}

class DesktopApiService {
  DesktopApiService._();

  static final DesktopApiService instance = DesktopApiService._();

  /// يحدد عند بناء النسخة المستقلة، مثال:
  /// --dart-define=TERA_API_BASE_URL=https://api.example.com/api/desktop
  ///
  /// القيمة الافتراضية مخصصة للتطوير المحلي. عند بناء نسخة العملاء يجب تمرير
  /// رابط خادم الإنتاج صراحةً باستخدام --dart-define.
  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000/api/desktop',
  );

  Future<Map<String, dynamic>> activate({
    required String activationCode,
    required String deviceFingerprint,
    required String deviceName,
  }) {
    return _post(
      endpoint: 'activate/',
      body: {
        'activation_code': activationCode,
        'device_fingerprint': deviceFingerprint,
        'device_name': deviceName,
      },
    );
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    required String deviceFingerprint,
  }) {
    return _post(
      endpoint: 'login/',
      body: {
        'username': username,
        'password': password,
        'device_fingerprint': deviceFingerprint,
      },
    );
  }

  Future<Map<String, dynamic>> checkLatestVersion() {
    return _get(endpoint: 'latest-version/');
  }

  Future<Map<String, dynamic>> _get({
    required String endpoint,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client
          .getUrl(Uri.parse('$_baseUrl/$endpoint'))
          .timeout(const Duration(seconds: 25));

      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );

      final responseText = await utf8.decoder.bind(response).join();

      Map<String, dynamic> data;

      try {
        final decoded = jsonDecode(responseText);

        if (decoded is! Map<String, dynamic>) {
          throw const FormatException();
        }

        data = decoded;
      } catch (_) {
        throw DesktopApiException(
          'استجابة غير صالحة من الخادم.',
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          data['ok'] != true) {
        throw DesktopApiException(
          (data['message'] as String?) ?? 'تعذر جلب البيانات.',
          statusCode: response.statusCode,
        );
      }

      return data;
    } on TimeoutException {
      throw const DesktopApiException(
        'انتهت مهلة الاتصال بالخادم.',
      );
    } on SocketException {
      throw const DesktopApiException(
        'تعذر الاتصال بالإنترنت أو بالخادم.',
      );
    } on HandshakeException {
      throw const DesktopApiException(
        'تعذر إنشاء اتصال آمن بالخادم.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _post({
    required String endpoint,
    required Map<String, dynamic> body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client
          .postUrl(Uri.parse('$_baseUrl/$endpoint'))
          .timeout(const Duration(seconds: 25));

      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      // يقرأ خادم Django المحلي Content-Length ولا يدعم طلبات chunked في
      // خادم التطوير. كما أن الإرسال بالبايتات واضح وآمن لخوادم الإنتاج.
      final bodyBytes = utf8.encode(jsonEncode(body));
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );

      final responseText = await utf8.decoder.bind(response).join();

      Map<String, dynamic> data;

      try {
        final decoded = jsonDecode(responseText);

        if (decoded is! Map<String, dynamic>) {
          throw const FormatException();
        }

        data = decoded;
      } catch (_) {
        throw DesktopApiException(
          'استجابة غير صالحة من الخادم. تأكد من اتصال الإنترنت وحاول لاحقاً.',
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          data['ok'] != true) {
        throw DesktopApiException(
          (data['message'] as String?) ?? 'تعذر إتمام العملية.',
          statusCode: response.statusCode,
        );
      }

      return data;
    } on TimeoutException {
      throw const DesktopApiException(
        'انتهت مهلة الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    } on SocketException {
      throw const DesktopApiException(
        'تعذر الاتصال بالإنترنت أو بالخادم.',
      );
    } on HandshakeException {
      throw const DesktopApiException(
        'تعذر إنشاء اتصال آمن بالخادم.',
      );
    } finally {
      client.close(force: true);
    }
  }
}
