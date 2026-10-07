import 'api_http.dart';

class ReportsApiException extends ApiHttpException {
  const ReportsApiException(
    super.message, {
    super.statusCode,
    super.isNetworkError,
  });
}

/// يستهلك /api/reports/* (summary/shifts للنسخ الأقدم، وأقسام شاشة التقارير
/// الجديدة: kpis, trend, categories, hours, items, stagnant, inventory,
/// purchases, losses, invoices, sellers) — كل التجميع (SUM,
/// COUNT, GROUP BY) يحدث على السيرفر (ReportsViewSet في الباك اند)، فهذه
/// الخدمة لا تُرسل سوى معاملَي start/end وتُعيد الـJSON كما هو دون أي حساب
/// إضافي على العميل.
class ReportsApiService {
  ReportsApiService._();

  static final ReportsApiService instance = ReportsApiService._();

  static const String _baseUrl = ApiHttp.rootUrl;

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

  /// قسم من أقسام شاشة التقارير: /api/reports/<section>/?start&end&...
  /// [start]/[end] اختياريان (inventory وضع حالي بلا فترة).
  Future<Map<String, dynamic>> fetchSection(
    String section, {
    DateTime? start,
    DateTime? end,
    Map<String, String> params = const {},
  }) {
    return _getQuery(endpoint: section, query: {
      if (start != null) 'start': _formatDate(start),
      if (end != null) 'end': _formatDate(end),
      ...params,
    });
  }

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<Map<String, dynamic>> _get({
    required String endpoint,
    required DateTime start,
    required DateTime end,
  }) {
    return _getQuery(endpoint: endpoint, query: {'start': _formatDate(start), 'end': _formatDate(end)});
  }

  Future<Map<String, dynamic>> _getQuery({
    required String endpoint,
    required Map<String, String> query,
  }) async {
    final url = Uri.parse('$_baseUrl/reports/$endpoint/').replace(queryParameters: query.isEmpty ? null : query).toString();
    return _parseResponse(await _request('GET', url));
  }

  Future<ApiHttpResponse> _request(String method, String url, {Map<String, dynamic>? body}) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const ReportsApiException('لم يتم تسجيل الدخول بعد.');
    }
    try {
      return await ApiHttp.request(method, url, token: token, body: body);
    } on ApiHttpException catch (e) {
      throw ReportsApiException(e.message, statusCode: e.statusCode, isNetworkError: e.isNetworkError);
    }
  }

  Map<String, dynamic> _parseResponse(ApiHttpResponse response) {
    final decoded = response.json ?? <String, dynamic>{};

    if (response.statusCode == 401) {
      throw const ReportsApiException(
        'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.',
        statusCode: 401,
      );
    }

    if (!response.isSuccess) {
      throw ReportsApiException(
        decoded is Map<String, dynamic> && decoded['detail'] is String && (decoded['detail'] as String).isNotEmpty
            ? decoded['detail'] as String
            : 'تعذر جلب التقرير من الخادم.',
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