import 'api_http.dart';

class ExpenseApiException extends ApiHttpException {
  const ExpenseApiException(
    super.message, {
    super.statusCode,
    super.isNetworkError,
  });
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
  static const String _baseUrl = ApiHttp.rootUrl;

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
    final response = await _request('DELETE', '$_baseUrl/expenses/$id/');
    if (!response.isSuccess) {
      throw ExpenseApiException(
        'تعذر حذف المصروف.',
        statusCode: response.statusCode,
      );
    }
  }

  Future<ApiHttpResponse> _request(String method, String url, {Map<String, dynamic>? body}) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const ExpenseApiException('لم يتم تسجيل الدخول بعد.');
    }
    try {
      return await ApiHttp.request(method, url, token: token, body: body);
    } on ApiHttpException catch (e) {
      throw ExpenseApiException(e.message, statusCode: e.statusCode, isNetworkError: e.isNetworkError);
    }
  }

  Future<Map<String, dynamic>> _get({required String url}) async {
    return _parseResponse(await _request('GET', url));
  }

  Future<Map<String, dynamic>> _send({
    required String method,
    required String url,
    required Map<String, dynamic> body,
  }) async {
    return _parseResponse(await _request(method, url, body: body));
  }

  Map<String, dynamic> _parseResponse(ApiHttpResponse response) {
    final decoded = response.json ?? <String, dynamic>{};

    if (response.statusCode == 401) {
      throw const ExpenseApiException(
        'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.',
        statusCode: 401,
      );
    }

    if (!response.isSuccess) {
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