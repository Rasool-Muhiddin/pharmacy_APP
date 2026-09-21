import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class DesktopAuthException implements Exception {
  final String message;

  const DesktopAuthException(this.message);

  @override
  String toString() => message;
}

class DesktopAuthStorage {
  DesktopAuthStorage._();

  static final DesktopAuthStorage instance = DesktopAuthStorage._();

  static const _fileName = 'desktop_auth_state.json';
  static const _passwordIterations = 210000;

  final Pbkdf2 _passwordHasher = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _passwordIterations,
    bits: 256,
  );

  Future<File> _stateFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}$_fileName');
  }

  Future<Map<String, dynamic>> _readState() async {
    final file = await _stateFile();

    if (!await file.exists()) {
      return {
        'device_fingerprint': '',
        'activation': <String, dynamic>{},
        'accounts': <String, dynamic>{},
      };
    }

    try {
      final content = await file.readAsString();
      final data = jsonDecode(content);

      if (data is! Map<String, dynamic>) {
        throw const FormatException();
      }

      data.putIfAbsent('device_fingerprint', () => '');
      data.putIfAbsent('activation', () => <String, dynamic>{});
      data.putIfAbsent('accounts', () => <String, dynamic>{});

      return data;
    } catch (_) {
      throw const DesktopAuthException(
        'تعذر قراءة بيانات التفعيل المحلية. تواصل مع الدعم الفني.',
      );
    }
  }

  Future<void> _writeState(Map<String, dynamic> state) async {
    final file = await _stateFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(state),
      flush: true,
    );
  }

  Future<String> getOrCreateDeviceFingerprint() async {
    final state = await _readState();
    final currentFingerprint =
        (state['device_fingerprint'] as String? ?? '').trim();

    if (currentFingerprint.isNotEmpty) {
      return currentFingerprint;
    }

    final fingerprint = const Uuid().v4();
    state['device_fingerprint'] = fingerprint;
    await _writeState(state);

    return fingerprint;
  }

  String getDeviceName() {
    final name = Platform.localHostname.trim();

    if (name.isEmpty) {
      return 'جهاز سطح المكتب';
    }

    return name.length > 120 ? name.substring(0, 120) : name;
  }

  Future<bool> isDeviceActivated() async {
    final state = await _readState();
    final activation = Map<String, dynamic>.from(
      state['activation'] as Map? ?? <String, dynamic>{},
    );

    return activation['is_activated'] == true;
  }

  Future<void> saveActivation({
    required Map<String, dynamic> pharmacy,
    required Map<String, dynamic> license,
  }) async {
    final state = await _readState();

    state['activation'] = {
      'is_activated': true,
      'activated_at': DateTime.now().toUtc().toIso8601String(),
      'pharmacy': pharmacy,
      'license': license,
    };

    await _writeState(state);
  }

  Future<void> saveOnlineLogin({required String password, required Map<String, dynamic> response}) async {
    if (response['user'] is! Map || response['pharmacy'] is! Map || response['license'] is! Map) {
      throw const DesktopAuthException('استجابة الخادم غير مكتملة.');
    }
    final user = Map<String, dynamic>.from(response['user'] as Map);
    final pharmacy = Map<String, dynamic>.from(response['pharmacy'] as Map);
    final license = Map<String, dynamic>.from(response['license'] as Map);
    final username = (user['username'] as String? ?? '').trim();

    if (username.isEmpty) {
      throw const DesktopAuthException(
        'استجابة الخادم لا تحتوي على اسم المستخدم.',
      );
    }

    final salt = List<int>.generate(
      16,
      (_) => Random.secure().nextInt(256),
    );

    final passwordHash = await _createPasswordHash(
      password: password,
      salt: salt,
    );

    final state = await _readState();
    final accounts = Map<String, dynamic>.from(
      state['accounts'] as Map? ?? <String, dynamic>{},
    );

    accounts[username] = {
      'user': user,
      'pharmacy': pharmacy,
      'license': license,
      'password_salt': base64Encode(salt),
      'password_hash': base64Encode(passwordHash),
      'last_validated_at': response['validated_at'] ??
          DateTime.now().toUtc().toIso8601String(),
      'offline_grace_days': response['offline_grace_days'] ?? 30,
    };

    state['accounts'] = accounts;

    // تحديث بيانات التفعيل دون حفظ رمز التفعيل نفسه.
    state['activation'] = {
      'is_activated': true,
      'activated_at': (state['activation'] as Map?)?['activated_at'] ??
          DateTime.now().toUtc().toIso8601String(),
      'pharmacy': pharmacy,
      'license': license,
    };

    await _writeState(state);
  }

  Future<Map<String, dynamic>> verifyOfflineLogin({
    required String username,
    required String password,
  }) async {
    final state = await _readState();
    final accounts = Map<String, dynamic>.from(
      state['accounts'] as Map? ?? <String, dynamic>{},
    );

    final rawAccount = accounts[username];

    if (rawAccount is! Map) {
      throw const DesktopAuthException(
        'لا توجد بيانات محلية لهذا الحساب. اتصل بالإنترنت وسجّل الدخول مرة واحدة.',
      );
    }

    final account = Map<String, dynamic>.from(rawAccount);

    final saltText = account['password_salt'] as String?;
    final hashText = account['password_hash'] as String?;

    if (saltText == null || hashText == null) {
      throw const DesktopAuthException(
        'بيانات الدخول المحلية غير مكتملة. اتصل بالإنترنت وسجّل الدخول مرة أخرى.',
      );
    }

    final actualHash = await _createPasswordHash(
      password: password,
      salt: base64Decode(saltText),
    );

    if (!_constantTimeEquals(actualHash, base64Decode(hashText))) {
      throw const DesktopAuthException('اسم المستخدم أو كلمة المرور غير صحيحة.');
    }

    final result = _checkAccountLicense(account);
    return {...result, 'is_offline_login': true};
  }

  /// يفحص حالة الترخيص المخزّن محلياً لحساب معيّن (نشاط، تاريخ انتهاء،
  /// مدة العمل بدون إنترنت). يُستخدم من verifyOfflineLogin (بعد التحقق من
  /// كلمة المرور) ومن getSavedSession (بدون كلمة مرور، لأنها جلسة محفوظة).
  Map<String, dynamic> _checkAccountLicense(Map<String, dynamic> account) {
    final license = Map<String, dynamic>.from(
      account['license'] as Map? ?? <String, dynamic>{},
    );

    if (license['status'] != 'active') {
      throw const DesktopAuthException('ترخيص نسخة سطح المكتب غير فعال.');
    }

    final expiresAtText = license['expires_at'] as String?;
    if (expiresAtText != null && expiresAtText.isNotEmpty) {
      final expiresAt = DateTime.tryParse(expiresAtText)?.toLocal();

      if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
        throw const DesktopAuthException('انتهت صلاحية ترخيص نسخة سطح المكتب.');
      }
    }

    final validatedAt = DateTime.tryParse(
      account['last_validated_at'] as String? ?? '',
    )?.toLocal();

    final graceDays = (account['offline_grace_days'] as num?)?.toInt() ?? 30;

    if (validatedAt == null ||
        DateTime.now().difference(validatedAt).inDays > graceDays) {
      throw DesktopAuthException(
        'انتهت مدة العمل دون إنترنت ($graceDays يومًا). اتصل بالإنترنت للتحقق من الترخيص.',
      );
    }

    return {
      'user': Map<String, dynamic>.from(account['user'] as Map),
      'pharmacy': Map<String, dynamic>.from(account['pharmacy'] as Map),
      'license': license,
    };
  }

  Future<List<int>> _createPasswordHash({
    required String password,
    required List<int> salt,
  }) async {
    final secretKey = await _passwordHasher.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );

    return secretKey.extractBytes();
  }

  bool _constantTimeEquals(List<int> first, List<int> second) {
    if (first.length != second.length) return false;

    var difference = 0;

    for (var index = 0; index < first.length; index++) {
      difference |= first[index] ^ second[index];
    }

    return difference == 0;
  }

  /// يُستدعى بعد أي تسجيل دخول ناجح (أونلاين أو أوفلاين) لحفظ الجلسة الحالية.
  Future<void> saveSession(String username) async {
    final state = await _readState();
    state['active_session'] = username;
    await _writeState(state);
  }

  /// يُستدعى عند بدء التطبيق للتحقق هل فيه جلسة محفوظة وصالحة.
  /// يرجع بيانات المستخدم/الصيدلية/الترخيص إذا الجلسة صالحة، أو null إذا لا
  /// (سواء ما فيه جلسة أصلاً، أو الترخيص انتهى، أو تجاوزت مدة العمل بدون نت).
  Future<Map<String, dynamic>?> getSavedSession() async {
    try {
      final state = await _readState();
      final activeUsername = (state['active_session'] as String?)?.trim();

      if (activeUsername == null || activeUsername.isEmpty) {
        return null;
      }

      final accounts = Map<String, dynamic>.from(
        state['accounts'] as Map? ?? <String, dynamic>{},
      );

      final rawAccount = accounts[activeUsername];
      if (rawAccount is! Map) return null;

      final account = Map<String, dynamic>.from(rawAccount);
      return _checkAccountLicense(account);
    } catch (_) {
      return null; // أي مشكلة = نرجّعه لشاشة تسجيل الدخول بأمان
    }
  }

  /// يمسح الجلسة المحفوظة (تُستدعى عند الضغط على "تسجيل خروج").
  Future<void> clearSession() async {
    final state = await _readState();
    state.remove('active_session');
    await _writeState(state);
  }
}