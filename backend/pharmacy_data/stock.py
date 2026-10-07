"""
منطق المخزون الموحّد على الخادم: متوسط الكلفة المرجّح + دفعات الصلاحية المخفية.

القاعدة الثابتة: Medicine.quantity = مجموع كميات MedicineBatch، وMedicine.expiry_date
= أقرب انتهاء بين الدفعات المتوفرة. كل عملية تغيّر المخزون (توريد، بيع، إرجاع،
إتلاف، نقل) تمر من هنا، ويجب استدعاؤها داخل transaction.atomic() على صف دواء
مقفول بـ select_for_update(). نفس المنطق حرفياً في DatabaseHelper (Flutter).
"""

from decimal import ROUND_HALF_UP, Decimal

from django.db.models import Case, F, IntegerField, Min, Q, Sum, Value, When
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from .models import Medicine, MedicineBatch

COST_PLACES = Decimal("0.0001")
MONEY_PLACES = Decimal("0.01")


def to_cost(value):
    return None if value is None else Decimal(value).quantize(COST_PLACES, rounding=ROUND_HALF_UP)


def to_money(value):
    return Decimal(value).quantize(MONEY_PLACES, rounding=ROUND_HALF_UP)


def weighted_avg_cost(old_qty, old_avg, new_qty, new_cost):
    """
    if old_qty <= 0 or avg_cost is null: avg = new_cost
    else: avg = (old_qty*avg + new_qty*new_cost) / (old_qty+new_qty)
    """
    new_cost = Decimal(new_cost)
    if old_qty <= 0 or old_avg is None:
        return to_cost(new_cost)
    total = Decimal(old_qty) * Decimal(old_avg) + Decimal(new_qty) * new_cost
    return to_cost(total / Decimal(old_qty + new_qty))


def avg_cost_after_return(old_qty, old_avg, returned_qty, cost_removed):
    """
    avg_cost بعد استرجاع لمذخر: الوحدات المسترجعة تخرج بمبلغ رصيدها
    (cost_removed = الوحدات المحسوبة × سعر الاسترجاع؛ البونص/المجاني = 0)،
    فيبقى على الباقي ما دُفع فعلاً صافياً من الأرصدة.
    if old_qty - returned_qty <= 0 or avg_cost is null: avg لا يتغير
    else: avg = max(0, (old_qty*avg - cost_removed) / (old_qty - returned_qty))
    """
    left = old_qty - returned_qty
    if left <= 0 or old_avg is None:
        return old_avg
    value = (Decimal(old_qty) * Decimal(old_avg) - Decimal(cost_removed)) / Decimal(left)
    return to_cost(max(value, Decimal(0)))


def effective_unit_cost(paid_qty, bonus_qty, buy_price):
    """
    كلفة الوحدة الفعلية لسطر فيه بونص: (المدفوع × سعر الشراء) / (المدفوع + البونص).
    سطر مجاني بالكامل (paid_qty == 0) كلفته 0 معروفة، لا NULL.
    مثال: 10 × 1000 + 2 بونص = 833.3333.
    """
    total = paid_qty + bonus_qty
    if total <= 0:
        raise ValidationError("الكمية يجب أن تكون أكبر من صفر.")
    if paid_qty == 0:
        return to_cost(0)
    return to_cost(Decimal(paid_qty) * Decimal(buy_price) / Decimal(total))


def line_total(paid_qty, buy_price):
    """إجمالي سطر قائمة المذخر: المدفوع فقط — البونص لا يدخل الإجمالي ولا دين المذخر."""
    return to_money(Decimal(paid_qty) * Decimal(buy_price or 0))


def refresh_stock(medicine):
    """يعيد ضبط quantity وexpiry_date المشتقّين من الدفعات."""
    agg = medicine.batches.filter(quantity__gt=0).aggregate(total=Sum("quantity"), nearest=Min("expiry_date"))
    medicine.quantity = agg["total"] or 0
    if agg["total"]:
        medicine.expiry_date = agg["nearest"]
    Medicine.objects.filter(pk=medicine.pk).update(quantity=medicine.quantity, expiry_date=medicine.expiry_date)


def reconcile(medicine):
    """
    دواء كميته أكبر من مجموع دفعاته (أُنشئ/عُدِّل خارج هذه الوحدة، مثلاً من
    لوحة الأدمن) يُعطى دفعة بالفرق وبصلاحيته الحالية، كي لا تُفقد كمية.
    """
    covered = medicine.batches.aggregate(total=Sum("quantity"))["total"] or 0
    if medicine.quantity > covered:
        MedicineBatch.objects.create(
            pharmacy_id=medicine.pharmacy_id,
            medicine=medicine,
            quantity=medicine.quantity - covered,
            expiry_date=medicine.expiry_date,
            purchase_price=medicine.avg_cost,
        )


def add_batch(medicine, quantity, expiry_date, purchase_price, *, source="", supplier=None, purchase_invoice=None):
    batch = MedicineBatch.objects.create(
        pharmacy_id=medicine.pharmacy_id,
        medicine=medicine,
        quantity=quantity,
        expiry_date=expiry_date,
        purchase_price=to_cost(purchase_price),
        source=source,
        supplier=supplier,
        purchase_invoice=purchase_invoice,
    )
    refresh_stock(medicine)
    return batch


def create_initial_batch(medicine):
    """دواء جديد: avg_cost من سعر الشراء (إن كان > 0) ودفعة بكميته الأولية."""
    if medicine.avg_cost is None and medicine.buy_price and medicine.buy_price > 0:
        medicine.avg_cost = to_cost(medicine.buy_price)
        Medicine.objects.filter(pk=medicine.pk).update(avg_cost=medicine.avg_cost)
    if medicine.quantity > 0:
        MedicineBatch.objects.create(
            pharmacy_id=medicine.pharmacy_id,
            medicine=medicine,
            quantity=medicine.quantity,
            expiry_date=medicine.expiry_date,
            purchase_price=medicine.avg_cost,
        )


def supply(
    medicine,
    quantity,
    expiry_date,
    purchase_price,
    sale_price,
    *,
    bonus_quantity=0,
    allow_unknown_cost=False,
    source="",
    supplier=None,
    purchase_invoice=None,
):
    """
    توريد شحنة: متوسط مرجّح + سعر بيع موحّد جديد + دفعة جديدة.

    quantity = المدفوع، bonus_quantity = المجاني فوقه؛ الدفعة = المجموع بكلفة
    effective_unit_cost. quantity == 0 = سطر مجاني بالكامل: كلفة 0 معروفة تدخل
    المتوسط، وbuy_price الحالي لا يتغير. sale_price=None يُبقي سعر البيع الحالي.
    allow_unknown_cost (الرصيد الافتتاحي بسعر شراء 0): كلفة مجهولة لا ترفض
    التوريد، فالدفعة بلا كلفة ولا يتغير avg_cost. يرجع الدفعة المُنشأة.
    """
    reconcile(medicine)
    total = quantity + bonus_quantity
    if quantity == 0:
        cost = Decimal(0)
    else:
        cost = Decimal(purchase_price) if purchase_price is not None else medicine.avg_cost
    if cost is None and not allow_unknown_cost:
        raise ValidationError("سعر الشراء مطلوب لأن كلفة هذا الصنف غير معروفة بعد.")
    unit_cost = effective_unit_cost(quantity, bonus_quantity, cost) if cost is not None else None
    update_fields = ["updated_at"]
    if unit_cost is not None:
        medicine.avg_cost = weighted_avg_cost(medicine.quantity, medicine.avg_cost, total, unit_cost)
        update_fields.append("avg_cost")
    if quantity > 0 and cost is not None:
        medicine.buy_price = to_money(cost)
        update_fields.append("buy_price")
    if sale_price is not None:
        medicine.sell_price = to_money(sale_price)
        update_fields.append("sell_price")
    medicine.save(update_fields=update_fields)
    return add_batch(
        medicine, total, expiry_date, unit_cost,
        source=source, supplier=supplier, purchase_invoice=purchase_invoice,
    )


def _fefo_batches(medicine, sellable_only, prefer_invoice_id=None):
    qs = medicine.batches.filter(quantity__gt=0).select_for_update()
    if sellable_only:
        today = timezone.localdate()
        qs = qs.filter(Q(expiry_date__isnull=True) | Q(expiry_date__gte=today))
    # الأقرب انتهاءً أولاً؛ الدفعات بلا تاريخ انتهاء أخيراً.
    order = [F("expiry_date").asc(nulls_last=True), "id"]
    if prefer_invoice_id is not None:
        # استرجاع لمذخر: دفعات فاتورته أولاً، ثم باقي الدفعات بنفس ترتيب FEFO.
        order.insert(
            0,
            Case(When(purchase_invoice_id=prefer_invoice_id, then=Value(0)), default=Value(1), output_field=IntegerField()),
        )
    return qs.order_by(*order)


def deduct_fefo(medicine, quantity, *, sellable_only, prefer_invoice_id=None):
    """
    يخصم [quantity] من الدفعات بترتيب FEFO مع التقسيم بين الدفعات، ويحذف
    الدفعات المستنفدة. sellable_only=True (البيع) يتجاهل الدفعات المنتهية.
    prefer_invoice_id (استرجاع لمذخر): دفعات تلك الفاتورة تُخصم أولاً.
    avg_cost لا يتغير (كالبيع والإتلاف).
    يرجع [(expiry_date, purchase_price, taken, origin)] لاستخدامها في النقل؛
    origin = مصدر الدفعة (source/supplier/purchase_invoice) كي يبقى التتبّع بعد النقل.
    """
    reconcile(medicine)
    remaining = quantity
    taken = []
    for batch in _fefo_batches(medicine, sellable_only, prefer_invoice_id):
        if remaining == 0:
            break
        part = min(batch.quantity, remaining)
        origin = {
            "source": batch.source,
            "supplier_id": batch.supplier_id,
            "purchase_invoice_id": batch.purchase_invoice_id,
        }
        taken.append((batch.expiry_date, batch.purchase_price, part, origin))
        remaining -= part
        if part == batch.quantity:
            batch.delete()
        else:
            MedicineBatch.objects.filter(pk=batch.pk).update(quantity=batch.quantity - part)
    if remaining:
        if sellable_only:
            raise ValidationError(f"الكمية الصالحة (غير المنتهية) من {medicine.trade_name} غير كافية.")
        raise ValidationError(f"الكمية المتوفرة من {medicine.trade_name} غير كافية.")
    refresh_stock(medicine)
    return taken


def restore_to_latest(medicine, quantity):
    """إرجاع: الكمية تعود لأبعد دفعة انتهاءً، أو دفعة جديدة إن لم توجد. avg_cost لا يتغير."""
    reconcile(medicine)
    batch = (
        medicine.batches.select_for_update()
        .order_by(F("expiry_date").desc(nulls_last=True), "-id")
        .first()
    )
    if batch is not None:
        MedicineBatch.objects.filter(pk=batch.pk).update(quantity=batch.quantity + quantity)
        refresh_stock(medicine)
    else:
        add_batch(medicine, quantity, medicine.expiry_date, medicine.avg_cost)
