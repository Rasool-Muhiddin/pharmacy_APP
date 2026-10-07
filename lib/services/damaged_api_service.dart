import 'api_http.dart';

class DamagedApiException extends ApiHttpException {
  const DamagedApiException(
    super.message, {
    super.statusCode,
    super.isNetworkError,
  });
}

/// يغلّف جميع طلبات الأدوية التالفة (/api/damaged-medicines/) على الخادم،
/// بنفس بنية ExpenseApiService/MedicineApiService تماماً. يفترض أن
/// api_token صار متوفراً مسبقاً وأنّ setAuthToken() استُدعيت به قبل أي طلب
/// هنا.
///
/// فرق جوهري عن ExpenseApiService: لا update/delete هنا إطلاقاً — الإتلاف
/// عملية نهائية على الخادم أيضاً (انظر DamagedMedicineViewSet.create في
/// الباك اند)، وكل create تُرجع medicine_new_quantity ضمن نفس الاستجابة
/// لتحديث كاش المخزون المحلي بلا طلب إضافي.
class DamagedApiService {
  DamagedApiService._();

  static final DamagedApiService instance = DamagedApiService._();

  static const String _baseUrl = ApiHttp.rootUrl;

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  Future<List<Map<String, dynamic>>> fetchDamagedMedicines() async {
    final results = <Map<String, dynamic>>[];
    String? nextUrl = '$_baseUrl/damaged-medicines/';

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

  /// POST /api/damaged-medicines/  body: {medicine, quantity_damaged, reason, notes}
  /// الخادم يخصم الكمية من المخزون ويُنشئ السجل ذرّياً في نفس الطلب —
  /// راجع MedicineRepository.damageMedicine لكيفية استهلاك medicine_new_quantity
  /// المُعادة هنا.
  Future<Map<String, dynamic>> createDamagedMedicine(
    Map<String, dynamic> data,
  ) {
    return _send(
      method: 'POST',
      url: '$_baseUrl/damaged-medicines/',
      body: data,
    );
  }

  Future<ApiHttpResponse> _request(String method, String url, {Map<String, dynamic>? body}) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const DamagedApiException('لم يتم تسجيل الدخول بعد.');
    }
    try {
      return await ApiHttp.request(method, url, token: token, body: body);
    } on ApiHttpException catch (e) {
      throw DamagedApiException(e.message, statusCode: e.statusCode, isNetworkError: e.isNetworkError);
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
      throw const DamagedApiException(
        'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.',
        statusCode: 401,
      );
    }

    if (!response.isSuccess) {
      throw DamagedApiException(
        _extractErrorMessage(decoded),
        statusCode: response.statusCode,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw DamagedApiException(
        'استجابة غير متوقعة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    return decoded;
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