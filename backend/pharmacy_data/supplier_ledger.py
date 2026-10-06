"""
حسابات المذاخر الموحّدة (مصدر واحد للملخص، كشف الحساب، قائمة الفواتير، حدود
الدفع، والتقارير). نفس الصيغ حرفياً في DatabaseHelper (Flutter).

  متبقي الفاتورة  = الإجمالي − المدفوع − (المرتجع − ما ذهب منه لرصيد المذخر)
                     − الرصيد المستخدم لها                  (لا يقل عن 0)
  رصيد المذخر     = الفواتير − المدفوعات − قيمة المرتجعات + المبالغ المستلمة منه
                     (موجب = دين على الصيدلية، سالب = رصيد لصالحها)
  رصيد الصيدلية لديه (bucket) = فائض المرتجعات − الرصيد المستخدم − المبالغ المستلمة

استخدام الرصيد ينقل المال من bucket إلى فاتورة فقط، فلا يغيّر رصيد المذخر.
كشف الحساب: مجموع debt_added لكل الحركات = رصيد المذخر دائماً.
"""

from decimal import Decimal

from django.db.models import DecimalField, F, OuterRef, Subquery, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone

from . import stock
from .models import (
    PurchaseInvoice,
    PurchaseInvoiceReturn,
    Supplier,
    SupplierCreditApplication,
    SupplierPayment,
    SupplierRefund,
)

ZERO = Decimal("0")
MONEY = DecimalField(max_digits=14, decimal_places=2)

CREDIT_NOTE_PREVIOUS = "خصم من رصيد سابق"
CREDIT_NOTE_RETURN = "تسوية من فائض مرتجع"


def _sum_subquery(model, link_field, value_expr):
    qs = (
        model.objects.filter(**{link_field: OuterRef("pk")})
        .order_by()
        .values(link_field)
        .annotate(total=Sum(value_expr))
        .values("total")
    )
    return Coalesce(Subquery(qs, output_field=MONEY), Value(ZERO), output_field=MONEY)


def annotate_invoices(qs):
    """يضيف returned_total, returned_on_invoice, applied_in, linked_paid لكل فاتورة."""
    return qs.annotate(
        returned_total=_sum_subquery(PurchaseInvoiceReturn, "purchase_invoice", "amount_returned"),
        returned_on_invoice=_sum_subquery(
            PurchaseInvoiceReturn, "purchase_invoice", F("amount_returned") - F("excess_credit")
        ),
        applied_in=_sum_subquery(SupplierCreditApplication, "purchase_invoice", "amount"),
        linked_paid=_sum_subquery(SupplierPayment, "purchase_invoice", "amount_paid"),
    )


def remaining_of(invoice):
    """متبقي فاتورة مُعلَّمة بـ annotate_invoices (قد يكون سالباً لبيانات شاذة فقط)."""
    return invoice.total_amount - invoice.paid_amount - invoice.returned_on_invoice - invoice.applied_in


def invoice_remaining(invoice):
    """متبقي فاتورة واحدة (يُعاد حسابه من القاعدة)."""
    return remaining_of(annotate_invoices(PurchaseInvoice.objects.filter(pk=invoice.pk)).get())


def supplier_figures(supplier_ids):
    """
    {supplier_id: {...}} لكل المذاخر المطلوبة: invoice_total, paid, returned,
    excess, applied, refunds, balance, debt, credit, available_credit,
    total_purchases, invoice_count.
    """
    supplier_ids = list(supplier_ids)
    result = {
        sid: {key: ZERO for key in ("invoice_total", "paid", "returned", "excess", "applied", "refunds")}
        | {"invoice_count": 0}
        for sid in supplier_ids
    }

    def add(rows, mapping):
        for row in rows:
            for key, field in mapping.items():
                result[row["sid"]][key] += row[field] or 0

    invoices = (
        PurchaseInvoice.objects.filter(supplier_id__in=supplier_ids)
        .values("supplier_id")
        .annotate(t=Sum("total_amount"), p=Sum("paid_amount"))
    )
    for row in invoices:
        result[row["supplier_id"]]["invoice_total"] += row["t"] or 0
        result[row["supplier_id"]]["paid"] += row["p"] or 0
    for row in PurchaseInvoice.objects.filter(supplier_id__in=supplier_ids).values("supplier_id"):
        result[row["supplier_id"]]["invoice_count"] += 1
    add(
        PurchaseInvoiceReturn.objects.filter(purchase_invoice__supplier_id__in=supplier_ids)
        .values(sid=F("purchase_invoice__supplier_id"))
        .annotate(r=Sum("amount_returned"), x=Sum("excess_credit")),
        {"returned": "r", "excess": "x"},
    )
    add(
        SupplierCreditApplication.objects.filter(supplier_id__in=supplier_ids).values(sid=F("supplier_id")).annotate(a=Sum("amount")),
        {"applied": "a"},
    )
    add(
        SupplierRefund.objects.filter(supplier_id__in=supplier_ids).values(sid=F("supplier_id")).annotate(f=Sum("amount")),
        {"refunds": "f"},
    )

    for figures in result.values():
        balance = figures["invoice_total"] - figures["paid"] - figures["returned"] + figures["refunds"]
        bucket = figures["excess"] - figures["applied"] - figures["refunds"]
        figures["balance"] = balance
        figures["debt"] = max(balance, ZERO)
        figures["credit"] = max(-balance, ZERO)
        figures["available_credit"] = max(ZERO, min(bucket, figures["credit"]))
        figures["total_purchases"] = figures["invoice_total"] - figures["returned"]
    return result


def figures_for(supplier):
    return supplier_figures([supplier.pk])[supplier.pk]


def total_debt(pharmacy):
    """مجموع ديون المذاخر — رصيد مذخر لصالحنا لا يُطرح من دين مذخر آخر."""
    ids = Supplier.objects.filter(pharmacy=pharmacy).values_list("pk", flat=True)
    return sum((f["debt"] for f in supplier_figures(ids).values()), ZERO)


def _open_invoices(supplier, exclude_pk=None):
    qs = PurchaseInvoice.objects.select_for_update().filter(supplier=supplier)
    if exclude_pk is not None:
        qs = qs.exclude(pk=exclude_pk)
    # select_for_update لا يقبل annotate بتجميع على PostgreSQL، فالقفل منفصل.
    locked_ids = list(qs.order_by("created_at", "id").values_list("pk", flat=True))
    invoices = annotate_invoices(PurchaseInvoice.objects.filter(pk__in=locked_ids)).order_by("created_at", "id")
    return [inv for inv in invoices if remaining_of(inv) > 0]


def apply_credit(supplier, invoice, amount, notes, when=None):
    if amount <= 0:
        return ZERO
    amount = stock.to_money(amount)
    SupplierCreditApplication.objects.create(
        pharmacy_id=supplier.pharmacy_id,
        supplier=supplier,
        purchase_invoice=invoice,
        amount=amount,
        notes=notes,
        applied_at=when or timezone.now(),
    )
    return amount


def settle_other_invoices(supplier, amount, exclude_pk, notes=CREDIT_NOTE_RETURN, when=None):
    """
    فائض مرتجع يسدّد فواتير المذخر الأخرى المفتوحة أولاً (الأقدم فالأحدث)،
    والباقي يبقى رصيداً لصالح الصيدلية. يرجع الباقي.
    """
    left = amount
    for invoice in _open_invoices(supplier, exclude_pk):
        if left <= 0:
            break
        left -= apply_credit(supplier, invoice, min(left, remaining_of(invoice)), notes, when)
    return left


def record_return(invoice, credit, notes="", returned_at=None):
    """
    يسجّل استرجاعاً بقيمة [credit] على فاتورة (مقفولة): ما يغطي متبقيها يخفّضه،
    والفائض excess_credit يسدّد فواتير المذخر الأخرى ثم يبقى رصيداً.
    """
    credit = stock.to_money(credit)
    outstanding = max(invoice_remaining(invoice), ZERO)
    excess = max(credit - outstanding, ZERO)
    record = PurchaseInvoiceReturn.objects.create(
        pharmacy_id=invoice.pharmacy_id,
        supplier_id=invoice.supplier_id,
        purchase_invoice=invoice,
        amount_returned=credit,
        excess_credit=excess,
        notes=notes,
        returned_at=returned_at or timezone.now(),
    )
    if excess > 0:
        settle_other_invoices(invoice.supplier, excess, invoice.pk, when=record.returned_at)
    return record


def apply_available_credit(invoice, notes=CREDIT_NOTE_PREVIOUS):
    """رصيد المذخر المتاح يُخصم تلقائياً من فاتورة جديدة حتى إجماليها. يرجع المبلغ المخصوم."""
    available = figures_for(invoice.supplier)["available_credit"]
    amount = min(available, max(invoice_remaining(invoice), ZERO))
    return apply_credit(invoice.supplier, invoice, amount, notes)
