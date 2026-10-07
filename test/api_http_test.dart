import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/services/api_http.dart';
import 'package:pharmacy_app/services/connectivity_service.dart';

void main() {
  late HttpServer server;
  late String base;
  final hits = <String, int>{};
  final clientPorts = <int>[];

  setUp(() async {
    hits.clear();
    clientPorts.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final path = req.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      clientPorts.add(req.connectionInfo!.remotePort);
      final res = req.response;
      switch (path) {
        case '/json':
          res.headers.contentType = ContentType.json;
          res.write('{"ok": true}');
        case '/json404':
          res.statusCode = 404;
          res.headers.contentType = ContentType.json;
          res.write('{"detail": "المذخر غير موجود."}');
        case '/html404':
          res.statusCode = 404;
          res.headers.contentType = ContentType.html;
          res.write('<h1>Not Found</h1>');
        case '/html502':
          res.statusCode = 502;
          res.write('<html>Bad gateway</html>');
        case '/empty':
          res.statusCode = 204;
        case '/slow':
          await Future<void>.delayed(const Duration(seconds: 2));
          res.write('{}');
        case '/drop-first':
          // أول طلب: الاتصال يُقطع بلا رد (كاتصال خامل أغلقه الخادم). بعده رد عادي.
          if (hits[path] == 1) {
            await req.drain<void>();
            final socket = await res.detachSocket(writeHeaders: false);
            socket.destroy();
            return;
          }
          res.write('{"ok": true}');
      }
      await res.close();
    });
  });

  tearDown(() async {
    ApiHttp.resetConnections();
    await server.close(force: true);
  });

  test('JSON response is decoded, including JSON error bodies', () async {
    final ok = await ApiHttp.request('GET', '$base/json');
    expect(ok.isSuccess, isTrue);
    expect(ok.json, {'ok': true});

    final notFound = await ApiHttp.request('GET', '$base/json404');
    expect(notFound.statusCode, 404);
    expect(notFound.json['detail'], 'المذخر غير موجود.');
  });

  test('empty body decodes to null', () async {
    final res = await ApiHttp.request('DELETE', '$base/empty');
    expect(res.statusCode, 204);
    expect(res.json, isNull);
  });

  test('non-JSON 404 means the server lacks the endpoint', () async {
    expect(
      () => ApiHttp.request('GET', '$base/html404'),
      throwsA(isA<ApiHttpException>()
          .having((e) => e.message, 'message', ApiHttp.unsupportedFeatureMessage)
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.isNetworkError, 'isNetworkError', isFalse)),
    );
  });

  test('non-JSON 5xx reports the status code', () async {
    expect(
      () => ApiHttp.request('GET', '$base/html502'),
      throwsA(isA<ApiHttpException>().having((e) => e.message, 'message', 'خطأ في الخادم (رمز 502)')),
    );
  });

  test('timeout has a clear message and counts as a network error', () async {
    expect(
      () => ApiHttp.request('GET', '$base/slow', timeout: const Duration(milliseconds: 200)),
      throwsA(isA<ApiHttpException>()
          .having((e) => e.message, 'message', ApiHttp.timeoutMessage)
          .having((e) => e.isNetworkError, 'isNetworkError', isTrue)),
    );
  });

  test('requests reuse keep-alive connections instead of one per request', () async {
    for (var i = 0; i < 6; i++) {
      await ApiHttp.request('GET', '$base/json');
    }
    // HttpClient يعيد الاتصال للمجمّع بعد اكتمال الرد بشكل غير متزامن، فطلبان
    // متتاليان فوراً قد يتناوبان على اتصالين — لكن لا اتصال جديد لكل طلب.
    expect(clientPorts.toSet().length, lessThanOrEqualTo(2));
  });

  test('GET is retried once on a fresh connection after a dropped connection', () async {
    final res = await ApiHttp.request('GET', '$base/drop-first');
    expect(res.json, {'ok': true});
    expect(hits['/drop-first'], 2);
  });

  test('a write that may have reached the server is never retried', () async {
    await expectLater(
      ApiHttp.request('POST', '$base/drop-first', body: {'x': 1}),
      throwsA(isA<ApiHttpException>()
          .having((e) => e.message, 'message', ApiHttp.writeUnknownMessage)
          .having((e) => e.isNetworkError, 'isNetworkError', isTrue)),
    );
    expect(hits['/drop-first'], 1);
  });

  test('a write that could not connect says nothing was saved', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    expect(
      () => ApiHttp.request('POST', 'http://127.0.0.1:$port/x', body: {'x': 1}),
      throwsA(isA<ApiHttpException>().having((e) => e.message, 'message', ApiHttp.writeNotSentMessage)),
    );
  });

  test('server responses refresh the health cache; network failures clear it', () async {
    final connectivity = ConnectivityService.instance;
    connectivity.invalidate();
    await ApiHttp.request('GET', '$base/json');
    expect(connectivity.hasCachedResult, isTrue);
    expect(await connectivity.hasConnection(), isTrue); // من الكاش، بلا طلب /health/

    await expectLater(
      ApiHttp.request('GET', '$base/slow', timeout: const Duration(milliseconds: 200)),
      throwsA(isA<ApiHttpException>()),
    );
    expect(connectivity.hasCachedResult, isFalse);
  });
}
