import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ReportsApiException implements Exception {
  final String message;
  final int? statusCode;

  const ReportsApiException(
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => message;
}

/// يستهلك /api/reports/summary/ و/api/reports/shifts/ — كل التجميع (SUM,
/// COUNT, GROUP BY) يحدث على السيرفر (ReportsViewSet في الباك اند)، فهذه
/// الخدمة لا تُرسل سوى معاملَي start/end وتُعيد الـJSON كما هو دون أي حساب
/// إضافي على العميل.
class ReportsApiService {
  ReportsApiService._();

  static final ReportsApiService instance = ReportsApiService._();

  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  Future<Map<String, dynamic>> fetchSummary({
    required DateTime start,
    required DateTime end,
  }) {
    return _get(endpoint: 'summary', start: start, end: end);
  }

  Future<Map<String, dynamic>> fetchShifts({
    required DateTime start,
    required DateTime end,
  }) {
    return _get(endpoint: 'shifts', start: start, end: end);
  }

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _applyAuthHeader(HttpClientRequest request) {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const ReportsApiException('لم يتم تسجيل الدخول بعد.');
    }
    request.headers.set(HttpHeaders.authorizationHeader, 'Token $token');
  }

  Future<Map<String, dynamic>> _get({
    required String endpoint,
    required DateTime start,
    required DateTime end,
  }) async {
    final url =
        '$_baseUrl/reports/$endpoint/?start=${_formatDate(start)}&end=${_formatDate(end)}';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(
            const Duration(seconds: 25),
          );

      _applyAuthHeader(request);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(const Duration(seconds: 30));
      final responseText = await utf8.decoder.bind(response).join();
      return _parseResponse(response, responseText);
    } on TimeoutException {
      throw const ReportsApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const ReportsApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const ReportsApiException('تعذر إنشاء اتصال آمن بالخادم.');
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
      throw ReportsApiException(
        'استجابة غير صالحة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode == 401) {
      throw const ReportsApiException(
        'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.',
        statusCode: 401,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
      throw ReportsApiException(
        detail is String && detail.isNotEmpty ? detail : 'تعذر جلب التقرير من الخادم.',
        statusCode: response.statusCode,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw ReportsApiException(
        'استجابة غير متوقعة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    return decoded;
  }
}