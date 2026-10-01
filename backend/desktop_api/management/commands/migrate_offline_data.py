"""
رفع أولي لبيانات صيدلية أوفلاين إلى الخادم من ملف JSON (بديل الإدارة عن زر
"رفع الآن" في التطبيق، مثلاً عند استلام نسخة من جهاز المالك).

    python manage.py migrate_offline_data --pharmacy-id 7 --file offline.json

الملف بنفس شكل حمولة التطبيق (DatabaseHelper.getOfflineMigrationPayload).
يستخدم نفس منطق MigrationViewSet.upload_offline_data حرفياً
(pharmacy_data.offline_import) ونفس الشروط: باقة Gold/Diamond، لم تُرفع من
قبل، ولا بيانات أونلاين قائمة. كل شيء في معاملة واحدة: أي خطأ = لا شيء يُحفظ.
"""

import json
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from rest_framework.exceptions import APIException

from desktop_api.models import DesktopLicense, Pharmacy
from pharmacy_data.offline_import import error_message, run_offline_import, validate_offline_import


class Command(BaseCommand):
    help = "يرفع بيانات صيدلية أوفلاين (ملف JSON) إلى الخادم ضمن معاملة واحدة."

    def add_arguments(self, parser):
        parser.add_argument("--pharmacy-id", type=int, required=True, help="معرّف الصيدلية على الخادم.")
        parser.add_argument("--file", required=True, help="مسار ملف JSON بحمولة الرفع.")

    def handle(self, *args, **opts):
        path = Path(opts["file"])
        if not path.is_file():
            raise CommandError(f"الملف غير موجود: {path}")
        try:
            payload = json.loads(path.read_text(encoding="utf-8-sig"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise CommandError(f"ملف JSON غير صالح: {exc}")

        try:
            with transaction.atomic():
                try:
                    pharmacy = Pharmacy.objects.select_for_update().get(pk=opts["pharmacy_id"])
                except Pharmacy.DoesNotExist:
                    raise CommandError(f"لا توجد صيدلية بالمعرّف {opts['pharmacy_id']}.")
                license = DesktopLicense.objects.filter(pharmacy=pharmacy).first()
                if license is None:
                    raise CommandError("لا يوجد ترخيص لهذه الصيدلية.")

                validate_offline_import(pharmacy, license, payload)
                summary = run_offline_import(pharmacy, payload)
        except CommandError:
            raise
        except APIException as exc:
            raise CommandError(error_message(exc))
        except Exception as exc:
            raise CommandError(f"فشل الاستيراد ولم يُحفظ أي شيء: {error_message(exc)}")

        self.stdout.write(self.style.SUCCESS(f"تم الرفع الأولي لصيدلية {pharmacy.name} (#{pharmacy.pk}):"))
        width = max(len(key) for key in summary)
        for key, value in summary.items():
            self.stdout.write(f"  {key.ljust(width)} : {value}")
