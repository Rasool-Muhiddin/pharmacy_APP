"""
تجهيز بيئة عرض نظيفة للزبون.

    python manage.py seed_demo --reset --yes
    python manage.py seed_demo --reset --yes --password "كلمة-قوية"

--reset يمسح كل بيانات الصيدليات والحسابات التجريبية (يُبقي حسابات superuser
وإصدارات التحديث DesktopAppVersion)، ثم يُنشئ صيدلية "تجريبية" بباقة Gold
وترخيص أونلاين ومالك وموظف وبعض الأدوية. يطبع رمز التفعيل وكلمات المرور.
"""

import secrets
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

from desktop_api.models import DesktopLicense, Pharmacy, PharmacyMembership
from pharmacy_data.models import Medicine

DEMO_MEDICINES = [
    ("Panadol 500mg", "Paracetamol", "مسكنات", 120, "1500", "2000"),
    ("Brufen 400mg", "Ibuprofen", "مسكنات", 80, "2500", "3500"),
    ("Augmentin 1g", "Amoxicillin/Clavulanate", "مضادات حيوية", 45, "9000", "12000"),
    ("Amoxil 500mg", "Amoxicillin", "مضادات حيوية", 60, "4000", "5500"),
    ("Voltaren 50mg", "Diclofenac", "مسكنات", 70, "3000", "4250"),
    ("Cataflam 50mg", "Diclofenac Potassium", "مسكنات", 55, "3500", "5000"),
    ("Nexium 40mg", "Esomeprazole", "جهاز هضمي", 30, "11000", "15000"),
    ("Concor 5mg", "Bisoprolol", "قلب وضغط", 40, "7000", "9500"),
    ("Glucophage 850mg", "Metformin", "سكري", 90, "2500", "3500"),
    ("Ventolin Inhaler", "Salbutamol", "جهاز تنفسي", 25, "5500", "8000"),
    ("Vitamin C 1000mg", "Ascorbic Acid", "فيتامينات", 100, "3000", "4500"),
    ("Zyrtec 10mg", "Cetirizine", "حساسية", 65, "4000", "6000"),
]


class Command(BaseCommand):
    help = "يمسح البيانات التجريبية وينشئ صيدلية عرض جاهزة (Gold + أونلاين)."

    def add_arguments(self, parser):
        parser.add_argument("--reset", action="store_true", help="مسح كل بيانات الصيدليات والمستخدمين غير الإداريين.")
        parser.add_argument("--yes", action="store_true", help="تأكيد المسح دون سؤال.")
        parser.add_argument("--password", default="", help="كلمة مرور حسابي المالك والموظف (عشوائية إن تُركت).")
        parser.add_argument("--name", default="صيدلية العرض", help="اسم الصيدلية.")
        # بيئة العرض أونلاين دائماً، والأونلاين حصري لـ Gold/Diamond (ONLINE_PLANS).
        parser.add_argument("--plan", default="gold", choices=["gold", "diamond"])

    @transaction.atomic
    def handle(self, *args, **opts):
        User = get_user_model()
        if opts["reset"]:
            if not opts["yes"]:
                raise CommandError("المسح نهائي. أضف --yes للتأكيد.")
            Pharmacy.objects.all().delete()  # يحذف الأدوية والفواتير... بالتسلسل (CASCADE)
            User.objects.filter(is_superuser=False).delete()  # يحذف الـTokens أيضاً
            self.stdout.write(self.style.WARNING("تم مسح بيانات الصيدليات والحسابات التجريبية."))

        password = opts["password"] or secrets.token_urlsafe(9)
        pharmacy = Pharmacy.objects.create(name=opts["name"])
        owner = User.objects.create_user("owner", password=password, first_name="المالك")
        staff = User.objects.create_user("staff", password=password, first_name="الموظف")
        PharmacyMembership.objects.create(user=owner, pharmacy=pharmacy, role=PharmacyMembership.ROLE_OWNER)
        PharmacyMembership.objects.create(user=staff, pharmacy=pharmacy, role=PharmacyMembership.ROLE_STAFF)
        license = DesktopLicense.objects.create(
            pharmacy=pharmacy,
            mode=DesktopLicense.ONLINE,
            plan=opts["plan"],
            license_type=DesktopLicense.TRIAL,
            expires_at=timezone.now() + timedelta(days=30),
            max_devices=3,
        )
        today = timezone.localdate()
        for i, (trade, sci, cat, qty, buy, sell) in enumerate(DEMO_MEDICINES):
            Medicine.objects.create(
                pharmacy=pharmacy, trade_name=trade, scientific_name=sci, category=cat,
                quantity=qty, buy_price=Decimal(buy), sell_price=Decimal(sell),
                expiry_date=today + timedelta(days=200 + i * 45), barcode=f"DEMO-{i + 1:04d}",
            )

        self.stdout.write(self.style.SUCCESS("تم تجهيز بيئة العرض:"))
        self.stdout.write(f"  رمز التفعيل : {license.activation_code}")
        self.stdout.write(f"  المالك      : owner / {password}")
        self.stdout.write(f"  الموظف      : staff / {password}")
        self.stdout.write(f"  الباقة      : {license.plan}  |  الوضع: {license.mode}  |  تنتهي: {license.expires_at:%Y-%m-%d}")
