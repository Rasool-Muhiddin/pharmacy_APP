import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ExpenseApiException implements Exception {
  final String message;
  final int? statusCode;

  const ExpenseApiException(
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => message;
}

/// يغلّف جميع طلبات المصروفات (/api/expenses/) على الخادم، بنفس بنية
/// MedicineApiService تماماً. يفترض أن api_token صار متوفراً مسبقاً (من
/// استجابة desktop_login) وأنّ setAuthToken() استُدعيت به قبل أي طلب هنا.
class ExpenseApiService {
  ExpenseApiService._();

  static final ExpenseApiService instance = ExpenseApiService._();

  /// نفس رابط جذر API العام المستخدم في MedicineApiService/InvoiceApiService
  /// (TERA_API_ROOT_URL)، لأن endpoints بيانات الصيدلية كلها تعيش تحت /api/
  /// مباشرة، لا تحت /api/desktop/.
  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  Future<List<Map<String, dynamic>>> fetchExpenses() async {
    final results = <Map<String, dynamic>>[];
    String? nextUrl = '$_baseUrl/expenses/';

    // /api/expenses/ يُفترض مُرقَّماً بالصفحات مثل /api/medicines/ و
    // /api/invoices/ تماماً، فنتابع "next" حتى تُستنفد كل الصفحات — الفلترة
    // بالتاريخ/النوع تبقى محلية على الكاش بعد الجلب، كما في المخزون
    // والفواتير، لا عبر query params على الخادم.
    while (nextUrl != null) {
      final page = await _get(url: nextUrl);
      final pageResults = page['results'];

      if (pageResults is List) {
        results.addAll(pageResults.whereType<Map<String, dynamic>>());
      } else {
        // رد غير مرقّم (احتياط لو عُطّل pagination مستقبلاً على الخادم).
        break;
      }

      nextUrl = page['next'] as String?;
    }

    return results;
  }

  Future<Map<String, dynamic>> createExpense(Map<String, dynamic> data) {
    return _send(method: 'POST', url: '$_baseUrl/expenses/', body: data);
  }

  Future<Map<String, dynamic>> updateExpense(
    int id,
    Map<String, dynamic> data,
  ) {
    return _send(
      method: 'PATCH',
      url: '$_baseUrl/expenses/$id/',
      body: data,
    );
  }

  Future<void> deleteExpense(int id) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client
          .deleteUrl(Uri.parse('$_baseUrl/expenses/$id/'))
          .timeout(const Duration(seconds: 25));

      _applyAuthHeader(request);

      final response = await request.close().timeout(const Duration(seconds: 30));
      await utf8.decoder.bind(response).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ExpenseApiException(
          'تعذر حذف المصروف.',
          statusCode: response.statusCode,
        );
      }
    } on TimeoutException {
      throw const ExpenseApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const ExpenseApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const ExpenseApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  void _applyAuthHeader(HttpClientRequest request) {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const ExpenseApiException('لم يتم تسجيل الدخول بعد.');
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
      throw const ExpenseApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const ExpenseApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const ExpenseApiException('تعذر إنشاء اتصال آمن بالخادم.');
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
      throw const ExpenseApiException(
        'انتهت مهلة الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    } on SocketException {
      throw const ExpenseApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const ExpenseApiException('تعذر إنشاء اتصال آمن بالخادم.');
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
      throw ExpenseApiException(
        'استجابة غير صالحة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode == 401) {
      throw const ExpenseApiException(
        'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.',
        statusCode: 401,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ExpenseApiException(
        _extractErrorMessage(decoded),
        statusCode: response.statusCode,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw ExpenseApiException(
        'استجابة غير متوقعة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    return decoded;
  }

  /// نفس منطق استخراج الأخطاء المستخدم في MedicineApiService/
  /// InvoiceApiService، لتوحيد شكل رسائل خطأ DRF عبر كل الخدمات.
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