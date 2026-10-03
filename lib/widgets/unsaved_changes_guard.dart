import 'package:flutter/material.dart';

/// أدوات موحّدة لحماية العمل غير المحفوظ من الضياع عند المغادرة. ثلاث قطع:
///  - [confirmDiscardChanges]: نافذة التأكيد نفسها ("البقاء" هو الافتراضي).
///  - [UnsavedChangesGuard]: يلفّ نافذة/مساراً ويعترض كل طرق إغلاقه.
///  - [LeaveGuardController] + [LeaveGuardScope]: لشاشات داخل MainLayout تُغادَر
///    عبر الشريط الجانبي أو تسجيل الخروج (لا عبر Navigator).

/// يرجع true فقط عند اختيار [leaveLabel]. "البقاء" مركَّز عليه افتراضياً، وEsc
/// أو النقر خارج النافذة يعنيان البقاء أيضاً.
Future<bool> confirmDiscardChanges(
  BuildContext context, {
  required String message,
  required String leaveLabel,
  String stayLabel = 'البقاء',
}) async {
  final leave = await showDialog<bool>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(leaveLabel, style: const TextStyle(color: Color(0xFFDC2626))),
          ),
          FilledButton(
            autofocus: true,
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1ABC9C)),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(stayLabel),
          ),
        ],
      ),
    ),
  );
  return leave == true;
}

/// يعترض كل محاولة لإغلاق المسار الذي يلفّه (زر إلغاء يستدعي
/// Navigator.maybePop، Esc، النقر خارج النافذة، زر الرجوع) ما دام [isDirty]
/// صحيحاً، ويسأل قبل الإغلاق. بلا تغييرات يُغلق مباشرة بلا سؤال.
///
/// الإغلاق بعد الحفظ الناجح يجب أن يكون Navigator.pop (لا maybePop) فلا يُسأل.
class UnsavedChangesGuard extends StatelessWidget {
  final bool Function() isDirty;
  final String message;
  final String leaveLabel;
  final Widget child;

  const UnsavedChangesGuard({
    super.key,
    required this.isDirty,
    required this.message,
    required this.leaveLabel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (!isDirty() || await confirmDiscardChanges(context, message: message, leaveLabel: leaveLabel)) {
          navigator.pop(result);
        }
      },
      child: child,
    );
  }
}

/// فحص مغادرة الشاشة الحالية: null = لا شيء يستحق الحماية (لم تُعرض نافذة)،
/// true = المستخدم اختار الخروج، false = اختار البقاء.
typedef LeaveCheck = Future<bool?> Function();

/// يملكه MainLayout ويسأله قبل تبديل الشاشة أو تسجيل الخروج؛ الشاشة الحالية
/// تسجّل فحصها فيه (attach) وتزيله عند إغلاقها (detach).
class LeaveGuardController {
  LeaveCheck? _check;

  void attach(LeaveCheck check) => _check = check;

  void detach(LeaveCheck check) {
    if (_check == check) _check = null;
  }

  Future<bool?> confirmLeave() async {
    final check = _check;
    return check == null ? null : await check();
  }
}

class LeaveGuardScope extends InheritedWidget {
  final LeaveGuardController controller;

  const LeaveGuardScope({super.key, required this.controller, required super.child});

  static LeaveGuardController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<LeaveGuardScope>()?.controller;

  @override
  bool updateShouldNotify(LeaveGuardScope oldWidget) => controller != oldWidget.controller;
}
