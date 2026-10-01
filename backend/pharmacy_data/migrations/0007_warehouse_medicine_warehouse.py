import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    """
    الخطوة 1 من 3 لتعدد المخازن: إنشاء جدول Warehouse وإضافة Medicine.warehouse
    كعمود اختياري مؤقتاً. التعبئة (0008) وجعل العمود إلزامياً (0009) في ترحيلات
    منفصلة لأن PostgreSQL يرفض ALTER TABLE بعد UPDATE لعمود FK مؤجَّل في نفس
    المعاملة ("pending trigger events").
    """

    dependencies = [
        ('desktop_api', '0004_remove_pharmacylink_desktoplicense_max_warehouses'),
        ('pharmacy_data', '0006_medicine_barcode_per_pharmacy'),
    ]

    operations = [
        migrations.CreateModel(
            name='Warehouse',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=120)),
                ('is_main', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('pharmacy', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='warehouses', to='desktop_api.pharmacy')),
            ],
            options={
                'ordering': ['-is_main', 'id'],
                'constraints': [
                    models.UniqueConstraint(condition=models.Q(('is_main', True)), fields=('pharmacy',), name='one_main_warehouse_per_pharmacy'),
                ],
            },
        ),
        migrations.AddField(
            model_name='medicine',
            name='warehouse',
            field=models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, related_name='medicines', to='pharmacy_data.warehouse'),
        ),
    ]
