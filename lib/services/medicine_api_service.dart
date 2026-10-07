import 'api_http.dart';

class MedicineApiException extends ApiHttpException {
  /// رقم السطر المرفوض في قائمة الرصيد الافتتاحي (من 0)، إن أرسله الخادم.
  final int? line;

  const MedicineApiException(
    super.message, {
    super.statusCode,
    super.isNetworkError,
    this.line,
  });
}

/// يغلّف جميع طلبات جدول المخزون (/api/medicines/) على الخادم.
/// يفترض أن api_token صار متوفراً مسبقاً (من استجابة desktop_login)
/// وأنّ setAuthToken() استُدعيت به قبل أي طلب هنا.
class MedicineApiService {
  MedicineApiService._();

  static final MedicineApiService instance = MedicineApiService._();

  /// رابط جذر API العام (بدون /desktop)، منفصل عمداً عن TERA_API_BASE_URL
  /// الخاص بـ DesktopApiService، لأن endpoints بيانات الصيدلية (المخزون،
  /// الفواتير...) تعيش تحت /api/ مباشرة، لا تحت /api/desktop/.
  /// مثال بناء نسخة الإنتاج:
  /// --dart-define=TERA_API_ROOT_URL=https://pharmacy-api.tera-software1.com/api
  static const String _baseUrl = ApiHttp.rootUrl;

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  Future<List<Map<String, dynamic>>> fetchMedicines() async {
    final results = <Map<String, dynamic>>[];
    String? nextUrl = '$_baseUrl/medicines/';

    // /api/medicines/ مُرقَّم بالصفحات (PAGE_SIZE=100 على الخادم)، فنتابع
    // "next" حتى تُستنفد كل الصفحات لضمان جلب كامل المخزون دفعة واحدة.
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

  Future<Map<String, dynamic>> createMedicine(Map<String, dynamic> data) {
    return _send(method: 'POST', url: '$_baseUrl/medicines/', body: data);
  }

  Future<Map<String, dynamic>> updateMedicine(
    int id,
    Map<String, dynamic> data,
  ) {
    return _send(
      method: 'PATCH',
      url: '$_baseUrl/medicines/$id/',
      body: data,
    );
  }

  /// رصيد افتتاحي ذرّي (`POST /api/medicines/opening-stock/`): نفس أسطر قائمة
  /// المذخر بلا مذخر ولا فاتورة. يرجع {"medicines": [...]} بالأصناف المتأثرة.
  Future<Map<String, dynamic>> createOpeningStock(Map<String, dynamic> body) {
    return _send(method: 'POST', url: '$_baseUrl/medicines/opening-stock/', body: body);
  }

  Future<void> deleteMedicine(int id) async {
    final response = await _request('DELETE', '$_baseUrl/medicines/$id/');
    if (!response.isSuccess) {
      throw MedicineApiException(
        'تعذر حذف الدواء.',
        statusCode: response.statusCode,
      );
    }
  }

  Future<ApiHttpResponse> _request(String method, String url, {Map<String, dynamic>? body}) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const MedicineApiException('لم يتم تسجيل الدخول بعد.');
    }
    try {
      return await ApiHttp.request(method, url, token: token, body: body);
    } on ApiHttpException catch (e) {
      throw MedicineApiException(e.message, statusCode: e.statusCode, isNetworkError: e.isNetworkError);
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
      throw const MedicineApiException(
        'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.',
        statusCode: 401,
      );
    }

    if (!response.isSuccess) {
      throw MedicineApiException(
        _extractErrorMessage(decoded),
        statusCode: response.statusCode,
        line: decoded is Map ? int.tryParse(decoded['line']?.toString() ?? '') : null,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw MedicineApiException(
        'استجابة غير متوقعة من الخادم.',
        statusCode: response.statusCode,
      );
    }

    return decoded;
  }

  /// أخطاء DRF لا تأتي بصيغة {"ok","message"} كما في desktop_api، بل إما
  /// {"detail": "..."} أو أخطاء تحقق لكل حقل مثل
  /// {"trade_name": ["This field is required."]}. هذه الدالة تحوّلها إلى
  /// رسالة واحدة قابلة للعرض للمستخدم.
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