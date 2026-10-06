"""
قبل قيد فرادة (pharmacy, supplier, invoice_number): فواتير الشراء القديمة
المكررة بنفس الرقم لنفس المذخر تُعاد تسميتها بإلحاق -2، -3… بترتيب الإنشاء
(الأقدم يحتفظ برقمه). لا يُحذف أي سجل. الرقم الفارغ لا يخضع للقيد.
"""

from django.db import migrations
from django.db.models import Count


def dedupe(apps, schema_editor):
    PurchaseInvoice = apps.get_model("pharmacy_data", "PurchaseInvoice")
    groups = (
        PurchaseInvoice.objects.exclude(invoice_number="")
        .values("pharmacy_id", "supplier_id", "invoice_number")
        .annotate(n=Count("id"))
        .filter(n__gt=1)
    )
    for group in groups:
        taken = set(
            PurchaseInvoice.objects.filter(
                pharmacy_id=group["pharmacy_id"], supplier_id=group["supplier_id"]
            ).values_list("invoice_number", flat=True)
        )
        duplicates = PurchaseInvoice.objects.filter(
            pharmacy_id=group["pharmacy_id"],
            supplier_id=group["supplier_id"],
            invoice_number=group["invoice_number"],
        ).order_by("created_at", "id")[1:]
        suffix = 2
        for invoice in duplicates:
            while f"{group['invoice_number']}-{suffix}" in taken:
                suffix += 1
            new_number = f"{group['invoice_number']}-{suffix}"[:60]
            taken.add(new_number)
            PurchaseInvoice.objects.filter(pk=invoice.pk).update(invoice_number=new_number)


class Migration(migrations.Migration):

    dependencies = [
        ("pharmacy_data", "0012_purchaseinvoiceitem_batch_links"),
    ]

    operations = [
        migrations.RunPython(dedupe, migrations.RunPython.noop),
    ]
