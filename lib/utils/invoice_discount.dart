import 'package:flutter/services.dart';

/// خصم الفاتورة في نقطة البيع (على مستوى الفاتورة فقط، لا خصم لكل سطر).
///
/// الإدخال أعداد صحيحة فقط (لا فاصلة عشرية ولا إشارة سالب) سواء كان مبلغاً أو
/// نسبة. النسبة محصورة بـ100 والمبلغ بالمجموع، والمبلغ الناتج يُقرَّب نصف-للأعلى
/// إلى خانتين (12% من 1255 = 150.60) — نفس القيمة تُحفظ أوفلاين وتُرسل أونلاين.
class InvoiceDiscount {
  InvoiceDiscount._();

  static const String amount = 'amount';
  static const String percent = 'percent';

  /// أرقام فقط: تُسقط "-" و"." وأي حرف آخر حتى عند اللصق.
  static final List<TextInputFormatter> inputFormatters = [FilteringTextInputFormatter.digitsOnly];

  /// قيمة الخصم المطبَّقة. يُحسب بالفلس (أعداد صحيحة) لتقريب نصف-للأعلى دقيق
  /// بلا أخطاء الفاصلة العائمة. قيمة سالبة (لا تصل من حقل الإدخال أصلاً) لا
  /// تُصحَّح هنا عمداً: إتمام البيع يرفضها برسالة واضحة.
  static double compute({required double subtotal, required String type, required String input}) {
    final value = int.tryParse(input.trim()) ?? 0;
    if (value == 0 || subtotal <= 0) return 0;
    final subtotalFils = (subtotal * 100).round();
    final int discountFils;
    if (type == percent) {
      final pct = value > 100 ? 100 : value;
      final raw = subtotalFils * pct;
      discountFils = raw >= 0 ? (raw + 50) ~/ 100 : -((-raw + 50) ~/ 100);
    } else {
      final fils = value * 100;
      discountFils = fils > subtotalFils ? subtotalFils : fils;
    }
    return discountFils / 100;
  }
}
