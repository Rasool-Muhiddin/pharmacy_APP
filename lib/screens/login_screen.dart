import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../services/desktop_api_service.dart';
import '../services/desktop_auth_storage.dart';
import '../services/medicine_api_service.dart';
import '../services/invoice_api_service.dart';
import '../services/suppliers_api_service.dart';
import '../services/expense_api_service.dart';
import '../services/damaged_api_service.dart';
import 'main_layout.dart';
import '../database/db_helper.dart';
import '../models/subscription_plan.dart';

class AuthScreen extends StatefulWidget {
  final Function(
    int pharmacyId,
    int userId,
    bool isOwner,
    bool isOnlineMode,
    SubscriptionEntitlements entitlements,
  )? onLoginSuccess;

  const AuthScreen({
    super.key,
    this.onLoginSuccess,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _hidePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate() || _isLoading) return;

    setState(() => _isLoading = true);

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    try {
      final deviceFingerprint =
          await DesktopAuthStorage.instance.getOrCreateDeviceFingerprint();

      final response = await DesktopApiService.instance.login(
        username: username,
        password: password,
        deviceFingerprint: deviceFingerprint,
      );

      await DesktopAuthStorage.instance.saveOnlineLogin(
        password: password,
        response: response,
      );

      if (!mounted) return;

      _showMessage('تم تسجيل الدخول بنجاح.', const Color(0xFF0D9488));
      await _continueToApplication(response);
    } on DesktopApiException catch (error) {
      // لا نستخدم التحقق المحلي عند رفض الخادم لكلمة المرور أو الترخيص.
      final canUseOfflineLogin =
          error.statusCode == null || error.statusCode! >= 500;

      if (!canUseOfflineLogin) {
        _showMessage(error.message, const Color(0xFFB91C1C));
        return;
      }

      await _tryOfflineLogin(
        username: username,
        password: password,
        connectionMessage: error.message,
      );
    } on DesktopAuthException catch (error) {
      if (mounted) {
        _showMessage(error.message, const Color(0xFFB91C1C));
      }
    } catch (_) {
      if (mounted) {
        _showMessage(
          'حدث خطأ غير متوقع أثناء تسجيل الدخول.',
          const Color(0xFFB91C1C),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _tryOfflineLogin({
    required String username,
    required String password,
    required String connectionMessage,
  }) async {
    try {
      final response = await DesktopAuthStorage.instance.verifyOfflineLogin(
        username: username,
        password: password,
      );

      if (!mounted) return;

      _showMessage(
        'تم تسجيل الدخول دون إنترنت. $connectionMessage',
        const Color(0xFFB45309),
      );

      await _continueToApplication(response);
    } on DesktopAuthException catch (error) {
      if (!mounted) return;
      _showMessage(error.message, const Color(0xFFB91C1C));
    } catch (_) {
      if (!mounted) return;
      _showMessage('حدث خطأ غير متوقع.', const Color(0xFFB91C1C));
    }
  }

  Future<void> _continueToApplication(
  Map<String, dynamic> response,
  ) async {
    final user = Map<String, dynamic>.from(response['user'] as Map);
    final pharmacy = Map<String, dynamic>.from(response['pharmacy'] as Map);

    final pharmacyId = (pharmacy['id'] as num?)?.toInt() ?? 0;
    final userId = (user['id'] as num?)?.toInt() ?? 0;
    final isOwner = user['is_owner'] == true || user['is_owner'] == 1;
    final license = Map<String, dynamic>.from(response['license'] as Map);
    final entitlements = SubscriptionEntitlements.fromLicense(license);
    // license.mode قادم من DesktopLicense.mode على الخادم ("online"/"offline")؛
    // متوفر سواء جاء الرد من دخول أونلاين فعلي أو من verifyOfflineLogin
    // (لأنه يُحفظ ويُعاد من الترخيص المخزَّن محلياً في كلتا الحالتين).
    final isOnlineMode = license['mode'] == 'online';

    // api_token يصل فقط عند تسجيل دخول أونلاين فعلي عبر السيرفر (desktop_login).
    // دخول الأوفلاين (verifyOfflineLogin) لا يمرّ بالسيرفر، فلا يحمل توكن صالحاً؛
    // في تلك الحالة نُفرغه صراحة بدل ترك قيمة قديمة قد تكون منتهية.
    final apiToken = response['api_token'];
    MedicineApiService.instance.setAuthToken(
      apiToken is String && apiToken.isNotEmpty ? apiToken : null,
    );
    InvoiceApiService.instance.setAuthToken(
      apiToken is String && apiToken.isNotEmpty ? apiToken : null,
    );
    SuppliersApiService.instance.setAuthToken(
      apiToken is String && apiToken.isNotEmpty ? apiToken : null,
    );
    ExpenseApiService.instance.setAuthToken(
      apiToken is String && apiToken.isNotEmpty ? apiToken : null,
    );
    DamagedApiService.instance.setAuthToken(
      apiToken is String && apiToken.isNotEmpty ? apiToken : null,
    );

    if (pharmacyId == 0 || userId == 0) {
      _showMessage(
        'بيانات الحساب المستلمة غير مكتملة.',
        const Color(0xFFB91C1C),
      );
      return;
    }
  final username = (user['username'] ?? '').toString();
    if (username.isNotEmpty) {
      await DesktopAuthStorage.instance.saveSession(username);
    }
    final db = await DatabaseHelper.instance.database;

    // لا بد من وجود صف مطابق في pharmacy_branch محلياً أولاً،
    // لأن user_profile.pharmacy_id مرتبط به بقيد FOREIGN KEY صارم
    // (PRAGMA foreign_keys = ON)، وهذا أول تشغيل للتطبيق بعد التفعيل
    // فلا يوجد أي صف محلي للصيدلية بعد.
    //
    // ملاحظة: نستخدم INSERT OR IGNORE ثم UPDATE بدل REPLACE،
    // لأن REPLACE ينفّذ DELETE+INSERT داخلياً، وبما أن جداول أخرى
    // (medicine, user_profile, ...) تشير لهذا الصف بقيد FOREIGN KEY
    // بدون ON DELETE CASCADE، فسيفشل الحذف في أي تسجيل دخول لاحق.
    final pharmacyName = (pharmacy['name'] ?? 'الصيدلية').toString();

    await db.insert(
      'pharmacy_branch',
      {
        'id': pharmacyId,
        'name': pharmacyName,
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    await db.update(
      'pharmacy_branch',
      {'name': pharmacyName, 'is_active': 1},
      where: 'id = ?',
      whereArgs: [pharmacyId],
    );

    await db.insert(
      'users',
      {
        'id': userId,
        'username': (user['username'] ?? '').toString(),
        'password': '',
        'full_name':
            (user['full_name'] ?? user['name'] ?? user['username']).toString(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await db.insert(
      'user_profile',
      {
        'id': userId,
        'user_id': userId,
        'pharmacy_id': pharmacyId,
        'is_owner': isOwner ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // نفس السبب: invoice.cashier_id يشير إلى user_profile(id) بدون
    // ON DELETE CASCADE، فـ REPLACE سيفشل بعد أول عملية بيع يسجّلها المستخدم.
    await db.update(
      'user_profile',
      {
        'user_id': userId,
        'pharmacy_id': pharmacyId,
        'is_owner': isOwner ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [userId],
    );

    if (widget.onLoginSuccess != null) {
      widget.onLoginSuccess!(pharmacyId, userId, isOwner, isOnlineMode, entitlements);
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => MainLayout(
          pharmacyId: pharmacyId,
          userId: userId,
          isOwner: isOwner,
          isOnlineMode: isOnlineMode,
          entitlements: entitlements,
        ),
      ),
    );
  }

  void _showMessage(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
      ),
    );
  }

  // نقطة كسر التصميم: تحت هذا العرض يختفي القسم الدعائي الجانبي
  // ويبقى نموذج تسجيل الدخول وحده متمركزاً في الشاشة.
  static const double _brandPanelBreakpoint = 900;
  static const Color _brandStart = Color(0xFF1ABC9C);
  static const Color _brandEnd = Color(0xFF148F77);

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F6F9),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final showBrandPanel = constraints.maxWidth >= _brandPanelBreakpoint;

            if (!showBrandPanel) {
              return Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: _buildFormCard(elevated: true),
                ),
              );
            }

            return Row(
              children: [
                // النموذج على يمين الشاشة (أول عنصر في Row تحت RTL).
                Expanded(
                  flex: 5,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      child: _buildFormCard(elevated: false),
                    ),
                  ),
                ),
                // اللوحة الدعائية على يسار الشاشة.
                Expanded(
                  flex: 6,
                  child: _buildBrandPanel(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildFormCard({required bool elevated}) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(32),
      decoration: elevated
          ? BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 5),
                ),
              ],
            )
          : null,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Image.asset(
              'assets/image/tera_logo1.png',
              height: 85,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 16),
            const Text(
              'تسجيل الدخول للنظام',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'استخدم بيانات الحساب التي أنشأتها الشركة .',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF6B7280),
              ),
            ),
            const SizedBox(height: 28),
            TextFormField(
              controller: _usernameController,
              autofocus: true,
              enabled: !_isLoading,
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'اسم المستخدم مطلوب.';
                }

                return null;
              },
              decoration: InputDecoration(
                labelText: 'اسم المستخدم',
                prefixIcon: const Icon(
                  Icons.person_rounded,
                  color: Color(0xFF0D9488),
                ),
                filled: true,
                fillColor: const Color(0xFFF9FAFB),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _brandEnd, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              enabled: !_isLoading,
              obscureText: _hidePassword,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _handleLogin(),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'كلمة المرور مطلوبة.';
                }

                return null;
              },
              decoration: InputDecoration(
                labelText: 'كلمة المرور',
                prefixIcon: const Icon(
                  Icons.lock_rounded,
                  color: Color(0xFF0D9488),
                ),
                suffixIcon: IconButton(
                  onPressed: _isLoading
                      ? null
                      : () {
                          setState(() {
                            _hidePassword = !_hidePassword;
                          });
                        },
                  icon: Icon(
                    _hidePassword
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                ),
                filled: true,
                fillColor: const Color(0xFFF9FAFB),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _brandEnd, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: _isLoading
                      ? null
                      : const LinearGradient(
                          colors: [_brandStart, _brandEnd],
                        ),
                  boxShadow: _isLoading
                      ? null
                      : [
                          BoxShadow(
                            color: _brandEnd.withValues(alpha: 0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                          ),
                        ],
                ),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        _isLoading ? const Color(0xFF0D9488) : Colors.transparent,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: _isLoading ? null : _handleLogin,
                  child: _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'دخول',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'يتطلب أول تسجيل دخول اتصالًا بالإنترنت.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF6B7280),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrandPanel() {
    // اللوحة اليسرى: صورة المشهد الدعائي (الصيدلية + شاشة الداشبورد)
    // كخلفية كاملة تغطي المساحة، مع تدرج احتياطي أثناء تحميل الصورة
    // أو في حال عدم توفرها.
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_brandStart, _brandEnd],
        ),
      ),
      child: Image.asset(
        'assets/image/tera_login_bg1.png',
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      ),
    );
  }
}