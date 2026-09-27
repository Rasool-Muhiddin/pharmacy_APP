from django.contrib import admin

from .models import DesktopAppVersion, DesktopLicense, DeviceActivation, Pharmacy, PharmacyLink, PharmacyMembership


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
    list_display = ("pharmacy", "activation_code", "mode", "plan", "status", "max_devices", "expires_at")
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


@admin.register(PharmacyLink)
class PharmacyLinkAdmin(admin.ModelAdmin):
    # خاصية الباقة الذهبية (تعدد المخازن + ربط الصيدليات) — يُنشأ الربط من
    # هنا حصراً، لا يوجد أي مسار آخر من داخل التطبيق نفسه.
    list_display = ("pharmacy_a", "pharmacy_b", "created_at")
    search_fields = ("pharmacy_a__name", "pharmacy_b__name")
    autocomplete_fields = ("pharmacy_a", "pharmacy_b")