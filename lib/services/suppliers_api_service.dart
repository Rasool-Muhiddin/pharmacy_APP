import 'api_http.dart';

class SuppliersApiException extends ApiHttpException {
  /// رقم السطر المرفوض في قائمة المذخر (من 0)، إن أرسله الخادم.
  final int? line;

  const SuppliersApiException(
    super.message, {
    super.statusCode,
    super.isNetworkError,
    this.line,
  });
}

/// يغلّف جميع طلبات المذاخر وفواتير الشراء (/api/suppliers/,
/// /api/purchase-invoices/) على الخادم. نفس نمط MedicineApiService تماماً:
/// يفترض أن setAuthToken() استُدعيت قبل أي طلب هنا.
class SuppliersApiService {
  SuppliersApiService._();

  static final SuppliersApiService instance = SuppliersApiService._();

  static const String _baseUrl = ApiHttp.rootUrl;

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  // ================== المذاخر (Suppliers) ==================

  Future<List<Map<String, dynamic>>> fetchSuppliers() async {
    final results = <Map<String, dynamic>>[];
    String? nextUrl = '$_baseUrl/suppliers/';

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

  /// GET /api/suppliers/summary/ — إحصاءات مالية جاهزة لكل مذخر (صافي
  /// المشتريات، الدين المتبقي، عدد الفواتير). رد غير مُرقَّم بالصفحات
  /// (action مخصّص، لا يمر عبر ModelViewSet.list القياسي).
  Future<List<Map<String, dynamic>>> fetchSuppliersSummary() {
    return _getList(url: '$_baseUrl/suppliers/summary/');
  }

  /// GET `/api/suppliers/<id>/statement/` — كشف حساب خام (فواتير + دفعات +
  /// استرجاعات)؛ الترتيب والرصيد التراكمي يُحسَبان في الشاشة عبر
  /// _computeRunningBalance تماماً كما مع db_helper محلياً.
  Future<List<Map<String, dynamic>>> fetchSupplierStatement(int supplierId) {
    return _getList(url: '$_baseUrl/suppliers/$supplierId/statement/');
  }

  Future<Map<String, dynamic>> createSupplier(Map<String, dynamic> data) {
    return _send(method: 'POST', url: '$_baseUrl/suppliers/', body: data);
  }

  Future<void> deleteSupplier(int id) => _delete(url: '$_baseUrl/suppliers/$id/');

  // ================== فواتير الشراء (Purchase Invoices) ==================

  Future<List<Map<String, dynamic>>> fetchPurchaseInvoices(int supplierId) async {
    final results = <Map<String, dynamic>>[];
    String? nextUrl = '$_baseUrl/purchase-invoices/?supplier=$supplierId';

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

  /// POST /api/purchase-invoices/from-list/ — قائمة مذخر كاملة ذرّياً (المذخر،
  /// الفاتورة، توريد كل الأصناف، الدفعة الأولية). يرجع
  /// {"purchase_invoice", "supplier", "medicines"}؛ المجاميع يحسبها الخادم.
  Future<Map<String, dynamic>> createPurchaseList(Map<String, dynamic> body) {
    return _send(method: 'POST', url: '$_baseUrl/purchase-invoices/from-list/', body: body);
  }

  /// `GET /api/purchase-invoices/{id}/items/` — أصناف الفاتورة (فارغة لليدوية القديمة).
  Future<List<Map<String, dynamic>>> fetchPurchaseInvoiceItems(int invoiceId) {
    return _getList(url: '$_baseUrl/purchase-invoices/$invoiceId/items/');
  }

  /// `GET /api/suppliers/{id}/purchased-items/` — الأصناف المشتراة من المذخر.
  Future<List<Map<String, dynamic>>> fetchSupplierPurchasedItems(int supplierId) {
    return _getList(url: '$_baseUrl/suppliers/$supplierId/purchased-items/');
  }

  Future<Map<String, dynamic>> addPurchaseInvoicePayment(
    int invoiceId, {
    required double amount,
    String? notes,
  }) {
    return _send(
      method: 'POST',
      url: '$_baseUrl/purchase-invoices/$invoiceId/add_payment/',
      body: {'amount': amount, 'notes': notes ?? ''},
    );
  }

  /// `POST /api/purchase-invoices/{id}/return-items/` — استرجاع أدوية للمذخر ذرّياً.
  /// يرجع {"purchase_invoice", "return", "medicines"}؛ الحدود والرصيد يحسبها الخادم.
  Future<Map<String, dynamic>> returnPurchaseItems(int invoiceId, Map<String, dynamic> body) {
    return _send(method: 'POST', url: '$_baseUrl/purchase-invoices/$invoiceId/return-items/', body: body);
  }

  /// `POST /api/suppliers/{id}/receive-refund/` — استلام أموال من المذخر مقابل رصيد الصيدلية.
  Future<Map<String, dynamic>> receiveSupplierRefund(int supplierId, Map<String, dynamic> body) {
    return _send(method: 'POST', url: '$_baseUrl/suppliers/$supplierId/receive-refund/', body: body);
  }

  // ================== طبقة النقل المشتركة (نفس نمط MedicineApiService) ==================

  Future<ApiHttpResponse> _request(String method, String url, {Map<String, dynamic>? body}) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const SuppliersApiException('لم يتم تسجيل الدخول بعد.');
    }
    try {
      return await ApiHttp.request(method, url, token: token, body: body);
    } on ApiHttpException catch (e) {
      throw SuppliersApiException(e.message, statusCode: e.statusCode, isNetworkError: e.isNetworkError);
    }
  }

  Future<void> _delete({required String url}) async {
    final response = await _request('DELETE', url);
    if (!response.isSuccess) {
      throw SuppliersApiException('تعذر تنفيذ عملية الحذف.', statusCode: response.statusCode);
    }
  }

  Future<Map<String, dynamic>> _get({required String url}) async {
    return _parseMapResponse(await _request('GET', url));
  }

  /// لطلبات ترجع قائمة خامة غير مُرقَّمة (summary، statement) بدل
  /// {"results": [...], "next": ...}.
  Future<List<Map<String, dynamic>>> _getList({required String url}) async {
    return _parseListResponse(await _request('GET', url));
  }

  Future<Map<String, dynamic>> _send({
    required String method,
    required String url,
    required Map<String, dynamic> body,
  }) async {
    return _parseMapResponse(await _request(method, url, body: body));
  }

  dynamic _decodeOrThrow(ApiHttpResponse response) {
    final decoded = response.json;

    if (response.statusCode == 401) {
      throw const SuppliersApiException('انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.', statusCode: 401);
    }

    if (!response.isSuccess) {
      throw SuppliersApiException(
        _extractErrorMessage(decoded),
        statusCode: response.statusCode,
        line: decoded is Map ? int.tryParse(decoded['line']?.toString() ?? '') : null,
      );
    }

    return decoded;
  }

  Map<String, dynamic> _parseMapResponse(ApiHttpResponse response) {
    final decoded = _decodeOrThrow(response) ?? <String, dynamic>{};
    if (decoded is! Map<String, dynamic>) {
      throw SuppliersApiException('استجابة غير متوقعة من الخادم.', statusCode: response.statusCode);
    }
    return decoded;
  }

  List<Map<String, dynamic>> _parseListResponse(ApiHttpResponse response) {
    final decoded = _decodeOrThrow(response) ?? <dynamic>[];
    if (decoded is! List) {
      throw SuppliersApiException('استجابة غير متوقعة من الخادم.', statusCode: response.statusCode);
    }
    return decoded.whereType<Map<String, dynamic>>().toList();
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