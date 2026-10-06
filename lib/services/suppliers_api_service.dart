import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SuppliersApiException implements Exception {
  final String message;
  final int? statusCode;

  /// رقم السطر المرفوض في قائمة المذخر (من 0)، إن أرسله الخادم.
  final int? line;

  const SuppliersApiException(
    this.message, {
    this.statusCode,
    this.line,
  });

  @override
  String toString() => message;
}

/// يغلّف جميع طلبات المذاخر وفواتير الشراء (/api/suppliers/,
/// /api/purchase-invoices/) على الخادم. نفس نمط MedicineApiService تماماً:
/// يفترض أن setAuthToken() استُدعيت قبل أي طلب هنا.
class SuppliersApiService {
  SuppliersApiService._();

  static final SuppliersApiService instance = SuppliersApiService._();

  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

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

  void _applyAuthHeader(HttpClientRequest request) {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const SuppliersApiException('لم يتم تسجيل الدخول بعد.');
    }
    request.headers.set(HttpHeaders.authorizationHeader, 'Token $token');
  }

  Future<void> _delete({required String url}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.deleteUrl(Uri.parse(url)).timeout(const Duration(seconds: 25));
      _applyAuthHeader(request);

      final response = await request.close().timeout(const Duration(seconds: 30));
      await utf8.decoder.bind(response).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SuppliersApiException('تعذر تنفيذ عملية الحذف.', statusCode: response.statusCode);
      }
    } on TimeoutException {
      throw const SuppliersApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const SuppliersApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const SuppliersApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _get({required String url}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 25));
      _applyAuthHeader(request);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(const Duration(seconds: 30));
      return _parseMapResponse(response, await utf8.decoder.bind(response).join());
    } on TimeoutException {
      throw const SuppliersApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const SuppliersApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const SuppliersApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  /// لطلبات ترجع قائمة خامة غير مُرقَّمة (summary، statement) بدل
  /// {"results": [...], "next": ...}.
  Future<List<Map<String, dynamic>>> _getList({required String url}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 25));
      _applyAuthHeader(request);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(const Duration(seconds: 30));
      final text = await utf8.decoder.bind(response).join();
      return _parseListResponse(response, text);
    } on TimeoutException {
      throw const SuppliersApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const SuppliersApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const SuppliersApiException('تعذر إنشاء اتصال آمن بالخادم.');
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
      final request = await client.openUrl(method, Uri.parse(url)).timeout(const Duration(seconds: 25));

      _applyAuthHeader(request);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final bodyBytes = utf8.encode(jsonEncode(body));
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close().timeout(const Duration(seconds: 30));
      final responseText = await utf8.decoder.bind(response).join();
      return _parseMapResponse(response, responseText);
    } on TimeoutException {
      throw const SuppliersApiException('انتهت مهلة الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى.');
    } on SocketException {
      throw const SuppliersApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const SuppliersApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  dynamic _decodeOrThrow(HttpClientResponse response, String responseText) {
    dynamic decoded;
    try {
      decoded = responseText.isEmpty ? null : jsonDecode(responseText);
    } catch (_) {
      throw SuppliersApiException('استجابة غير صالحة من الخادم.', statusCode: response.statusCode);
    }

    if (response.statusCode == 401) {
      throw const SuppliersApiException('انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.', statusCode: 401);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SuppliersApiException(
        _extractErrorMessage(decoded),
        statusCode: response.statusCode,
        line: decoded is Map ? int.tryParse(decoded['line']?.toString() ?? '') : null,
      );
    }

    return decoded;
  }

  Map<String, dynamic> _parseMapResponse(HttpClientResponse response, String responseText) {
    final decoded = _decodeOrThrow(response, responseText) ?? <String, dynamic>{};
    if (decoded is! Map<String, dynamic>) {
      throw SuppliersApiException('استجابة غير متوقعة من الخادم.', statusCode: response.statusCode);
    }
    return decoded;
  }

  List<Map<String, dynamic>> _parseListResponse(HttpClientResponse response, String responseText) {
    final decoded = _decodeOrThrow(response, responseText) ?? <dynamic>[];
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