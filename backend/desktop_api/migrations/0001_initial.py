import desktop_api.models
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    initial = True
    dependencies = [migrations.swappable_dependency(settings.AUTH_USER_MODEL)]
    operations = [
        migrations.CreateModel(name="DesktopAppVersion", fields=[
            ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
            ("version", models.CharField(max_length=40, unique=True)), ("download_url", models.URLField()),
            ("release_notes", models.TextField(blank=True)), ("is_mandatory", models.BooleanField(default=False)),
            ("released_at", models.DateTimeField(auto_now_add=True)),
        ], options={"ordering": ["-released_at"]}),
        migrations.CreateModel(name="Pharmacy", fields=[
            ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
            ("name", models.CharField(max_length=160)), ("is_active", models.BooleanField(default=True)),
            ("created_at", models.DateTimeField(auto_now_add=True)),
        ], options={"verbose_name_plural": "Pharmacies"}),
        migrations.CreateModel(name="DesktopLicense", fields=[
            ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
            ("activation_code", models.CharField(default=desktop_api.models.generate_activation_code, editable=False, max_length=80, unique=True)),
            ("mode", models.CharField(choices=[("offline", "Offline"), ("online", "Online")], default="offline", max_length=12)),
            ("license_type", models.CharField(choices=[("trial", "Trial"), ("annual", "Annual"), ("lifetime", "Lifetime")], default="lifetime", max_length=16)),
            ("status", models.CharField(choices=[("active", "Active"), ("suspended", "Suspended"), ("revoked", "Revoked")], default="active", max_length=16)),
            ("max_devices", models.PositiveSmallIntegerField(default=1)), ("expires_at", models.DateTimeField(blank=True, null=True)),
            ("offline_grace_days", models.PositiveSmallIntegerField(default=30)), ("created_at", models.DateTimeField(auto_now_add=True)), ("updated_at", models.DateTimeField(auto_now=True)),
            ("pharmacy", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="desktop_license", to="desktop_api.pharmacy")),
        ]),
        migrations.CreateModel(name="PharmacyMembership", fields=[
            ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
            ("role", models.CharField(choices=[("owner", "Owner"), ("staff", "Staff")], default="staff", max_length=12)),
            ("pharmacy", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="members", to="desktop_api.pharmacy")),
            ("user", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, to=settings.AUTH_USER_MODEL)),
        ]),
        migrations.CreateModel(name="DeviceActivation", fields=[
            ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
            ("device_fingerprint", models.CharField(max_length=128)), ("device_name", models.CharField(blank=True, max_length=120)),
            ("is_active", models.BooleanField(default=True)), ("activated_at", models.DateTimeField(auto_now_add=True)), ("last_seen_at", models.DateTimeField(auto_now=True)),
            ("license", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="devices", to="desktop_api.desktoplicense")),
        ]),
        migrations.AddConstraint(model_name="deviceactivation", constraint=models.UniqueConstraint(fields=("license", "device_fingerprint"), name="unique_device_per_license")),
    ]
