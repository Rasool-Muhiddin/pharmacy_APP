# Generated manually for the Gold-plan multi-warehouse / pharmacy-linking feature

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('desktop_api', '0002_pharmacy_migrated_from_offline_at'),
    ]

    operations = [
        migrations.AddField(
            model_name='desktoplicense',
            name='plan',
            field=models.CharField(
                choices=[('basic', 'Basic'), ('gold', 'Gold'), ('diamond', 'Diamond')],
                default='basic',
                max_length=12,
            ),
        ),
        migrations.CreateModel(
            name='PharmacyLink',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('pharmacy_a', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='links_as_a', to='desktop_api.pharmacy')),
                ('pharmacy_b', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='links_as_b', to='desktop_api.pharmacy')),
            ],
        ),
        migrations.AddConstraint(
            model_name='pharmacylink',
            constraint=models.UniqueConstraint(fields=('pharmacy_a', 'pharmacy_b'), name='unique_pharmacy_link'),
        ),
        migrations.AddConstraint(
            model_name='pharmacylink',
            constraint=models.CheckConstraint(
                condition=models.Q(('pharmacy_a', models.F('pharmacy_b')), _negated=True),
                name='pharmacy_link_not_self',
            ),
        ),
    ]
