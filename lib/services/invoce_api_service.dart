import 'dart:async';
import 'dart:convert';
import 'dart:io';

class InvoiceApiException implements Exception {
  final String message;
  final int? statusCode;

  const InvoiceApiException(
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => message;
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
  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  Future<List<Map<String, dynamic>>> fetchInvoices() async {
    final results = <Map<String, dynamic>>[];
    String? nextUrl = '$_baseUrl/invoices/';

    // /api/invoices/ مُرقَّم بالصفحات مثل /api/medicines/ تماماً، فنتابع
    // "next" حتى تُستنفد كل الصفحات لضمان جلب كامل سجل المبيعات دفعة واحدة.
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

  /// POST /api/invoices/<id>/refund/
  Future<Map<String, dynamic>> refundInvoice(int id) {
    return _send(
      method: 'POST',
      url: '$_baseUrl/invoices/$id/refund/',
      body: const {},
    );
  }

  void _applyAuthHeader(HttpClientRequest request) {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const InvoiceApiException('لم يتم تسجيل الدخول بعد.');
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
      throw const InvoiceApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const InvoiceApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const InvoiceApiException('تعذر إنشاء اتصال آمن بالخادم.');
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
      throw const InvoiceApiException(
        'انتهت مهلة الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    } on SocketException {
      throw const InvoiceApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const InvoiceApiException('تعذر إنشاء اتصال آمن بالخادم.');
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
      throw InvoiceApiException(
        'استجابة غير صالحة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode == 401) {
      throw const InvoiceApiException(
        'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.',
        statusCode: 401,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
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