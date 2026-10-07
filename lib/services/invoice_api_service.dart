import 'api_http.dart';

class InvoiceApiException extends ApiHttpException {
  const InvoiceApiException(
    super.message, {
    super.statusCode,
    super.isNetworkError,
  });
}

/// يغلّف جميع طلبات الفواتير (/api/invoices/) على الخادم. لا تُنشأ الفواتير
/// أو تُرجَع إلا عبر checkout()/refundInvoice() أدناه — تماماً كما أن
/// InvoiceViewSet على الخادم للقراءة فقط (list/retrieve) بالإضافة لعمليتين
/// خاصتين فقط، بلا create/update/delete عاديين كما في MedicineApiService.
/// يفترض أن api_token صار متوفراً مسبقاً (من استجابة desktop_login)
/// وأنّ setAuthToken() استُدعيت به قبل أي طلب هنا.
class InvoiceApiService {
  InvoiceApiService._();

  static final InvoiceApiService instance = InvoiceApiService._();

  /// نفس رابط جذر API العام المستخدم في MedicineApiService
  /// (TERA_API_ROOT_URL)، لأن endpoints بيانات الصيدلية كلها (المخزون،
  /// الفواتير...) تعيش تحت /api/ مباشرة.
  static const String _baseUrl = ApiHttp.rootUrl;

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  /// صفحة واحدة من سجل المبيعات (الأحدث أولاً) مع فلاتر الخادم:
  /// {"count", "next", "previous", "results": [...]}. لا يُجلب السجل كاملاً
  /// أبداً — قد يكون آلاف الفواتير.
  Future<Map<String, dynamic>> fetchInvoicesPage({
    int page = 1,
    int pageSize = 50,
    String search = '',
    String? start,
    String? end,
  }) {
    final uri = Uri.parse('$_baseUrl/invoices/').replace(queryParameters: {
      'page': '$page',
      'page_size': '$pageSize',
      if (search.isNotEmpty) 'search': search,
      if (start != null) 'start': start,
      if (end != null) 'end': end,
    });
    return _get(url: uri.toString());
  }

  /// GET /api/invoices/stats/ — مبيعات اليوم (صافي غير المسترجعة) وعدد
  /// فواتيره: {"sales_total", "invoices_count"}. متاح للموظف أيضاً.
  Future<Map<String, dynamic>> fetchTodayStats() => _get(url: '$_baseUrl/invoices/stats/');

  /// GET /api/invoices/{id}/ — فاتورة واحدة بأصنافها (نافذة تفاصيل الفاتورة في
  /// التقارير أونلاين، بدل مزامنة كل سجل المبيعات محلياً).
  Future<Map<String, dynamic>> fetchInvoice(int id) => _get(url: '$_baseUrl/invoices/$id/');

  /// POST /api/invoices/checkout/
  /// items: [{'medicine_id': ..., 'quantity': ...}, ...] فقط — سعر كل صنف
  /// ورقم الفاتورة يُحدَّدان من السيرفر دائماً (انظر
  /// InvoiceViewSet.checkout)، لا يُرسَلان من هنا.
  Future<Map<String, dynamic>> checkout({
    required double discount,
    required List<Map<String, dynamic>> items,
  }) {
    return _send(
      method: 'POST',
      url: '$_baseUrl/invoices/checkout/',
      body: {
        'discount': discount,
        'items': items,
      },
    );
  }

  /// POST `/api/invoices/<id>/refund/`
  Future<Map<String, dynamic>> refundInvoice(int id) {
    return _send(
      method: 'POST',
      url: '$_baseUrl/invoices/$id/refund/',
      body: const {},
    );
  }

  Future<ApiHttpResponse> _request(String method, String url, {Map<String, dynamic>? body}) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const InvoiceApiException('لم يتم تسجيل الدخول بعد.');
    }
    try {
      return await ApiHttp.request(method, url, token: token, body: body);
    } on ApiHttpException catch (e) {
      throw InvoiceApiException(e.message, statusCode: e.statusCode, isNetworkError: e.isNetworkError);
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
      throw const InvoiceApiException(
        'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.',
        statusCode: 401,
      );
    }

    if (!response.isSuccess) {
      throw InvoiceApiException(
        _extractErrorMessage(decoded),
        statusCode: response.statusCode,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw InvoiceApiException(
        'استجابة غير متوقعة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    return decoded;
  }

  /// أخطاء checkout الشائعة (نفاد كمية صنف، خصم أكبر من إجمالي الفاتورة،
  /// فاتورة مسترجعة مسبقاً...) قد تصل كنص عام {"detail": "..."} أو كأخطاء
  /// تحقق لكل حقل — نفس منطق الاستخراج المستخدم في MedicineApiService،
  /// لعرض رسالة واحدة مفهومة للمستخدم بدل استثناء DRF الخام.
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