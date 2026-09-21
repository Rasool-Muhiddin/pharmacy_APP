import 'package:flutter/material.dart';

import '../services/desktop_api_service.dart';
import '../services/desktop_auth_storage.dart';
import 'login_screen.dart';

class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _activationCodeController = TextEditingController();

  bool _isLoading = false;
  String? _deviceName;

  @override
  void initState() {
    super.initState();
    _prepareDevice();
  }

  Future<void> _prepareDevice() async {
    try {
      await DesktopAuthStorage.instance.getOrCreateDeviceFingerprint();

      if (!mounted) return;

      setState(() {
        _deviceName = DesktopAuthStorage.instance.getDeviceName();
      });
    } catch (_) {
      if (!mounted) return;

      _showMessage(
        'تعذر تجهيز بيانات الجهاز. أعد تشغيل التطبيق.',
        isError: true,
      );
    }
  }

  @override
  void dispose() {
    _activationCodeController.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    if (!_formKey.currentState!.validate() || _isLoading) return;

    setState(() => _isLoading = true);

    try {
      final deviceFingerprint =
          await DesktopAuthStorage.instance.getOrCreateDeviceFingerprint();

      final response = await DesktopApiService.instance.activate(
        activationCode: _activationCodeController.text.trim(),
        deviceFingerprint: deviceFingerprint,
        deviceName: DesktopAuthStorage.instance.getDeviceName(),
      );

      final pharmacy = Map<String, dynamic>.from(response['pharmacy'] as Map);
      final license = Map<String, dynamic>.from(response['license'] as Map);

      await DesktopAuthStorage.instance.saveActivation(
        pharmacy: pharmacy,
        license: license,
      );

      if (!mounted) return;

      await _showSuccessDialog(pharmacy['name'] as String? ?? 'الصيدلية');

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const AuthScreen(),
        ),
      );
    } on DesktopApiException catch (error) {
      if (mounted) {
        _showMessage(error.message, isError: true);
      }
    } on DesktopAuthException catch (error) {
      if (mounted) {
        _showMessage(error.message, isError: true);
      }
    } catch (_) {
      if (mounted) {
        _showMessage(
          'حدث خطأ غير متوقع أثناء التفعيل. حاول مرة أخرى.',
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _showSuccessDialog(String pharmacyName) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(
            Icons.verified_rounded,
            color: Color(0xFF0D9488),
            size: 42,
          ),
          title: const Text('تم تفعيل البرنامج'),
          content: Text(
            'تم ربط هذا الجهاز بصيدلية $pharmacyName بنجاح. يمكنك الآن تسجيل الدخول.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('متابعة'),
            ),
          ],
        );
      },
    );
  }

  void _showMessage(
    String message, {
    required bool isError,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor:
            isError ? const Color(0xFFB91C1C) : const Color(0xFF0D9488),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F6F9),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              width: 460,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/image/tera_logo.png',
                      height: 85,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'تفعيل نسخة سطح المكتب',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1F2937),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'أدخل رمز التفعيل الذي استلمته من إدارة النظام.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF6B7280),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _activationCodeController,
                      autofocus: true,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center,
                      textCapitalization: TextCapitalization.characters,
                      enabled: !_isLoading,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'رمز التفعيل مطلوب.';
                        }

                        return null;
                      },
                      decoration: InputDecoration(
                        labelText: 'رمز التفعيل',
                        hintText: 'XXXX-XXXX-XXXX',
                        prefixIcon: const Icon(
                          Icons.key_rounded,
                          color: Color(0xFF0D9488),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: Color(0xFF0D9488),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _deviceName == null
                          ? 'جاري تجهيز معلومات الجهاز...'
                          : 'سيتم تفعيل هذا الجهاز: $_deviceName',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF0D9488),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: _isLoading ? null : _activate,
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
                                'تفعيل الجهاز',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'يتطلب التفعيل اتصالًا بالإنترنت مرة واحدة.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}