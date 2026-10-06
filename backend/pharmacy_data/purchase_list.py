"""
إدخال قائمة مذخر (أو رصيد افتتاحي) كاملة من شاشة المخزون في عملية ذرّية واحدة.

نفس منطق DatabaseHelper.createPurchaseList في Flutter حرفياً:
  1. المذخر (موجود أو يُنشأ بالاسم) ← 2. فاتورة الشراء ← 3. لكل سطر: توريد
  لصنف موجود في المخزن (نفس الباركود أو نفس الاسم التجاري) أو إنشاء صنف جديد،
  مع دفعة مرتبطة بالمذخر والفاتورة ← 4. الدفعة الأولية الاختيارية.
الرصيد الافتتاحي: نفس الأسطر بلا مذخر ولا فاتورة ولا دفعة ولا دين.

المجاميع والكلفة الفعلية تُحسب هنا فقط (stock.effective_unit_cost/line_total)،
ولا يُوثق بأي مجموع يرسله العميل. يجب الاستدعاء داخل transaction.atomic().
أي خطأ في سطر يُرفع ValidationError({"detail": ..., "line": index}) ليُبرز
التطبيق السطر المعني، والمعاملة كلها تُلغى.
"""

from decimal import Decimal

from django.db import IntegrityError
from django.db.models import Sum
from django.db.models.functions import Coalesce
from rest_framework.exceptions import PermissionDenied, ValidationError

from desktop_api.permissions import FEATURE_MULTI_WAREHOUSE, plan_allows

from . import stock, supplier_ledger
from .models import (
    BATCH_SOURCE_OPENING_STOCK,
    BATCH_SOURCE_PURCHASE_LIST,
    PURCHASE_SOURCE_INVENTORY_LIST,
    Medicine,
    PurchaseInvoice,
    PurchaseInvoiceItem,
    Supplier,
    SupplierPayment,
    Warehouse,
)

MODE_SUPPLIER_LIST = "supplier_list"
MODE_OPENING_STOCK = "opening_stock"


def fail(message):
    """{"detail": ...} كي يعرض التطبيق الرسالة كما هي (قائمة مجرّدة تظهر كخطأ عام)."""
    return ValidationError({"detail": message})


def line_error(index, message):
    return ValidationError({"detail": message, "line": index})


def validated_input(serializer_class, data):
    """
    يتحقق من بيانات الدخل، ويحوّل أخطاء حقول الأسطر (صيغة رقم/تاريخ...) إلى
    {"detail", "line"} كي يُبرز التطبيق السطر المعني بدل رسالة حقل عامة.
    """
    serializer = serializer_class(data=data)
    if serializer.is_valid():
        return serializer.validated_data
    errors = serializer.errors
    item_errors = errors.get("items")
    # DRF يعيد أخطاء القائمة المتداخلة كقائمة (عنصر لكل سطر) أو كقاموس {الرقم: الأخطاء}.
    if isinstance(item_errors, list):
        item_errors = dict(enumerate(item_errors))
    if isinstance(item_errors, dict):
        for index, fields in sorted(item_errors.items()):
            if isinstance(fields, dict) and fields:
                messages = [str(m) for values in fields.values() for m in (values if isinstance(values, list) else [values])]
                raise line_error(index, " ".join(messages))
    raise ValidationError(errors)


def resolve_warehouse(pharmacy, license, warehouse_id):
    """المخزن المختار (من صيدلية المستخدم فقط) أو الرئيسي. غير الرئيسي يتطلب باقة تعدد المخازن."""
    if warehouse_id in (None, ""):
        return Warehouse.main_for(pharmacy)
    try:
        warehouse = Warehouse.objects.get(pk=warehouse_id, pharmacy=pharmacy)
    except (Warehouse.DoesNotExist, TypeError, ValueError):
        raise fail("المخزن غير موجود في هذه الصيدلية.")
    if not warehouse.is_main and not plan_allows(license, FEATURE_MULTI_WAREHOUSE):
        raise PermissionDenied("باقتك الحالية تسمح فقط بالمخزن الرئيسي.")
    return warehouse


def resolve_supplier(pharmacy, supplier_id, supplier_name, supplier_phone):
    """مذخر موجود بالمعرّف، أو بنفس الاسم (تفادياً للتكرار)، أو يُنشأ جديداً."""
    if supplier_id not in (None, ""):
        try:
            return Supplier.objects.get(pk=supplier_id, pharmacy=pharmacy)
        except (Supplier.DoesNotExist, TypeError, ValueError):
            raise fail("المذخر غير موجود في هذه الصيدلية.")
    name = (supplier_name or "").strip()
    if not name:
        raise fail("يرجى اختيار المذخر أو كتابة اسم مذخر جديد.")
    existing = Supplier.objects.filter(pharmacy=pharmacy, name__iexact=name).first()
    if existing is not None:
        return existing
    return Supplier.objects.create(pharmacy=pharmacy, name=name, phone=(supplier_phone or "").strip())


def find_existing_medicine(index, warehouse, medicine_id, barcode, trade_name):
    """
    الصنف الموجود في نفس المخزن (مقفول): بالمعرّف إن أُرسل، وإلا نفس الباركود،
    وإلا نفس الاسم التجاري (بلا حساسية لحالة الأحرف).
    """
    qs = Medicine.objects.select_for_update().filter(warehouse=warehouse)
    if medicine_id not in (None, ""):
        medicine = qs.filter(pk=medicine_id).first()
        if medicine is None:
            raise line_error(index, "الصنف المحدد غير موجود في هذا المخزن.")
        return medicine
    if barcode:
        medicine = qs.filter(barcode=barcode).first()
        if medicine is not None:
            return medicine
    return qs.filter(trade_name__iexact=trade_name).order_by("id").first()


def _validate_line(index, line, mode, is_new):
    quantity = line["quantity"]
    bonus = line.get("bonus_quantity") or 0
    is_free = bool(line.get("is_free"))
    buy_price = line.get("buy_price")
    sell_price = line.get("sell_price")

    if not line.get("expiry_date"):
        raise line_error(index, "يرجى تحديد تاريخ الانتهاء.")
    if mode == MODE_OPENING_STOCK:
        if is_free or bonus:
            raise line_error(index, "الرصيد الافتتاحي لا يقبل بونص أو أصنافاً مجانية.")
        if quantity < 1:
            raise line_error(index, "الكمية يجب أن تكون 1 على الأقل.")
        if buy_price is None or buy_price < 0:
            raise line_error(index, "سعر الشراء لا يمكن أن يكون سالباً.")
    elif is_free:
        if quantity != 0:
            raise line_error(index, "الصنف المجاني لا يحتوي كمية مدفوعة.")
        if bonus < 1:
            raise line_error(index, "كمية الصنف المجاني يجب أن تكون 1 على الأقل.")
    else:
        if quantity < 1:
            raise line_error(index, "الكمية المدفوعة يجب أن تكون 1 على الأقل.")
        if bonus < 0:
            raise line_error(index, "كمية البونص لا يمكن أن تكون سالبة.")
        if buy_price is None or buy_price <= 0:
            raise line_error(index, "سعر الشراء يجب أن يكون أكبر من صفر.")

    # سعر البيع إلزامي دائماً، عدا سطر مجاني لصنف موجود (يبقى سعره الحالي).
    sell_optional = is_free and not is_new
    if sell_price is None:
        if not sell_optional:
            raise line_error(index, "سعر البيع يجب أن يكون أكبر من صفر.")
    elif sell_price <= 0:
        raise line_error(index, "سعر البيع يجب أن يكون أكبر من صفر.")


def _receive_lines(pharmacy, warehouse, lines, mode, supplier=None, purchase_invoice=None):
    """يورّد كل الأسطر بالترتيب ويرجع [(medicine, line, batch, paid_qty, bonus_qty, buy_price)]."""
    source = BATCH_SOURCE_OPENING_STOCK if mode == MODE_OPENING_STOCK else BATCH_SOURCE_PURCHASE_LIST
    received = []
    for index, line in enumerate(lines):
        trade_name = (line.get("trade_name") or "").strip()
        barcode = (line.get("barcode") or "").strip() or None
        if not trade_name and line.get("medicine_id") in (None, ""):
            raise line_error(index, "يرجى إدخال اسم الصنف.")
        medicine = find_existing_medicine(index, warehouse, line.get("medicine_id"), barcode, trade_name)
        is_new = medicine is None
        _validate_line(index, line, mode, is_new)

        is_free = bool(line.get("is_free")) and mode == MODE_SUPPLIER_LIST
        quantity = 0 if is_free else line["quantity"]
        bonus = (line.get("bonus_quantity") or 0) if mode == MODE_SUPPLIER_LIST else 0
        buy_price = Decimal(0) if is_free else line.get("buy_price") or Decimal(0)
        # رصيد افتتاحي بسعر شراء 0 = كلفة غير معروفة (نفس قاعدة إضافة الصنف القديمة).
        unknown_cost = mode == MODE_OPENING_STOCK and buy_price == 0

        if is_new:
            medicine = Medicine.objects.create(
                pharmacy=pharmacy,
                warehouse=warehouse,
                trade_name=trade_name,
                scientific_name=(line.get("scientific_name") or "").strip(),
                category=(line.get("category") or "").strip(),
                quantity=0,
                buy_price=stock.to_money(buy_price),
                sell_price=stock.to_money(line["sell_price"]),
                shelf_location=(line.get("shelf_location") or "").strip(),
                barcode=barcode,
            )
        batch = stock.supply(
            medicine,
            quantity=quantity,
            expiry_date=line.get("expiry_date"),
            purchase_price=None if unknown_cost else buy_price,
            sale_price=line.get("sell_price"),
            bonus_quantity=bonus,
            allow_unknown_cost=unknown_cost,
            source=source,
            supplier=supplier,
            purchase_invoice=purchase_invoice,
        )
        received.append((medicine, line, batch, quantity, bonus, buy_price))
    return received


def create_purchase_list(pharmacy, license, data):
    """
    data: مخرجات PurchaseListInputSerializer. يرجع (purchase_invoice, medicines).
    """
    lines = data["items"]
    warehouse = resolve_warehouse(pharmacy, license, data.get("warehouse"))
    supplier = resolve_supplier(pharmacy, data.get("supplier"), data.get("supplier_name"), data.get("supplier_phone"))
    invoice_number = (data.get("invoice_number") or "").strip()
    if not invoice_number:
        raise fail("رقم فاتورة المذخر مطلوب.")
    if PurchaseInvoice.objects.filter(pharmacy=pharmacy, supplier=supplier, invoice_number=invoice_number).exists():
        raise fail(f"رقم الفاتورة {invoice_number} مسجّل مسبقاً لهذا المذخر.")
    # قفل المذخر يسلسل استخدام رصيده بين الطلبات المتزامنة. الرصيد المتاح يُقرأ
    # قبل إنشاء الفاتورة الجديدة (إجماليها يرفع رصيد المذخر).
    supplier = Supplier.objects.select_for_update().get(pk=supplier.pk)
    available_credit = supplier_ledger.figures_for(supplier)["available_credit"]

    try:
        purchase_invoice = PurchaseInvoice.objects.create(
            pharmacy=pharmacy,
            supplier=supplier,
            invoice_number=invoice_number,
            invoice_date=data.get("invoice_date"),
            source=PURCHASE_SOURCE_INVENTORY_LIST,
        )
    except IntegrityError:
        raise fail(f"رقم الفاتورة {invoice_number} مسجّل مسبقاً لهذا المذخر.")

    received = _receive_lines(pharmacy, warehouse, lines, MODE_SUPPLIER_LIST, supplier, purchase_invoice)
    total = Decimal(0)
    for medicine, line, batch, quantity, bonus, buy_price in received:
        amount = stock.line_total(quantity, buy_price)
        total += amount
        PurchaseInvoiceItem.objects.create(
            pharmacy=pharmacy,
            purchase_invoice=purchase_invoice,
            medicine=medicine,
            trade_name=medicine.trade_name,
            quantity=quantity,
            bonus_quantity=bonus,
            buy_price=stock.to_money(buy_price),
            effective_unit_cost=batch.purchase_price or 0,
            sell_price=medicine.sell_price,
            expiry_date=line.get("expiry_date"),
            line_total=amount,
        )

    total = stock.to_money(total)
    # رصيد المذخر لصالح الصيدلية يُخصم أولاً حتى إجمالي الفاتورة، ثم "المدفوع الآن".
    credit_applied = min(available_credit, total)
    paid = data.get("paid_amount") or Decimal(0)
    if paid < 0:
        raise fail("المبلغ المدفوع لا يمكن أن يكون سالباً.")
    if paid > total - credit_applied:
        if credit_applied > 0:
            raise fail("المبلغ المدفوع أكبر من المتبقي بعد الخصم من رصيد المذخر السابق.")
        raise fail("المبلغ المدفوع أكبر من إجمالي الفاتورة.")
    purchase_invoice.total_amount = total
    purchase_invoice.paid_amount = stock.to_money(paid)
    purchase_invoice.item_count = len(received)
    purchase_invoice.save(update_fields=["total_amount", "paid_amount", "item_count", "updated_at"])
    supplier_ledger.apply_credit(supplier, purchase_invoice, credit_applied, supplier_ledger.CREDIT_NOTE_PREVIOUS)
    if paid > 0:
        SupplierPayment.objects.create(
            pharmacy=pharmacy,
            supplier=supplier,
            purchase_invoice=purchase_invoice,
            amount_paid=stock.to_money(paid),
            notes="دفعة عند استلام القائمة",
        )
    return purchase_invoice, _distinct_medicines(received)


def create_opening_stock(pharmacy, license, data):
    """رصيد افتتاحي: نفس الأسطر بلا مذخر/فاتورة/دفعة. يرجع الأصناف المتأثرة."""
    warehouse = resolve_warehouse(pharmacy, license, data.get("warehouse"))
    received = _receive_lines(pharmacy, warehouse, data["items"], MODE_OPENING_STOCK)
    return _distinct_medicines(received)


def _distinct_medicines(received):
    seen = {}
    for medicine, *_ in received:
        seen[medicine.pk] = medicine
    return list(seen.values())


def invoice_items(invoice):
    """أصناف فاتورة مع المسترجع من كل سطر ومخزون صنفه الحالي (لنافذة الأصناف والاسترجاع)."""
    return (
        invoice.items.select_related("purchase_invoice", "medicine")
        .annotate(returned_quantity_total=Coalesce(Sum("return_items__quantity"), 0))
        .order_by("id")
    )


def supplier_purchased_items(supplier):
    """أصناف اشتُريت من مذخر (لكشف الحساب): أحدث الفواتير أولاً."""
    return (
        PurchaseInvoiceItem.objects.filter(purchase_invoice__supplier=supplier)
        .select_related("purchase_invoice")
        .order_by("-purchase_invoice__created_at", "id")
    )

