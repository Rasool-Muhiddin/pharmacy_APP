import 'dart:async';
import 'dart:convert';
import 'dart:io';

class MigrationApiException implements Exception {
  final String message;
  final int? statusCode;

  const MigrationApiException(
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => message;
}

/// يستهلك /api/migration/status/ و/api/migration/upload_offline_data/.
///
/// الثانية تُعيد استجابة **متدفقة** (NDJSON: سطر JSON واحد لكل حدث)، لا
/// جسم JSON واحد كباقي الخدمات — راجع MigrationViewSet._migration_stream
/// في الباك اند. هذا يسمح بعرض تقدّم حي حقيقي (عدد السجلات المرفوعة من
/// الإجمالي) رغم أن كل العملية معاملة ذرّية واحدة على السيرفر.
class MigrationApiService {
  MigrationApiService._();

  static final MigrationApiService instance = MigrationApiService._();

  static const String _baseUrl = String.fromEnvironment(
    'TERA_API_ROOT_URL',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  Future<Map<String, dynamic>> checkStatus() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client
          .getUrl(Uri.parse('$_baseUrl/migration/status/'))
          .timeout(const Duration(seconds: 25));
      _applyAuthHeader(request);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 30));
      final text = await utf8.decoder.bind(response).join();
      return _parseSimpleJsonResponse(response, text);
    } on TimeoutException {
      throw const MigrationApiException('انتهت مهلة الاتصال بالخادم.');
    } on SocketException {
      throw const MigrationApiException('تعذر الاتصال بالإنترنت أو بالخادم.');
    } on HandshakeException {
      throw const MigrationApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  /// يرفع كل الحمولة ويستهلك الاستجابة المتدفقة سطراً بسطر، مستدعياً
  /// [onProgress] مع كل حدث "progress" (overall_done/overall_total/stage).
  /// يُرجع ملخص النتيجة النهائية عند نجاح الحدث "done"، أو يرمي استثناءً
  /// عند الحدث "error" — **العملية بأكملها معاملة ذرّية واحدة على السيرفر،
  /// فأي فشل يعني عدم حفظ أي شيء إطلاقاً، ويمكن إعادة المحاولة بأمان من
  /// الصفر**.
  Future<Map<String, dynamic>> uploadOfflineData(
    Map<String, dynamic> payload, {
    void Function(int done, int total, String stage)? onProgress,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);

    try {
      final request = await client
          .postUrl(Uri.parse('$_baseUrl/migration/upload_offline_data/'))
          .timeout(const Duration(seconds: 30));

      _applyAuthHeader(request);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/x-ndjson');

      final bodyBytes = utf8.encode(jsonEncode(payload));
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      // مهلة الاتصال الأولي فقط (حتى وصول رأس الاستجابة)، لا مهلة على
      // العملية كاملة — قد تستغرق دقائق مع بيانات ضخمة، وهذا متوقَّع.
      final response = await request.close().timeout(const Duration(seconds: 30));

      if (response.statusCode == 401) {
        await response.drain();
        throw const MigrationApiException('انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.', statusCode: 401);
      }

      if (response.statusCode != 200) {
        final text = await utf8.decoder.bind(response).join();
        throw MigrationApiException(_extractPreStreamError(text), statusCode: response.statusCode);
      }

      Map<String, dynamic>? summary;
      String? errorMessage;
      var buffer = '';

      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        var newlineIndex = buffer.indexOf('\n');
        while (newlineIndex != -1) {
          final lineStr = buffer.substring(0, newlineIndex).trim();
          buffer = buffer.substring(newlineIndex + 1);

          if (lineStr.isNotEmpty) {
            Map<String, dynamic>? event;
            try {
              event = jsonDecode(lineStr) as Map<String, dynamic>;
            } catch (_) {
              // سطر تالف/غير مكتمل — يُتجاهل، الحدث النهائي done/error هو ما يهم.
            }

            if (event != null) {
              switch (event['event']) {
                case 'progress':
                  onProgress?.call(
                    (event['overall_done'] as num).toInt(),
                    (event['overall_total'] as num).toInt(),
                    (event['stage'] as String?) ?? '',
                  );
                  break;
                case 'error':
                  errorMessage = (event['message'] as String?) ?? 'فشل الرفع.';
                  break;
                case 'done':
                  summary = Map<String, dynamic>.from(event['summary'] as Map);
                  break;
              }
            }
          }
          newlineIndex = buffer.indexOf('\n');
        }
      }

      if (errorMessage != null) {
        throw MigrationApiException(errorMessage);
      }
      if (summary == null) {
        throw const MigrationApiException(
          'انقطع الاتصال قبل اكتمال الرفع. العملية معاملة ذرّية واحدة، فلم يُحفظ شيء بعد — أعد المحاولة بأمان.',
        );
      }
      return summary;
    } on TimeoutException {
      throw const MigrationApiException('انتهت مهلة الاتصال بالخادم أثناء بدء الرفع.');
    } on SocketException {
      throw const MigrationApiException(
        'تعذر الاتصال بالإنترنت أو بالخادم أثناء الرفع. لم يُحفظ شيء بعد — أعد المحاولة بأمان.',
      );
    } on HandshakeException {
      throw const MigrationApiException('تعذر إنشاء اتصال آمن بالخادم.');
    } finally {
      client.close(force: true);
    }
  }

  void _applyAuthHeader(HttpClientRequest request) {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const MigrationApiException('لم يتم تسجيل الدخول بعد.');
    }
    request.headers.set(HttpHeaders.authorizationHeader, 'Token $token');
  }

  Map<String, dynamic> _parseSimpleJsonResponse(HttpClientResponse response, String text) {
    dynamic decoded;
    try {
      decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    } catch (_) {
      throw MigrationApiException('استجابة غير صالحة من الخادم.', statusCode: response.statusCode);
    }

    if (response.statusCode == 401) {
      throw const MigrationApiException('انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.', statusCode: 401);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MigrationApiException(_extractPreStreamError(text), statusCode: response.statusCode);
    }
    if (decoded is! Map<String, dynamic>) {
      throw MigrationApiException('استجابة غير متوقعة من الخادم.', statusCode: response.statusCode);
    }
    return decoded;
  }

  String _extractPreStreamError(String text) {
    dynamic decoded;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      return 'تعذر إتمام عملية الرفع.';
    }
    if (decoded is List && decoded.isNotEmpty) {
      return decoded.first.toString();
    }
    if (decoded is Map<String, dynamic>) {
      final detail = decoded['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
    }
    return 'تعذر إتمام عملية الرفع.';
  }
}