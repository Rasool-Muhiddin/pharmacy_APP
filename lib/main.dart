import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'screens/activation_screen.dart';
import 'screens/login_screen.dart';
import 'screens/main_layout.dart';
import 'services/desktop_auth_storage.dart';
import 'services/medicine_api_service.dart';
import 'services/backup_service.dart';
import 'services/update_service.dart';
import 'models/subscription_plan.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  runApp(const PharmacyApp());
}

class PharmacyApp extends StatelessWidget {
  const PharmacyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'نظام إدارة الصيدلية',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar', 'SA'),
      supportedLocales: const [
        Locale('ar', 'SA'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        primaryColor: const Color(0xff1abc9c),
        scaffoldBackgroundColor: const Color(0xfff8f9fa),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff1abc9c),
          primary: const Color(0xff1abc9c),
          secondary: const Color(0xff148f77),
        ),
        textTheme: GoogleFonts.tajawalTextTheme(),
      ),
      home: const _StartupGate(),
    );
  }
}

class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  bool? _isActivated;
  Map<String, dynamic>? _savedSession;

  @override
  void initState() {
    super.initState();
    _checkActivation();
  }

  Future<void> _checkActivation() async {
    try {
      final isActivated =
          await DesktopAuthStorage.instance.isDeviceActivated();

      Map<String, dynamic>? savedSession;
      if (isActivated) {
        savedSession = await DesktopAuthStorage.instance.getSavedSession();
      }

      // تسجيل الدخول التلقائي (جلسة محفوظة) يتخطى AuthScreen بالكامل، لذا لا
      // بد من تفعيل api_token هنا يدوياً وإلا بقيت طلبات المخزون الأونلاين
      // بلا توكن رغم أن المستخدم "مسجّل دخول" فعلياً من وجهة نظره.
      if (savedSession != null) {
        final cachedToken = savedSession['api_token'];
        MedicineApiService.instance.setAuthToken(
          cachedToken is String ? cachedToken : null,
        );
      }

      // النسخ الاحتياطي: يشتغل بكل فتح تطبيق فيه جلسة صالحة (محفوظة)،
      // بدون انتظار (fire-and-forget) حتى لا يؤخر فتح التطبيق.
      if (isActivated && savedSession != null) {
        BackupService.runDailyBackupIfNeeded();
      }

      if (!mounted) return;

      setState(() {
        _isActivated = isActivated;
        _savedSession = savedSession;
      });

      // فحص التحديث لا يعطل فتح التطبيق (fire-and-forget)
      if (mounted) {
        UpdateService.checkForUpdate(context);
      }
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _isActivated = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isActivated == null) {
      return const Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Center(
            child: CircularProgressIndicator(
              color: Color(0xFF0D9488),
            ),
          ),
        ),
      );
    }

    if (_isActivated == false) {
      return const ActivationScreen();
    }

    // فيه جلسة محفوظة وصالحة -> ادخل مباشرة بدون المرور بشاشة تسجيل الدخول
    if (_savedSession != null) {
      final user = Map<String, dynamic>.from(_savedSession!['user'] as Map);
      final pharmacy =
          Map<String, dynamic>.from(_savedSession!['pharmacy'] as Map);

      final pharmacyId = (pharmacy['id'] as num?)?.toInt() ?? 0;
      final userId = (user['id'] as num?)?.toInt() ?? 0;
      final isOwner = user['is_owner'] == true || user['is_owner'] == 1;
      final license = Map<String, dynamic>.from(_savedSession!['license'] as Map);

      return MainLayout(
        pharmacyId: pharmacyId,
        userId: userId,
        isOwner: isOwner,
        entitlements: SubscriptionEntitlements.fromLicense(license),
      );
    }

    return AuthScreen(
      onLoginSuccess: (pharmacyId, userId, isOwner, entitlements) {
        // طبقة أمان إضافية: تغطي أول تسجيل دخول قبل وجود أي جلسة محفوظة،
        // ولا تكرر النسخة لو كانت _checkActivation أخذتها أصلاً بنفس اليوم.
        BackupService.runDailyBackupIfNeeded();

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => MainLayout(
              pharmacyId: pharmacyId,
              userId: userId,
              isOwner: isOwner,
              entitlements: entitlements,
            ),
          ),
        );
      },
    );
  }
}