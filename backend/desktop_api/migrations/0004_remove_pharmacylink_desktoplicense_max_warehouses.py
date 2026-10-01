from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('desktop_api', '0003_desktoplicense_plan_pharmacylink'),
    ]

    operations = [
        # خاصية ربط الصيدليات أُزيلت بالكامل (لا endpoint ولا أدمن ولا كاش في التطبيق).
        migrations.DeleteModel(
            name='PharmacyLink',
        ),
        migrations.AddField(
            model_name='desktoplicense',
            name='max_warehouses',
            field=models.PositiveSmallIntegerField(default=2),
        ),
    ]
