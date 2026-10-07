import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../../models/medicine_categories.dart';
import '../../../widgets/medicine_dialogs.dart' show damageReasons;
import 'report_export_data.dart';

/// أسماء الأوراق بالترتيب (الأولى ملخص ثم ورقة لكل تبويب).
const List<String> reportExcelSheets = [
  'ملخص',
  'المبيعات',
  'الأصناف',
  'المخزون',
  'المشتريات والمذاخر',
  'المصاريف والخسائر',
];

/// يُستدعى عبر compute(): يبني ملف xlsx كاملاً (أوراق من اليمين لليسار،
/// المبالغ والكميات خلايا رقمية حقيقية، التواريخ خلايا تاريخ).
Uint8List buildReportExcel(ReportExportData d) {
  final excel = Excel.createExcel();
  final defaultSheet = excel.getDefaultSheet();
  final writers = {for (final name in reportExcelSheets) name: _SheetWriter(excel[name])};
  if (defaultSheet != null && !reportExcelSheets.contains(defaultSheet)) excel.delete(defaultSheet);
  excel.setDefaultSheet(reportExcelSheets.first);

  _summary(writers['ملخص']!, d);
  _sales(writers['المبيعات']!, d);
  _items(writers['الأصناف']!, d);
  _inventory(writers['المخزون']!, d);
  _purchases(writers['المشتريات والمذاخر']!, d);
  _losses(writers['المصاريف والخسائر']!, d);

  // حزمة excel (4.0.x) لا تحفظ isRTL إلا لورقة موجودة أصلاً في ملف مقروء،
  // فنقرأ الملف المبني مرة ثانية ونضبط الاتجاه وعرض الأعمدة عليه.
  final book = Excel.decodeBytes(excel.encode()!);
  for (final MapEntry(key: name, value: w) in writers.entries) {
    final sheet = book[name];
    sheet.isRTL = true;
    for (final (i, width) in w.columnWidths.indexed) {
      sheet.setColumnWidth(i, width);
    }
  }
  return Uint8List.fromList(book.encode()!);
}

// ---------------------------------------------------------------------------
// الأوراق
// ---------------------------------------------------------------------------

void _summary(_SheetWriter w, ReportExportData d) {
  final p = d.period, prev = p.previous;
  w.title('تقرير الصيدلية');
  w.pair('الصيدلية', _T(d.pharmacyName));
  w.row([_T('الفترة'), _Date(p.start), _Date(p.end)], bold0: true);
  w.row([_T('الفترة السابقة (للمقارنة)'), _Date(prev.start), _Date(prev.end)], bold0: true);
  w.pair('تاريخ الإنشاء', _DateTime(d.generatedAt));
  w.blank();

  w.section('المؤشرات الرئيسية');
  w.table(['المؤشر', 'الفترة الحالية', 'الفترة السابقة', 'نسبة التغيير'], [
    for (final k in d.kpiLines)
      [
        _T(k.label),
        k.isCount ? _Int(k.current) : _Money(k.current),
        k.isCount ? _Int(k.previous) : _Money(k.previous),
        k.change == null ? _T('-') : _Pct(k.change!),
      ],
  ]);
  w.blank();

  w.section('قائمة الدخل المبسطة');
  w.table(['البند', 'المبلغ'], [
    for (final l in d.incomeLines) [_T(l.label), l.percent ? _Pct(l.value) : _Money(l.value)],
  ], boldRows: {for (final (i, l) in d.incomeLines.indexed) if (l.total) i});
  if (d.expiredNotDisposedValue > 0) {
    w.row([_T('منتهي الصلاحية غير مُسجَّل كتالف (للعلم — لم يُخصم من الربح)'), _Money(d.expiredNotDisposedValue)]);
  }
  w.blank();

  final a = d.alerts;
  w.section('التنبيهات الحالية');
  w.table(['التنبيه', 'العدد', 'القيمة'], [
    [_T('أصناف تُباع بأقل من كلفتها'), _Int(a['below_cost_count']), _T('-')],
    [_T('تنتهي صلاحيتها خلال ${xi(a['expiring_days'] ?? 30)} يوماً'), _Int(a['expiring_count']), _Money(a['expiring_value'])],
    [_T('منتهية الصلاحية غير مُسجَّلة كتالف'), _Int(a['expired_count']), _Money(a['expired_value'])],
    [_T('نفدت أو أوشكت على النفاد'), _Int(a['low_stock_count']), _T('-')],
    [_T('منها نفدت بالكامل'), _Int(a['out_of_stock_count']), _T('-')],
  ]);
  w.widths([44, 20, 20, 16]);
}

void _sales(_SheetWriter w, ReportExportData d) {
  final c = d.current;
  final count = xn(c['invoices_count']);
  w.section('ملخص المبيعات');
  w.pair('صافي المبيعات', _Money(c['net_sales']));
  w.pair('إجمالي المبيعات قبل الخصم', _Money(c['gross_sales']));
  w.pair('الخصومات الممنوحة', _Money(c['discounts']));
  w.pair('عدد الفواتير', _Int(count));
  w.pair('متوسط الفاتورة', _Money(count > 0 ? xn(c['net_sales']) / count : 0));
  w.pair('عدد الفواتير المسترجعة', _Int(c['refunded_count']));
  w.pair('قيمة الفواتير المسترجعة', _Money(c['refunded_value']));
  w.blank();

  w.section('ملخص البائعين');
  w.table(['البائع', 'عدد الفواتير', 'صافي المبيعات', 'متوسط الفاتورة'], [
    for (final r in d.sellers)
      [
        _T(r['seller_name']),
        _Int(r['invoices_count']),
        _Money(r['net_sales']),
        _Money(xi(r['invoices_count']) > 0 ? xn(r['net_sales']) / xi(r['invoices_count']) : 0),
      ],
  ]);
  w.blank();

  _invoiceTable(w, 'الفواتير الصادرة', d.invoices);
  w.blank();
  _invoiceTable(w, 'الفواتير المسترجعة', d.refunds);
  w.widths([22, 20, 22, 16, 14, 16]);
}

void _invoiceTable(_SheetWriter w, String title, PagedRows data) {
  w.section('$title (${data.count})');
  w.table(['رقم الفاتورة', 'التاريخ والوقت', 'البائع', 'الإجمالي', 'الخصم', 'الصافي'], [
    for (final r in data.rows)
      [
        _T(r['invoice_number']),
        _DateTime.parse(r['created_at']),
        _T(r['seller_name']),
        _Money(r['total_amount']),
        _Money(r['discount']),
        _Money(r['final_amount']),
      ],
  ]);
  if (data.capped) w.note(_capNote(data));
}

String _capNote(PagedRows data) =>
    'ملاحظة: عُرضت أول ${data.rows.length} صفاً فقط من أصل ${data.count} (الحد الأقصى ${ReportExportData.rowCap}).';

void _items(_SheetWriter w, ReportExportData d) {
  final top = xrows(d.itemsByQty['items']);
  w.section('الأكثر مبيعاً (أعلى ${top.length} صنفاً بالكمية)');
  w.table(['#', 'الصنف', 'الكمية', 'الإيراد', 'الكلفة', 'الربح', 'الهامش'], [
    for (final (i, r) in top.indexed)
      () {
        final costed = xn(r['costed_revenue']);
        return [
          _Int(i + 1),
          _T(r['trade_name']),
          _Int(r['quantity']),
          _Money(r['revenue']),
          costed > 0 ? _Money(r['cost']) : _T('غير معروفة'),
          costed > 0 ? _Money(r['profit']) : _T('-'),
          costed > 0 ? _Pct(xn(r['profit']) / costed) : _T('-'),
        ];
      }(),
  ]);
  w.blank();

  w.section('أصناف تُباع بأقل من كلفتها');
  w.table(['الصنف', 'الكلفة', 'سعر البيع', 'الخسارة للقطعة', 'الكمية المتوفرة'], [
    for (final r in xrows(d.itemsByQty['below_cost']))
      [_T(r['trade_name']), _Money(r['cost']), _Money(r['sell_price']), _Money(r['loss_per_unit']), _Int(r['quantity'])],
  ]);
  w.blank();

  final s = d.stagnant;
  w.section('الأصناف الراكدة (${s.count} صنفاً بقيمة مجمّدة ${_plain(s.first['total_value'])})');
  w.table(['الصنف', 'الشكل الدوائي', 'الكمية', 'القيمة المجمّدة', 'آخر بيع'], [
    for (final r in s.rows)
      [
        _T(r['trade_name']),
        _T(medicineCategoryLabel(r['category'])),
        _Int(r['quantity']),
        _Money(r['stock_value']),
        r['last_sale'] == null ? _T('لم يُبع') : _Date.parse(r['last_sale']),
      ],
  ]);
  if (s.capped) w.note(_capNote(s));
  w.widths([8, 34, 22, 16, 18, 16, 12]);
}

void _inventory(_SheetWriter w, ReportExportData d) {
  final inv = d.inventory;
  w.section('قيمة المخزون الحالي');
  w.pair('بسعر الكلفة', _Money(inv['stock_cost_value']));
  w.pair('بسعر البيع', _Money(inv['stock_sell_value']));
  w.pair('الربح المتوقع عند بيع الكل', _Money(inv['expected_profit']));
  w.blank();

  void batches(String title, Object? rows) {
    w.section(title);
    w.table(['الصنف', 'تاريخ الانتهاء', 'الكمية', 'القيمة (بالكلفة)', 'المذخر'], [
      for (final r in xrows(rows))
        [
          _T(r['trade_name']),
          _Date.parse(r['expiry_date']),
          _Int(r['quantity']),
          _Money(r['value']),
          _T((r['supplier_name'] as String?)?.isNotEmpty == true ? r['supplier_name'] : 'غير مسجّل'),
        ],
    ]);
    w.blank();
  }

  batches('تنتهي صلاحيتها خلال ${xi(inv['days'] ?? ReportExportData.expiryDays)} يوماً', inv['expiring']);
  batches('منتهية الصلاحية ولم تُسجَّل كتالف', inv['expired']);

  w.section('أصناف نفدت أو أوشكت على النفاد (الكمية ${xi(inv['low_stock_threshold'])} أو أقل)');
  w.table(['الصنف', 'الشكل الدوائي', 'الكمية', 'سعر البيع', 'الحالة'], [
    for (final r in xrows(inv['low_stock']))
      [
        _T(r['trade_name']),
        _T(medicineCategoryLabel(r['category'])),
        _Int(r['quantity']),
        _Money(r['sell_price']),
        _T(xi(r['quantity']) <= 0 ? 'نفد' : 'أوشك على النفاد'),
      ],
  ]);
  w.widths([34, 18, 12, 18, 22]);
}

void _purchases(_SheetWriter w, ReportExportData d) {
  final p = d.purchases;
  w.section('مشتريات الفترة');
  w.pair('إجمالي المشتريات', _Money(p['purchases_total']));
  w.pair('عدد فواتير الشراء', _Int(p['invoices_count']));
  w.pair('مرتجعات للمذاخر', _Money(p['returns_total']));
  w.pair('المدفوع للمذاخر', _Money(p['payments_total']));
  w.pair('مبالغ مستلمة من المذاخر', _Money(p['refunds_received']));
  w.blank();

  w.section('المشتريات حسب المذخر');
  w.table(['المذخر', 'عدد الفواتير', 'قيمة المشتريات', 'المرتجعات'], [
    for (final r in xrows(p['by_supplier'])) [_T(r['name']), _Int(r['invoices_count']), _Money(r['total']), _Money(r['returns'])],
  ]);
  w.blank();

  w.section('أرصدة المذاخر (الرصيد الحالي)');
  w.pair('إجمالي ديون المذاخر', _Money(p['total_debt']));
  w.pair('رصيدنا لدى المذاخر', _Money(p['total_credit']));
  w.blank();
  w.section('أعلى المذاخر ديناً');
  w.table(['المذخر', 'الدين'], [
    for (final r in xrows(p['top_debtors'])) [_T(r['name']), _Money(r['debt'])],
  ]);
  w.widths([34, 18, 20, 18]);
}

void _losses(_SheetWriter w, ReportExportData d) {
  final l = d.losses;
  w.section('المصاريف حسب النوع');
  final byType = xrows(l['expenses_by_type']);
  w.table(['النوع', 'عدد القيود', 'المبلغ'], [
    for (final r in byType) [_T(r['type']), _Int(r['count']), _Money(r['total'])],
    [_T('الإجمالي'), _Int(byType.fold<int>(0, (s, r) => s + xi(r['count']))), _Money(l['expenses_total'])],
  ], boldRows: {byType.length});
  w.blank();

  w.section('خسائر التوالف والمنتهي المسجّلة (بسعر الكلفة)');
  final byReason = xrows(l['damage_by_reason']);
  w.table(['السبب', 'عدد السجلات', 'الكمية', 'الكلفة'], [
    for (final r in byReason) [_T(damageReasonLabel(r['reason'])), _Int(r['count']), _Int(r['quantity']), _Money(r['total'])],
    [
      _T('الإجمالي'),
      _Int(byReason.fold<int>(0, (s, r) => s + xi(r['count']))),
      _Int(byReason.fold<int>(0, (s, r) => s + xi(r['quantity']))),
      _Money(l['damage_total']),
    ],
  ], boldRows: {byReason.length});
  w.pair('منها منتهي الصلاحية', _Money(l['expired_recorded']));
  w.pair('منتهي غير مُسجَّل كتالف (الوضع الحالي — لم يُخصم من الربح)', _Money(l['expired_not_disposed_value']));
  w.widths([44, 16, 14, 18]);
}

String damageReasonLabel(Object? reason) {
  final key = reason?.toString() ?? '';
  return damageReasons[key] ?? (key.isEmpty ? 'غير محدد' : key);
}

String _plain(Object? v) {
  final n = xn(v).round().toString();
  return n.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
}

// ---------------------------------------------------------------------------
// الخلايا والكتابة
// ---------------------------------------------------------------------------

/// قيمة خلية مع تنسيقها.
sealed class _Cell {
  const _Cell();
  CellValue get value;
  NumFormat get format;
}

class _T extends _Cell {
  _T(Object? text) : text = text?.toString() ?? '';
  final String text;
  @override
  CellValue get value => TextCellValue(text);
  @override
  NumFormat get format => NumFormat.standard_0;
}

const _moneyFormat = CustomNumericNumFormat(formatCode: '#,##0 "د.ع"');
const _intFormat = CustomNumericNumFormat(formatCode: '#,##0');
const _pctFormat = CustomNumericNumFormat(formatCode: '0.0%');
const _dateFormat = CustomDateTimeNumFormat(formatCode: 'yyyy-mm-dd');
const _dateTimeFormat = CustomDateTimeNumFormat(formatCode: 'yyyy-mm-dd hh:mm');

class _Money extends _Cell {
  _Money(Object? v) : amount = xn(v);
  final double amount;
  @override
  CellValue get value => DoubleCellValue(amount);
  @override
  NumFormat get format => _moneyFormat;
}

class _Int extends _Cell {
  _Int(Object? v) : number = xi(v);
  final int number;
  @override
  CellValue get value => IntCellValue(number);
  @override
  NumFormat get format => _intFormat;
}

class _Pct extends _Cell {
  _Pct(this.fraction);
  final double fraction;
  @override
  CellValue get value => DoubleCellValue(fraction);
  @override
  NumFormat get format => _pctFormat;
}

class _Date extends _Cell {
  _Date(this.date);
  final DateTime date;

  /// YYYY-MM-DD... (نص من المصدر)؛ غير الصالح يُكتب نصاً كما هو.
  static _Cell parse(Object? raw) {
    final text = raw?.toString() ?? '';
    final d = text.length >= 10 ? DateTime.tryParse(text.substring(0, 10)) : null;
    return d == null ? _T(text.isEmpty ? '-' : text) : _Date(d);
  }

  @override
  CellValue get value => DateCellValue(year: date.year, month: date.month, day: date.day);
  @override
  NumFormat get format => _dateFormat;
}

class _DateTime extends _Cell {
  _DateTime(this.date);
  final DateTime date;

  /// وقت الفاتورة كما خُزّن (محلي): YYYY-MM-DD[T ]HH:MM بلا تحويل منطقة زمنية،
  /// مثل shortDateTime في report_widgets.dart.
  static _Cell parse(Object? raw) {
    final text = raw?.toString() ?? '';
    final day = text.length >= 10 ? DateTime.tryParse(text.substring(0, 10)) : null;
    if (day == null) return _T(text.isEmpty ? '-' : text);
    final h = text.length >= 16 ? int.tryParse(text.substring(11, 13)) : null;
    final m = text.length >= 16 ? int.tryParse(text.substring(14, 16)) : null;
    return _DateTime(DateTime(day.year, day.month, day.day, h ?? 0, m ?? 0));
  }

  @override
  CellValue get value =>
      DateTimeCellValue(year: date.year, month: date.month, day: date.day, hour: date.hour, minute: date.minute);
  @override
  NumFormat get format => _dateTimeFormat;
}

class _SheetWriter {
  _SheetWriter(this.sheet);

  final Sheet sheet;
  int _row = 0;
  final Map<String, CellStyle> _styles = {};

  static final _headerBg = ExcelColor.fromHexString('FFD1F2EB');
  static final _sectionColor = ExcelColor.fromHexString('FF117A65');
  static final _noteColor = ExcelColor.fromHexString('FF9A3412');

  CellStyle _style(NumFormat format, {bool bold = false, bool header = false, ExcelColor? color, int? size}) {
    final key = '${format.formatCode}|$bold|$header|${color?.colorHex}|$size';
    return _styles[key] ??= CellStyle(
      numberFormat: format,
      bold: bold || header,
      fontSize: size,
      fontColorHex: color ?? ExcelColor.black,
      backgroundColorHex: header ? _headerBg : ExcelColor.none,
      horizontalAlign: HorizontalAlign.Right,
    );
  }

  void _put(int col, _Cell cell, {bool bold = false, bool header = false, ExcelColor? color, int? size}) {
    final data = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: _row));
    data.value = cell.value;
    data.cellStyle = _style(cell.format, bold: bold, header: header, color: color, size: size);
  }

  void title(String text) {
    _put(0, _T(text), bold: true, size: 16, color: _sectionColor);
    _row++;
  }

  void section(String text) {
    _put(0, _T(text), bold: true, size: 12, color: _sectionColor);
    _row++;
  }

  void note(String text) {
    _put(0, _T(text), bold: true, color: _noteColor);
    _row++;
  }

  void pair(String label, _Cell value) => row([_T(label), value], bold0: true);

  void row(List<_Cell> cells, {bool bold0 = false, bool bold = false}) {
    for (final (i, c) in cells.indexed) {
      _put(i, c, bold: bold || (bold0 && i == 0));
    }
    _row++;
  }

  void table(List<String> headers, List<List<_Cell>> rows, {Set<int> boldRows = const {}}) {
    for (final (i, h) in headers.indexed) {
      _put(i, _T(h), header: true);
    }
    _row++;
    if (rows.isEmpty) {
      _put(0, _T('لا توجد بيانات'), color: ExcelColor.grey);
      _row++;
      return;
    }
    for (final (i, r) in rows.indexed) {
      row(r, bold: boldRows.contains(i));
    }
  }

  void blank() => _row++;

  final List<double> columnWidths = [];
  void widths(List<double> values) => columnWidths
    ..clear()
    ..addAll(values);
}
