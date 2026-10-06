// قواعد قائمة المذخر / الرصيد الافتتاحي المشتركة بين نافذة الإدخال
// (inventory) والحفظ المحلي (DatabaseHelper.createPurchaseList). نسخة حرفية
// من backend/pharmacy_data/purchase_list.py و stock.effective_unit_cost —
// أي تغيير هنا يجب أن يقابله تغيير هناك (يتحقق منه test/fixtures/profit_parity.json).

/// وضع النافذة: قائمة مذخر (الافتراضي) أو رصيد افتتاحي بلا مذخر ولا فاتورة.
enum PurchaseListMode { supplierList, openingStock }

/// مصدر الدفعة (medicine_batch.source / MedicineBatch.source).
class BatchSource {
  static const purchaseList = 'purchase_list';
  static const openingStock = 'opening_stock';
}

/// مصدر فاتورة الشراء (purchase_invoice.source).
class PurchaseInvoiceSource {
  static const manual = 'manual';
  static const inventoryList = 'inventory_list';
}

/// خطأ حفظ القائمة. [line] رقم السطر (من 0) لإبرازه في النافذة، أو null
/// لخطأ في رأس القائمة (المذخر، رقم الفاتورة، المبلغ المدفوع...).
class PurchaseListException implements Exception {
  final String message;
  final int? line;

  const PurchaseListException(this.message, {this.line});

  @override
  String toString() => message;
}

double _roundCost(num value) => (value * 10000).round() / 10000;

double _roundMoney(num value) => (value * 100).round() / 100;

/// كلفة الوحدة الفعلية: (المدفوع × سعر الشراء) / (المدفوع + البونص). سطر
/// مجاني بالكامل (paid == 0) كلفته 0 معروفة. مثال: 10 × 1000 + 2 بونص = 833.3333.
double effectiveUnitCost({required int paidQty, required int bonusQty, required double buyPrice}) {
  final total = paidQty + bonusQty;
  if (total <= 0) throw const PurchaseListException('الكمية يجب أن تكون أكبر من صفر.');
  if (paidQty == 0) return 0;
  return _roundCost(paidQty * buyPrice / total);
}

/// إجمالي السطر: المدفوع فقط — البونص والمجاني لا يدخلان الإجمالي ولا الدين.
double purchaseLineTotal({required int paidQty, required double buyPrice}) => _roundMoney(paidQty * buyPrice);

/// قراءة رقم من سطر القائمة (رقم أو نص أو null).
double? lineNum(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final text = value.toString().trim();
  return text.isEmpty ? null : double.tryParse(text);
}

int lineInt(dynamic value) => lineNum(value)?.toInt() ?? 0;

/// يتحقق من سطر واحد (مفاتيح الخادم نفسها: quantity, bonus_quantity, is_free,
/// buy_price, sell_price, expiry_date). [isNew]: الصنف غير موجود في المخزن
/// المختار. يرجع رسالة الخطأ أو null — نفس _validate_line في الخادم.
String? validatePurchaseLine(Map<String, dynamic> line, PurchaseListMode mode, {required bool isNew}) {
  final name = (line['trade_name'] ?? '').toString().trim();
  if (name.isEmpty && line['medicine_id'] == null) return 'يرجى إدخال اسم الصنف.';

  final quantity = lineInt(line['quantity']);
  final bonus = lineInt(line['bonus_quantity']);
  final isFree = line['is_free'] == true;
  final buyPrice = lineNum(line['buy_price']);
  final sellPrice = lineNum(line['sell_price']);
  final expiry = (line['expiry_date'] ?? '').toString().trim();

  if (expiry.isEmpty) return 'يرجى تحديد تاريخ الانتهاء.';
  if (mode == PurchaseListMode.openingStock) {
    if (isFree || bonus != 0) return 'الرصيد الافتتاحي لا يقبل بونص أو أصنافاً مجانية.';
    if (quantity < 1) return 'الكمية يجب أن تكون 1 على الأقل.';
    if (buyPrice == null || buyPrice < 0) return 'سعر الشراء لا يمكن أن يكون سالباً.';
  } else if (isFree) {
    if (quantity != 0) return 'الصنف المجاني لا يحتوي كمية مدفوعة.';
    if (bonus < 1) return 'كمية الصنف المجاني يجب أن تكون 1 على الأقل.';
  } else {
    if (quantity < 1) return 'الكمية المدفوعة يجب أن تكون 1 على الأقل.';
    if (bonus < 0) return 'كمية البونص لا يمكن أن تكون سالبة.';
    if (buyPrice == null || buyPrice <= 0) return 'سعر الشراء يجب أن يكون أكبر من صفر.';
  }

  // سعر البيع إلزامي دائماً، عدا سطر مجاني لصنف موجود (يبقى سعره الحالي).
  final sellOptional = isFree && !isNew;
  if (sellPrice == null) {
    if (!sellOptional) return 'سعر البيع يجب أن يكون أكبر من صفر.';
  } else if (sellPrice <= 0) {
    return 'سعر البيع يجب أن يكون أكبر من صفر.';
  }
  return null;
}

/// يحوّل تاريخ انتهاء مكتوباً بسرعة إلى YYYY-MM-DD، أو null إن لم يُفهم.
/// يقبل: 2027-05-31، 2027-05 أو 05/2027 أو 5/27 (= آخر يوم في الشهر، كما يُطبع
/// على العلب غالباً)، و31/05/2027.
String? normalizeExpiryInput(String input) {
  final text = input.trim().replaceAll('\\', '/').replaceAll('.', '/');
  if (text.isEmpty) return null;
  String fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  DateTime? endOfMonth(int year, int month) {
    if (month < 1 || month > 12) return null;
    if (year < 100) year += 2000;
    return DateTime(year, month + 1, 0);
  }

  DateTime? exact(int year, int month, int day) {
    if (year < 100) year += 2000;
    final d = DateTime(year, month, day);
    return (d.year == year && d.month == month && d.day == day) ? d : null;
  }

  final ymd = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(text);
  if (ymd != null) {
    final d = exact(int.parse(ymd[1]!), int.parse(ymd[2]!), int.parse(ymd[3]!));
    return d == null ? null : fmt(d);
  }
  final ym = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(text);
  if (ym != null) {
    final d = endOfMonth(int.parse(ym[1]!), int.parse(ym[2]!));
    return d == null ? null : fmt(d);
  }
  final dmy = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2}|\d{4})$').firstMatch(text);
  if (dmy != null) {
    final d = exact(int.parse(dmy[3]!), int.parse(dmy[2]!), int.parse(dmy[1]!));
    return d == null ? null : fmt(d);
  }
  final my = RegExp(r'^(\d{1,2})/(\d{2}|\d{4})$').firstMatch(text);
  if (my != null) {
    final d = endOfMonth(int.parse(my[2]!), int.parse(my[1]!));
    return d == null ? null : fmt(d);
  }
  return null;
}

/// مجاميع القائمة للتذييل الحي وللحفظ (لا يُرسل أي مجموع للخادم).
class PurchaseListTotals {
  final int itemCount;
  final int paidQuantity;
  final int bonusQuantity;
  final int freeItemCount;
  final double invoiceTotal;

  const PurchaseListTotals({
    required this.itemCount,
    required this.paidQuantity,
    required this.bonusQuantity,
    required this.freeItemCount,
    required this.invoiceTotal,
  });

  factory PurchaseListTotals.of(Iterable<Map<String, dynamic>> lines) {
    var count = 0, paid = 0, bonus = 0, free = 0;
    var total = 0.0;
    for (final line in lines) {
      count++;
      final isFree = line['is_free'] == true;
      final qty = isFree ? 0 : lineInt(line['quantity']);
      paid += qty;
      bonus += lineInt(line['bonus_quantity']);
      if (isFree) free++;
      total += purchaseLineTotal(paidQty: qty, buyPrice: isFree ? 0 : (lineNum(line['buy_price']) ?? 0));
    }
    return PurchaseListTotals(
      itemCount: count,
      paidQuantity: paid,
      bonusQuantity: bonus,
      freeItemCount: free,
      invoiceTotal: _roundMoney(total),
    );
  }
}
