"""
منطق المخزون الموحّد على الخادم: متوسط الكلفة المرجّح + دفعات الصلاحية المخفية.

القاعدة الثابتة: Medicine.quantity = مجموع كميات MedicineBatch، وMedicine.expiry_date
= أقرب انتهاء بين الدفعات المتوفرة. كل عملية تغيّر المخزون (توريد، بيع، إرجاع،
إتلاف، نقل) تمر من هنا، ويجب استدعاؤها داخل transaction.atomic() على صف دواء
مقفول بـ select_for_update(). نفس المنطق حرفياً في DatabaseHelper (Flutter).
"""

from decimal import ROUND_HALF_UP, Decimal

from django.db.models import F, Min, Q, Sum
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


def add_batch(medicine, quantity, expiry_date, purchase_price):
    batch = MedicineBatch.objects.create(
        pharmacy_id=medicine.pharmacy_id,
        medicine=medicine,
        quantity=quantity,
        expiry_date=expiry_date,
        purchase_price=to_cost(purchase_price),
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


def supply(medicine, quantity, expiry_date, purchase_price, sale_price):
    """توريد شحنة: متوسط مرجّح + سعر بيع موحّد جديد + دفعة جديدة."""
    reconcile(medicine)
    cost = Decimal(purchase_price) if purchase_price is not None else medicine.avg_cost
    if cost is None:
        raise ValidationError("سعر الشراء مطلوب لأن كلفة هذا الصنف غير معروفة بعد.")
    medicine.avg_cost = weighted_avg_cost(medicine.quantity, medicine.avg_cost, quantity, cost)
    medicine.buy_price = to_money(cost)
    medicine.sell_price = to_money(sale_price)
    medicine.save(update_fields=["avg_cost", "buy_price", "sell_price", "updated_at"])
    add_batch(medicine, quantity, expiry_date, cost)
    return medicine


def _fefo_batches(medicine, sellable_only):
    qs = medicine.batches.filter(quantity__gt=0).select_for_update()
    if sellable_only:
        today = timezone.localdate()
        qs = qs.filter(Q(expiry_date__isnull=True) | Q(expiry_date__gte=today))
    # الأقرب انتهاءً أولاً؛ الدفعات بلا تاريخ انتهاء أخيراً.
    return qs.order_by(F("expiry_date").asc(nulls_last=True), "id")


def deduct_fefo(medicine, quantity, *, sellable_only):
    """
    يخصم [quantity] من الدفعات بترتيب FEFO مع التقسيم بين الدفعات، ويحذف
    الدفعات المستنفدة. sellable_only=True (البيع) يتجاهل الدفعات المنتهية.
    يرجع [(expiry_date, purchase_price, taken)] لاستخدامها في النقل.
    """
    reconcile(medicine)
    remaining = quantity
    taken = []
    for batch in _fefo_batches(medicine, sellable_only):
        if remaining == 0:
            break
        part = min(batch.quantity, remaining)
        taken.append((batch.expiry_date, batch.purchase_price, part))
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
