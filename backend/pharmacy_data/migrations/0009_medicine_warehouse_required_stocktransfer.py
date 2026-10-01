import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    """
    الخطوة 3 من 3: Medicine.warehouse إلزامي، فرادة الباركود تصبح لكل مخزن
    (بدل كل صيدلية) كقيد Flutter المحلي، وجدول سجل عمليات النقل.
    """

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('desktop_api', '0004_remove_pharmacylink_desktoplicense_max_warehouses'),
        ('pharmacy_data', '0008_backfill_main_warehouses'),
    ]

    operations = [
        migrations.AlterField(
            model_name='medicine',
            name='warehouse',
            field=models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='medicines', to='pharmacy_data.warehouse'),
        ),
        migrations.RemoveConstraint(
            model_name='medicine',
            name='unique_medicine_barcode_per_pharmacy',
        ),
        migrations.AddConstraint(
            model_name='medicine',
            constraint=models.UniqueConstraint(condition=models.Q(('barcode__isnull', False), models.Q(('barcode', ''), _negated=True)), fields=('warehouse', 'barcode'), name='unique_medicine_barcode_per_warehouse'),
        ),
        migrations.CreateModel(
            name='StockTransfer',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('trade_name', models.CharField(max_length=200)),
                ('barcode', models.CharField(blank=True, max_length=64, null=True)),
                ('quantity', models.PositiveIntegerField()),
                ('notes', models.CharField(blank=True, default='', max_length=255)),
                ('from_warehouse_name', models.CharField(blank=True, default='', max_length=120)),
                ('to_warehouse_name', models.CharField(blank=True, default='', max_length=120)),
                ('transferred_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('from_warehouse', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='transfers_out', to='pharmacy_data.warehouse')),
                ('pharmacy', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='stock_transfers', to='desktop_api.pharmacy')),
                ('to_warehouse', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='transfers_in', to='pharmacy_data.warehouse')),
                ('transferred_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='stock_transfers', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-transferred_at', '-id'],
                'indexes': [models.Index(fields=['pharmacy', 'transferred_at'], name='pharmacy_da_pharmac_35b68e_idx')],
                'constraints': [
                    models.CheckConstraint(condition=models.Q(('quantity__gt', 0)), name='stock_transfer_quantity_gt_0'),
                    models.CheckConstraint(condition=models.Q(('from_warehouse', models.F('to_warehouse')), _negated=True), name='stock_transfer_distinct_warehouses'),
                ],
            },
        ),
    ]
