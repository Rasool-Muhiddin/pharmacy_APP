import 'package:flutter/material.dart';

import '../../../models/medicine_categories.dart';
import '../../../widgets/medicine_dialogs.dart';
import '../report_widgets.dart';
import '../reports_scope.dart';

/// الوضع الحالي للمخزون — غير مقيّد بفترة التقرير.
class InventoryTab extends StatefulWidget {
  const InventoryTab({super.key, required this.scope});

  final ReportsScope scope;

  @override
  State<InventoryTab> createState() => _InventoryTabState();
}

class _InventoryTabState extends State<InventoryTab> {
  ReportsScope get s => widget.scope;

  int _days = 30;

  void _retry() => setState(() {});

  /// تسجيل دفعة منتهية كتالف بسبب 'expired' عبر نفس نافذة الإتلاف (FEFO يخصم
  /// المنتهية أولاً)، فتنتقل قيمتها إلى خسائر الفترة الحالية.
  Future<void> _recordExpired(Map<String, dynamic> row) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final med = await s.repo.medicine(row['medicine_id'] as int);
      if (!mounted) return;
      if (med == null) {
        messenger.showSnackBar(const SnackBar(content: Text('الصنف لم يعد موجوداً في المخزون.')));
        return;
      }
      final done = await showMedicineDamageDialog(
        context,
        med: med,
        pharmacyId: s.pharmacyId,
        isOnlineMode: s.isOnlineMode,
        initialReason: 'expired',
        initialQuantity: ji(row['quantity']),
      );
      if (!done || !mounted) return;
      messenger.showSnackBar(
          const SnackBar(content: Text('تم تسجيل الكمية المنتهية كتالف'), backgroundColor: Colors.orange));
      s.onDataChanged();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyWriteErrorMessage(e)), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = s.load('inventory:$_days', () => s.repo.inventory(days: _days));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportCard(
          title: 'قيمة المخزون',
          icon: Icons.warehouse_outlined,
          trailing: currentStateTag,
          child: SectionFuture(
            future: data,
            onRetry: _retry,
            skeletonHeight: 80,
            builder: (d) => StatGrid(maxColumns: 3, tiles: [
              StatTile(label: 'بسعر الكلفة', value: iqd(d['stock_cost_value'])),
              StatTile(label: 'بسعر البيع', value: iqd(d['stock_sell_value'])),
              StatTile(label: 'الربح المتوقع عند بيع الكل', value: iqd(d['expected_profit']), color: RC.green),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        ReportCard(
          title: 'تنتهي صلاحيتها قريباً',
          icon: Icons.event_outlined,
          accent: RC.orange,
          trailing: Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SegmentedButton<int>(
              key: const Key('expiry-days'),
              segments: const [
                ButtonSegment(value: 30, label: Text('30 يوماً')),
                ButtonSegment(value: 60, label: Text('60 يوماً')),
                ButtonSegment(value: 90, label: Text('90 يوماً')),
              ],
              selected: {_days},
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(selectedBackgroundColor: RC.tealDark, selectedForegroundColor: Colors.white),
              onSelectionChanged: (v) => setState(() => _days = v.first),
            ),
            currentStateTag,
          ]),
          child: SectionFuture(
            future: data,
            onRetry: _retry,
            builder: (d) {
              final rows = List<Map<String, dynamic>>.from(d['expiring'] as List);
              if (rows.isEmpty) return EmptyState('لا توجد دفعات تنتهي خلال $_days يوماً.', icon: Icons.check_circle_outline);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${rows.length} دفعة بقيمة ${iqd(d['expiring_value'])} (بالكلفة)',
                      style: const TextStyle(fontSize: 12.5, color: RC.orange, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _batchTable(rows),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        ReportCard(
          title: 'منتهية الصلاحية ولم تُسجَّل كتالف',
          subtitle: 'لا تُخصم من صافي الربح حتى تُسجَّل كتالف',
          icon: Icons.event_busy_outlined,
          accent: RC.red,
          trailing: currentStateTag,
          child: SectionFuture(
            future: data,
            onRetry: _retry,
            builder: (d) {
              final rows = List<Map<String, dynamic>>.from(d['expired'] as List);
              if (rows.isEmpty) return const EmptyState('لا توجد دفعات منتهية في المخزون.', icon: Icons.check_circle_outline);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${rows.length} دفعة بقيمة ${iqd(d['expired_value'])} (بالكلفة)',
                      style: const TextStyle(fontSize: 12.5, color: RC.red, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _batchTable(rows, onRecord: s.isOwner ? _recordExpired : null),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        ReportCard(
          title: 'أصناف نفدت أو أوشكت على النفاد',
          icon: Icons.inventory_outlined,
          accent: RC.blue,
          trailing: currentStateTag,
          child: SectionFuture(
            future: data,
            onRetry: _retry,
            builder: (d) {
              final rows = List<Map<String, dynamic>>.from(d['low_stock'] as List);
              if (rows.isEmpty) return const EmptyState('كل الأصناف متوفرة بكمية كافية.', icon: Icons.check_circle_outline);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('الكمية ${ji(d['low_stock_threshold'])} أو أقل', style: const TextStyle(fontSize: 12, color: RC.muted)),
                  const SizedBox(height: 8),
                  ReportTable(
                    columns: const [
                      RCol('الصنف', width: 200),
                      RCol('الشكل الدوائي', width: 160),
                      RCol('الكمية', width: 110),
                      RCol('سعر البيع', width: 110),
                    ],
                    rows: [
                      for (final r in rows)
                        [
                          cellText('${r['trade_name']}', bold: true),
                          cellText(medicineCategoryLabel(r['category']), color: RC.muted),
                          ji(r['quantity']) <= 0
                              ? const Tag('نفد', color: RC.red, background: RC.redBg)
                              : Tag('${ji(r['quantity'])} متبقٍ', color: RC.orange, background: RC.orangeBg),
                          cellText(iqd(r['sell_price'])),
                        ],
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _batchTable(List<Map<String, dynamic>> rows, {void Function(Map<String, dynamic>)? onRecord}) {
    return ReportTable(
      columns: [
        const RCol('الصنف', width: 180),
        const RCol('تاريخ الانتهاء', width: 120),
        const RCol('الكمية', width: 80),
        const RCol('القيمة', width: 110),
        const RCol('المذخر', width: 140),
        if (onRecord != null) const RCol('', width: 140),
      ],
      rows: [
        for (final r in rows)
          [
            cellText('${r['trade_name']}', bold: true),
            cellText('${r['expiry_date']}', color: onRecord != null ? RC.red : RC.orange),
            cellText('${ji(r['quantity'])}'),
            cellText(iqd(r['value']), bold: true),
            cellText((r['supplier_name'] as String?)?.isNotEmpty == true ? r['supplier_name'] as String : 'غير مسجّل',
                color: RC.muted),
            if (onRecord != null)
              OutlinedButton.icon(
                key: Key('record-expired-${r['batch_id']}'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: RC.red,
                  side: const BorderSide(color: RC.red),
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                onPressed: () => onRecord(r),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('تسجيل كتالف'),
              ),
          ],
      ],
    );
  }
}
