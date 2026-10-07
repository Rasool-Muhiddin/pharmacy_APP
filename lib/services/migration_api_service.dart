import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_http.dart';

class MigrationApiException extends ApiHttpException {
  const MigrationApiException(
    super.message, {
    super.statusCode,
    super.isNetworkError,
  });
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

  static const String _baseUrl = ApiHttp.rootUrl;

  String? _token;

  void setAuthToken(String? token) {
    _token = token;
  }

  /// هل يُعرض اقتراح الرفع الأولي بناءً على رد /api/migration/status/؟
  /// can_migrate (الخوادم الأحدث) هو الحاسم: الرفع ممكن ما دامت الصيدلية بلا
  /// بيانات أونلاين، حتى لو كان migrated_from_offline_at مضبوطاً — علَم بلا
  /// بيانات كان يُخفي الاقتراح للأبد فتظهر الصيدلية فارغة أونلاين.
  static bool shouldOfferMigration(Map<String, dynamic> status) {
    final canMigrate = status['can_migrate'];
    if (canMigrate is bool) return canMigrate;
    return status['migrated'] != true && status['has_existing_online_data'] != true;
  }

  Future<Map<String, dynamic>> checkStatus() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const MigrationApiException('لم يتم تسجيل الدخول بعد.');
    }
    final ApiHttpResponse response;
    try {
      response = await ApiHttp.request('GET', '$_baseUrl/migration/status/', token: token);
    } on ApiHttpException catch (e) {
      throw MigrationApiException(e.message, statusCode: e.statusCode, isNetworkError: e.isNetworkError);
    }

    if (response.statusCode == 401) {
      throw const MigrationApiException('انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.', statusCode: 401);
    }
    if (!response.isSuccess) {
      throw MigrationApiException(_extractPreStreamError(response.json), statusCode: response.statusCode);
    }
    final decoded = response.json ?? <String, dynamic>{};
    if (decoded is! Map<String, dynamic>) {
      throw MigrationApiException('استجابة غير متوقعة من الخادم.', statusCode: response.statusCode);
    }
    return decoded;
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
        final url = '$_baseUrl/migration/upload_offline_data/';
        final String message;
        try {
          message = _extractPreStreamError(ApiHttp.decodeJson(response.statusCode, text, url));
        } on ApiHttpException catch (e) {
          throw MigrationApiException(e.message, statusCode: response.statusCode);
        }
        throw MigrationApiException(message, statusCode: response.statusCode);
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

  String _extractPreStreamError(dynamic decoded) {
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