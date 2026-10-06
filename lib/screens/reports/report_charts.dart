import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'report_widgets.dart';

String _compact(double v) {
  final a = v.abs();
  if (a >= 1000000) return '${(v / 1000000).toStringAsFixed(a >= 10000000 ? 0 : 1)}م';
  if (a >= 1000) return '${(v / 1000).toStringAsFixed(a >= 10000 ? 0 : 1)}أ';
  return v.toStringAsFixed(0);
}

double _niceMax(double max) {
  if (max <= 0) return 1000;
  final step = [1, 2, 2.5, 5, 10];
  var magnitude = 1.0;
  while (magnitude * 10 <= max) {
    magnitude *= 10;
  }
  for (final s in step) {
    if (s * magnitude >= max) return s * magnitude;
  }
  return 10 * magnitude;
}

/// صافي المبيعات لكل عمود (يوم/أسبوع/شهر)، والجزء الأغمق من العمود = الربح الإجمالي.
/// الزمن يسير من اليسار لليمين كالمعتاد في الرسوم، ومحور القيم على اليمين.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.points, required this.bucket});

  final List<Map<String, dynamic>> points;
  final String bucket;

  String _label(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return key;
    final m = int.parse(parts[1]), d = int.parse(parts[2]);
    return bucket == 'month' ? '$m/${parts[0].substring(2)}' : '$d/$m';
  }

  @override
  Widget build(BuildContext context) {
    if (points.every((p) => jn(p['net_sales']) == 0 && jn(p['gross_profit']) == 0)) {
      return const SizedBox(height: 220, child: EmptyState('لا توجد مبيعات في هذه الفترة.', icon: Icons.bar_chart));
    }
    final maxY = _niceMax(points.fold<double>(0, (m, p) => jn(p['net_sales']) > m ? jn(p['net_sales']) : m));
    final labelEvery = (points.length / 10).ceil().clamp(1, 1000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Wrap(
          spacing: 16,
          children: [
            _Legend(color: RC.tealLight, label: 'صافي المبيعات'),
            _Legend(color: RC.tealDark, label: 'منه الربح الإجمالي'),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 240,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: LayoutBuilder(builder: (context, c) {
              final barWidth = ((c.maxWidth - 60) / points.length * 0.6).clamp(3.0, 28.0);
              return BarChart(
                BarChartData(
                  maxY: maxY,
                  minY: 0,
                  alignment: BarChartAlignment.spaceAround,
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    horizontalInterval: maxY / 4,
                    getDrawingHorizontalLine: (_) => const FlLine(color: Color(0xFFEDF2F7), strokeWidth: 1),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(),
                    topTitles: const AxisTitles(),
                    rightTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        interval: maxY / 4,
                        getTitlesWidget: (value, meta) => SideTitleWidget(
                          meta: meta,
                          child: Text(_compact(value), style: const TextStyle(fontSize: 10, color: RC.muted)),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 24,
                        getTitlesWidget: (value, meta) {
                          final i = value.toInt();
                          if (i < 0 || i >= points.length || i % labelEvery != 0) return const SizedBox.shrink();
                          return SideTitleWidget(
                            meta: meta,
                            child: Text(_label(points[i]['key'] as String),
                                style: const TextStyle(fontSize: 10, color: RC.muted)),
                          );
                        },
                      ),
                    ),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => const Color(0xFF1E293B),
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final p = points[group.x];
                        return BarTooltipItem(
                          '${p['key']}\nصافي المبيعات: ${iqd(p['net_sales'])}\nالربح الإجمالي: ${iqd(p['gross_profit'])}',
                          const TextStyle(color: Colors.white, fontSize: 11.5, height: 1.5),
                          textDirection: TextDirection.rtl,
                        );
                      },
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < points.length; i++)
                      _group(i, jn(points[i]['net_sales']), jn(points[i]['gross_profit']), barWidth),
                  ],
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  BarChartGroupData _group(int x, double net, double gross, double width) {
    final total = net < 0 ? 0.0 : net;
    final profit = gross.clamp(0.0, total);
    return BarChartGroupData(x: x, barRods: [
      BarChartRodData(
        toY: total,
        width: width,
        color: RC.tealLight,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
        rodStackItems: [
          BarChartRodStackItem(0, profit, RC.tealDark),
          BarChartRodStackItem(profit, total, RC.tealLight),
        ],
      ),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12, color: RC.muted)),
    ]);
  }
}

/// عدد الفواتير لكل ساعة من اليوم (أوقات الذروة).
class HoursChart extends StatelessWidget {
  const HoursChart({super.key, required this.hours});

  final List<Map<String, dynamic>> hours;

  @override
  Widget build(BuildContext context) {
    final maxCount = hours.fold<int>(0, (m, h) => ji(h['invoices_count']) > m ? ji(h['invoices_count']) : m);
    if (maxCount == 0) {
      return const SizedBox(height: 180, child: EmptyState('لا توجد فواتير في هذه الفترة.', icon: Icons.schedule));
    }
    final peak = hours.reduce((a, b) => ji(b['invoices_count']) > ji(a['invoices_count']) ? b : a);
    final maxY = (maxCount * 1.2).ceilToDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ساعة الذروة: ${peak['hour']}:00 (${peak['invoices_count']} فاتورة)',
            style: const TextStyle(fontSize: 12, color: RC.muted)),
        const SizedBox(height: 10),
        SizedBox(
          height: 170,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: BarChart(
              BarChartData(
                maxY: maxY,
                minY: 0,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: const AxisTitles(),
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      getTitlesWidget: (value, meta) => value.toInt() % 3 == 0
                          ? SideTitleWidget(
                              meta: meta,
                              child: Text('${value.toInt()}', style: const TextStyle(fontSize: 10, color: RC.muted)),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => const Color(0xFF1E293B),
                    fitInsideHorizontally: true,
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      final h = hours[group.x];
                      return BarTooltipItem(
                        '${h['hour']}:00\n${h['invoices_count']} فاتورة\n${iqd(h['net_sales'])}',
                        const TextStyle(color: Colors.white, fontSize: 11.5, height: 1.5),
                        textDirection: TextDirection.rtl,
                      );
                    },
                  ),
                ),
                barGroups: [
                  for (final h in hours)
                    BarChartGroupData(x: ji(h['hour']), barRods: [
                      BarChartRodData(
                        toY: jn(h['invoices_count']),
                        width: 8,
                        color: h == peak ? RC.tealDark : RC.teal,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                      ),
                    ]),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
