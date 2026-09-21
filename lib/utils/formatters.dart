import 'package:intl/intl.dart';

class AppFormatter {
  static final NumberFormat _iqd =
      NumberFormat('#,##0', 'en_US');

  static String iqd(num? value) {
    if (value == null) return '0';
    return _iqd.format(value);
  }

  static String iqdWithCurrency(num? value) {
    if (value == null) return '0 د.ع';
    return '${_iqd.format(value)} د.ع';
  }
}