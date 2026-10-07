import 'package:flutter/material.dart';

/// تُعرض بدل تنفيذ ميزة "ظاهرة لكن مقفولة" (lockedButVisibleInBasic) عندما
/// تكون الصيدلية على باقة لا تتيحها: الزر يبقى ظاهراً، والضغط يشرح سبب القفل.
Future<void> showUpgradeRequiredDialog(BuildContext context, {required String message}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('upgrade-required-dialog'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Row(
        children: [
          Icon(Icons.lock_outline, color: Color(0xFFD97706)),
          SizedBox(width: 10),
          Text('ميزة الباقة الذهبية'),
        ],
      ),
      content: Text(message),
      actions: [
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD97706)),
          onPressed: () => Navigator.pop(ctx),
          child: const Text('حسناً', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
}
