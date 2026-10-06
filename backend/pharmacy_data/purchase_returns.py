"""
استرجاع أصناف لمذخر من فاتورة شراء، واستلام أموال من المذخر مقابل رصيد
الصيدلية لديه. نفس DatabaseHelper.returnPurchaseItems / receiveSupplierRefund
في Flutter. يجب الاستدعاء داخل transaction.atomic() على فاتورة/مذخر مقفولين.

قواعد السطر (يعيد الخادم حسابها كلها ولا يثق بأي رقم من العميل):
  الحد الأقصى = min(المدفوع + البونص − المسترجع سابقاً من السطر، مخزون الصنف الحالي)
  الوحدات المحسوبة = min(الكمية، max(0, المدفوع − المسترجع سابقاً))
      (المسترجع يُحسب من الوحدات المدفوعة أولاً؛ البونص والمجاني بلا رصيد)
  الرصيد = الوحدات المحسوبة × سعر الاسترجاع (افتراضياً سعر الشراء، قابل للتعديل)
"""

from datetime import datetime, time
from decimal import Decimal

from django.db.models import Sum
from django.utils import timezone

from . import stock, supplier_ledger
from .models import Medicine, PurchaseInvoiceReturnItem, Supplier, SupplierRefund
from .purchase_list import fail, line_error

ZERO = Decimal("0")


def credited_units(paid_qty, already_returned, quantity):
    return min(quantity, max(0, paid_qty - already_returned))


def returned_quantity(item):
    return item.return_items.aggregate(total=Sum("quantity"))["total"] or 0


def moment(day):
    """تاريخ الحركة: اليوم = الآن، تاريخ سابق = منتصف ذلك اليوم. المستقبل مرفوض."""
    today = timezone.localdate()
    if day is None or day == today:
        return timezone.now()
    if day > today:
        raise fail("لا يمكن تسجيل حركة بتاريخ مستقبلي.")
    return timezone.make_aware(datetime.combine(day, time(12, 0)))


def return_items(invoice, lines, notes="", return_date=None):
    """
    lines: [{"purchase_invoice_item": id, "quantity": n, "unit_price": Decimal|None}].
    يرجع (سجل الاسترجاع، الأصناف المتأثرة).
    """
    if not lines:
        raise fail("اختر صنفاً واحداً على الأقل لاسترجاعه.")
    returned_at = moment(return_date)
    # قفل المذخر يسلسل حركات رصيده (فائض المرتجع يسدّد فواتيره الأخرى).
    Supplier.objects.select_for_update().get(pk=invoice.supplier_id)
    seen = set()
    prepared = []
    total_credit = ZERO
    touched = {}
    for index, line in enumerate(lines):
        item_id = line["purchase_invoice_item"]
        if item_id in seen:
            raise line_error(index, "هذا الصنف مكرر في طلب الاسترجاع.")
        seen.add(item_id)
        item = invoice.items.filter(pk=item_id).first()
        if item is None:
            raise line_error(index, "هذا الصنف ليس من أصناف الفاتورة.")
        if item.medicine_id is None:
            raise line_error(index, f"الصنف {item.trade_name} حُذف من المخزون ولا يمكن استرجاعه.")
        medicine = Medicine.objects.select_for_update().get(pk=item.medicine_id)
        quantity = line["quantity"]
        already = returned_quantity(item)
        bought_left = item.quantity + item.bonus_quantity - already
        limit = max(0, min(bought_left, medicine.quantity))
        if quantity < 1:
            raise line_error(index, "الكمية المسترجعة يجب أن تكون 1 على الأقل.")
        if quantity > limit:
            raise line_error(
                index,
                f"أقصى كمية يمكن استرجاعها من {item.trade_name} هي {limit} "
                f"(المتبقي من الفاتورة {max(bought_left, 0)}، المتوفر بالمخزون {medicine.quantity}).",
            )
        price = line.get("unit_price")
        price = item.buy_price if price is None else price
        if price < 0:
            raise line_error(index, "سعر الاسترجاع لا يمكن أن يكون سالباً.")
        credited = credited_units(item.quantity, already, quantity)
        credit = stock.to_money(Decimal(credited) * Decimal(price))
        stock.deduct_fefo(medicine, quantity, sellable_only=False, prefer_invoice_id=invoice.pk)
        touched[medicine.pk] = medicine
        total_credit += credit
        prepared.append((item, medicine, quantity, credited, stock.to_money(price), credit))

    record = supplier_ledger.record_return(invoice, total_credit, notes=(notes or "").strip(), returned_at=returned_at)
    for item, medicine, quantity, credited, price, credit in prepared:
        PurchaseInvoiceReturnItem.objects.create(
            pharmacy_id=invoice.pharmacy_id,
            purchase_return=record,
            purchase_invoice_item=item,
            medicine=medicine,
            trade_name=item.trade_name,
            quantity=quantity,
            credited_quantity=credited,
            unit_return_price=price,
            credit_amount=credit,
        )
    return record, list(touched.values())


def receive_refund(supplier, amount, notes="", received_date=None):
    """استلام أموال من المذخر: جزئي مسموح، ولا يتجاوز رصيد الصيدلية المتاح لديه."""
    supplier = Supplier.objects.select_for_update().get(pk=supplier.pk)
    if amount is None or amount <= 0:
        raise fail("يجب أن يكون المبلغ المستلم أكبر من صفر.")
    available = supplier_ledger.figures_for(supplier)["available_credit"]
    if amount > available:
        raise fail(f"المبلغ أكبر من رصيدك لدى المذخر ({stock.to_money(available)}).")
    return SupplierRefund.objects.create(
        pharmacy_id=supplier.pharmacy_id,
        supplier=supplier,
        amount=stock.to_money(amount),
        notes=(notes or "").strip(),
        received_at=moment(received_date),
    )
