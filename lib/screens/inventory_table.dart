import 'package:flutter/material.dart';

import '../database/db_helper.dart';
import '../models/medicine_categories.dart';
import '../widgets/lazy_table.dart';

/// جدول أصناف شاشة المخزون. ويدجت مستقلة كي لا تُعاد بناؤها مع كل حرف في
/// حقل البحث (تُبنى فقط عند وصول نتائج جديدة)، وصفوفها تُبنى عند ظهورها فقط.
class InventoryTable extends StatelessWidget {
  final List<Map<String, dynamic>> medicines;
  final bool isOwner;
  final ValueChanged<Map<String, dynamic>> onShowBatches;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<Map<String, dynamic>> onDamage;
  final ValueChanged<Map<String, dynamic>> onDelete;

  const InventoryTable({
    super.key,
    required this.medicines,
    required this.isOwner,
    required this.onShowBatches,
    required this.onEdit,
    required this.onDamage,
    required this.onDelete,
  });

  static const _headerStyle = TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9));

  /// إزالة الأصفار العشرية الزائدة وإضافة فواصل الآلاف.
  static String formatAmount(dynamic value) {
    if (value == null) return '0';
    final numVal = double.tryParse(value.toString()) ?? 0;
    final str = numVal % 1 == 0 ? numVal.toInt().toString() : numVal.toStringAsFixed(2);
    return str.replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},');
  }

  @override
  Widget build(BuildContext context) {
    return LazyTable(
      columns: [
        const LazyColumn('اسم الدواء', 260),
        const LazyColumn('الكمية', 110),
        // الكلفة وسعر الشراء للمالك فقط.
        if (isOwner) const LazyColumn('الكلفة (متوسط)', 130),
        const LazyColumn('سعر البيع', 120),
        const LazyColumn('الصلاحية', 140),
        const LazyColumn('الشكل الدوائي', 170),
        if (isOwner) const LazyColumn('الإجراءات', 140),
      ],
      itemCount: medicines.length,
      rowHeight: 74,
      headerColor: const Color(0xFF1ABC9C),
      headerStyle: _headerStyle,
      cellPadding: const EdgeInsets.symmetric(horizontal: 12),
      rowKey: (i) => ValueKey('inventory-row-${medicines[i]['id']}'),
      cellsBuilder: (context, index) => _cells(medicines[index]),
    );
  }

  List<Widget> _cells(Map<String, dynamic> med) {
    final int qty = med['quantity'] ?? 0;
    final isLowStock = qty <= kLowStockThreshold;
    final String tradeName = med['trade_name'] ?? '';
    final String scientificName = med['scientific_name'] ?? '';
    final String barcode = med['barcode'] ?? '';
    final avgCost = med['avg_cost'] as num?;

    return [
      // اسم الدواء والتفاصيل (النقر يعرض دفعات الصلاحية)
      InkWell(
        onTap: () => onShowBatches(med),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                tradeName,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (scientificName.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  scientificName,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (barcode.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '║ $barcode',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 11, fontFamily: 'monospace'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
      // شارة الكمية
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isLowStock ? const Color(0xFFFEF2F2) : const Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isLowStock ? const Color(0xFFFCA5A5) : const Color(0xFF86EFAC)),
        ),
        child: Text(
          '$qty قطعة',
          style: TextStyle(
            color: isLowStock ? const Color(0xFFDC2626) : const Color(0xFF166534),
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
      // متوسط الكلفة (المالك فقط)
      if (isOwner)
        Text(
          avgCost == null ? '-' : '${formatAmount(avgCost)} د.ع',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
        ),
      // سعر البيع
      Text(
        '${formatAmount(med['sell_price'])} د.ع',
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1ABC9C)),
      ),
      // الصلاحية: أقرب دفعة؛ النقر يعرض كل الدفعات
      InkWell(
        onTap: () => onShowBatches(med),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(med['expiry_date'] ?? '-', style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 4),
            Icon(Icons.layers_outlined, size: 14, color: Colors.grey.shade500),
          ],
        ),
      ),
      // الشكل الدوائي
      Text(medicineCategoryLabel(med['category']), style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
      // أزرار الإجراءات التفاعلية
      if (isOwner)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _action('تعديل', Icons.edit_outlined, const Color(0xFF2563EB), const Color(0xFFEFF6FF), () => onEdit(med)),
            const SizedBox(width: 6),
            _action('إتلاف', Icons.warning_amber_rounded, const Color(0xFFD97706), const Color(0xFFFFFBEB), () => onDamage(med)),
            const SizedBox(width: 6),
            _action('حذف نهائي', Icons.delete_outline, const Color(0xFFDC2626), const Color(0xFFFEF2F2), () => onDelete(med)),
          ],
        ),
    ];
  }

  Widget _action(String tooltip, IconData icon, Color color, Color background, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, color: color, size: 18),
        ),
      ),
    );
  }
}
