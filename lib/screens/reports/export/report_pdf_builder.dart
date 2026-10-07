import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../utils/formatters.dart';
import 'report_excel_builder.dart' show damageReasonLabel;
import 'report_export_data.dart';

/// الخط العربي المضمَّن (Tajawal — OFL، assets/fonts/OFL.txt). يغطي العربية
/// بأشكالها (Presentation Forms) واللاتينية فتظهر أسماء الأصناف الإنجليزية.
const String reportPdfFontRegular = 'assets/fonts/Tajawal-Regular.ttf';
const String reportPdfFontBold = 'assets/fonts/Tajawal-Bold.ttf';

/// مدخلات compute(): البيانات + بايتات الخط (rootBundle لا يعمل داخل isolate).
class ReportPdfInput {
  const ReportPdfInput(this.data, this.regularFont, this.boldFont);

  final ReportExportData data;
  final Uint8List regularFont;
  final Uint8List boldFont;
}

const int _topLimit = 10;

const _teal = PdfColor.fromInt(0xFF117A65);
const _muted = PdfColor.fromInt(0xFF64748B);
const _red = PdfColor.fromInt(0xFFDC2626);
const _orange = PdfColor.fromInt(0xFFC2410C);
const _border = PdfColor.fromInt(0xFFE2E8F0);
const _headerBg = PdfColor.fromInt(0xFFE8F8F5);
const _totalBg = PdfColor.fromInt(0xFFF1F5F9);

/// ملخص مختصر A4 عمودي بلا رسوم بيانية.
Future<Uint8List> buildReportPdf(ReportPdfInput input) {
  final d = input.data;
  final doc = pw.Document(title: d.fileName('pdf'), author: d.pharmacyName, creator: 'Tera Pharmacy');
  doc.addPage(
    pw.MultiPage(
      pageTheme: reportPdfPageTheme(input.regularFont, input.boldFont),
      footer: (context) => reportPdfFooter(context, d.pharmacyName),
      build: (context) => [
        _header(d),
        _section('المؤشرات الرئيسية (مقارنة بالفترة السابقة)'),
        _kpis(d),
        _section('قائمة الدخل المبسطة'),
        ..._income(d),
        _section('التنبيهات الحالية'),
        _alerts(d),
        _section('أعلى $_topLimit أصناف ربحاً'),
        _topItems(d),
        _section('أعلى $_topLimit أصناف راكدة (حسب القيمة المجمّدة)'),
        _stagnant(d),
        _section('ملخص المصاريف والخسائر'),
        ..._losses(d),
        _section('ملخص المشتريات والمذاخر'),
        ..._purchases(d),
      ],
    ),
  );
  return doc.save();
}

// ---------------------------------------------------------------------------
// عناصر مشتركة مع ملفات PDF أخرى (كشف حساب المذخر)
// ---------------------------------------------------------------------------

/// صفحة A4 عمودية من اليمين لليسار بالخط العربي المضمَّن.
pw.PageTheme reportPdfPageTheme(Uint8List regularFont, Uint8List boldFont) => pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(
        base: pw.Font.ttf(regularFont.buffer.asByteData()),
        bold: pw.Font.ttf(boldFont.buffer.asByteData()),
      ),
      margin: const pw.EdgeInsets.fromLTRB(32, 32, 32, 28),
    );

pw.Widget reportPdfFooter(pw.Context context, String pharmacyName) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 10),
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _border))),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(pharmacyName, style: const pw.TextStyle(fontSize: 8, color: _muted)),
          pw.Text('صفحة ${context.pageNumber} من ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: _muted)),
        ],
      ),
    );

/// عنوان قسم بلون التطبيق.
pw.Widget reportPdfSection(String title) => _section(title);

/// جدول من اليمين لليسار (انظر [_table]).
pw.Widget reportPdfTable(
  List<String> headers,
  List<List<String>> rows, {
  required List<int> flex,
  Set<int> boldRows = const {},
  Set<int> redRows = const {},
  String emptyText = 'لا توجد بيانات في هذه الفترة.',
}) =>
    _table(headers, rows, flex: flex, boldRows: boldRows, redRows: redRows, emptyText: emptyText);

// ---------------------------------------------------------------------------
// الأقسام
// ---------------------------------------------------------------------------

String _money(Object? v) => AppFormatter.iqdWithCurrency(xn(v));
String _int(Object? v) => AppFormatter.iqd(xi(v));
String _pct(double fraction) {
  final v = fraction * 100;
  return '${v.toStringAsFixed(v.abs() >= 10 ? 0 : 1)}%';
}

String _day(DateTime d) => DateFormat('yyyy/MM/dd').format(d);

pw.Widget _header(ReportExportData d) {
  final p = d.period;
  final range = p.days == 1 ? _day(p.start) : 'من ${_day(p.start)} إلى ${_day(p.end)}';
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(color: _headerBg, borderRadius: pw.BorderRadius.circular(6)),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('تقرير الصيدلية — ${d.pharmacyName}',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: _teal)),
        pw.SizedBox(height: 4),
        pw.Text('الفترة: $range (${p.days} يوم)', style: const pw.TextStyle(fontSize: 10)),
        pw.Text('تاريخ الإنشاء: ${DateFormat('yyyy/MM/dd HH:mm').format(d.generatedAt)}',
            style: const pw.TextStyle(fontSize: 9, color: _muted)),
      ],
    ),
  );
}

pw.Widget _section(String title) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
      child: pw.Text(title, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _teal)),
    );

pw.Widget _kpis(ReportExportData d) {
  return _table(
    ['المؤشر', 'الفترة الحالية', 'الفترة السابقة', 'التغيير'],
    [
      for (final k in d.kpiLines)
        [
          k.label,
          k.isCount ? _int(k.current) : _money(k.current),
          k.isCount ? _int(k.previous) : _money(k.previous),
          k.change == null ? '-' : '${k.change! > 0 ? '+' : ''}${_pct(k.change!)}',
        ],
    ],
    flex: const [3, 3, 3, 2],
  );
}

List<pw.Widget> _income(ReportExportData d) {
  final lines = d.incomeLines;
  return [
    _table(
      ['البند', 'المبلغ'],
      [for (final l in lines) [l.label, l.percent ? _pct(l.value) : _money(l.value)]],
      flex: const [3, 2],
      boldRows: {for (final (i, l) in lines.indexed) if (l.total) i},
    ),
    if (d.expiredNotDisposedValue > 0)
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 4),
        child: pw.Text(
          'للعلم: منتهي الصلاحية غير مُسجَّل كتالف بقيمة ${_money(d.expiredNotDisposedValue)} (لم يُخصم من الربح).',
          style: const pw.TextStyle(fontSize: 9, color: _orange),
        ),
      ),
  ];
}

pw.Widget _alerts(ReportExportData d) {
  final a = d.alerts;
  return _table(
    ['التنبيه', 'العدد', 'القيمة'],
    [
      ['أصناف تُباع بأقل من كلفتها', _int(a['below_cost_count']), '-'],
      ['تنتهي صلاحيتها خلال ${xi(a['expiring_days'] ?? 30)} يوماً', _int(a['expiring_count']), _money(a['expiring_value'])],
      ['منتهية غير مُسجَّلة كتالف', _int(a['expired_count']), _money(a['expired_value'])],
      ['نفدت أو أوشكت على النفاد', _int(a['low_stock_count']), '-'],
      ['منها نفدت بالكامل', _int(a['out_of_stock_count']), '-'],
    ],
    flex: const [4, 1, 2],
  );
}

pw.Widget _topItems(ReportExportData d) {
  final rows = xrows(d.itemsByProfit['items']).take(_topLimit).toList();
  return _table(
    ['#', 'الصنف', 'الكمية', 'الإيراد', 'الربح', 'الهامش'],
    [
      for (final (i, r) in rows.indexed)
        () {
          final costed = xn(r['costed_revenue']);
          return [
            '${i + 1}',
            '${r['trade_name'] ?? '-'}',
            _int(r['quantity']),
            _money(r['revenue']),
            costed > 0 ? _money(r['profit']) : '-',
            costed > 0 ? _pct(xn(r['profit']) / costed) : '-',
          ];
        }(),
    ],
    flex: const [1, 5, 2, 3, 3, 2],
    redRows: {for (final (i, r) in rows.indexed) if (xn(r['profit']) < 0) i},
  );
}

pw.Widget _stagnant(ReportExportData d) {
  final s = d.stagnant;
  final rows = [...s.rows]..sort((a, b) => xn(b['stock_value']).compareTo(xn(a['stock_value'])));
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text('${_int(s.count)} صنفاً بلا مبيعات في الفترة، بقيمة مجمّدة ${_money(s.first['total_value'])}',
          style: const pw.TextStyle(fontSize: 9, color: _muted)),
      pw.SizedBox(height: 4),
      _table(
        ['الصنف', 'الكمية', 'القيمة المجمّدة', 'آخر بيع'],
        [
          for (final r in rows.take(_topLimit))
            [
              '${r['trade_name'] ?? '-'}',
              _int(r['quantity']),
              _money(r['stock_value']),
              r['last_sale'] == null ? 'لم يُبع' : '${r['last_sale']}'.substring(0, 10),
            ],
        ],
        flex: const [5, 2, 3, 2],
      ),
    ],
  );
}

List<pw.Widget> _losses(ReportExportData d) {
  final l = d.losses;
  return [
    _table(
      ['البند', 'المبلغ'],
      [
        ['إجمالي المصاريف', _money(l['expenses_total'])],
        ['إجمالي التوالف المسجّلة (بسعر الكلفة)', _money(l['damage_total'])],
        ['منها منتهي الصلاحية', _money(l['expired_recorded'])],
        ['منتهي غير مُسجَّل كتالف (لم يُخصم)', _money(l['expired_not_disposed_value'])],
      ],
      flex: const [3, 2],
    ),
    pw.SizedBox(height: 8),
    _table(
      ['نوع المصروف', 'عدد القيود', 'المبلغ'],
      [for (final r in xrows(l['expenses_by_type'])) ['${r['type']}', _int(r['count']), _money(r['total'])]],
      flex: const [3, 1, 2],
    ),
    pw.SizedBox(height: 8),
    _table(
      ['سبب التلف', 'الكمية', 'الكلفة'],
      [
        for (final r in xrows(l['damage_by_reason']))
          [damageReasonLabel(r['reason']), _int(r['quantity']), _money(r['total'])],
      ],
      flex: const [3, 1, 2],
    ),
  ];
}

List<pw.Widget> _purchases(ReportExportData d) {
  final p = d.purchases;
  return [
    _table(
      ['البند', 'المبلغ'],
      [
        ['إجمالي المشتريات (${_int(p['invoices_count'])} فاتورة)', _money(p['purchases_total'])],
        ['مرتجعات للمذاخر', _money(p['returns_total'])],
        ['المدفوع للمذاخر', _money(p['payments_total'])],
        ['مبالغ مستلمة من المذاخر', _money(p['refunds_received'])],
        ['إجمالي ديون المذاخر (الرصيد الحالي)', _money(p['total_debt'])],
        ['رصيدنا لدى المذاخر (الرصيد الحالي)', _money(p['total_credit'])],
      ],
      flex: const [3, 2],
    ),
    pw.SizedBox(height: 8),
    _table(
      ['المذخر', 'عدد الفواتير', 'قيمة المشتريات', 'المرتجعات'],
      [
        for (final r in xrows(p['by_supplier']))
          ['${r['name']}', _int(r['invoices_count']), _money(r['total']), _money(r['returns'])],
      ],
      flex: const [4, 2, 3, 3],
    ),
    pw.SizedBox(height: 8),
    _table(
      ['أعلى المذاخر ديناً', 'الدين'],
      [for (final r in xrows(p['top_debtors'])) ['${r['name']}', _money(r['debt'])]],
      flex: const [3, 2],
    ),
  ];
}

// ---------------------------------------------------------------------------
// جدول من اليمين لليسار
// ---------------------------------------------------------------------------

/// [headers]/[rows] بالترتيب المنطقي (العمود الأول يمينَ الجدول). جدول pdf
/// لا يعكس الأعمدة في RTL فنعكسها هنا. الترويسة تتكرر عند انقسام الجدول على
/// أكثر من صفحة.
pw.Widget _table(
  List<String> headers,
  List<List<String>> rows, {
  required List<int> flex,
  Set<int> boldRows = const {},
  Set<int> redRows = const {},
  String emptyText = 'لا توجد بيانات في هذه الفترة.',
}) {
  if (rows.isEmpty) {
    return pw.Text(emptyText, style: const pw.TextStyle(fontSize: 9, color: _muted));
  }
  final n = headers.length;
  List<T> mirror<T>(List<T> cells) => cells.reversed.toList();
  return pw.TableHelper.fromTextArray(
    headers: mirror(headers),
    data: [for (final r in rows) mirror(r)],
    headerCount: 1,
    columnWidths: {for (var i = 0; i < n; i++) i: pw.FlexColumnWidth(flex[n - 1 - i].toDouble())},
    cellAlignment: pw.Alignment.centerRight,
    headerAlignment: pw.Alignment.centerRight,
    headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _teal),
    cellStyle: const pw.TextStyle(fontSize: 9),
    headerDecoration: const pw.BoxDecoration(color: _headerBg),
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3.5),
    headerPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
    border: const pw.TableBorder(
      horizontalInside: pw.BorderSide(color: _border, width: 0.5),
      bottom: pw.BorderSide(color: _border, width: 0.5),
    ),
    cellDecoration: (index, data, rowNum) =>
        boldRows.contains(rowNum - 1) ? const pw.BoxDecoration(color: _totalBg) : const pw.BoxDecoration(),
    textStyleBuilder: (index, data, rowNum) {
      if (rowNum == 0) return null;
      final row = rowNum - 1;
      return pw.TextStyle(
        fontSize: 9,
        fontWeight: boldRows.contains(row) ? pw.FontWeight.bold : pw.FontWeight.normal,
        color: redRows.contains(row) ? _red : null,
      );
    },
    tableDirection: pw.TextDirection.rtl,
    headerDirection: pw.TextDirection.rtl,
  );
}
