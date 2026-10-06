import 'package:flutter/material.dart';

import '../report_widgets.dart';
import '../reports_scope.dart';

class PurchasesTab extends StatefulWidget {
  const PurchasesTab({super.key, required this.scope});

  final ReportsScope scope;

  @override
  State<PurchasesTab> createState() => _PurchasesTabState();
}

class _PurchasesTabState extends State<PurchasesTab> {
  ReportsScope get s => widget.scope;

  void _retry() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final data = s.load('purchases', () => s.repo.purchases(s.period));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportCard(
          title: 'مشتريات الفترة',
          subtitle: 'قوائم المذاخر المُدخلة خلال الفترة المختارة',
          icon: Icons.shopping_cart_outlined,
          child: SectionFuture(
            future: data,
            onRetry: _retry,
            builder: (d) {
              final suppliers = List<Map<String, dynamic>>.from(d['by_supplier'] as List);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatGrid(maxColumns: 5, minTileWidth: 150, tiles: [
                    StatTile(label: 'إجمالي المشتريات', value: iqd(d['purchases_total']),
                        hint: '${ji(d['invoices_count'])} فاتورة'),
                    StatTile(label: 'مرتجعات للمذاخر', value: iqd(d['returns_total']), color: RC.orange),
                    StatTile(label: 'المدفوع للمذاخر', value: iqd(d['payments_total']), color: RC.green),
                    StatTile(label: 'مبالغ مستلمة من المذاخر', value: iqd(d['refunds_received'])),
                  ]),
                  const SizedBox(height: 16),
                  if (suppliers.isEmpty)
                    const EmptyState('لا توجد مشتريات في هذه الفترة.')
                  else
                    ReportTable(
                      columns: const [
                        RCol('المذخر', width: 200),
                        RCol('عدد الفواتير', width: 110),
                        RCol('قيمة المشتريات', width: 130),
                        RCol('المرتجعات', width: 120),
                      ],
                      rows: [
                        for (final r in suppliers)
                          [
                            cellText('${r['name']}', bold: true),
                            cellText('${ji(r['invoices_count'])}'),
                            cellText(iqd(r['total']), bold: true),
                            cellText(jn(r['returns']) > 0 ? iqd(r['returns']) : '-', color: RC.orange),
                          ],
                      ],
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        ReportCard(
          title: 'أرصدة المذاخر',
          icon: Icons.account_balance_outlined,
          accent: RC.orange,
          trailing: const Tag('الرصيد الحالي', icon: Icons.schedule),
          child: SectionFuture(
            future: data,
            onRetry: _retry,
            builder: (d) {
              final debtors = List<Map<String, dynamic>>.from(d['top_debtors'] as List);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatGrid(maxColumns: 2, tiles: [
                    StatTile(label: 'إجمالي ديون المذاخر', value: iqd(d['total_debt']), color: RC.red),
                    StatTile(label: 'رصيدنا لدى المذاخر', value: iqd(d['total_credit']), color: RC.green),
                  ]),
                  const SizedBox(height: 16),
                  const Text('أعلى المذاخر ديناً', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: RC.text)),
                  const SizedBox(height: 10),
                  if (debtors.isEmpty)
                    const EmptyState('لا توجد ديون مستحقة للمذاخر.', icon: Icons.check_circle_outline)
                  else
                    ShareBars(color: RC.orange, entries: [for (final r in debtors) ('${r['name']}', jn(r['debt']), null)]),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
