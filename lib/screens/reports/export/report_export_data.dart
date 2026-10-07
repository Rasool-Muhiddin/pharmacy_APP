import '../../../models/report_period.dart';
import '../../../repository/reports_repository.dart';

/// رقم من JSON (num أو نص عشري من الخادم) — نفس jn/ji في report_widgets.dart
/// لكن بلا اعتماد على Flutter كي تعمل البُناة داخل compute().
double xn(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

int xi(Object? v) => xn(v).round();

List<Map<String, dynamic>> xrows(Object? v) =>
    [for (final r in (v as List?) ?? const []) Map<String, dynamic>.from(r as Map)];

/// كل ما يحتاجه التصدير (Excel وPDF) في لقطة واحدة من ReportsDataSource —
/// نفس بيانات تبويبات الشاشة أوفلاين وأونلاين، بلا واجهات خادم جديدة.
/// القوائم المجزّأة (الفواتير، الراكدة) تُجلب كل صفحاتها حتى [rowCap].
class ReportExportData {
  ReportExportData({
    required this.pharmacyName,
    required this.period,
    required this.generatedAt,
    required this.kpis,
    required this.itemsByQty,
    required this.itemsByProfit,
    required this.inventory,
    required this.purchases,
    required this.losses,
    required this.sellers,
    required this.invoices,
    required this.refunds,
    required this.stagnant,
  });

  static const int rowCap = 10000;
  static const int exportPageSize = 200;
  static const int expiryDays = 90;

  final String pharmacyName;
  final ReportPeriod period;
  final DateTime generatedAt;
  final Map<String, dynamic> kpis;
  final Map<String, dynamic> itemsByQty;
  final Map<String, dynamic> itemsByProfit;
  final Map<String, dynamic> inventory;
  final Map<String, dynamic> purchases;
  final Map<String, dynamic> losses;
  final List<Map<String, dynamic>> sellers;
  final PagedRows invoices;
  final PagedRows refunds;
  final PagedRows stagnant;

  Map<String, dynamic> get current => Map<String, dynamic>.from(kpis['current'] as Map? ?? const {});
  Map<String, dynamic> get previous => Map<String, dynamic>.from(kpis['previous'] as Map? ?? const {});
  Map<String, dynamic> get alerts => Map<String, dynamic>.from(kpis['alerts'] as Map? ?? const {});

  /// [onProgress] من 0 إلى 1 تقريباً (عدد الطلبات المنجزة).
  static Future<ReportExportData> collect(
    ReportsDataSource repo,
    ReportPeriod period, {
    required String pharmacyName,
    DateTime? now,
    void Function(double progress)? onProgress,
  }) async {
    var done = 0;
    const steps = 11;
    Future<T> step<T>(Future<T> future) async {
      final value = await future;
      onProgress?.call((++done / steps).clamp(0, 1).toDouble());
      return value;
    }

    // أونلاين كل قسم طلب HTTP مستقل؛ تُطلب بالتوازي.
    final results = await Future.wait<Object>([
      step(repo.kpis(period)),
      step(repo.items(period, sort: 'qty')),
      step(repo.items(period, sort: 'profit')),
      step(repo.inventory(days: expiryDays)),
      step(repo.purchases(period)),
      step(repo.losses(period)),
      step(repo.sellers(period)),
    ]);
    final invoices = await step(PagedRows.fetchAll(
        (page) => repo.invoices(period, page: page, pageSize: exportPageSize)));
    final refunds = await step(PagedRows.fetchAll(
        (page) => repo.invoices(period, page: page, pageSize: exportPageSize, refunded: true)));
    final stagnant = await step(PagedRows.fetchAll(
        (page) => repo.stagnant(period, page: page, pageSize: exportPageSize)));
    onProgress?.call(1);

    Map<String, dynamic> m(int i) => Map<String, dynamic>.from(results[i] as Map);
    return ReportExportData(
      pharmacyName: pharmacyName,
      period: period,
      generatedAt: now ?? DateTime.now(),
      kpis: m(0),
      itemsByQty: m(1),
      itemsByProfit: m(2),
      inventory: m(3),
      purchases: m(4),
      losses: m(5),
      sellers: xrows(m(6)['sellers']),
      invoices: invoices,
      refunds: refunds,
      stagnant: stagnant,
    );
  }
}

/// كل صفوف قسم مجزّأ (count/results) حتى [ReportExportData.rowCap].
class PagedRows {
  const PagedRows({required this.rows, required this.count, required this.first});

  final List<Map<String, dynamic>> rows;

  /// العدد الكلي كما يعيده المصدر (قد يتجاوز rows عند القص).
  final int count;

  /// استجابة الصفحة الأولى (total_amount / total_value ...).
  final Map<String, dynamic> first;

  bool get capped => count > rows.length;

  static Future<PagedRows> fetchAll(
    Future<Map<String, dynamic>> Function(int page) fetch, {
    int cap = ReportExportData.rowCap,
  }) async {
    final rows = <Map<String, dynamic>>[];
    Map<String, dynamic> first = const {};
    var count = 0;
    for (var page = 1;; page++) {
      final data = await fetch(page);
      if (page == 1) first = data;
      count = xi(data['count']);
      final results = xrows(data['results']);
      rows.addAll(results);
      if (results.isEmpty || rows.length >= count || rows.length >= cap) break;
    }
    if (rows.length > cap) rows.removeRange(cap, rows.length);
    return PagedRows(rows: rows, count: count < rows.length ? rows.length : count, first: first);
  }
}

/// مؤشر من الأربعة مع قيمة الفترة السابقة.
class KpiLine {
  const KpiLine(this.label, this.current, this.previous, {this.isCount = false});

  final String label;
  final double current;
  final double previous;
  final bool isCount;

  /// نسبة التغيير ككسر (0.12 = 12%)، null عند غياب أساس للمقارنة.
  double? get change => previous == 0 ? null : (current - previous) / previous.abs();
}

/// سطر في قائمة الدخل المبسطة. [value] بإشارته (الخصميات سالبة)، و[percent]
/// لسطر الهامش (كسر).
class IncomeLine {
  const IncomeLine(this.label, this.value, {this.total = false, this.muted = false, this.percent = false});

  final String label;
  final double value;
  final bool total;
  final bool muted;
  final bool percent;
}

extension ReportExportFigures on ReportExportData {
  List<KpiLine> get kpiLines {
    final c = current, p = previous;
    return [
      KpiLine('صافي المبيعات', xn(c['net_sales']), xn(p['net_sales'])),
      KpiLine('الربح الإجمالي', xn(c['gross_profit']), xn(p['gross_profit'])),
      KpiLine('صافي الربح', xn(c['net_profit']), xn(p['net_profit'])),
      KpiLine('عدد الفواتير', xn(c['invoices_count']), xn(p['invoices_count']), isCount: true),
    ];
  }

  /// نفس أسطر IncomeStatement في overview_tab.dart.
  List<IncomeLine> get incomeLines {
    double f(String k) => xn(current[k]);
    final uncosted = f('uncosted_revenue');
    final costedSales = f('net_sales') - uncosted;
    return [
      IncomeLine('إجمالي المبيعات', f('gross_sales')),
      IncomeLine('الخصومات', -f('discounts')),
      IncomeLine('صافي المبيعات', f('net_sales'), total: true),
      if (uncosted > 0) IncomeLine('مبيعات بلا كلفة مسجّلة (مستبعدة من الربح)', -uncosted, muted: true),
      IncomeLine('كلفة البضاعة المباعة', -f('cost_of_goods_sold')),
      IncomeLine('الربح الإجمالي', f('gross_profit'), total: true),
      IncomeLine('هامش الربح الإجمالي', costedSales > 0 ? f('gross_profit') / costedSales : 0, muted: true, percent: true),
      IncomeLine('المصاريف', -f('expenses')),
      IncomeLine('خسائر التوالف والمنتهي المسجّلة', -f('damage_cost')),
      IncomeLine('صافي الربح', f('net_profit'), total: true),
    ];
  }

  /// المنتهي غير المسجّل كتالف — للعلم فقط، لا يُخصم من الربح.
  double get expiredNotDisposedValue => xn(alerts['expired_value']);

  String fileName(String extension) => reportFileName(pharmacyName, period, extension);
}

/// `تقرير_<الصيدلية>_<من>_<إلى>.<ext>` بلا محارف ممنوعة في أسماء الملفات.
String reportFileName(String pharmacyName, ReportPeriod period, String extension) {
  String clean(String s) => s.trim().replaceAll(RegExp(r'[\\/:*?"<>|]+'), '').replaceAll(RegExp(r'\s+'), '_');
  final name = clean(pharmacyName).isEmpty ? 'الصيدلية' : clean(pharmacyName);
  return 'تقرير_${name}_${period.startKey}_${period.endKey}.$extension';
}
