import 'package:flutter/material.dart';

import '../../repository/reports_repository.dart';
import 'report_widgets.dart';

/// نافذة تفاصيل الفاتورة. أسطرها من الجدول المحلي (أوفلاين) أو من
/// /api/invoices/{id}/ (أونلاين) — الاسم من سطر الفاتورة نفسه، فلا يختفي سطر
/// صنف حُذف لاحقاً.
Future<void> showInvoiceDetails(BuildContext context, ReportsDataSource repo, Map<String, dynamic> invoice) {
  return showDialog(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 620, maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: const Border(top: BorderSide(color: RC.teal, width: 6)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.receipt_long, color: RC.teal, size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'تفاصيل الفاتورة: ${invoice['invoice_number'] ?? ''}',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50)),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Color(0xFFA0AEC0)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  Text(
                    '${shortDateTime(invoice['created_at'])}  •  البائع: ${invoice['seller_name'] ?? '-'}',
                    style: const TextStyle(fontSize: 12, color: RC.muted),
                  ),
                  const Divider(height: 22, color: Color(0xFFEDF2F7)),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: repo.invoiceItems(invoice['id'] as int),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Text('تعذر جلب أصناف الفاتورة: ${snap.error}', style: const TextStyle(color: RC.red));
                      }
                      if (!snap.hasData) return const SkeletonBlock(height: 100);
                      final items = snap.data!;
                      if (items.isEmpty) return const EmptyState('لا توجد أصناف مسجلة لهذه الفاتورة.');
                      return ReportTable(
                        columns: const [
                          RCol('اسم الدواء', width: 200),
                          RCol('الكمية', width: 80),
                          RCol('سعر المفرد', width: 110),
                          RCol('المجموع', width: 110),
                        ],
                        rows: [
                          for (final item in items)
                            [
                              cellText((item['trade_name'] ?? '-').toString(), bold: true),
                              cellText('${ji(item['quantity'])} قطعة', color: RC.blue),
                              cellText(iqd(item['unit_price'])),
                              cellText(iqd(item['total_price']), bold: true),
                            ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                  _totalRow('المجموع الإجمالي:', iqd(invoice['total_amount'])),
                  _totalRow('الخصم المطبق:', jn(invoice['discount']) > 0 ? '-${iqd(invoice['discount'])}' : iqd(0),
                      color: RC.red),
                  const Divider(height: 18, color: Color(0xFFEDF2F7)),
                  _totalRow('الصافي النهائي للمدفوع:', iqd(invoice['final_amount']), color: RC.green, bold: true),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _totalRow(String label, String value, {Color color = RC.text, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: color == RC.text ? RC.muted : color, fontSize: 13, fontWeight: bold ? FontWeight.bold : null)),
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: bold ? 15 : 13)),
        ],
      ),
    );
