import 'package:flutter/material.dart';

import '../../../widgets/medicine_dialogs.dart';
import '../report_widgets.dart';
import '../reports_scope.dart';

class LossesTab extends StatefulWidget {
  const LossesTab({super.key, required this.scope});

  final ReportsScope scope;

  @override
  State<LossesTab> createState() => _LossesTabState();
}

class _LossesTabState extends State<LossesTab> {
  ReportsScope get s => widget.scope;

  void _retry() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final data = s.load('losses', () => s.repo.losses(s.period));
    return ResponsiveRow(
      breakpoint: 1000,
      children: [
        ReportCard(
          title: 'المصاريف حسب النوع',
          icon: Icons.account_balance_wallet_outlined,
          child: SectionFuture(
            future: data,
            onRetry: _retry,
            builder: (d) {
              final rows = List<Map<String, dynamic>>.from(d['expenses_by_type'] as List);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatTile(label: 'إجمالي المصاريف', value: iqd(d['expenses_total']), color: RC.red),
                  const SizedBox(height: 14),
                  if (rows.isEmpty)
                    const EmptyState('لا توجد مصاريف في هذه الفترة.')
                  else
                    ShareBars(color: RC.red, entries: [
                      for (final r in rows) ('${r['type']}', jn(r['total']), '${ji(r['count'])} قيد'),
                    ]),
                ],
              );
            },
          ),
        ),
        ReportCard(
          title: 'خسائر التوالف والمنتهي',
          subtitle: 'المسجّلة كتالف في الفترة، بسعر الكلفة (بلا تصحيح الإدخال)',
          icon: Icons.delete_forever_outlined,
          accent: RC.red,
          child: SectionFuture(
            future: data,
            onRetry: _retry,
            builder: (d) {
              final rows = List<Map<String, dynamic>>.from(d['damage_by_reason'] as List);
              final notDisposed = jn(d['expired_not_disposed_value']);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatGrid(maxColumns: 2, tiles: [
                    StatTile(label: 'إجمالي التوالف المسجّلة', value: iqd(d['damage_total']), color: RC.red,
                        hint: 'مخصومة من صافي الربح'),
                    StatTile(label: 'منها منتهي الصلاحية', value: iqd(d['expired_recorded']), color: RC.orange),
                  ]),
                  const SizedBox(height: 14),
                  if (rows.isEmpty)
                    const EmptyState('لا توجد توالف مسجّلة في هذه الفترة.', icon: Icons.check_circle_outline)
                  else
                    ReportTable(
                      columns: const [
                        RCol('السبب', width: 160),
                        RCol('عدد السجلات', width: 100),
                        RCol('الكمية', width: 80),
                        RCol('الكلفة', width: 120),
                      ],
                      rows: [
                        for (final r in rows)
                          [
                            cellText(damageReasons[r['reason']] ?? ((r['reason'] as String).isEmpty ? 'غير محدد' : '${r['reason']}'),
                                bold: true),
                            cellText('${ji(r['count'])}'),
                            cellText('${ji(r['quantity'])}'),
                            cellText(iqd(r['total']), bold: true, color: RC.red),
                          ],
                      ],
                    ),
                  if (notDisposed > 0) ...[
                    const SizedBox(height: 14),
                    Container(
                      key: const Key('expired-not-disposed'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: RC.orangeBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, color: RC.orange, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'منتهي الصلاحية غير مُسجَّل كتالف (الوضع الحالي): ${iqd(notDisposed)} — لم يُخصم من الربح.',
                              style: const TextStyle(color: RC.orange, fontSize: 12.5, fontWeight: FontWeight.bold),
                            ),
                          ),
                          TextButton(
                            onPressed: () => s.openTab(3),
                            child: const Text('عرض في المخزون', style: TextStyle(color: RC.orange)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
