from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pharmacy_data", "0013_dedupe_purchase_invoice_numbers"),
    ]

    operations = [
        migrations.AddConstraint(
            model_name="purchaseinvoice",
            constraint=models.UniqueConstraint(
                condition=models.Q(("invoice_number", ""), _negated=True),
                fields=("pharmacy", "supplier", "invoice_number"),
                name="unique_purchase_invoice_number_per_supplier",
            ),
        ),
    ]
