import 'api_http.dart';

class WarehouseApiException extends ApiHttpException {
  const WarehouseApiException(
    super.message, {
    super.statusCode,
    super.isNetworkError,
  });
}

/// يغلّف طلبات /api/warehouses/ على الخادم (خاصية تعدد المخازن). الخادم يفرض
/// كل القواعد (الباقة، الحد الأقصى، المالك فقط للكتابة، النقل داخل نفس
/// الصيدلية فقط)، وهذه الطبقة تنقل رسائله العربية كما هي. يفترض أن
/// setAuthToken() استُدعيت قبل أي طلب، بنفس نمط MedicineApiService.
class WarehouseApiService {
  WarehouseApiService._();

  static final WarehouseApiService instance = WarehouseApiService._();

  static const String _baseUrl = ApiHttp.rootUrl;

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
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const WarehouseApiException('لم يتم تسجيل الدخول بعد.');
    }
    final ApiHttpResponse response;
    try {
      response = await ApiHttp.request(method, url, token: token, body: body);
    } on ApiHttpException catch (e) {
      throw WarehouseApiException(e.message, statusCode: e.statusCode, isNetworkError: e.isNetworkError);
    }

    if (response.statusCode == 401) {
      throw const WarehouseApiException('انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.', statusCode: 401);
    }
    if (!response.isSuccess) {
      throw WarehouseApiException(_extractErrorMessage(response.json), statusCode: response.statusCode);
    }
    return response.json;
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
