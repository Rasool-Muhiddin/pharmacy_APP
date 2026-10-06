import 'package:flutter/material.dart';

import '../../../models/medicine_categories.dart';
import '../report_charts.dart';
import '../report_widgets.dart';
import '../reports_scope.dart';

class OverviewTab extends StatefulWidget {
  const OverviewTab({super.key, required this.scope, required this.kpis});

  final ReportsScope scope;
  final Future<Map<String, dynamic>> kpis;

  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  ReportsScope get s => widget.scope;

  void _retry() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final bucket = s.period.bucket.name;
    final bucketLabel = {'day': 'يومياً', 'week': 'أسبوعياً', 'month': 'شهرياً'}[bucket];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResponsiveRow(
          flex: const [3, 2],
          breakpoint: 1000,
          children: [
            ReportCard(
              title: 'اتجاه المبيعات والربح',
              subtitle: 'صافي المبيعات والربح الإجمالي $bucketLabel',
              icon: Icons.bar_chart,
              child: SectionFuture(
                future: s.load('trend', () => s.repo.trend(s.period)),
                onRetry: _retry,
                skeletonHeight: 260,
                builder: (data) => TrendChart(
                  points: List<Map<String, dynamic>>.from(data['points'] as List),
                  bucket: data['bucket'] as String? ?? bucket,
                ),
              ),
            ),
            ReportCard(
              title: 'قائمة الدخل المبسطة',
              subtitle: 'للفترة المختارة',
              icon: Icons.receipt_outlined,
              child: SectionFuture(
                future: widget.kpis,
                onRetry: s.onDataChanged,
                skeletonHeight: 260,
                builder: (data) => IncomeStatement(
                  figures: data['current'] as Map<String, dynamic>,
                  expiredNotRecorded: jn((data['alerts'] as Map?)?['expired_value']),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ResponsiveRow(
          breakpoint: 1000,
          children: [
            ReportCard(
              title: 'المبيعات حسب الشكل الدوائي',
              icon: Icons.category_outlined,
              child: SectionFuture(
                future: s.load('categories', () => s.repo.categories(s.period)),
                onRetry: _retry,
                builder: (data) {
                  final rows = List<Map<String, dynamic>>.from(data['categories'] as List);
                  if (rows.isEmpty) return const EmptyState('لا توجد مبيعات في هذه الفترة.');
                  return ShareBars(entries: [
                    for (final r in rows)
                      (medicineCategoryLabel(r['category']), jn(r['net_sales']), '${ji(r['quantity'])} قطعة'),
                  ]);
                },
              ),
            ),
            ReportCard(
              title: 'أوقات الذروة',
              subtitle: 'عدد الفواتير حسب ساعة اليوم',
              icon: Icons.schedule,
              child: SectionFuture(
                future: s.load('hours', () => s.repo.hours(s.period)),
                onRetry: _retry,
                builder: (data) => HoursChart(hours: List<Map<String, dynamic>>.from(data['hours'] as List)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// إجمالي المبيعات − الخصومات = صافي المبيعات − كلفة البضاعة = الربح الإجمالي
/// − المصاريف − التوالف = صافي الربح. المنتهي غير المسجّل كتالف يُعرض للعلم
/// فقط ولا يُخصم (حتى لا تتغير الفترات المغلقة بعد تسجيله لاحقاً).
class IncomeStatement extends StatelessWidget {
  const IncomeStatement({super.key, required this.figures, required this.expiredNotRecorded});

  final Map<String, dynamic> figures;
  final double expiredNotRecorded;

  @override
  Widget build(BuildContext context) {
    double f(String k) => jn(figures[k]);
    final uncosted = f('uncosted_revenue');
    final costedSales = f('net_sales') - uncosted;
    final net = f('net_profit');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _line('إجمالي المبيعات', f('gross_sales')),
        _line('الخصومات', f('discounts'), sign: '−'),
        _line('صافي المبيعات', f('net_sales'), total: true),
        if (uncosted > 0) _line('مبيعات بلا كلفة مسجّلة (مستبعدة من الربح)', uncosted, sign: '−', muted: true),
        _line('كلفة البضاعة المباعة', f('cost_of_goods_sold'), sign: '−'),
        _line('الربح الإجمالي', f('gross_profit'), total: true,
            extra: 'هامش ${pct(costedSales > 0 ? f('gross_profit') / costedSales * 100 : 0)}'),
        _line('المصاريف', f('expenses'), sign: '−'),
        _line('خسائر التوالف والمنتهي المسجّلة', f('damage_cost'), sign: '−'),
        const SizedBox(height: 8),
        Container(
          key: const Key('net-profit-row'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: net < 0 ? RC.redBg : const Color(0xFFE8F8F5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text('= صافي الربح', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: RC.text)),
              ),
              Text(iqd(net),
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: net < 0 ? RC.red : RC.tealDark)),
            ],
          ),
        ),
        if (expiredNotRecorded > 0) ...[
          const SizedBox(height: 10),
          Row(
            key: const Key('expired-not-recorded-row'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 16, color: RC.orange),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'منتهي الصلاحية غير مُسجَّل كتالف: ${iqd(expiredNotRecorded)} (لم يُخصم من الربح)',
                  style: const TextStyle(fontSize: 12, color: RC.orange, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _line(String label, double value, {String sign = '', bool total = false, bool muted = false, String? extra}) {
    final style = TextStyle(
      fontSize: total ? 14 : 13,
      fontWeight: total ? FontWeight.bold : FontWeight.normal,
      color: muted ? RC.muted : RC.text,
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: total ? RC.border : const Color(0xFFF1F5F9))),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(total ? '=' : sign, style: style.copyWith(color: total ? RC.tealDark : RC.muted)),
          ),
          Expanded(child: Text(label, style: style)),
          if (extra != null) ...[Text(extra, style: const TextStyle(fontSize: 11.5, color: RC.muted)), const SizedBox(width: 10)],
          Text(iqd(value), style: style),
        ],
      ),
    );
  }
}
