"""
فواتير شراء قديمة متبقيها سالب (استرجاع بالمبلغ أكبر من المتبقي، كان يظهر
"رصيد دائن" على الفاتورة) تُنقل للقواعد الجديدة دون تغيير رصيد أي مذخر:

  - الجزء السالب يصبح excess_credit على أحدث استرجاعات تلك الفاتورة، فيصبح
    متبقيها 0؛
  - ثم يسدّد فواتير المذخر الأخرى المفتوحة (الأقدم أولاً) بسجلات استخدام رصيد،
    والباقي يبقى رصيداً لصالح الصيدلية لدى المذخر.

رصيد المذخر = الفواتير − المدفوع − المرتجع + المستلم: لا يتغير أي حد منها.
لا يُحذف أي سجل. نفس ترقية v12 المحلية (_upgradeToSupplierCredit).
"""

from decimal import Decimal

from django.db import migrations
from django.db.models import F, Sum

NOTE = "تسوية رصيد دائن قديم"


def convert(apps, schema_editor):
    PurchaseInvoice = apps.get_model("pharmacy_data", "PurchaseInvoice")
    PurchaseInvoiceReturn = apps.get_model("pharmacy_data", "PurchaseInvoiceReturn")
    SupplierCreditApplication = apps.get_model("pharmacy_data", "SupplierCreditApplication")

    def remaining(invoice):
        returned = (
            PurchaseInvoiceReturn.objects.filter(purchase_invoice=invoice)
            .aggregate(t=Sum(F("amount_returned") - F("excess_credit")))["t"]
            or Decimal("0")
        )
        applied = SupplierCreditApplication.objects.filter(purchase_invoice=invoice).aggregate(t=Sum("amount"))["t"] or Decimal("0")
        return invoice.total_amount - invoice.paid_amount - returned - applied

    supplier_ids = PurchaseInvoice.objects.values_list("supplier_id", flat=True).distinct()
    for supplier_id in supplier_ids:
        invoices = list(PurchaseInvoice.objects.filter(supplier_id=supplier_id).order_by("created_at", "id"))
        for invoice in invoices:
            need = -remaining(invoice)
            if need <= 0:
                continue
            excess = need
            for ret in PurchaseInvoiceReturn.objects.filter(purchase_invoice=invoice).order_by("-returned_at", "-id"):
                if need <= 0:
                    break
                take = min(need, ret.amount_returned - ret.excess_credit)
                if take > 0:
                    PurchaseInvoiceReturn.objects.filter(pk=ret.pk).update(excess_credit=ret.excess_credit + take)
                    need -= take
            # need > 0 هنا يعني متبقياً سالباً ليس من استرجاع (بيانات شاذة): يُترك كما هو.
            excess -= need
            for other in invoices:
                if excess <= 0:
                    break
                if other.pk == invoice.pk:
                    continue
                open_amount = remaining(other)
                if open_amount > 0:
                    amount = min(excess, open_amount)
                    SupplierCreditApplication.objects.create(
                        pharmacy_id=other.pharmacy_id,
                        supplier_id=supplier_id,
                        purchase_invoice=other,
                        amount=amount,
                        notes=NOTE,
                    )
                    excess -= amount


class Migration(migrations.Migration):

    dependencies = [
        ("pharmacy_data", "0015_supplier_returns_and_credit"),
    ]

    operations = [
        migrations.RunPython(convert, migrations.RunPython.noop),
    ]
