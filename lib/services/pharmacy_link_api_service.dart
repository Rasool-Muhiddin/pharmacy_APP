import 'dart:async';
import 'dart:convert';
import 'dart:io';

class PharmacyLinkApiException implements Exception {
  final String message;
  final int? statusCode;

  const PharmacyLinkApiException(
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => message;
}

/// يستهلك GET /api/pharmacy-links/ فقط (خاصية الباقة الذهبية: تعدد
/// المخازن + ربط الصيدليات). ⚠️ للقراءة فقط عمداً — لا توجد ولن توجد هنا
/// دالة create/delete: الربط بين صيدليتين قرار إداري مركزي يتم حصراً من
/// PharmacyLinkAdmin على لوحة أدمن Django (راجع backend/desktop_api).
/// يفترض أن setAuthToken() استُدعيت قبل أي طلب هنا، بنفس نمط
/// MedicineApiService/MigrationApiService.
class PharmacyLinkApiService {
  PharmacyLinkApiService._();

  static final PharmacyLinkApiService instance = PharmacyLinkApiService._();

  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  /// يرجّع معرّفات الصيدليات المرتبطة بصيدلية المستخدم الحالي فقط
  /// (الخادم يحدّد "المستخدم الحالي" من التوكن، لا حاجة لتمرير pharmacyId).
  /// يُستخدم عادة مباشرة كوسيط لـ
  /// DatabaseHelper.instance.replacePharmacyLinksCache().
  Future<List<int>> fetchLinkedPharmacyIds() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client
          .getUrl(Uri.parse('$_baseUrl/pharmacy-links/'))
          .timeout(const Duration(seconds: 25));
      _applyAuthHeader(request);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(const Duration(seconds: 30));
      final text = await utf8.decoder.bind(response).join();
      final decoded = _parseResponse(response, text);

      final linked = decoded['linked_pharmacies'];
      if (linked is! List) return const [];
      return linked
          .whereType<Map<String, dynamic>>()
          .map((e) => (e['id'] as num?)?.toInt())
          .whereType<int>()
          .toList();
    } on TimeoutException {
      throw const PharmacyLinkApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const PharmacyLinkApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const PharmacyLinkApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  void _applyAuthHeader(HttpClientRequest request) {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const PharmacyLinkApiException('لم يتم تسجيل الدخول بعد.');
    }
    request.headers.set(HttpHeaders.authorizationHeader, 'Token $token');
  }

  Map<String, dynamic> _parseResponse(HttpClientResponse response, String text) {
    dynamic decoded;
    try {
      decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    } catch (_) {
      throw PharmacyLinkApiException('استجابة غير صالحة من الخادم.', statusCode: response.statusCode);
    }

    if (response.statusCode == 401) {
      throw const PharmacyLinkApiException('انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.', statusCode: 401);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PharmacyLinkApiException('تعذر جلب الصيدليات المرتبطة.', statusCode: response.statusCode);
    }
    if (decoded is! Map<String, dynamic>) {
      throw PharmacyLinkApiException('استجابة غير متوقعة من الخادم.', statusCode: response.statusCode);
    }
    return decoded;
  }
}
