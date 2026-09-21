import secrets

from django.conf import settings
from django.db import models
from django.utils import timezone


def generate_activation_code():
    return f"TERA-{secrets.token_urlsafe(24).upper()}"


class Pharmacy(models.Model):
    name = models.CharField(max_length=160)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name_plural = "Pharmacies"

    def __str__(self):
        return self.name


class PharmacyMembership(models.Model):
    ROLE_OWNER = "owner"
    ROLE_STAFF = "staff"
    ROLE_CHOICES = [(ROLE_OWNER, "Owner"), (ROLE_STAFF, "Staff")]

    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="members")
    role = models.CharField(max_length=12, choices=ROLE_CHOICES, default=ROLE_STAFF)

    @property
    def is_owner(self):
        return self.role == self.ROLE_OWNER

    def __str__(self):
        return f"{self.user.username} @ {self.pharmacy.name}"


class DesktopLicense(models.Model):
    OFFLINE = "offline"
    ONLINE = "online"
    MODE_CHOICES = [(OFFLINE, "Offline"), (ONLINE, "Online")]
    TRIAL = "trial"
    ANNUAL = "annual"
    LIFETIME = "lifetime"
    TYPE_CHOICES = [(TRIAL, "Trial"), (ANNUAL, "Annual"), (LIFETIME, "Lifetime")]
    ACTIVE = "active"
    SUSPENDED = "suspended"
    REVOKED = "revoked"
    STATUS_CHOICES = [(ACTIVE, "Active"), (SUSPENDED, "Suspended"), (REVOKED, "Revoked")]

    pharmacy = models.OneToOneField(Pharmacy, on_delete=models.CASCADE, related_name="desktop_license")
    activation_code = models.CharField(max_length=80, unique=True, default=generate_activation_code, editable=False)
    mode = models.CharField(max_length=12, choices=MODE_CHOICES, default=OFFLINE)
    license_type = models.CharField(max_length=16, choices=TYPE_CHOICES, default=LIFETIME)
    status = models.CharField(max_length=16, choices=STATUS_CHOICES, default=ACTIVE)
    max_devices = models.PositiveSmallIntegerField(default=1)
    expires_at = models.DateTimeField(null=True, blank=True)
    offline_grace_days = models.PositiveSmallIntegerField(default=30)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    @property
    def is_valid(self):
        return self.status == self.ACTIVE and (
            self.license_type == self.LIFETIME or
            (self.expires_at is not None and self.expires_at >= timezone.now())
        )

    def __str__(self):
        return f"{self.pharmacy.name} ({self.mode})"


class DeviceActivation(models.Model):
    license = models.ForeignKey(DesktopLicense, on_delete=models.CASCADE, related_name="devices")
    device_fingerprint = models.CharField(max_length=128)
    device_name = models.CharField(max_length=120, blank=True)
    is_active = models.BooleanField(default=True)
    activated_at = models.DateTimeField(auto_now_add=True)
    last_seen_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["license", "device_fingerprint"], name="unique_device_per_license")]

    def __str__(self):
        return self.device_name or self.device_fingerprint[:20]


class DesktopAppVersion(models.Model):
    version = models.CharField(max_length=40, unique=True)
    download_url = models.URLField()
    release_notes = models.TextField(blank=True)
    is_mandatory = models.BooleanField(default=False)
    released_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-released_at"]

    def __str__(self):
        return self.version
