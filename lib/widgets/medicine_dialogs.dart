import 'package:flutter/material.dart';

import '../models/medicine_categories.dart';
import '../repository/medicine_repository.dart';
import '../repository/warehouse_repository.dart';
import '../services/medicine_api_service.dart';
import '../services/warehouse_api_service.dart';

/// نافذتا تعديل بيانات الدواء والإتلاف الجزئي — مشتركتان بين شاشة المخزون
/// وشاشة التقارير (تعديل سعر صنف يُباع بأقل من كلفته، تسجيل منتهي كتالف).

/// أسباب الإتلاف. 'correction' لتصحيح خطأ إدخال كمية — لا يُحتسب خسارة.
/// 'expired' لتسجيل دفعة منتهية الصلاحية كتالف (من تقرير المخزون).
const Map<String, String> damageReasons = {
  'broken': 'كسر وضرر',
  'spoiled': 'سوء خزن',
  'withdrawn': 'سحب وزاري',
  'expired': 'انتهاء الصلاحية',
  'correction': 'تصحيح إدخال (خطأ كمية)',
  'other': 'أسباب أخرى',
};

// تحويل رسائل خطأ قاعدة البيانات الخام (طويلة وتقنية) إلى سبب مباشر
// ومفهوم للصيدلي، بدل عرض نص الاستثناء الكامل بالـ SnackBar
String friendlyDbErrorMessage(Object error) {
  final text = error.toString();

  if (text.contains('UNIQUE constraint failed') && text.contains('barcode')) {
    return 'هذا الباركود مستخدم مسبقاً لدواء آخر بالمخزن. تحقق من الرقم أو اتركه فارغاً.';
  }
  if (text.contains('NOT NULL constraint failed')) {
    return 'يوجد حقل إلزامي فارغ، يرجى تعبئة كل الحقول المطلوبة (*).';
  }
  if (text.contains('CHECK constraint failed')) {
    return 'إحدى القيم المُدخَلة غير صحيحة (مثل كمية أو سعر سالب).';
  }
  if (text.contains('FOREIGN KEY constraint failed')) {
    return 'لا يمكن تنفيذ هذا الإجراء لوجود بيانات أخرى مرتبطة بهذا الدواء.';
  }

  return 'حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.';
}

// رسائل MedicineRepositoryException/MedicineApiException جاهزة بالعربية
// أصلاً من مصدرها (انظر medicine_repository.dart وmedicine_api_service.dart)
// فتُعرض كما هي، بعكس أخطاء sqflite الخام التي تحتاج friendlyDbErrorMessage.
String friendlyWriteErrorMessage(Object error) {
  if (error is MedicineRepositoryException ||
      error is MedicineApiException ||
      error is WarehouseRepositoryException ||
      error is WarehouseApiException) {
    return error.toString();
  }
  return friendlyDbErrorMessage(error);
}

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.red, duration: const Duration(seconds: 3)),
  );
}

/// تعديل بيانات الدواء. يعيد true بعد حفظ ناجح (المستدعي يحدّث شاشته).
Future<bool> showMedicineEditDialog(
  BuildContext context, {
  required Map<String, dynamic> med,
  required int pharmacyId,
  required bool isOnlineMode,
}) async {
  const categories = medicineCategories;
  final barcodeCtrl = TextEditingController(text: med['barcode'] ?? '');
  final tradeCtrl = TextEditingController(text: med['trade_name']);
  final scientificCtrl = TextEditingController(text: med['scientific_name'] ?? '');
  final buyPriceCtrl = TextEditingController(text: med['buy_price'].toString());
  final sellPriceCtrl = TextEditingController(text: med['sell_price'].toString());
  final expiryCtrl = TextEditingController(text: med['expiry_date'] ?? '');
  // موقع الرف مخفي من الواجهة؛ قيمته الحالية تُرسل كما هي عند الحفظ.
  final shelfCtrl = TextEditingController(text: med['shelf_location'] ?? '');
  String selectedCategory = (med['category'] ?? '').toString();

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.edit_note, color: Color(0xFF3182CE)),
              SizedBox(width: 8),
              Text('تعديل بيانات الدواء', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 450,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // --- بيانات الهوية ---
                  TextField(controller: tradeCtrl, decoration: const InputDecoration(labelText: 'الاسم التجاري *')),
                  const SizedBox(height: 10),
                  TextField(controller: scientificCtrl, decoration: const InputDecoration(labelText: 'الاسم العلمي')),
                  const SizedBox(height: 10),
                  TextField(controller: barcodeCtrl, decoration: const InputDecoration(labelText: 'الباركود')),

                  const SizedBox(height: 18),
                  Divider(color: Colors.grey.shade300),
                  const SizedBox(height: 8),

                  // --- التصنيف والموقع ---
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: selectedCategory.isEmpty ? categories.keys.first : selectedCategory,
                          decoration: const InputDecoration(labelText: 'الشكل الدوائي'),
                          items: [
                            ...categories.entries.map((e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value))),
                            // قيمة قديمة غير موجودة بالقائمة تبقى كما هي (لا تُستبدل بصمت عند الحفظ).
                            if (selectedCategory.isNotEmpty && !categories.containsKey(selectedCategory))
                              DropdownMenuItem<String>(value: selectedCategory, child: Text(selectedCategory)),
                          ],
                          onChanged: (val) => setDialogState(() => selectedCategory = val!),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),
                  Divider(color: Colors.grey.shade300),
                  const SizedBox(height: 8),

                  // --- التسعير والصلاحية ---
                  Row(
                    children: [
                      Expanded(child: TextField(controller: buyPriceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'آخر سعر شراء *'))),
                      const SizedBox(width: 10),
                      Expanded(child: TextField(controller: sellPriceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'سعر البيع *'))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // الصلاحية تُدار لكل دفعة عبر "إضافة قائمة مذخر"؛ هنا أقربها للعرض فقط.
                  TextField(
                    controller: expiryCtrl,
                    readOnly: true,
                    enabled: false,
                    decoration: const InputDecoration(
                      labelText: 'أقرب تاريخ انتهاء (حسب الشحنات)',
                      prefixIcon: Icon(Icons.calendar_month_outlined, color: Color(0xFF3182CE)),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3182CE)),
              onPressed: () async {
                try {
                  await MedicineRepository.instance.updateMedicine(
                    pharmacyId: pharmacyId,
                    isOnlineMode: isOnlineMode,
                    id: med['id'],
                    data: {
                      'barcode': barcodeCtrl.text.trim().isEmpty ? null : barcodeCtrl.text.trim(),
                      'trade_name': tradeCtrl.text.trim(),
                      'scientific_name': scientificCtrl.text.trim(),
                      'category': selectedCategory,
                      'buy_price': double.tryParse(buyPriceCtrl.text) ?? 0.0,
                      'sell_price': double.tryParse(sellPriceCtrl.text) ?? 0.0,
                      'shelf_location': shelfCtrl.text.trim(),
                    },
                  );
                  if (ctx.mounted && Navigator.canPop(ctx)) Navigator.pop(ctx, true);
                } catch (e) {
                  if (!context.mounted) return;
                  _showError(context, friendlyWriteErrorMessage(e));
                }
              },
              child: const Text('حفظ التعديلات', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    ),
  );
  return saved == true;
}

/// الإتلاف الجزئي لدواء (خصم FEFO + سجل تالف). يعيد true بعد نجاح العملية.
/// [initialReason]/[initialQuantity]: قيم مبدئية (مثلاً 'expired' وكمية الدفعة
/// المنتهية عند الفتح من تقرير المخزون).
Future<bool> showMedicineDamageDialog(
  BuildContext context, {
  required Map<String, dynamic> med,
  required int pharmacyId,
  required bool isOnlineMode,
  String initialReason = 'broken',
  int? initialQuantity,
}) async {
  final int currentQty = (med['quantity'] as num).toInt();
  final damageQtyCtrl = TextEditingController(text: (initialQuantity ?? currentQty).toString());
  final notesCtrl = TextEditingController();
  String selectedReason = damageReasons.containsKey(initialReason) ? initialReason : 'broken';

  final done = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFE53E3E)),
              SizedBox(width: 8),
              Text('نقل لقائمة التوالف', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE53E3E))),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('الدواء المستهدف: ${med['trade_name']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 6),
                Text('الكمية المتوفرة حالياً: $currentQty قطعة', style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 12),
                TextField(
                  controller: damageQtyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'الكمية المراد إتلافها *'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedReason,
                  decoration: const InputDecoration(labelText: 'سبب الإتلاف *'),
                  items: damageReasons.entries.map((e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (val) => setDialogState(() => selectedReason = val!),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'ملاحظات إضافية (اختياري)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE53E3E)),
              onPressed: () async {
                int qtyToDamage = int.tryParse(damageQtyCtrl.text) ?? 0;
                if (qtyToDamage <= 0 || qtyToDamage > currentQty) {
                  _showError(context, 'يرجى إدخال كمية صحيحة لا تتجاوز المتاح ($currentQty)');
                  return;
                }

                try {
                  await MedicineRepository.instance.damageMedicine(
                    pharmacyId: pharmacyId,
                    isOnlineMode: isOnlineMode,
                    medicineId: med['id'],
                    quantityToDamage: qtyToDamage,
                    reason: selectedReason,
                    notes: notesCtrl.text.trim(),
                  );
                  if (ctx.mounted && Navigator.canPop(ctx)) Navigator.pop(ctx, true);
                } catch (e) {
                  if (!context.mounted) return;
                  _showError(context, friendlyWriteErrorMessage(e));
                }
              },
              child: const Text('تأكيد الإتلاف', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    ),
  );
  return done == true;
}
