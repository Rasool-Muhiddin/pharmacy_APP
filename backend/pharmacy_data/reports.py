"""
التقارير التحليلية للمالك (ReportsViewSet). نفس الصيغ حرفياً في
lib/services/reports_local_service.dart (Flutter أوفلاين)، ويتحقق من تطابقهما
test/fixtures/reports_parity.json في مجموعتي الاختبار.

قواعد مشتركة:
  - الفترة [start, end] أيام كاملة شاملة بتوقيت Asia/Baghdad (TIME_ZONE).
  - الفواتير المسترجعة مستبعدة من المبيعات والربح.
  - صافي السطر = إجمالي السطر − حصته من خصم فاتورته (الخصم × إجمالي السطر ÷ إجمالي الفاتورة).
  - الربح الإجمالي = Σ(صافي السطر − كلفته) للأسطر ذات الكلفة المعروفة فقط؛
    الأسطر بلا unit_cost تُعدّ في items_without_cost.
  - كلفة الإتلاف = total_cost المسجّلة، وإلا الكمية × (avg_cost ثم buy_price).
    سجلات "تصحيح إدخال" (correction) ليست خسارة.
  - قيمة المخزون/المنتهي = كمية الدفعة × (كلفة الدفعة ثم avg_cost ثم buy_price).
  - صافي الربح يطرح الخسائر المسجّلة فقط (المصاريف + الإتلاف). المنتهي غير
    المسجّل كتالف يُعرض منفصلاً ولا يُخصم، كي لا تتغير الفترات المغلقة لاحقاً.
"""

from datetime import datetime, time, timedelta
from decimal import Decimal

from django.db.models import (
    Case,
    CharField,
    Count,
    DecimalField,
    ExpressionWrapper,
    F,
    FloatField,
    Max,
    OuterRef,
    Q,
    Subquery,
    Sum,
    Value,
    When,
)
from django.db.models.functions import Cast, Coalesce, Concat, ExtractHour, NullIf, Trim, TruncDate
from django.utils import timezone

from . import stock, supplier_ledger
from .models import (
    DamagedMedicine,
    Expense,
    Invoice,
    InvoiceItem,
    Medicine,
    MedicineBatch,
    PurchaseInvoice,
    PurchaseInvoiceReturn,
    Supplier,
    SupplierPayment,
    SupplierRefund,
)

# نفس kLowStockThreshold في Flutter (db_helper.dart).
LOW_STOCK_THRESHOLD = 10
EXPIRY_ALERT_DAYS = 30
TOP_ITEMS_LIMIT = 20
TOP_DEBTORS_LIMIT = 10
DEFAULT_PAGE_SIZE = 50
MAX_PAGE_SIZE = 200
UNKNOWN_SELLER = "بائع غير محدد"

ZERO = Decimal("0")
FLOAT = FloatField()
VALUE = DecimalField(max_digits=20, decimal_places=4)


def money(value):
    """تقريب لخانتين (Decimal أو float أو None)."""
    if value is None:
        return stock.to_money(ZERO)
    if isinstance(value, float):
        value = Decimal(repr(value))
    return stock.to_money(value)


def _f(name):
    # حساب حصة الخصم بالقسمة يتم بالأعداد العشرية (float) لا Decimal: في SQLite
    # تُخزَّن 1000.00 عدداً صحيحاً فتصبح القسمة صحيحة مقطوعة. نفس double في Dart.
    return Cast(name, FLOAT)


# حصة السطر من خصم فاتورته، وصافيه، وكلفته.
LINE_DISCOUNT = Case(
    When(invoice__total_amount__gt=0,
         then=_f("invoice__discount") * _f("total_price") / _f("invoice__total_amount")),
    default=Value(0.0),
    output_field=FLOAT,
)
LINE_NET = ExpressionWrapper(_f("total_price") - LINE_DISCOUNT, output_field=FLOAT)
LINE_COST = ExpressionWrapper(_f("unit_cost") * _f("quantity"), output_field=FLOAT)
COSTED = Q(unit_cost__isnull=False)
UNCOSTED = Q(unit_cost__isnull=True)

# كلفة سجل إتلاف وقيمة دفعة (نفس قاعدة الكلفة في كل التقارير).
DAMAGE_COST = Coalesce(
    "total_cost",
    ExpressionWrapper(F("quantity_damaged") * Coalesce("medicine__avg_cost", "medicine__buy_price"), output_field=VALUE),
    output_field=VALUE,
)
BATCH_VALUE = ExpressionWrapper(
    F("quantity") * Coalesce("purchase_price", "medicine__avg_cost", "medicine__buy_price", output_field=VALUE),
    output_field=VALUE,
)
MEDICINE_COST = Coalesce("avg_cost", "buy_price", output_field=VALUE)

# اسم البائع: نفس shifts (get_full_name ثم username، وإلا cashier_name المرحَّل).
SELLER_NAME = Case(
    When(
        cashier__isnull=False,
        then=Coalesce(
            NullIf(Trim(Concat("cashier__first_name", Value(" "), "cashier__last_name")), Value("")),
            "cashier__username",
        ),
    ),
    default=Coalesce(NullIf("cashier_name", Value("")), Value(UNKNOWN_SELLER)),
    output_field=CharField(),
)


# ---------------------------------------------------------------------------
# الفترات
# ---------------------------------------------------------------------------

def today():
    return timezone.localdate()


def day_bounds(start, end):
    """[بداية يوم start, بداية اليوم التالي لـ end) بالتوقيت المحلي — يستخدم فهرس created_at."""
    tz = timezone.get_current_timezone()
    lo = timezone.make_aware(datetime.combine(start, time.min), tz)
    hi = timezone.make_aware(datetime.combine(end + timedelta(days=1), time.min), tz)
    return lo, hi


def previous_period(start, end):
    """الفترة السابقة بنفس الطول مباشرة قبل start."""
    prev_end = start - timedelta(days=1)
    return prev_end - (end - start), prev_end


def bucket_kind(start, end):
    days = (end - start).days + 1
    if days < 60:
        return "day"
    if days <= 180:
        return "week"
    return "month"


def bucket_key(day, start, kind):
    if kind == "day":
        return day
    if kind == "week":
        return start + timedelta(days=((day - start).days // 7) * 7)
    return max(day.replace(day=1), start)


def bucket_keys(start, end, kind):
    keys, day = [], start
    while day <= end:
        key = bucket_key(day, start, kind)
        if not keys or keys[-1] != key:
            keys.append(key)
        day += timedelta(days=1)
    return keys


def page_params(params):
    try:
        page = max(1, int(params.get("page") or 1))
        size = int(params.get("page_size") or DEFAULT_PAGE_SIZE)
    except ValueError:
        page, size = 1, DEFAULT_PAGE_SIZE
    return page, min(max(1, size), MAX_PAGE_SIZE)


def paginate(qs, page, size):
    count = qs.count()
    offset = (page - 1) * size
    return count, list(qs[offset:offset + size])


def local_iso(dt):
    """وقت الفاتورة بالتوقيت المحلي بلا كسور ثوانٍ (نفس صيغة العرض في Flutter)."""
    return timezone.localtime(dt).replace(microsecond=0).isoformat() if dt else None


# ---------------------------------------------------------------------------
# الاستعلامات الأساسية
# ---------------------------------------------------------------------------

def period_invoices(pharmacy, start, end, refunded=False):
    lo, hi = day_bounds(start, end)
    return Invoice.objects.filter(pharmacy=pharmacy, is_refunded=refunded, created_at__gte=lo, created_at__lt=hi)


def period_items(pharmacy, start, end):
    lo, hi = day_bounds(start, end)
    return InvoiceItem.objects.filter(
        invoice__pharmacy=pharmacy, invoice__is_refunded=False,
        invoice__created_at__gte=lo, invoice__created_at__lt=hi,
    )


def period_damage(pharmacy, start, end):
    return DamagedMedicine.objects.filter(
        pharmacy=pharmacy, damaged_at__gte=start, damaged_at__lte=end
    ).exclude(reason="correction")


def stock_batches(pharmacy):
    return MedicineBatch.objects.filter(pharmacy=pharmacy, medicine__is_damaged=False, quantity__gt=0)


def profit_figures(pharmacy, start, end):
    """revenue, cost_of_goods_sold, gross_profit, items_without_cost (+ uncosted_revenue)."""
    revenue = period_invoices(pharmacy, start, end).aggregate(t=Sum("final_amount"))["t"]
    lines = period_items(pharmacy, start, end).aggregate(
        costed_net=Sum(LINE_NET, filter=COSTED),
        uncosted_net=Sum(LINE_NET, filter=UNCOSTED),
        cogs=Sum(LINE_COST, filter=COSTED),
        missing=Count("id", filter=UNCOSTED),
    )
    cogs = lines["cogs"] or 0.0
    return {
        "revenue": money(revenue),
        "cost_of_goods_sold": money(cogs),
        "gross_profit": money((lines["costed_net"] or 0.0) - cogs),
        "uncosted_revenue": money(lines["uncosted_net"]),
        "items_without_cost": lines["missing"],
    }


def expenses_total(pharmacy, start, end):
    return money(
        Expense.objects.filter(pharmacy=pharmacy, expense_date__gte=start, expense_date__lte=end)
        .aggregate(t=Sum("amount"))["t"]
    )


def damage_total(pharmacy, start, end):
    return money(period_damage(pharmacy, start, end).aggregate(t=Sum(DAMAGE_COST))["t"])


def period_figures(pharmacy, start, end):
    sales = period_invoices(pharmacy, start, end).aggregate(
        gross_sales=Sum("total_amount"),
        discounts=Sum("discount"),
        invoices_count=Count("id"),
        discounted_invoices_count=Count("id", filter=Q(discount__gt=0)),
    )
    refunded = period_invoices(pharmacy, start, end, refunded=True).aggregate(
        count=Count("id"), value=Sum("final_amount")
    )
    profit = profit_figures(pharmacy, start, end)
    expenses = expenses_total(pharmacy, start, end)
    damage = damage_total(pharmacy, start, end)
    return {
        "gross_sales": money(sales["gross_sales"]),
        "discounts": money(sales["discounts"]),
        "net_sales": profit["revenue"],
        "invoices_count": sales["invoices_count"],
        "discounted_invoices_count": sales["discounted_invoices_count"],
        "refunded_count": refunded["count"],
        "refunded_value": money(refunded["value"]),
        "cost_of_goods_sold": profit["cost_of_goods_sold"],
        "gross_profit": profit["gross_profit"],
        "uncosted_revenue": profit["uncosted_revenue"],
        "items_without_cost": profit["items_without_cost"],
        "expenses": expenses,
        "damage_cost": damage,
        "net_profit": money(profit["gross_profit"] - expenses - damage),
    }


def _expiry_figures(batches):
    agg = batches.aggregate(count=Count("medicine_id", distinct=True), value=Sum(BATCH_VALUE))
    return agg["count"], money(agg["value"])


def below_cost_medicines(pharmacy):
    return (
        Medicine.objects.filter(pharmacy=pharmacy, is_damaged=False, quantity__gt=0)
        .annotate(cost=MEDICINE_COST)
        .filter(cost__gt=0, sell_price__lt=F("cost"))
    )


def alerts(pharmacy):
    day = today()
    batches = stock_batches(pharmacy)
    expiring_count, expiring_value = _expiry_figures(
        batches.filter(expiry_date__gte=day, expiry_date__lte=day + timedelta(days=EXPIRY_ALERT_DAYS))
    )
    expired_count, expired_value = _expiry_figures(batches.filter(expiry_date__lt=day))
    medicines = Medicine.objects.filter(pharmacy=pharmacy, is_damaged=False)
    return {
        "below_cost_count": below_cost_medicines(pharmacy).count(),
        "expiring_days": EXPIRY_ALERT_DAYS,
        "expiring_count": expiring_count,
        "expiring_value": expiring_value,
        "expired_count": expired_count,
        "expired_value": expired_value,
        "low_stock_count": medicines.filter(quantity__lte=LOW_STOCK_THRESHOLD).count(),
        "out_of_stock_count": medicines.filter(quantity__lte=0).count(),
    }


# ---------------------------------------------------------------------------
# الأقسام
# ---------------------------------------------------------------------------

def kpis(pharmacy, start, end):
    prev_start, prev_end = previous_period(start, end)
    return {
        "start": start.isoformat(),
        "end": end.isoformat(),
        "previous_start": prev_start.isoformat(),
        "previous_end": prev_end.isoformat(),
        "current": period_figures(pharmacy, start, end),
        "previous": period_figures(pharmacy, prev_start, prev_end),
        "alerts": alerts(pharmacy),
    }


def trend(pharmacy, start, end):
    kind = bucket_kind(start, end)
    keys = bucket_keys(start, end, kind)
    points = {key: {"net_sales": 0.0, "gross_profit": 0.0} for key in keys}

    sales = (
        period_invoices(pharmacy, start, end)
        .annotate(day=TruncDate("created_at"))
        .values("day")
        .annotate(net=Sum("final_amount"))
    )
    for row in sales:
        points[bucket_key(row["day"], start, kind)]["net_sales"] += float(row["net"] or 0)

    lines = (
        period_items(pharmacy, start, end)
        .annotate(day=TruncDate("invoice__created_at"))
        .values("day")
        .annotate(net=Sum(LINE_NET, filter=COSTED), cost=Sum(LINE_COST, filter=COSTED))
    )
    for row in lines:
        points[bucket_key(row["day"], start, kind)]["gross_profit"] += (row["net"] or 0.0) - (row["cost"] or 0.0)

    return {
        "bucket": kind,
        "points": [
            {"key": key.isoformat(), "net_sales": money(points[key]["net_sales"]),
             "gross_profit": money(points[key]["gross_profit"])}
            for key in keys
        ],
    }


def categories(pharmacy, start, end):
    rows = (
        period_items(pharmacy, start, end)
        .values(category=F("medicine__category"))
        .annotate(net=Sum(LINE_NET), quantity=Sum("quantity"))
    )
    merged = {}
    for row in rows:
        key = (row["category"] or "").strip()
        bucket = merged.setdefault(key, {"category": key, "net_sales": 0.0, "quantity": 0})
        bucket["net_sales"] += row["net"] or 0.0
        bucket["quantity"] += row["quantity"] or 0
    result = [{**b, "net_sales": money(b["net_sales"])} for b in merged.values()]
    result.sort(key=lambda b: (-b["net_sales"], b["category"]))
    return {"categories": result}


def hours(pharmacy, start, end):
    rows = (
        period_invoices(pharmacy, start, end)
        .annotate(hour=ExtractHour("created_at"))
        .values("hour")
        .annotate(count=Count("id"), net=Sum("final_amount"))
    )
    by_hour = {row["hour"]: row for row in rows}
    return {
        "hours": [
            {"hour": h, "invoices_count": by_hour[h]["count"] if h in by_hour else 0,
             "net_sales": money(by_hour[h]["net"] if h in by_hour else None)}
            for h in range(24)
        ]
    }


ITEM_SORTS = {"qty": "qty", "revenue": "revenue", "profit": "profit"}


def items(pharmacy, start, end, sort="qty"):
    order = ITEM_SORTS.get(sort, "qty")
    rows = (
        period_items(pharmacy, start, end)
        .values("medicine_id")
        .annotate(
            # أسماء التجميعات تختلف عن أسماء الحقول (quantity/…) حتى لا تحجبها داخل LINE_COST.
            name=Max("medicine__trade_name"),
            qty=Sum("quantity"),
            revenue=Sum(LINE_NET),
            costed_revenue=Coalesce(Sum(LINE_NET, filter=COSTED), Value(0.0), output_field=FLOAT),
            line_cost=Coalesce(Sum(LINE_COST, filter=COSTED), Value(0.0), output_field=FLOAT),
            uncosted_qty=Coalesce(Sum("quantity", filter=UNCOSTED), Value(0)),
        )
        .annotate(profit=ExpressionWrapper(F("costed_revenue") - F("line_cost"), output_field=FLOAT))
        .order_by(f"-{order}", "name", "medicine_id")[:TOP_ITEMS_LIMIT]
    )
    top = [
        {
            "medicine_id": row["medicine_id"],
            "trade_name": row["name"],
            "quantity": row["qty"],
            "revenue": money(row["revenue"]),
            "costed_revenue": money(row["costed_revenue"]),
            "cost": money(row["line_cost"]),
            "profit": money(row["profit"]),
            "uncosted_quantity": row["uncosted_qty"],
        }
        for row in rows
    ]
    below = [
        {
            "medicine_id": m.id,
            "trade_name": m.trade_name,
            "quantity": m.quantity,
            "cost": money(m.cost),
            "sell_price": money(m.sell_price),
            "loss_per_unit": money(m.cost - m.sell_price),
        }
        for m in below_cost_medicines(pharmacy).annotate(loss=F("cost") - F("sell_price")).order_by("-loss", "trade_name", "id")
    ]
    return {"sort": sort if sort in ITEM_SORTS else "qty", "items": top, "below_cost": below}


def stagnant(pharmacy, start, end, page=1, page_size=DEFAULT_PAGE_SIZE):
    sold_ids = period_items(pharmacy, start, end).values("medicine_id")
    batch_value = (
        MedicineBatch.objects.filter(medicine_id=OuterRef("pk"), quantity__gt=0)
        .order_by()
        .values("medicine_id")
        .annotate(t=Sum(BATCH_VALUE))
        .values("t")
    )
    last_sale = (
        InvoiceItem.objects.filter(medicine_id=OuterRef("pk"), invoice__is_refunded=False)
        .order_by()
        .values("medicine_id")
        .annotate(t=Max("invoice__created_at"))
        .values("t")
    )
    qs = (
        Medicine.objects.filter(pharmacy=pharmacy, is_damaged=False, quantity__gt=0)
        .exclude(id__in=sold_ids)
        .annotate(
            stock_value=Coalesce(Subquery(batch_value, output_field=VALUE), Value(ZERO), output_field=VALUE),
            last_sale=Subquery(last_sale),
        )
        .order_by("-stock_value", "trade_name", "id")
    )
    total_value = stock_batches(pharmacy).filter(medicine__in=qs.values("pk")).aggregate(t=Sum(BATCH_VALUE))["t"]
    count, rows = paginate(qs, page, page_size)
    return {
        "count": count,
        "page": page,
        "page_size": page_size,
        "total_value": money(total_value),
        "results": [
            {
                "medicine_id": m.id,
                "trade_name": m.trade_name,
                "category": m.category or "",
                "quantity": m.quantity,
                "stock_value": money(m.stock_value),
                "last_sale": timezone.localtime(m.last_sale).date().isoformat() if m.last_sale else None,
            }
            for m in rows
        ],
    }


def _batch_rows(batches):
    rows = (
        batches.annotate(value=BATCH_VALUE)
        .select_related("medicine", "supplier")
        .order_by("expiry_date", "medicine__trade_name", "id")
    )
    return [
        {
            "medicine_id": b.medicine_id,
            "batch_id": b.id,
            "trade_name": b.medicine.trade_name,
            "expiry_date": b.expiry_date.isoformat(),
            "quantity": b.quantity,
            "value": money(b.value),
            "supplier_name": b.supplier.name if b.supplier_id else "",
        }
        for b in rows
    ]


def inventory(pharmacy, days=EXPIRY_ALERT_DAYS):
    day = today()
    batches = stock_batches(pharmacy)
    cost_value = money(batches.aggregate(t=Sum(BATCH_VALUE))["t"])
    medicines = Medicine.objects.filter(pharmacy=pharmacy, is_damaged=False)
    sell_value = money(
        medicines.filter(quantity__gt=0).aggregate(
            t=Sum(ExpressionWrapper(F("quantity") * F("sell_price"), output_field=VALUE))
        )["t"]
    )
    expiring = _batch_rows(batches.filter(expiry_date__gte=day, expiry_date__lte=day + timedelta(days=days)))
    expired = _batch_rows(batches.filter(expiry_date__lt=day))
    low = medicines.filter(quantity__lte=LOW_STOCK_THRESHOLD).order_by("quantity", "trade_name", "id")
    return {
        "today": day.isoformat(),
        "days": days,
        "stock_cost_value": cost_value,
        "stock_sell_value": sell_value,
        "expected_profit": money(sell_value - cost_value),
        "expiring": expiring,
        "expiring_value": money(sum((r["value"] for r in expiring), ZERO)),
        "expired": expired,
        "expired_value": money(sum((r["value"] for r in expired), ZERO)),
        "low_stock_threshold": LOW_STOCK_THRESHOLD,
        "low_stock": [
            {"medicine_id": m.id, "trade_name": m.trade_name, "quantity": m.quantity,
             "category": m.category or "", "sell_price": money(m.sell_price)}
            for m in low
        ],
    }


def purchases(pharmacy, start, end):
    lo, hi = day_bounds(start, end)
    invoices = PurchaseInvoice.objects.filter(pharmacy=pharmacy, created_at__gte=lo, created_at__lt=hi)
    returns = PurchaseInvoiceReturn.objects.filter(pharmacy=pharmacy, returned_at__gte=lo, returned_at__lt=hi)
    totals = invoices.aggregate(total=Sum("total_amount"), count=Count("id"))

    by_supplier = {}
    for row in invoices.values("supplier_id", "supplier__name").annotate(total=Sum("total_amount"), count=Count("id")):
        by_supplier[row["supplier_id"]] = {
            "supplier_id": row["supplier_id"], "name": row["supplier__name"],
            "invoices_count": row["count"], "total": money(row["total"]), "returns": money(ZERO),
        }
    for row in returns.values("supplier_id", "supplier__name").annotate(total=Sum("amount_returned")):
        entry = by_supplier.setdefault(row["supplier_id"], {
            "supplier_id": row["supplier_id"], "name": row["supplier__name"],
            "invoices_count": 0, "total": money(ZERO), "returns": money(ZERO),
        })
        entry["returns"] = money(row["total"])

    suppliers = dict(Supplier.objects.filter(pharmacy=pharmacy).values_list("id", "name"))
    figures = supplier_ledger.supplier_figures(suppliers.keys())
    debtors = sorted(
        ({"supplier_id": sid, "name": suppliers[sid], "debt": money(f["debt"])} for sid, f in figures.items() if f["debt"] > 0),
        key=lambda r: (-r["debt"], r["name"], r["supplier_id"]),
    )
    return {
        "purchases_total": money(totals["total"]),
        "invoices_count": totals["count"],
        "returns_total": money(returns.aggregate(t=Sum("amount_returned"))["t"]),
        "payments_total": money(
            SupplierPayment.objects.filter(pharmacy=pharmacy, paid_at__gte=lo, paid_at__lt=hi).aggregate(t=Sum("amount_paid"))["t"]
        ),
        "refunds_received": money(
            SupplierRefund.objects.filter(pharmacy=pharmacy, received_at__gte=lo, received_at__lt=hi).aggregate(t=Sum("amount"))["t"]
        ),
        "by_supplier": sorted(by_supplier.values(), key=lambda r: (-r["total"], r["name"], r["supplier_id"])),
        "total_debt": money(sum((f["debt"] for f in figures.values()), ZERO)),
        "total_credit": money(sum((f["credit"] for f in figures.values()), ZERO)),
        "top_debtors": debtors[:TOP_DEBTORS_LIMIT],
    }


def losses(pharmacy, start, end):
    expenses = (
        Expense.objects.filter(pharmacy=pharmacy, expense_date__gte=start, expense_date__lte=end)
        .values("expense_type")
        .annotate(total=Sum("amount"), count=Count("id"))
    )
    damage = period_damage(pharmacy, start, end).values("reason").annotate(
        total=Sum(DAMAGE_COST), quantity=Sum("quantity_damaged"), count=Count("id")
    )
    by_type = sorted(
        ({"type": r["expense_type"], "total": money(r["total"]), "count": r["count"]} for r in expenses),
        key=lambda r: (-r["total"], r["type"]),
    )
    by_reason = sorted(
        ({"reason": r["reason"] or "", "total": money(r["total"]), "quantity": r["quantity"], "count": r["count"]} for r in damage),
        key=lambda r: (-r["total"], r["reason"]),
    )
    _, expired_value = _expiry_figures(stock_batches(pharmacy).filter(expiry_date__lt=today()))
    return {
        "expenses_total": money(sum((r["total"] for r in by_type), ZERO)),
        "expenses_by_type": by_type,
        "damage_total": money(sum((r["total"] for r in by_reason), ZERO)),
        "damage_by_reason": by_reason,
        "expired_recorded": money(sum((r["total"] for r in by_reason if r["reason"] == "expired"), ZERO)),
        "expired_not_disposed_value": expired_value,
    }


def invoices(pharmacy, start, end, *, page=1, page_size=DEFAULT_PAGE_SIZE, q="", seller="", refunded=False):
    qs = period_invoices(pharmacy, start, end, refunded=refunded).annotate(seller_name=SELLER_NAME)
    if q:
        qs = qs.filter(invoice_number__icontains=q)
    if seller:
        qs = qs.filter(seller_name=seller)
    totals = qs.aggregate(t=Sum("final_amount"))
    count, rows = paginate(qs.order_by("-created_at", "-id"), page, page_size)
    return {
        "count": count,
        "page": page,
        "page_size": page_size,
        "total_amount": money(totals["t"]),
        "results": [
            {
                "id": inv.id,
                "invoice_number": inv.invoice_number,
                "created_at": local_iso(inv.created_at),
                "total_amount": money(inv.total_amount),
                "discount": money(inv.discount),
                "final_amount": money(inv.final_amount),
                "seller_name": inv.seller_name,
                "is_refunded": inv.is_refunded,
            }
            for inv in rows
        ],
    }


def sellers(pharmacy, start, end):
    rows = (
        period_invoices(pharmacy, start, end)
        .annotate(seller_name=SELLER_NAME)
        .values("seller_name")
        .annotate(count=Count("id"), net=Sum("final_amount"))
    )
    result = [
        {"seller_name": r["seller_name"], "invoices_count": r["count"], "net_sales": money(r["net"])}
        for r in rows
    ]
    result.sort(key=lambda r: (-r["net_sales"], r["seller_name"]))
    return {"sellers": result}
