"""
صلاحيات واجهات بيانات الصيدلية (المخزون، الفواتير، ...).

قبل هذا الملف كانت كل الواجهات تكتفي بـ IsAuthenticated، أي أن أي Token
صالح كان يعمل حتى لو أُوقف الترخيص أو انتهى أو عُطّلت الصيدلية، وكان
الموظف (staff) يملك نفس صلاحيات المالك. هنا نفرض ثلاث طبقات على الخادم نفسه
(لا نعتمد على إخفاء الأزرار في Flutter):

1) العضوية + الصيدلية فعّالة + الترخيص ساري + الوضع "أونلاين" + باقة
   تسمح بالأونلاين (Gold/Diamond — ONLINE_PLANS).
2) الدور: مالك أو موظف.
3) الباقة: خصائص Gold/Diamond.
"""

from ipaddress import ip_address

from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import BasePermission

from .models import DesktopLicense

# يطابق AppFeature / SubscriptionEntitlements في subscription_plan.dart.
FEATURE_MULTI_WAREHOUSE = "multi_warehouse"

PLAN_FEATURES = {
    DesktopLicense.PLAN_BASIC: frozenset(),
    DesktopLicense.PLAN_GOLD: frozenset({FEATURE_MULTI_WAREHOUSE}),
    DesktopLicense.PLAN_DIAMOND: frozenset({FEATURE_MULTI_WAREHOUSE}),
}


def plan_allows(license, feature):
    return feature in PLAN_FEATURES.get(license.plan, frozenset())


# الوضع الأونلاين (بيانات على الخادم، مزامنة بين الأجهزة، الترحيل أوفلاين→
# أونلاين) حصري للباقة الذهبية وما فوق. الأوفلاين متاح لكل الباقات.
ONLINE_PLANS = frozenset({DesktopLicense.PLAN_GOLD, DesktopLicense.PLAN_DIAMOND})

ONLINE_PLAN_REQUIRED_MESSAGE = "الوضع الأونلاين متاح للباقة الذهبية وما فوق فقط. تواصل مع الدعم للترقية."


def plan_allows_online(license):
    return license.plan in ONLINE_PLANS


def max_warehouses_for(license):
    """
    العدد الفعلي المسموح من المخازن (الرئيسي ضمنها). الباقة الأساسية = مخزن
    واحد دائماً؛ Gold/Diamond = license.max_warehouses (يُضبط من الأدمن لكل
    عميل). يُرسَل نفس الرقم للتطبيق في license_payload ليفرضه أوفلاين أيضاً.
    """
    if not plan_allows(license, FEATURE_MULTI_WAREHOUSE):
        return 1
    return max(1, license.max_warehouses)


def _membership_for(user):
    from .models import PharmacyMembership

    return (
        PharmacyMembership.objects.select_related("pharmacy", "pharmacy__desktop_license")
        .filter(user=user)
        .first()
    )


def resolve_context(request):
    """
    يرجع (membership, license) بعد التحقق الكامل، أو يرفع PermissionDenied
    برسالة عربية واضحة يعرضها Flutter كما هي. يُخزَّن الناتج على الطلب كي لا
    يتكرر الاستعلام داخل نفس الطلب.
    """
    cached = getattr(request, "_pharmacy_ctx", None)
    if cached is not None:
        return cached

    membership = _membership_for(request.user)
    if membership is None:
        raise PermissionDenied("هذا الحساب غير مرتبط بأي صيدلية.")
    pharmacy = membership.pharmacy
    if not pharmacy.is_active:
        raise PermissionDenied("هذه الصيدلية موقوفة. تواصل مع الدعم.")
    try:
        license = pharmacy.desktop_license
    except DesktopLicense.DoesNotExist:
        raise PermissionDenied("لا يوجد ترخيص لهذه الصيدلية.")
    if not license.is_valid:
        raise PermissionDenied("الترخيص غير فعال أو منتهي. تواصل مع الدعم لتجديده.")
    if license.mode != DesktopLicense.ONLINE:
        raise PermissionDenied("هذه الصيدلية مرخّصة للوضع الأوفلاين فقط.")
    # حماية حتى لو حُفظ ترخيص أونلاين+Basic متجاوزاً DesktopLicense.clean()
    # (مثلاً من shell أو قبل نشر هذا التحقق).
    if not plan_allows_online(license):
        raise PermissionDenied(ONLINE_PLAN_REQUIRED_MESSAGE)

    request._pharmacy_ctx = (membership, license)
    return request._pharmacy_ctx


class IsActiveOnlineMember(BasePermission):
    """أي مستخدم (مالك أو موظف) بترخيص أونلاين ساري."""

    def has_permission(self, request, view):
        if not request.user or not request.user.is_authenticated:
            return False
        resolve_context(request)
        return True


class IsActiveOnlineOwner(IsActiveOnlineMember):
    """مالك الصيدلية فقط، بترخيص أونلاين ساري."""

    def has_permission(self, request, view):
        super().has_permission(request, view)
        membership, _ = resolve_context(request)
        if not membership.is_owner:
            raise PermissionDenied("هذه العملية متاحة لمالك الصيدلية فقط.")
        return True


def client_ip(request):
    """
    عنوان الزائر لـ django-ratelimit. نثق بترويسة Cloudflare فقط عند
    ضبط TRUST_CLOUDFLARE_IP=True (الخادم خلف Cloudflare فعلاً)، وإلا
    نستخدم REMOTE_ADDR. وإن كانت الترويسة غائبة أو غير صالحة نرجع لـ
    REMOTE_ADDR بدل إسقاط الطلب بخطأ 500 كما كان يحدث سابقاً.
    """
    from django.conf import settings

    candidates = []
    if getattr(settings, "TRUST_CLOUDFLARE_IP", False):
        candidates.append(request.META.get("HTTP_CF_CONNECTING_IP", ""))
    candidates.append(request.META.get("REMOTE_ADDR", ""))
    for value in candidates:
        value = (value or "").strip()
        if not value:
            continue
        try:
            ip_address(value)
        except ValueError:
            continue
        return value
    return "0.0.0.0"


def login_username_key(group, request):
    """
    مفتاح django-ratelimit باسم المستخدم المُرسَل في جسم طلب الدخول (JSON)،
    ليُحدَّ تخمين كلمة مرور حساب واحد حتى لو تبدّلت عناوين IP المهاجم.
    """
    import json

    try:
        data = json.loads(request.body.decode("utf-8"))
        username = str(data.get("username", "")) if isinstance(data, dict) else ""
    except (ValueError, UnicodeDecodeError):
        username = ""
    return username.strip().lower()[:150] or "-"
