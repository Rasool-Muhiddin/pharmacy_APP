from django import forms
from django.contrib import admin

from .models import DesktopAppVersion, DesktopLicense, DeviceActivation, Pharmacy, PharmacyMembership


class DesktopLicenseAdminForm(forms.ModelForm):
    """
    نموذج الترخيص في الأدمن (صفحة الترخيص + الترخيص المضمَّن في صفحة الصيدلية).
    ModelForm يستدعي DesktopLicense.full_clean() تلقائياً، فيظهر رفض
    "أونلاين + Basic" تحت حقل mode بدل حفظ ترخيص لا يعمل. نص المساعدة هنا
    (لا على حقل الموديل) كي لا يتطلب ترحيل قاعدة بيانات.
    """

    class Meta:
        model = DesktopLicense
        fields = "__all__"
        help_texts = {"mode": "Online requires Gold or Diamond plan"}


class DeviceActivationInline(admin.TabularInline):
    model = DeviceActivation
    extra = 0
    readonly_fields = ("activated_at", "last_seen_at")


@admin.register(Pharmacy)
class PharmacyAdmin(admin.ModelAdmin):
    list_display = ("name", "is_active", "migrated_from_offline_at", "created_at")
    search_fields = ("name",)


@admin.register(PharmacyMembership)
class PharmacyMembershipAdmin(admin.ModelAdmin):
    list_display = ("user", "pharmacy", "role")
    list_filter = ("role",)
    search_fields = ("user__username", "pharmacy__name")


@admin.register(DesktopLicense)
class DesktopLicenseAdmin(admin.ModelAdmin):
    form = DesktopLicenseAdminForm
    list_display = ("pharmacy", "activation_code", "mode", "plan", "status", "max_devices", "max_warehouses", "expires_at")
    list_filter = ("mode", "plan", "status", "license_type")
    search_fields = ("pharmacy__name", "activation_code")
    readonly_fields = ("activation_code", "created_at", "updated_at")
    inlines = (DeviceActivationInline,)


@admin.register(DeviceActivation)
class DeviceActivationAdmin(admin.ModelAdmin):
    list_display = ("license", "device_name", "device_fingerprint", "is_active", "last_seen_at")
    list_filter = ("is_active",)
    search_fields = ("device_name", "device_fingerprint", "license__pharmacy__name")


@admin.register(DesktopAppVersion)
class DesktopAppVersionAdmin(admin.ModelAdmin):
    list_display = ("version", "is_mandatory", "released_at")


# تسهيل إنشاء صيدلية كاملة من صفحة واحدة: الصيدلية + الترخيص + حساب المالك.
class PharmacyMembershipInline(admin.TabularInline):
    model = PharmacyMembership
    extra = 0
    autocomplete_fields = ("user",)


class DesktopLicenseInline(admin.StackedInline):
    model = DesktopLicense
    form = DesktopLicenseAdminForm
    extra = 0
    readonly_fields = ("activation_code", "created_at", "updated_at")


PharmacyAdmin.inlines = (DesktopLicenseInline, PharmacyMembershipInline)
