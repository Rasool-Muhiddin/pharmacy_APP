import 'api_http.dart';

class DesktopApiException extends ApiHttpException {
  const DesktopApiException(
    super.message, {
    super.statusCode,
    super.isNetworkError,
  });
}

class DesktopApiService {
  DesktopApiService._();

  static final DesktopApiService instance = DesktopApiService._();

  /// نفس متغير TERA_API_ROOT_URL المستخدم في كل خدمات البيانات الأخرى
  /// (medicine/invoice/suppliers/...)، مثال عند بناء نسخة العملاء:
  /// --dart-define=TERA_API_ROOT_URL=https://pharmacy-api.tera-software1.com/api
  ///
  /// القيمة الافتراضية مخصصة للتطوير المحلي فقط. كان هذا الملف سابقاً يقرأ
  /// متغيراً مختلف الاسم (TERA_API_BASE_URL) لم يكن يُمرَّر عند البناء أبداً،
  /// فكان التفعيل/الدخول يستخدمان صمتاً نفس الرابط الافتراضي المحلي إن لم
  /// يُعرَّف أي من المتغيرين، ما قد يسبب سلوكاً غير متسق بين الشاشات.
  static const String _apiRootUrl = ApiHttp.rootUrl;

  static const String _baseUrl = '$_apiRootUrl/desktop';

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
  }) {
    return _request('GET', endpoint, fallbackMessage: 'تعذر جلب البيانات.');
  }

  Future<Map<String, dynamic>> _post({
    required String endpoint,
    required Map<String, dynamic> body,
  }) {
    return _request('POST', endpoint, body: body, fallbackMessage: 'تعذر إتمام العملية.');
  }

  /// ردود desktop_api بصيغة {"ok": bool, "message": "..."} (وليس DRF).
  Future<Map<String, dynamic>> _request(
    String method,
    String endpoint, {
    Map<String, dynamic>? body,
    required String fallbackMessage,
  }) async {
    final ApiHttpResponse response;
    try {
      response = await ApiHttp.request(method, '$_baseUrl/$endpoint', body: body);
    } on ApiHttpException catch (e) {
      throw DesktopApiException(e.message, statusCode: e.statusCode, isNetworkError: e.isNetworkError);
    }

    final data = response.json;
    if (data is! Map<String, dynamic>) {
      throw DesktopApiException(
        'استجابة غير صالحة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    if (!response.isSuccess || data['ok'] != true) {
      throw DesktopApiException(
        (data['message'] as String?) ?? fallbackMessage,
        statusCode: response.statusCode,
      );
    }

    return data;
  }
}