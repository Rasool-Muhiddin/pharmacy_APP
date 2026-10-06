import 'package:flutter/material.dart';

import '../../../models/medicine_categories.dart';
import '../../../widgets/medicine_dialogs.dart';
import '../report_widgets.dart';
import '../reports_scope.dart';

class ItemsTab extends StatefulWidget {
  const ItemsTab({super.key, required this.scope});

  final ReportsScope scope;

  @override
  State<ItemsTab> createState() => _ItemsTabState();
}

class _ItemsTabState extends State<ItemsTab> {
  ReportsScope get s => widget.scope;

  String _sort = 'qty';
  int _stagnantPage = 1;

  void _retry() => setState(() {});

  Future<void> _editPrice(Map<String, dynamic> row) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final med = await s.repo.medicine(row['medicine_id'] as int);
      if (!mounted) return;
      if (med == null) {
        messenger.showSnackBar(const SnackBar(content: Text('الصنف لم يعد موجوداً في المخزون.')));
        return;
      }
      final saved = await showMedicineEditDialog(context, med: med, pharmacyId: s.pharmacyId, isOnlineMode: s.isOnlineMode);
      if (!saved || !mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('تم حفظ التعديلات بنجاح'), backgroundColor: Colors.green));
      s.onDataChanged();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyWriteErrorMessage(e)), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = s.load('items:$_sort', () => s.repo.items(s.period, sort: _sort));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportCard(
          title: 'أصناف تُباع بأقل من كلفتها',
          subtitle: 'سعر البيع الحالي أقل من الكلفة (متوسط الكلفة أو آخر سعر شراء)',
          icon: Icons.warning_amber_rounded,
          accent: RC.red,
          trailing: currentStateTag,
          child: SectionFuture(
            future: items,
            onRetry: _retry,
            builder: (data) {
              final rows = List<Map<String, dynamic>>.from(data['below_cost'] as List);
              if (rows.isEmpty) {
                return const EmptyState('لا توجد أصناف تُباع بأقل من كلفتها.', icon: Icons.check_circle_outline);
              }
              return ReportTable(
                columns: [
                  const RCol('الصنف', width: 180),
                  const RCol('الكلفة', width: 110),
                  const RCol('سعر البيع', width: 110),
                  const RCol('الخسارة للقطعة', width: 120),
                  const RCol('الكمية المتوفرة', width: 110),
                  if (s.isOwner) const RCol('', width: 130),
                ],
                rowColors: [for (final _ in rows) const Color(0xFFFFF5F5)],
                rows: [
                  for (final r in rows)
                    [
                      cellText('${r['trade_name']}', bold: true, color: RC.red),
                      cellText(iqd(r['cost'])),
                      cellText(iqd(r['sell_price'])),
                      cellText('− ${iqd(r['loss_per_unit'])}', bold: true, color: RC.red),
                      cellText('${ji(r['quantity'])}'),
                      if (s.isOwner)
                        ElevatedButton.icon(
                          key: Key('edit-price-${r['medicine_id']}'),
                          style: tealButton(),
                          onPressed: () => _editPrice(r),
                          icon: const Icon(Icons.edit, size: 15),
                          label: const Text('تعديل السعر'),
                        ),
                    ],
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        ReportCard(
          title: 'الأكثر مبيعاً',
          subtitle: 'أعلى 20 صنفاً في الفترة',
          icon: Icons.emoji_events_outlined,
          trailing: SegmentedButton<String>(
            key: const Key('items-sort'),
            segments: const [
              ButtonSegment(value: 'qty', label: Text('بالكمية')),
              ButtonSegment(value: 'revenue', label: Text('بالإيراد')),
              ButtonSegment(value: 'profit', label: Text('بالربح')),
            ],
            selected: {_sort},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(selectedBackgroundColor: RC.tealDark, selectedForegroundColor: Colors.white),
            onSelectionChanged: (v) => setState(() => _sort = v.first),
          ),
          child: SectionFuture(
            future: items,
            onRetry: _retry,
            builder: (data) {
              final rows = List<Map<String, dynamic>>.from(data['items'] as List);
              if (rows.isEmpty) return const EmptyState('لا توجد مبيعات في هذه الفترة.');
              return ReportTable(
                columns: const [
                  RCol('#', width: 44),
                  RCol('الصنف', width: 180),
                  RCol('الكمية', width: 80),
                  RCol('الإيراد', width: 110),
                  RCol('الكلفة', width: 110),
                  RCol('الربح', width: 110),
                  RCol('الهامش', width: 80),
                ],
                rowColors: [for (final r in rows) jn(r['profit']) < 0 ? const Color(0xFFFFF5F5) : null],
                rows: [
                  for (final (i, r) in rows.indexed)
                    () {
                      final profit = jn(r['profit']);
                      final costed = jn(r['costed_revenue']);
                      final uncosted = ji(r['uncosted_quantity']);
                      return [
                        cellText('${i + 1}', color: RC.muted),
                        cellText('${r['trade_name'] ?? '-'}', bold: true),
                        cellText('${ji(r['quantity'])}'),
                        cellText(iqd(r['revenue'])),
                        cellText(costed > 0 ? iqd(r['cost']) : 'غير معروفة', color: costed > 0 ? RC.text : RC.muted),
                        cellText(costed > 0 ? iqd(profit) : '-', bold: true, color: profit < 0 ? RC.red : RC.green),
                        cellText(
                          costed > 0 ? '${pct(profit / costed * 100)}${uncosted > 0 ? '*' : ''}' : '-',
                          color: profit < 0 ? RC.red : RC.text,
                        ),
                      ];
                    }(),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        ReportCard(
          title: 'الأصناف الراكدة',
          subtitle: 'في المخزون ولم يُبع منها شيء خلال الفترة، الأعلى قيمة مجمّدة أولاً',
          icon: Icons.hourglass_bottom,
          accent: RC.orange,
          child: SectionFuture(
            future: s.load('stagnant:$_stagnantPage', () => s.repo.stagnant(s.period, page: _stagnantPage)),
            onRetry: _retry,
            builder: (data) {
              final rows = List<Map<String, dynamic>>.from(data['results'] as List);
              if (rows.isEmpty) return const EmptyState('كل الأصناف المتوفرة بيع منها شيء في هذه الفترة.');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${ji(data['count'])} صنفاً بقيمة مجمّدة ${iqd(data['total_value'])} (بالكلفة)',
                      style: const TextStyle(fontSize: 12.5, color: RC.orange, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ReportTable(
                    columns: const [
                      RCol('الصنف', width: 180),
                      RCol('الشكل الدوائي', width: 150),
                      RCol('الكمية', width: 80),
                      RCol('قيمة المخزون', width: 120),
                      RCol('آخر بيع', width: 120),
                    ],
                    rows: [
                      for (final r in rows)
                        [
                          cellText('${r['trade_name']}', bold: true),
                          cellText(medicineCategoryLabel(r['category']), color: RC.muted),
                          cellText('${ji(r['quantity'])}'),
                          cellText(iqd(r['stock_value']), bold: true),
                          cellText(r['last_sale'] == null ? 'لم يُبع أبداً' : '${r['last_sale']}',
                              color: r['last_sale'] == null ? RC.red : RC.muted),
                        ],
                    ],
                  ),
                  Pager(
                    page: ji(data['page']),
                    pageSize: ji(data['page_size']),
                    count: ji(data['count']),
                    onPage: (p) => setState(() => _stagnantPage = p),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
