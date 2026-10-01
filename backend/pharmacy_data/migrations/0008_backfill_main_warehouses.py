from django.db import migrations

MAIN_WAREHOUSE_NAME = "المخزن الرئيسي"


def create_main_warehouses(apps, schema_editor):
    """
    الخطوة 2 من 3: مخزن رئيسي لكل صيدلية موجودة، وربط كل الأدوية الحالية به —
    نفس ما يفعله ترحيل Flutter المحلي (onUpgrade v7) لبيانات الأوفلاين.
    """
    Pharmacy = apps.get_model("desktop_api", "Pharmacy")
    Warehouse = apps.get_model("pharmacy_data", "Warehouse")
    Medicine = apps.get_model("pharmacy_data", "Medicine")

    for pharmacy in Pharmacy.objects.all().iterator():
        main = Warehouse.objects.filter(pharmacy=pharmacy, is_main=True).first()
        if main is None:
            main = Warehouse.objects.create(pharmacy=pharmacy, name=MAIN_WAREHOUSE_NAME, is_main=True)
        Medicine.objects.filter(pharmacy=pharmacy, warehouse__isnull=True).update(warehouse=main)


class Migration(migrations.Migration):

    dependencies = [
        ('pharmacy_data', '0007_warehouse_medicine_warehouse'),
    ]

    operations = [
        migrations.RunPython(create_main_warehouses, migrations.RunPython.noop),
    ]
