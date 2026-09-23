import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DamagedApiException implements Exception {
  final String message;
  final int? statusCode;

  const DamagedApiException(
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => message;
}

/// يغلّف جميع طلبات الأدوية التالفة (/api/damaged-medicines/) على الخادم،
/// بنفس بنية ExpenseApiService/MedicineApiService تماماً. يفترض أن
/// api_token صار متوفراً مسبقاً وأنّ setAuthToken() استُدعيت به قبل أي طلب
/// هنا.
///
/// فرق جوهري عن ExpenseApiService: لا update/delete هنا إطلاقاً — الإتلاف
/// عملية نهائية على الخادم أيضاً (انظر DamagedMedicineViewSet.create في
/// الباك اند)، وكل create تُرجع medicine_new_quantity ضمن نفس الاستجابة
/// لتحديث كاش المخزون المحلي بلا طلب إضافي.
class DamagedApiService {
  DamagedApiService._();

  static final DamagedApiService instance = DamagedApiService._();

  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  Future<List<Map<String, dynamic>>> fetchDamagedMedicines() async {
    final results = <Map<String, dynamic>>[];
    String? nextUrl = '$_baseUrl/damaged-medicines/';

    while (nextUrl != null) {
      final page = await _get(url: nextUrl);
      final pageResults = page['results'];

      if (pageResults is List) {
        results.addAll(pageResults.whereType<Map<String, dynamic>>());
      } else {
        break;
      }

      nextUrl = page['next'] as String?;
    }

    return results;
  }

  /// POST /api/damaged-medicines/  body: {medicine, quantity_damaged, reason, notes}
  /// الخادم يخصم الكمية من المخزون ويُنشئ السجل ذرّياً في نفس الطلب —
  /// راجع MedicineRepository.damageMedicine لكيفية استهلاك medicine_new_quantity
  /// المُعادة هنا.
  Future<Map<String, dynamic>> createDamagedMedicine(
    Map<String, dynamic> data,
  ) {
    return _send(
      method: 'POST',
      url: '$_baseUrl/damaged-medicines/',
      body: data,
    );
  }

  void _applyAuthHeader(HttpClientRequest request) {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const DamagedApiException('لم يتم تسجيل الدخول بعد.');
    }
    request.headers.set(HttpHeaders.authorizationHeader, 'Token $token');
  }

  Future<Map<String, dynamic>> _get({required String url}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(
            const Duration(seconds: 25),
          );

      _applyAuthHeader(request);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(const Duration(seconds: 30));
      return _parseResponse(response, await utf8.decoder.bind(response).join());
    } on TimeoutException {
      throw const DamagedApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const DamagedApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const DamagedApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _send({
    required String method,
    required String url,
    required Map<String, dynamic> body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client
          .openUrl(method, Uri.parse(url))
          .timeout(const Duration(seconds: 25));

      _applyAuthHeader(request);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final bodyBytes = utf8.encode(jsonEncode(body));
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close().timeout(const Duration(seconds: 30));
      final responseText = await utf8.decoder.bind(response).join();
      return _parseResponse(response, responseText);
    } on TimeoutException {
      throw const DamagedApiException(
        'انتهت مهلة الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    } on SocketException {
      throw const DamagedApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const DamagedApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _parseResponse(
    HttpClientResponse response,
    String responseText,
  ) {
    dynamic decoded;
    try {
      decoded = responseText.isEmpty ? <String, dynamic>{} : jsonDecode(responseText);
    } catch (_) {
      throw DamagedApiException(
        'استجابة غير صالحة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode == 401) {
      throw const DamagedApiException(
        'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.',
        statusCode: 401,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DamagedApiException(
        _extractErrorMessage(decoded),
        statusCode: response.statusCode,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw DamagedApiException(
        'استجابة غير متوقعة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    return decoded;
  }

  String _extractErrorMessage(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      final detail = decoded['detail'];
      if (detail is String && detail.isNotEmpty) {
        return detail;
      }

      final fieldErrors = <String>[];
      decoded.forEach((field, value) {
        if (value is List) {
          fieldErrors.addAll(value.map((e) => '$field: $e'));
        } else if (value is String) {
          fieldErrors.add('$field: $value');
        }
      });

      if (fieldErrors.isNotEmpty) {
        return fieldErrors.join('\n');
      }
    }
    return 'تعذر إتمام العملية.';
  }
}