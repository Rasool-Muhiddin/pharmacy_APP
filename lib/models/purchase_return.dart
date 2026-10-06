// قواعد استرجاع الأصناف للمذخر المشتركة بين نافذة الاسترجاع والحفظ المحلي
// (DatabaseHelper.returnPurchaseItems). نسخة حرفية من
// backend/pharmacy_data/purchase_returns.py — يتحقق منها
// test/fixtures/profit_parity.json (supplier_returns).

/// ملاحظات سجلات استخدام رصيد المذخر (نفس supplier_ledger في الخادم).
class SupplierCreditNote {
  static const previous = 'خصم من رصيد سابق';
  static const fromReturn = 'تسوية من فائض مرتجع';
  static const legacy = 'تسوية رصيد دائن قديم';
}

double _roundMoney(num value) => (value * 100).round() / 100;

/// أقصى كمية يمكن استرجاعها من سطر فاتورة: المتبقي من السطر (المدفوع +
/// البونص − المسترجع سابقاً) محدوداً بمخزون الصنف الحالي.
int returnableQuantity({
  required int paidQty,
  required int bonusQty,
  required int alreadyReturned,
  required int currentStock,
}) {
  final left = paidQty + bonusQty - alreadyReturned;
  final limit = left < currentStock ? left : currentStock;
  return limit < 0 ? 0 : limit;
}

/// الوحدات التي لها رصيد: المسترجع يُحسب من الوحدات المدفوعة أولاً، والبونص
/// والمجاني (بعد نفاد المدفوع) بلا رصيد.
int creditedUnits({required int paidQty, required int alreadyReturned, required int quantity}) {
  final paidLeft = paidQty - alreadyReturned;
  if (paidLeft <= 0) return 0;
  return quantity < paidLeft ? quantity : paidLeft;
}

double returnLineCredit({
  required int paidQty,
  required int alreadyReturned,
  required int quantity,
  required double unitPrice,
}) =>
    _roundMoney(creditedUnits(paidQty: paidQty, alreadyReturned: alreadyReturned, quantity: quantity) * unitPrice);
