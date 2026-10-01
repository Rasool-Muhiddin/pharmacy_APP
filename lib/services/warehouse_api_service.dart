import 'dart:async';
import 'dart:convert';
import 'dart:io';

class WarehouseApiException implements Exception {
  final String message;
  final int? statusCode;

  const WarehouseApiException(
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => message;
}

/// يغلّف طلبات /api/warehouses/ على الخادم (خاصية تعدد المخازن). الخادم يفرض
/// كل القواعد (الباقة، الحد الأقصى، المالك فقط للكتابة، النقل داخل نفس
/// الصيدلية فقط)، وهذه الطبقة تنقل رسائله العربية كما هي. يفترض أن
/// setAuthToken() استُدعيت قبل أي طلب، بنفس نمط MedicineApiService.
class WarehouseApiService {
  WarehouseApiService._();

  static final WarehouseApiService instance = WarehouseApiService._();

  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  /// كل مخازن الصيدلية (الرئيسي أولاً). الخادم ينشئ الرئيسي تلقائياً إن لم
  /// يوجد، والقائمة غير مرقّمة.
  Future<List<Map<String, dynamic>>> fetchWarehouses() async {
    final decoded = await _request(method: 'GET', url: '$_baseUrl/warehouses/');
    if (decoded is! List) {
      throw const WarehouseApiException('استجابة غير متوقعة من الخادم.');
    }
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>> createWarehouse(String name) async {
    return _asMap(await _request(
      method: 'POST',
      url: '$_baseUrl/warehouses/',
      body: {'name': name},
    ));
  }

  Future<Map<String, dynamic>> renameWarehouse(int id, String name) async {
    return _asMap(await _request(
      method: 'PATCH',
      url: '$_baseUrl/warehouses/$id/',
      body: {'name': name},
    ));
  }

  Future<void> deleteWarehouse(int id) async {
    await _request(method: 'DELETE', url: '$_baseUrl/warehouses/$id/');
  }

  /// نقل ذرّي على الخادم. الرد يحتوي: transfer، source (أو null إن حُذف
  /// صف المصدر)، source_deleted، source_id، destination — لتحديث الكاش
  /// المحلي مباشرة.
  Future<Map<String, dynamic>> transferStock({
    required int medicineId,
    required int toWarehouseId,
    required int quantity,
    String? notes,
  }) async {
    return _asMap(await _request(
      method: 'POST',
      url: '$_baseUrl/warehouses/transfer/',
      body: {
        'medicine_id': medicineId,
        'to_warehouse_id': toWarehouseId,
        'quantity': quantity,
        'notes': notes ?? '',
      },
    ));
  }

  Map<String, dynamic> _asMap(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) {
      throw const WarehouseApiException('استجابة غير متوقعة من الخادم.');
    }
    return decoded;
  }

  Future<dynamic> _request({
    required String method,
    required String url,
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client
          .openUrl(method, Uri.parse(url))
          .timeout(const Duration(seconds: 25));

      final token = _token;
      if (token == null || token.isEmpty) {
        throw const WarehouseApiException('لم يتم تسجيل الدخول بعد.');
      }
      request.headers.set(HttpHeaders.authorizationHeader, 'Token $token');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      if (body != null) {
        request.headers.contentType = ContentType.json;
        final bodyBytes = utf8.encode(jsonEncode(body));
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
      }

      final response = await request.close().timeout(const Duration(seconds: 30));
      final text = await utf8.decoder.bind(response).join();
      return _parseResponse(response.statusCode, text);
    } on TimeoutException {
      throw const WarehouseApiException('انتهت مهلة الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى.');
    } on SocketException {
      throw const WarehouseApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const WarehouseApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  dynamic _parseResponse(int statusCode, String text) {
    dynamic decoded;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      throw WarehouseApiException('استجابة غير صالحة من الخادم.', statusCode: statusCode);
    }

    if (statusCode == 401) {
      throw const WarehouseApiException('انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.', statusCode: 401);
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw WarehouseApiException(_extractErrorMessage(decoded), statusCode: statusCode);
    }
    return decoded;
  }

  /// أخطاء DRF: {"detail": "..."} أو ["..."] (ValidationError عامة) أو
  /// أخطاء حقول {"name": ["..."]}.
  String _extractErrorMessage(dynamic decoded) {
    if (decoded is List && decoded.isNotEmpty) {
      return decoded.first.toString();
    }
    if (decoded is Map<String, dynamic>) {
      final detail = decoded['detail'];
      if (detail is String && detail.isNotEmpty) return detail;

      final messages = <String>[];
      decoded.forEach((_, value) {
        if (value is List) {
          messages.addAll(value.map((e) => e.toString()));
        } else if (value is String) {
          messages.add(value);
        }
      });
      if (messages.isNotEmpty) return messages.join('\n');
    }
    return 'تعذر إتمام العملية.';
  }
}
