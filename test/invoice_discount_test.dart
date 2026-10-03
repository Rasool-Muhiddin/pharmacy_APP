import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/utils/invoice_discount.dart';

String formatInput(String typed) => InvoiceDiscount.inputFormatters.fold<TextEditingValue>(
      TextEditingValue(text: typed),
      (value, formatter) => formatter.formatEditUpdate(TextEditingValue.empty, value),
    ).text;

double discount(double subtotal, String type, String input) =>
    InvoiceDiscount.compute(subtotal: subtotal, type: type, input: input);

void main() {
  group('whole-number input', () {
    test('digits only: no decimal point, no minus sign (typed or pasted)', () {
      expect(formatInput('15'), '15');
      expect(formatInput('-15'), '15');
      expect(formatInput('12.5'), '125');
      expect(formatInput('1,000'), '1000');
      expect(formatInput('abc'), '');
    });
  });

  group('amount', () {
    test('applied as-is, capped at the subtotal, empty or zero = no discount', () {
      expect(discount(3000, InvoiceDiscount.amount, '100'), 100);
      expect(discount(3000, InvoiceDiscount.amount, '5000'), 3000);
      expect(discount(1255.5, InvoiceDiscount.amount, '9999'), 1255.5);
      expect(discount(3000, InvoiceDiscount.amount, ''), 0);
      expect(discount(3000, InvoiceDiscount.amount, '0'), 0);
      expect(discount(0, InvoiceDiscount.amount, '10'), 0);
    });
  });

  group('percentage', () {
    test('capped at 100%', () {
      expect(discount(1255, InvoiceDiscount.percent, '100'), 1255);
      expect(discount(1255, InvoiceDiscount.percent, '250'), 1255);
    });

    test('fractional result is rounded half-up to 2 decimals', () {
      expect(discount(1255, InvoiceDiscount.percent, '12'), 150.6); // 150.60
      expect(discount(10.25, InvoiceDiscount.percent, '7'), 0.72); // 0.7175 -> 0.72
      expect(discount(0.5, InvoiceDiscount.percent, '1'), 0.01); // 0.005 -> 0.01 (half-up)
      expect(discount(0.49, InvoiceDiscount.percent, '1'), 0); // 0.0049 -> 0.00
      expect(discount(1999, InvoiceDiscount.percent, '7'), 139.93);
    });
  });

  test('a negative value is not silently clamped (checkout rejects it)', () {
    expect(discount(1000, InvoiceDiscount.amount, '-50'), -50);
    expect(discount(1000, InvoiceDiscount.percent, '-10'), -100);
  });
}
