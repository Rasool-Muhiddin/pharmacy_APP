import json
import tempfile
from datetime import timedelta
from io import StringIO
from pathlib import Path

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.core.management import CommandError, call_command
from django.test import TestCase, override_settings
from django.utils import timezone

from desktop_api.models import DesktopLicense, DeviceActivation, Pharmacy, PharmacyMembership
from desktop_api.permissions import ONLINE_PLAN_REQUIRED_MESSAGE
from pharmacy_data.models import Medicine, StockTransfer, Warehouse

User = get_user_model()
PASSWORD = "Passw0rd!x-test"


FAST_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]


@override_settings(ALLOWED_HOSTS=["testserver", "localhost"], PASSWORD_HASHERS=FAST_HASHERS)
class AccessControlTests(TestCase):
    def setUp(self):
        cache.clear()  # عدّادات rate-limit تبقى في الذاكرة بين الاختبارات
        self.pharmacy = Pharmacy.objects.create(name="P1")
        self.license = DesktopLicense.objects.create(
            pharmacy=self.pharmacy, mode="online", plan="gold", max_devices=3
        )
        self.owner = User.objects.create_user("owner", password=PASSWORD)
        self.staff = User.objects.create_user("staff", password=PASSWORD)
        PharmacyMembership.objects.create(user=self.owner, pharmacy=self.pharmacy, role="owner")
        PharmacyMembership.objects.create(user=self.staff, pharmacy=self.pharmacy, role="staff")
        self.activate("d1")
        self.owner_token = self.login("owner")
        self.staff_token = self.login("staff")
        self.medicine = Medicine.objects.create(
            pharmacy=self.pharmacy, trade_name="A", quantity=10, sell_price=10, buy_price=5
        )

    # helpers
    def post(self, path, data, token=None):
        headers = {"HTTP_AUTHORIZATION": f"Token {token}"} if token else {}
        return self.client.post(path, json.dumps(data), content_type="application/json", **headers)

    def get(self, path, token):
        return self.client.get(path, HTTP_AUTHORIZATION=f"Token {token}")

    def activate(self, fingerprint):
        r = self.post("/api/desktop/activate/", {"activation_code": self.license.activation_code, "device_fingerprint": fingerprint})
        self.assertEqual(r.status_code, 200, r.content)

    def login(self, username, fingerprint="d1"):
        r = self.post("/api/desktop/login/", {"username": username, "password": PASSWORD, "device_fingerprint": fingerprint})
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()["api_token"]

    # login works without a Cloudflare header (used to crash with 500)
    def test_login_without_cloudflare_header(self):
        self.assertTrue(self.login("owner"))

    def test_staff_can_read_sell_and_refund_but_not_manage(self):
        self.assertEqual(self.get("/api/medicines/", self.staff_token).status_code, 200)
        self.assertEqual(self.get("/api/invoices/", self.staff_token).status_code, 200)
        checkout = self.post("/api/invoices/checkout/", {"items": [{"medicine_id": self.medicine.id, "quantity": 1}]}, self.staff_token)
        self.assertEqual(checkout.status_code, 201, checkout.content)
        invoice_id = checkout.json()["id"]
        refund = self.post("/api/invoices/%d/refund/" % invoice_id, {}, self.staff_token)
        self.assertEqual(refund.status_code, 200, refund.content)
        self.assertEqual(self.post("/api/medicines/", {"trade_name": "B"}, self.staff_token).status_code, 403)
        self.assertEqual(self.client.delete(f"/api/medicines/{self.medicine.id}/", HTTP_AUTHORIZATION=f"Token {self.staff_token}").status_code, 403)
        for path in ("/api/reports/summary/", "/api/expenses/", "/api/suppliers/", "/api/damaged-medicines/", "/api/migration/status/"):
            self.assertEqual(self.get(path, self.staff_token).status_code, 403, path)

    def test_owner_has_full_access(self):
        for path in ("/api/medicines/", "/api/reports/summary/", "/api/expenses/", "/api/suppliers/", "/api/damaged-medicines/"):
            self.assertEqual(self.get(path, self.owner_token).status_code, 200, path)
        self.assertEqual(self.post("/api/medicines/", {"trade_name": "B"}, self.owner_token).status_code, 201)
        refund_target = self.post("/api/invoices/checkout/", {"items": [{"medicine_id": self.medicine.id, "quantity": 1}]}, self.owner_token).json()["id"]
        self.assertEqual(self.post(f"/api/invoices/{refund_target}/refund/", {}, self.owner_token).status_code, 200)

    def test_license_state_is_enforced_on_data_api(self):
        self.license.status = "suspended"
        self.license.save()
        self.assertEqual(self.get("/api/medicines/", self.owner_token).status_code, 403)
        self.license.status = "active"
        self.license.license_type = "trial"
        self.license.expires_at = timezone.now() - timedelta(days=1)
        self.license.save()
        self.assertEqual(self.get("/api/medicines/", self.owner_token).status_code, 403)
        self.license.expires_at = timezone.now() + timedelta(days=5)
        self.license.save()
        self.assertEqual(self.get("/api/medicines/", self.owner_token).status_code, 200)
        self.pharmacy.is_active = False
        self.pharmacy.save()
        self.assertEqual(self.get("/api/medicines/", self.owner_token).status_code, 403)

    def test_offline_license_cannot_use_online_api(self):
        self.license.mode = "offline"
        self.license.save()
        self.assertEqual(self.get("/api/medicines/", self.owner_token).status_code, 403)

    def test_pharmacy_linking_endpoint_removed(self):
        self.assertEqual(self.get("/api/pharmacy-links/", self.owner_token).status_code, 404)

    def test_barcode_unique_per_pharmacy_not_globally(self):
        first = self.post("/api/medicines/", {"trade_name": "X", "barcode": "123"}, self.owner_token)
        self.assertEqual(first.status_code, 201)
        dup = self.post("/api/medicines/", {"trade_name": "Y", "barcode": "123"}, self.owner_token)
        self.assertEqual(dup.status_code, 400)
        # empty barcodes never collide
        for name in ("E1", "E2"):
            self.assertEqual(self.post("/api/medicines/", {"trade_name": name, "barcode": ""}, self.owner_token).status_code, 201)
        # same barcode in another pharmacy is allowed
        other = Pharmacy.objects.create(name="P2")
        Medicine.objects.create(pharmacy=other, trade_name="Z", barcode="123")

    def test_wrong_credentials_and_inactive_device(self):
        r = self.post("/api/desktop/login/", {"username": "owner", "password": "bad", "device_fingerprint": "d1"})
        self.assertEqual(r.status_code, 401)
        DeviceActivation.objects.update(is_active=False)
        r = self.post("/api/desktop/login/", {"username": "owner", "password": PASSWORD, "device_fingerprint": "d1"})
        self.assertEqual(r.status_code, 403)



@override_settings(ALLOWED_HOSTS=["testserver", "localhost"], PASSWORD_HASHERS=FAST_HASHERS)
class RegressionTests(TestCase):
    """أخطاء حقيقية وُجدت أثناء فحص الـBackend قبل عرضه على الزبون."""

    def setUp(self):
        cache.clear()
        self.pharmacy = Pharmacy.objects.create(name="P1")
        self.license = DesktopLicense.objects.create(pharmacy=self.pharmacy, mode="online", plan="gold", max_devices=3)
        self.owner = User.objects.create_user("owner", password=PASSWORD)
        PharmacyMembership.objects.create(user=self.owner, pharmacy=self.pharmacy, role="owner")
        DeviceActivation.objects.create(license=self.license, device_fingerprint="d1")
        self.token = self.login()
        self.medicine = Medicine.objects.create(pharmacy=self.pharmacy, trade_name="A", quantity=5, sell_price=10, buy_price=5)

    def login(self, password=PASSWORD):
        return self.client.post(
            "/api/desktop/login/",
            json.dumps({"username": "owner", "password": password, "device_fingerprint": "d1"}),
            content_type="application/json",
        )

    def api(self, method, path, data=None):
        kwargs = {"HTTP_AUTHORIZATION": "Token " + self.token_key()}
        if data is not None:
            kwargs["data"] = json.dumps(data)
            kwargs["content_type"] = "application/json"
        return getattr(self.client, method)(path, **kwargs)

    def token_key(self):
        from rest_framework.authtoken.models import Token
        return Token.objects.get(user=self.owner).key

    def test_checkout_merges_duplicate_lines_and_rejects_oversell_cleanly(self):
        r = self.api("post", "/api/invoices/checkout/", {"items": [
            {"medicine_id": self.medicine.id, "quantity": 4}, {"medicine_id": self.medicine.id, "quantity": 4}]})
        self.assertEqual(r.status_code, 400, r.content)  # كان 500
        self.medicine.refresh_from_db()
        self.assertEqual(self.medicine.quantity, 5)

        r = self.api("post", "/api/invoices/checkout/", {"items": [
            {"medicine_id": self.medicine.id, "quantity": 2}, {"medicine_id": self.medicine.id, "quantity": 3}]})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(len(r.json()["items"]), 1)
        self.medicine.refresh_from_db()
        self.assertEqual(self.medicine.quantity, 0)

    def test_invoice_number_survives_gaps_and_migrated_numbers(self):
        from pharmacy_data.models import Invoice
        Invoice.objects.create(pharmacy=self.pharmacy, invoice_number="INV-000007")
        Invoice.objects.create(pharmacy=self.pharmacy, invoice_number="INV-000002")
        r = self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": self.medicine.id, "quantity": 1}]})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["invoice_number"], "INV-000008")  # كان INV-000003 ثم يتكرر لاحقاً

    def test_token_expires_and_login_renews_it(self):
        from rest_framework.authtoken.models import Token
        self.assertEqual(self.api("get", "/api/medicines/").status_code, 200)
        Token.objects.filter(user=self.owner).update(created=timezone.now() - timedelta(days=61))
        r = self.api("get", "/api/medicines/")
        self.assertEqual(r.status_code, 401)
        r = self.login()
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.api("get", "/api/medicines/").status_code, 200)

    def test_login_bruteforce_returns_json_429(self):
        last = None
        for _ in range(12):
            last = self.login(password="wrong-password")
        self.assertEqual(last.status_code, 429)
        self.assertFalse(last.json()["ok"])  # JSON يفهمه التطبيق، لا صفحة HTML

    def test_purchase_invoice_rejects_overpayment(self):
        from pharmacy_data.models import Supplier
        supplier = Supplier.objects.create(pharmacy=self.pharmacy, name="S")
        # الإنشاء اليدوي أُزيل: الفواتير تأتي حصراً من قوائم المخزون.
        r = self.api("post", "/api/purchase-invoices/", {"supplier": supplier.id, "total_amount": "100", "paid_amount": "40"})
        self.assertEqual(r.status_code, 405, r.content)
        line = {"trade_name": "B", "quantity": 1, "buy_price": "100", "sell_price": "150", "expiry_date": "2030-01-01"}
        body = {"supplier": supplier.id, "invoice_number": "X1", "items": [line], "paid_amount": "150"}
        r = self.api("post", "/api/purchase-invoices/from-list/", body)
        self.assertEqual(r.status_code, 400, r.content)
        body["paid_amount"] = "40"
        r = self.api("post", "/api/purchase-invoices/from-list/", body)
        self.assertEqual(r.status_code, 201, r.content)

    def test_migration_tolerates_duplicate_barcodes(self):
        self.pharmacy.migrated_from_offline_at = None
        Medicine.objects.filter(pharmacy=self.pharmacy).delete()
        payload = {"medicines": [
            {"local_id": 1, "trade_name": "X", "barcode": "123"},
            {"local_id": 2, "trade_name": "Y", "barcode": "123"},
            {"local_id": 3, "trade_name": "Z", "barcode": ""},
            {"local_id": 4, "trade_name": "W", "barcode": ""}]}
        r = self.api("post", "/api/migration/upload_offline_data/", payload)
        body = b"".join(r.streaming_content).decode()
        self.assertIn('"event": "done"', body, body)
        self.assertEqual(Medicine.objects.filter(pharmacy=self.pharmacy).count(), 4)

    def upload(self, payload):
        r = self.api("post", "/api/migration/upload_offline_data/", payload)
        if r.status_code != 200:
            return r.status_code, r.content.decode()
        return 200, b"".join(r.streaming_content).decode()

    def test_flag_without_online_data_does_not_lock_out_migration(self):
        # حالة "صيدلية الشعب": migrated_from_offline_at مضبوط لكن لا بيانات
        # أونلاين إطلاقاً للصيدلية — كان الخادم يرفض الرفع للأبد، والتطبيق
        # يُخفي الاقتراح، فتظهر الصيدلية فارغة رغم وجود بياناتها محلياً.
        Medicine.objects.filter(pharmacy=self.pharmacy).delete()
        Pharmacy.objects.filter(pk=self.pharmacy.pk).update(migrated_from_offline_at=timezone.now())

        status = self.api("get", "/api/migration/status/").json()
        self.assertEqual(status["migrated"], False)
        self.assertEqual(status["has_existing_online_data"], False)
        self.assertEqual(status["can_migrate"], True)

        code, body = self.upload({"medicines": [{"local_id": 10**12, "trade_name": "Local"}]})
        self.assertEqual(code, 200, body)
        self.assertIn('"event": "done"', body, body)
        self.assertEqual(Medicine.objects.get(pharmacy=self.pharmacy).trade_name, "Local")

        status = self.api("get", "/api/migration/status/").json()
        self.assertEqual((status["migrated"], status["can_migrate"]), (True, False))
        code, body = self.upload({"medicines": [{"local_id": 10**12, "trade_name": "Local"}]})
        self.assertEqual(code, 400, body)  # لا تكرار بعد رفع فعلي
        self.assertIn("مسبقاً", json.loads(body)[0])
        self.assertEqual(Medicine.objects.filter(pharmacy=self.pharmacy).count(), 1)

    def test_empty_upload_is_rejected_and_does_not_consume_migration(self):
        Medicine.objects.filter(pharmacy=self.pharmacy).delete()
        for payload in ({}, {key: [] for key in ("warehouses", "suppliers", "medicines", "invoices", "expenses")}):
            code, body = self.upload(payload)
            self.assertEqual(code, 400, body)
        self.pharmacy.refresh_from_db()
        self.assertIsNone(self.pharmacy.migrated_from_offline_at)
        self.assertTrue(self.api("get", "/api/migration/status/").json()["can_migrate"])

    def test_migration_targets_token_pharmacy_only(self):
        # لا يرسل التطبيق pharmacy_id إطلاقاً: الصيدلية تُحدَّد من عضوية صاحب
        # الـToken، فلا يمكن لأي اختلاف معرّفات محلي أن يرفع لصيدلية أخرى.
        Medicine.objects.filter(pharmacy=self.pharmacy).delete()
        other = Pharmacy.objects.create(name="P2")
        code, body = self.upload({"pharmacy_id": other.pk, "medicines": [{"local_id": 1, "trade_name": "A", "pharmacy": other.pk}]})
        self.assertIn('"event": "done"', body, body)
        self.assertEqual(Medicine.objects.get().pharmacy, self.pharmacy)
        other.refresh_from_db()
        self.assertIsNone(other.migrated_from_offline_at)
        self.assertEqual([m["trade_name"] for m in self.api("get", "/api/medicines/").json()["results"]], ["A"])

    def test_pharmacy_admin_cannot_edit_migration_flag(self):
        admin_user = User.objects.create_superuser("admin", password=PASSWORD)
        self.client.force_login(admin_user)
        r = self.client.get(f"/admin/desktop_api/pharmacy/{self.pharmacy.pk}/change/")
        self.assertEqual(r.status_code, 200)
        self.assertNotContains(r, 'name="migrated_from_offline_at_0"')


@override_settings(ALLOWED_HOSTS=["testserver", "localhost"], PASSWORD_HASHERS=FAST_HASHERS)
class WarehouseTests(TestCase):
    """تعدد المخازن (Gold): الحدود، النقل، البيع من الرئيسي فقط، والترحيل."""

    def setUp(self):
        cache.clear()
        self.pharmacy = Pharmacy.objects.create(name="P1")
        self.license = DesktopLicense.objects.create(pharmacy=self.pharmacy, mode="online", plan="gold", max_devices=3)
        self.owner = User.objects.create_user("owner", password=PASSWORD)
        self.staff = User.objects.create_user("staff", password=PASSWORD)
        PharmacyMembership.objects.create(user=self.owner, pharmacy=self.pharmacy, role="owner")
        PharmacyMembership.objects.create(user=self.staff, pharmacy=self.pharmacy, role="staff")
        DeviceActivation.objects.create(license=self.license, device_fingerprint="d1")
        self.owner_token = self.login("owner")["api_token"]
        self.staff_token = self.login("staff")["api_token"]
        self.main = Warehouse.main_for(self.pharmacy)

    def login(self, username):
        r = self.client.post(
            "/api/desktop/login/",
            json.dumps({"username": username, "password": PASSWORD, "device_fingerprint": "d1"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def call(self, method, path, data=None, token=None):
        kwargs = {"HTTP_AUTHORIZATION": f"Token {token or self.owner_token}"}
        if data is not None:
            kwargs["data"] = json.dumps(data)
            kwargs["content_type"] = "application/json"
        return getattr(self.client, method)(path, **kwargs)

    def add_warehouse(self, name="W2", token=None):
        return self.call("post", "/api/warehouses/", {"name": name}, token)

    def transfer(self, medicine_id, to_id, qty, token=None):
        return self.call(
            "post", "/api/warehouses/transfer/",
            {"medicine_id": medicine_id, "to_warehouse_id": to_id, "quantity": qty}, token,
        )

    def test_login_reports_effective_warehouse_limit(self):
        self.assertEqual(self.login("owner")["license"]["max_warehouses"], 2)
        # Basic متاح أوفلاين فقط الآن.
        self.license.plan = "basic"
        self.license.mode = "offline"
        self.license.save()
        self.assertEqual(self.login("owner")["license"]["max_warehouses"], 1)

    def test_login_reports_plan_features_including_report_export(self):
        # report_export (تصدير Excel/PDF) لـ Gold/Diamond فقط؛ التطبيق يحفظ
        # features مع الترخيص ويفرضها أوفلاين.
        for plan in ("gold", "diamond"):
            DesktopLicense.objects.filter(pk=self.license.pk).update(plan=plan)
            features = self.login("owner")["license"]["features"]
            self.assertEqual(features, ["multi_warehouse", "report_export"], plan)
        self.license.refresh_from_db()
        self.license.plan = "basic"
        self.license.mode = "offline"
        self.license.save()
        self.assertEqual(self.login("owner")["license"]["features"], [])

    def test_license_payload_report_export_only_for_gold_and_diamond(self):
        from desktop_api.permissions import FEATURE_REPORT_EXPORT, plan_allows
        from desktop_api.views import license_payload

        for plan, expected in (("basic", False), ("gold", True), ("diamond", True)):
            self.license.plan = plan
            self.assertIs(FEATURE_REPORT_EXPORT in license_payload(self.license)["features"], expected, plan)
            self.assertIs(plan_allows(self.license, FEATURE_REPORT_EXPORT), expected, plan)

    def test_list_always_includes_main_warehouse(self):
        Warehouse.objects.all().delete()
        r = self.call("get", "/api/warehouses/", token=self.staff_token)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual([w["is_main"] for w in r.json()], [True])

    def test_create_respects_plan_limit_and_role(self):
        self.assertEqual(self.add_warehouse(token=self.staff_token).status_code, 403)
        self.assertEqual(self.add_warehouse("W2").status_code, 201)
        self.assertEqual(self.add_warehouse("W3").status_code, 400)  # الحد الافتراضي = 2
        self.license.max_warehouses = 3
        self.license.save()
        self.assertEqual(self.add_warehouse("w2").status_code, 400)  # اسم مكرر
        self.assertEqual(self.add_warehouse("W3").status_code, 201)

    def test_basic_plan_is_rejected_from_warehouse_api(self):
        DesktopLicense.objects.filter(pk=self.license.pk).update(plan="basic")
        r = self.add_warehouse()
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["detail"], ONLINE_PLAN_REQUIRED_MESSAGE)

    def test_medicine_defaults_to_main_and_accepts_own_warehouse_only(self):
        r = self.call("post", "/api/medicines/", {"trade_name": "A"})
        self.assertEqual(r.json()["warehouse"], self.main.pk)
        w2 = self.add_warehouse().json()["id"]
        r = self.call("post", "/api/medicines/", {"trade_name": "B", "warehouse": w2})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["warehouse"], w2)
        other_wh = Warehouse.main_for(Pharmacy.objects.create(name="P2"))
        r = self.call("post", "/api/medicines/", {"trade_name": "C", "warehouse": other_wh.pk})
        self.assertEqual(r.status_code, 400)
        results = self.call("get", f"/api/medicines/?warehouse={w2}").json()["results"]
        self.assertEqual([m["trade_name"] for m in results], ["B"])
        # لا تغيير للمخزن عبر PATCH — النقل فقط
        r = self.call("patch", f"/api/medicines/{results[0]['id']}/", {"warehouse": self.main.pk})
        self.assertEqual(r.status_code, 400)

    def test_same_barcode_allowed_in_different_warehouses_only(self):
        w2 = self.add_warehouse().json()["id"]
        self.assertEqual(self.call("post", "/api/medicines/", {"trade_name": "A", "barcode": "111"}).status_code, 201)
        self.assertEqual(self.call("post", "/api/medicines/", {"trade_name": "A", "barcode": "111"}).status_code, 400)
        r = self.call("post", "/api/medicines/", {"trade_name": "A", "barcode": "111", "warehouse": w2})
        self.assertEqual(r.status_code, 201)

    def test_transfer_merges_by_barcode_and_removes_empty_source(self):
        w2 = Warehouse.objects.get(pk=self.add_warehouse().json()["id"])
        src = Medicine.objects.create(pharmacy=self.pharmacy, warehouse=w2, trade_name="A", barcode="111", quantity=10)
        dst = Medicine.objects.create(pharmacy=self.pharmacy, warehouse=self.main, trade_name="A", barcode="111", quantity=3)

        r = self.transfer(src.pk, self.main.pk, 4)
        self.assertEqual(r.status_code, 201, r.content)
        src.refresh_from_db()
        dst.refresh_from_db()
        self.assertEqual((src.quantity, dst.quantity), (6, 7))

        r = self.transfer(src.pk, self.main.pk, 6)
        self.assertTrue(r.json()["source_deleted"])
        self.assertFalse(Medicine.objects.filter(pk=src.pk).exists())
        dst.refresh_from_db()
        self.assertEqual(dst.quantity, 13)
        self.assertEqual(StockTransfer.objects.count(), 2)

    def test_transfer_creates_row_and_keeps_referenced_source_at_zero(self):
        w2 = self.add_warehouse().json()["id"]
        src = Medicine.objects.create(pharmacy=self.pharmacy, warehouse=self.main, trade_name="A", quantity=5, sell_price=10)
        sale = self.call("post", "/api/invoices/checkout/", {"items": [{"medicine_id": src.pk, "quantity": 1}]})
        self.assertEqual(sale.status_code, 201, sale.content)

        r = self.transfer(src.pk, w2, 4)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertFalse(r.json()["source_deleted"])  # له سجل مبيعات فلا يُحذف
        src.refresh_from_db()
        self.assertEqual(src.quantity, 0)
        self.assertEqual(r.json()["destination"]["warehouse"], w2)
        self.assertEqual(r.json()["destination"]["quantity"], 4)

    def test_transfer_validation(self):
        w2 = self.add_warehouse().json()["id"]
        src = Medicine.objects.create(pharmacy=self.pharmacy, warehouse=self.main, trade_name="A", quantity=2)
        self.assertEqual(self.transfer(src.pk, w2, 3).status_code, 400)  # أكثر من المتوفر
        self.assertEqual(self.transfer(src.pk, self.main.pk, 1).status_code, 400)  # نفس المخزن
        other_wh = Warehouse.main_for(Pharmacy.objects.create(name="P2"))
        self.assertEqual(self.transfer(src.pk, other_wh.pk, 1).status_code, 400)  # صيدلية أخرى
        self.assertEqual(self.transfer(src.pk, w2, 1, self.staff_token).status_code, 403)
        src.refresh_from_db()
        self.assertEqual(src.quantity, 2)

    def test_downgrade_to_basic_blocks_online_api_but_keeps_data(self):
        w2 = Warehouse.objects.get(pk=self.add_warehouse().json()["id"])
        in_w2 = Medicine.objects.create(pharmacy=self.pharmacy, warehouse=w2, trade_name="A", quantity=2)
        in_main = Medicine.objects.create(pharmacy=self.pharmacy, warehouse=self.main, trade_name="B", quantity=2)
        # تخفيض الباقة إلى Basic يوقف الأونلاين كاملاً؛ البيانات تبقى سليمة.
        DesktopLicense.objects.filter(pk=self.license.pk).update(plan="basic")
        self.assertEqual(self.transfer(in_main.pk, w2.pk, 1).status_code, 403)
        self.assertEqual(self.transfer(in_w2.pk, self.main.pk, 2).status_code, 403)
        self.assertEqual(Medicine.objects.get(pk=in_w2.pk).quantity, 2)

    def test_checkout_only_from_main_warehouse(self):
        w2 = self.add_warehouse().json()["id"]
        med = Medicine.objects.create(pharmacy=self.pharmacy, warehouse_id=w2, trade_name="A", quantity=5, sell_price=10)
        r = self.call("post", "/api/invoices/checkout/", {"items": [{"medicine_id": med.pk, "quantity": 1}]})
        self.assertEqual(r.status_code, 400)
        med.refresh_from_db()
        self.assertEqual(med.quantity, 5)

    def test_delete_warehouse_rules(self):
        self.assertEqual(self.call("delete", f"/api/warehouses/{self.main.pk}/").status_code, 400)
        w2 = self.add_warehouse().json()["id"]
        med = Medicine.objects.create(pharmacy=self.pharmacy, warehouse_id=w2, trade_name="A", quantity=1)
        self.assertEqual(self.call("delete", f"/api/warehouses/{w2}/").status_code, 400)
        self.assertEqual(self.transfer(med.pk, self.main.pk, 1).status_code, 201)
        self.assertEqual(self.call("delete", f"/api/warehouses/{w2}/").status_code, 204)
        # سجل النقل يبقى مقروءاً بعد حذف المخزن
        record = StockTransfer.objects.get()
        self.assertIsNone(record.from_warehouse)
        self.assertEqual(record.from_warehouse_name, "W2")
        history = self.call("get", "/api/warehouses/transfers/").json()["results"]
        self.assertEqual(history[0]["from_warehouse_name"], "W2")

    def test_rename_warehouse(self):
        w2 = self.add_warehouse().json()["id"]
        r = self.call("patch", f"/api/warehouses/{w2}/", {"name": "مخزن الطابق الثاني"})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(Warehouse.objects.get(pk=w2).name, "مخزن الطابق الثاني")

    def test_migration_accepts_app_local_id_range(self):
        # التطبيق يعطي الصفوف المحلية معرّفات >= 10^12 (DatabaseHelper.localIdBase).
        base = 10**12
        payload = {
            "warehouses": [{"local_id": base + 1, "name": "Main", "is_main": True}],
            "medicines": [{"local_id": base + 5, "local_warehouse_id": base + 1, "trade_name": "A", "quantity": 3}],
            "invoices": [{
                "invoice_number": "INV-000001", "total_amount": 1, "final_amount": 1,
                "items": [{"local_medicine_id": base + 5, "trade_name": "A", "quantity": 1, "unit_price": 1, "total_price": 1}],
            }],
            "damaged_medicines": [{"local_medicine_id": base + 5, "quantity_damaged": 1}],
        }
        r = self.call("post", "/api/migration/upload_offline_data/", payload)
        body = b"".join(r.streaming_content).decode()
        self.assertIn('"event": "done"', body, body)
        medicine = Medicine.objects.get(pharmacy=self.pharmacy, trade_name="A")
        self.assertEqual(medicine.warehouse, self.main)
        self.assertEqual(medicine.invoice_items.count(), 1)
        self.assertEqual(medicine.damaged_records.count(), 1)

    def test_migration_maps_local_warehouses(self):
        payload = {
            "warehouses": [
                {"local_id": 10, "name": "رئيسي محلي", "is_main": True},
                {"local_id": 11, "name": "ثانوي", "is_main": False},
            ],
            "medicines": [
                {"local_id": 1, "local_warehouse_id": 10, "trade_name": "A", "barcode": "123", "quantity": 2},
                {"local_id": 2, "local_warehouse_id": 11, "trade_name": "A", "barcode": "123", "quantity": 3},
                {"local_id": 3, "trade_name": "Legacy", "quantity": 1},
            ],
            "stock_transfers": [
                {"local_from_warehouse_id": 10, "local_to_warehouse_id": 11, "trade_name": "A", "barcode": "123", "quantity": 3},
            ],
        }
        r = self.call("post", "/api/migration/upload_offline_data/", payload)
        body = b"".join(r.streaming_content).decode()
        self.assertIn('"event": "done"', body, body)
        secondary = Warehouse.objects.get(pharmacy=self.pharmacy, is_main=False)
        self.assertEqual(Warehouse.objects.filter(pharmacy=self.pharmacy).count(), 2)
        self.assertEqual(Medicine.objects.get(warehouse=secondary).barcode, "123")  # نفس الباركود بمخزن آخر
        self.assertEqual(Medicine.objects.filter(warehouse=self.main).count(), 2)
        self.assertEqual(StockTransfer.objects.get().to_warehouse, secondary)



@override_settings(ALLOWED_HOSTS=["testserver", "localhost"], PASSWORD_HASHERS=FAST_HASHERS)
class OnlinePlanTests(TestCase):
    """الأونلاين حصري لـ Gold/Diamond؛ الأوفلاين لكل الباقات."""

    PAYLOAD = {"medicines": [{"local_id": 1, "trade_name": "A", "quantity": 3}]}

    def setUp(self):
        cache.clear()
        self.pharmacy = Pharmacy.objects.create(name="P1")
        self.license = DesktopLicense.objects.create(pharmacy=self.pharmacy, mode="online", plan="gold", max_devices=3)
        self.owner = User.objects.create_user("owner", password=PASSWORD)
        PharmacyMembership.objects.create(user=self.owner, pharmacy=self.pharmacy, role="owner")
        DeviceActivation.objects.create(license=self.license, device_fingerprint="d1")

    def set_license(self, **fields):
        # update() يتجاوز clean() عمداً لمحاكاة ترخيص حُفظ قبل هذا التحقق.
        DesktopLicense.objects.filter(pk=self.license.pk).update(**fields)

    def login(self):
        return self.client.post(
            "/api/desktop/login/",
            json.dumps({"username": "owner", "password": PASSWORD, "device_fingerprint": "d1"}),
            content_type="application/json",
        )

    def get(self, path, token):
        return self.client.get(path, HTTP_AUTHORIZATION=f"Token {token}")

    def upload(self, token, payload):
        return self.client.post(
            "/api/migration/upload_offline_data/", json.dumps(payload),
            content_type="application/json", HTTP_AUTHORIZATION=f"Token {token}",
        )

    def run_command(self, payload, pharmacy_id=None):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "offline.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            out = StringIO()
            call_command(
                "migrate_offline_data", "--pharmacy-id", str(pharmacy_id or self.pharmacy.pk),
                "--file", str(path), stdout=out,
            )
            return out.getvalue()

    def test_online_basic_login_and_data_api_are_rejected(self):
        token = self.login().json()["api_token"]  # أُصدر عندما كانت Gold
        self.set_license(plan="basic")
        r = self.login()
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json(), {"ok": False, "message": ONLINE_PLAN_REQUIRED_MESSAGE})
        r = self.get("/api/medicines/", token)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["detail"], ONLINE_PLAN_REQUIRED_MESSAGE)

    def test_online_gold_and_diamond_work(self):
        for plan in ("gold", "diamond"):
            self.set_license(plan=plan)
            r = self.login()
            self.assertEqual(r.status_code, 200, (plan, r.content))
            self.assertEqual(self.get("/api/medicines/", r.json()["api_token"]).status_code, 200, plan)

    def test_offline_basic_login_still_works(self):
        self.set_license(plan="basic", mode="offline")
        r = self.login()
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["license"]["mode"], "offline")
        # واجهات البيانات تبقى للأونلاين فقط (الرسالة القديمة، لا رسالة الباقة).
        detail = self.get("/api/medicines/", r.json()["api_token"]).json()["detail"]
        self.assertNotEqual(detail, ONLINE_PLAN_REQUIRED_MESSAGE)

    def test_full_clean_rejects_online_basic_only(self):
        def make(mode, plan):
            return DesktopLicense(pharmacy=Pharmacy.objects.create(name=f"{mode}-{plan}"), mode=mode, plan=plan)

        with self.assertRaises(ValidationError) as ctx:
            make("online", "basic").full_clean()
        self.assertEqual(ctx.exception.message_dict["mode"], [ONLINE_PLAN_REQUIRED_MESSAGE])
        for mode, plan in (("offline", "basic"), ("online", "gold"), ("online", "diamond"), ("offline", "gold")):
            make(mode, plan).full_clean()

    def test_admin_shows_validation_error_and_help_text(self):
        admin_user = User.objects.create_superuser("admin", password=PASSWORD)
        self.client.force_login(admin_user)
        other = DesktopLicense.objects.create(pharmacy=Pharmacy.objects.create(name="P2"), mode="offline", plan="basic")
        url = f"/admin/desktop_api/desktoplicense/{other.pk}/change/"
        self.assertContains(self.client.get(url), "Online requires Gold or Diamond plan")
        data = {
            "pharmacy": other.pharmacy_id, "mode": "online", "license_type": "lifetime", "plan": "basic",
            "status": "active", "max_devices": 1, "max_warehouses": 2, "offline_grace_days": 30,
            "expires_at_0": "", "expires_at_1": "",
            "devices-TOTAL_FORMS": 0, "devices-INITIAL_FORMS": 0,
            "devices-MIN_NUM_FORMS": 0, "devices-MAX_NUM_FORMS": 1000,
        }
        r = self.client.post(url, data)
        self.assertEqual(r.status_code, 200)  # النموذج أُعيد مع الخطأ، لم يُحفظ
        self.assertContains(r, ONLINE_PLAN_REQUIRED_MESSAGE)
        other.refresh_from_db()
        self.assertEqual(other.mode, "offline")
        data["plan"] = "gold"
        self.assertEqual(self.client.post(url, data).status_code, 302)
        other.refresh_from_db()
        self.assertEqual((other.mode, other.plan), ("online", "gold"))

    def test_migration_endpoint_rejected_for_basic_and_works_for_gold(self):
        token = self.login().json()["api_token"]
        self.set_license(plan="basic")
        self.assertEqual(self.upload(token, self.PAYLOAD).status_code, 403)
        self.assertFalse(Medicine.objects.filter(pharmacy=self.pharmacy).exists())
        self.set_license(plan="gold")
        body = b"".join(self.upload(token, self.PAYLOAD).streaming_content).decode()
        self.assertIn('"event": "done"', body, body)
        self.assertEqual(Medicine.objects.filter(pharmacy=self.pharmacy).count(), 1)

    def test_command_rejected_for_basic(self):
        self.set_license(plan="basic", mode="offline")
        with self.assertRaisesMessage(CommandError, ONLINE_PLAN_REQUIRED_MESSAGE):
            self.run_command(self.PAYLOAD)
        self.assertFalse(Medicine.objects.filter(pharmacy=self.pharmacy).exists())

    def test_command_imports_for_gold_and_prints_summary(self):
        out = self.run_command(self.PAYLOAD)
        self.assertIn("medicines_created", out)
        self.assertEqual(Medicine.objects.filter(pharmacy=self.pharmacy).count(), 1)
        self.pharmacy.refresh_from_db()
        self.assertIsNotNone(self.pharmacy.migrated_from_offline_at)
        with self.assertRaises(CommandError):  # لا تكرار
            self.run_command(self.PAYLOAD)

    def test_command_refuses_existing_data_and_rolls_back_on_error(self):
        Medicine.objects.create(pharmacy=self.pharmacy, trade_name="Live", quantity=1)
        with self.assertRaisesMessage(CommandError, "توجد بيانات أونلاين"):
            self.run_command(self.PAYLOAD)
        Medicine.objects.all().delete()
        bad = {
            "medicines": [{"local_id": 1, "trade_name": "A"}],
            "invoices": [{"invoice_number": "X", "items": [{"local_medicine_id": 999, "quantity": 1}]}],
        }
        with self.assertRaises(CommandError):
            self.run_command(bad)
        self.assertFalse(Medicine.objects.filter(pharmacy=self.pharmacy).exists())  # معاملة واحدة
        with self.assertRaises(CommandError):
            self.run_command(self.PAYLOAD, pharmacy_id=99999)
