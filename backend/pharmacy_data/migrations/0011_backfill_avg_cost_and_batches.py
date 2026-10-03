from django.db import migrations


def backfill(apps, schema_editor):
    """
    avg_cost = buy_price الحالي (سعر 0 يعني "غير معروف" فيبقى NULL بدل
    افتراض كلفة صفرية)، ودفعة واحدة لكل دواء كميته > 0 بكميته وصلاحيته
    الحاليتين. unit_cost للمبيعات السابقة يبقى NULL عمداً (لا تخمين).
    """
    Medicine = apps.get_model("pharmacy_data", "Medicine")
    MedicineBatch = apps.get_model("pharmacy_data", "MedicineBatch")

    for medicine in Medicine.objects.all().iterator():
        cost = medicine.buy_price if medicine.buy_price and medicine.buy_price > 0 else None
        if cost is not None:
            Medicine.objects.filter(pk=medicine.pk).update(avg_cost=cost)
        if medicine.quantity > 0 and not MedicineBatch.objects.filter(medicine_id=medicine.pk).exists():
            MedicineBatch.objects.create(
                pharmacy_id=medicine.pharmacy_id,
                medicine_id=medicine.pk,
                quantity=medicine.quantity,
                expiry_date=medicine.expiry_date,
                purchase_price=cost,
            )


class Migration(migrations.Migration):
    dependencies = [
        ("pharmacy_data", "0010_medicine_cost_and_batches"),
    ]

    operations = [
        migrations.RunPython(backfill, migrations.RunPython.noop),
    ]
