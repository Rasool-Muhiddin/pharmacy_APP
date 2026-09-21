import json

from django.contrib.auth import authenticate
from django.db import transaction
from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST
from django_ratelimit.decorators import ratelimit

from .models import DesktopAppVersion, DesktopLicense, DeviceActivation, PharmacyMembership


def error(message, status):
    return JsonResponse({"ok": False, "message": message}, status=status)


def request_json(request):
    try:
        value = json.loads(request.body.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    return value if isinstance(value, dict) else None


def license_payload(license):
    return {
        "type": license.license_type,
        "mode": license.mode,
        "status": license.status,
        "expires_at": license.expires_at.isoformat() if license.expires_at else None,
        "max_devices": license.max_devices,
    }


@require_GET
def health(request):
    return JsonResponse({"ok": True, "service": "tera-desktop-backend"})


@ratelimit(key="ip", rate="20/m", method="POST", block=True)
@csrf_exempt
@require_POST
def desktop_activate(request):
    data = request_json(request)
    if data is None:
        return error("بيانات الطلب غير صحيحة.", 400)
    activation_code = str(data.get("activation_code", "")).strip()
    fingerprint = str(data.get("device_fingerprint", "")).strip()
    device_name = str(data.get("device_name", "")).strip()[:120]
    if not activation_code or not fingerprint or len(fingerprint) > 128:
        return error("رمز التفعيل ومعرف جهاز صالح مطلوبان.", 400)
    try:
        with transaction.atomic():
            license = DesktopLicense.objects.select_for_update().select_related("pharmacy").get(activation_code=activation_code)
            if not license.is_valid:
                return error("هذا الترخيص غير فعال أو منتهي.", 403)
            device, created = DeviceActivation.objects.get_or_create(
                license=license,
                device_fingerprint=fingerprint,
                defaults={"device_name": device_name},
            )
            if not device.is_active:
                return error("هذا الجهاز موقوف من لوحة الإدارة.", 403)
            if created and license.devices.filter(is_active=True).count() > license.max_devices:
                device.delete()
                return error("تم الوصول إلى الحد الأقصى للأجهزة المسموح بها.", 403)
            if not created and device.device_name != device_name:
                device.device_name = device_name
                device.save(update_fields=["device_name", "last_seen_at"])
    except DesktopLicense.DoesNotExist:
        return error("رمز التفعيل غير صحيح.", 404)
    return JsonResponse({"ok": True, "message": "تم تفعيل النسخة بنجاح.", "pharmacy": {"id": license.pharmacy_id, "name": license.pharmacy.name}, "license": license_payload(license)})


@ratelimit(key="ip", rate="20/m", method="POST", block=True)
@csrf_exempt
@require_POST
def desktop_login(request):
    data = request_json(request)
    if data is None:
        return error("بيانات الطلب غير صحيحة.", 400)
    username = str(data.get("username", "")).strip()
    password = str(data.get("password", ""))
    fingerprint = str(data.get("device_fingerprint", "")).strip()
    if not username or not password or not fingerprint or len(fingerprint) > 128:
        return error("اسم المستخدم وكلمة المرور ومعرف جهاز صالح مطلوبة.", 400)
    user = authenticate(request, username=username, password=password)
    if user is None or not user.is_active:
        return error("اسم المستخدم أو كلمة المرور غير صحيحة.", 401)
    try:
        membership = PharmacyMembership.objects.select_related("pharmacy", "pharmacy__desktop_license").get(user=user)
        license = membership.pharmacy.desktop_license
        device = license.devices.get(device_fingerprint=fingerprint)
    except (PharmacyMembership.DoesNotExist, DesktopLicense.DoesNotExist, DeviceActivation.DoesNotExist):
        return error("الحساب أو الجهاز غير مفعّل لهذه الصيدلية.", 403)
    if not membership.pharmacy.is_active or not device.is_active or not license.is_valid:
        return error("الحساب أو الجهاز أو الترخيص غير فعال.", 403)
    device.save(update_fields=["last_seen_at"])
    return JsonResponse({
        "ok": True,
        "message": "تم تسجيل الدخول بنجاح.",
        "validated_at": timezone.now().isoformat(),
        "offline_grace_days": license.offline_grace_days,
        "user": {"id": user.id, "username": user.username, "full_name": user.get_full_name().strip() or user.username, "is_owner": membership.is_owner},
        "pharmacy": {"id": membership.pharmacy_id, "name": membership.pharmacy.name},
        "license": license_payload(license),
    })


@ratelimit(key="ip", rate="30/m", method="GET", block=True)
@require_GET
def desktop_latest_version(request):
    latest = DesktopAppVersion.objects.first()
    if latest is None:
        return error("لا توجد بيانات إصدار متاحة.", 404)
    return JsonResponse({"ok": True, "version": latest.version, "download_url": latest.download_url, "release_notes": latest.release_notes, "is_mandatory": latest.is_mandatory})
