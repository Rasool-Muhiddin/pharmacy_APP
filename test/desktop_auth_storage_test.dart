import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/services/desktop_auth_storage.dart';

/// القفل المحلي (الجلسة المحفوظة + الدخول الأوفلاين) يتبع قاعدة الخادم
/// DesktopLicense.is_valid: الترخيص مدى الحياة لا ينتهي بسبب expires_at.
void main() {
  late Directory tempDir;
  final storage = DesktopAuthStorage.instance;
  const password = 'secret-pass';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('desktop_auth_test');
    DesktopAuthStorage.stateDirectoryOverride = tempDir.path;
  });

  tearDown(() async {
    DesktopAuthStorage.stateDirectoryOverride = null;
    await tempDir.delete(recursive: true);
  });

  String daysFromNow(int days) => DateTime.now().toUtc().add(Duration(days: days)).toIso8601String();

  /// يحفظ دخولاً أونلاين حديثاً (مهلة الأوفلاين سارية) بترخيص Basic أوفلاين.
  Future<void> loginWith({required String type, required String? expiresAt}) async {
    await storage.saveOnlineLogin(password: password, response: {
      'validated_at': DateTime.now().toUtc().toIso8601String(),
      'offline_grace_days': 30,
      'user': {'id': 5, 'username': 'owner', 'full_name': 'Owner', 'is_owner': true},
      'pharmacy': {'id': 3, 'name': 'P'},
      'license': {
        'type': type,
        'mode': 'offline',
        'plan': 'basic',
        'max_warehouses': 1,
        'status': 'active',
        'expires_at': expiresAt,
        'max_devices': 1,
      },
      'api_token': 'token',
    });
    await storage.saveSession('owner');
  }

  test('lifetime license with a past expires_at stays usable (saved session and offline login)', () async {
    await loginWith(type: 'lifetime', expiresAt: daysFromNow(-30));

    final session = await storage.getSavedSession();
    expect(session, isNotNull);
    expect((session!['license'] as Map)['type'], 'lifetime');

    final offline = await storage.verifyOfflineLogin(username: 'owner', password: password);
    expect(offline['is_offline_login'], isTrue);
  });

  test('annual license with a past expires_at is still locked', () async {
    await loginWith(type: 'annual', expiresAt: daysFromNow(-1));

    expect(await storage.getSavedSession(), isNull);
    await expectLater(
      storage.verifyOfflineLogin(username: 'owner', password: password),
      throwsA(isA<DesktopAuthException>().having((e) => e.message, 'message', 'انتهت صلاحية ترخيص نسخة سطح المكتب.')),
    );
  });

  test('annual license before expires_at works', () async {
    await loginWith(type: 'annual', expiresAt: daysFromNow(5));
    expect(await storage.getSavedSession(), isNotNull);
  });

  // مصفوفة قاعدة الخادم DesktopLicense.is_valid لكل الأنواع الثلاثة، عبر
  // القفل الفعلي (الجلسة المحفوظة + الدخول الأوفلاين).
  const expiredMessage = 'انتهت صلاحية ترخيص نسخة سطح المكتب.';
  const inactiveMessage = 'ترخيص نسخة سطح المكتب غير فعال.';
  final cases = <(String, int?, String?)>[
    ('lifetime', 5, null),
    ('lifetime', -5, null),
    ('lifetime', null, null),
    ('annual', 5, null),
    ('annual', -5, expiredMessage),
    ('annual', null, inactiveMessage),
    ('trial', 5, null),
    ('trial', -5, expiredMessage),
    ('trial', null, inactiveMessage),
  ];
  for (final (type, days, rejection) in cases) {
    final label = '$type, expires_at ${days == null ? 'missing' : '${days > 0 ? '+' : ''}$days days'}';
    test('$label -> ${rejection ?? 'valid'}', () async {
      await loginWith(type: type, expiresAt: days == null ? null : daysFromNow(days));
      final offline = storage.verifyOfflineLogin(username: 'owner', password: password);
      if (rejection == null) {
        expect(await storage.getSavedSession(), isNotNull);
        expect((await offline)['is_offline_login'], isTrue);
      } else {
        expect(await storage.getSavedSession(), isNull);
        await expectLater(offline, throwsA(isA<DesktopAuthException>().having((e) => e.message, 'message', rejection)));
      }
    });
  }

  test('the 30-day offline grace is unchanged and applies to every license type', () async {
    final file = File('${tempDir.path}${Platform.pathSeparator}desktop_auth_state.json');
    for (final type in ['lifetime', 'annual', 'trial']) {
      for (final (age, allowed) in [(30, true), (31, false)]) {
        await loginWith(type: type, expiresAt: daysFromNow(365));
        final validated = DateTime.now().toUtc().subtract(Duration(days: age, hours: 1)).toIso8601String();
        final text = await file.readAsString();
        await file.writeAsString(text.replaceFirst(RegExp(r'"last_validated_at":"[^"]*"'), '"last_validated_at":"$validated"'));
        expect(await storage.getSavedSession() != null, allowed, reason: '$type after $age days');
      }
    }
  });

  test('lifetime does not bypass the other checks (inactive status, offline grace)', () async {
    await loginWith(type: 'lifetime', expiresAt: null);
    final file = File('${tempDir.path}${Platform.pathSeparator}desktop_auth_state.json');

    var text = await file.readAsString();
    await file.writeAsString(text.replaceAll('"status":"active"', '"status":"suspended"'));
    expect(await storage.getSavedSession(), isNull);

    await loginWith(type: 'lifetime', expiresAt: null);
    text = await file.readAsString();
    final stale = DateTime.now().toUtc().subtract(const Duration(days: 40)).toIso8601String();
    await file.writeAsString(text.replaceFirst(RegExp(r'"last_validated_at":"[^"]*"'), '"last_validated_at":"$stale"'));
    await expectLater(
      storage.verifyOfflineLogin(username: 'owner', password: password),
      throwsA(isA<DesktopAuthException>().having((e) => e.message, 'message', contains('انتهت مدة العمل دون إنترنت'))),
    );
  });
}
