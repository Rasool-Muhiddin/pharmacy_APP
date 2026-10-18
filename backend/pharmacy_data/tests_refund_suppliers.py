from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings

from pharmacy_data.models import Invoice, Medicine, Supplier
from pharmacy_data import tests as base_tests
from pharmacy_data.views import MEDICINE_IN_USE_MESSAGE

User = get_user_model()


@override_settings(ALLOWED_HOSTS=["testserver"], PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class RefundTrackingTests(TestCase):
    """من أرجع الفاتورة ومتى (refunded_by/refunded_at)، ومنع حذف المذاخر، وحذف صنف له مبيعات."""

    # نفس تجهيز ProfitTrackingTests (مالك + موظف أونلاين Gold) بلا إعادة تشغيل اختباراته.
    setUp = base_tests.ProfitTrackingTests.setUp
    login = base_tests.ProfitTrackingTests.login
    api = base_tests.ProfitTrackingTests.api
    create_medicine = base_tests.ProfitTrackingTests.create_medicine

    def checkout(self, medicine, quantity=1):
        r = self.api("post", "/api/invoices/checkout/", {"discount": 0, "items": [{"medicine_id": medicine.pk, "quantity": quantity}]})
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()

    def test_refund_records_requesting_user_and_time(self):
        User.objects.filter(username="staff").update(first_name="Sara", last_name="Ali")
        medicine = self.create_medicine(quantity=5)
        sold = self.checkout(medicine)
        self.assertIsNone(sold["refunded_at"])
        self.assertIsNone(sold["refunded_by_display"])

        r = self.api("post", f"/api/invoices/{sold['id']}/refund/", token=self.staff_token)
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        self.assertTrue(body["is_refunded"])
        self.assertEqual(body["refunded_by_display"], "Sara Ali")
        self.assertIsNotNone(body["refunded_at"])
        invoice = Invoice.objects.get(pk=sold["id"])
        self.assertEqual(invoice.refunded_by.username, "staff")

        listed = self.api("get", "/api/invoices/").json()["results"][0]
        self.assertEqual((listed["refunded_by_display"], listed["refunded_at"]), (body["refunded_by_display"], body["refunded_at"]))
        # إرجاع ثانٍ مرفوض ولا يغيّر المنفّذ.
        self.assertEqual(self.api("post", f"/api/invoices/{sold['id']}/refund/").status_code, 400)
        self.assertEqual(Invoice.objects.get(pk=sold["id"]).refunded_by.username, "staff")

    def test_offline_import_carries_refund_name_and_time(self):
        payload = {
            "medicines": [{"local_id": 1, "trade_name": "A", "quantity": 5, "avg_cost": 100}],
            "invoices": [
                {"invoice_number": "INV-000001", "total_amount": 200, "final_amount": 200, "is_refunded": True,
                 "refunded_by_name": "Omar", "refunded_at": "2026-10-03T09:15:00",
                 "items": [{"local_medicine_id": 1, "trade_name": "A", "quantity": 1, "unit_price": 200, "total_price": 200}]},
            ],
        }
        r = self.api("post", "/api/migration/upload_offline_data/", payload)
        self.assertIn('"event": "done"', b"".join(r.streaming_content).decode())
        invoice = Invoice.objects.get(invoice_number="INV-000001")
        self.assertIsNone(invoice.refunded_by)
        self.assertEqual(invoice.refunded_by_name, "Omar")
        self.assertEqual(invoice.refunded_at.date().isoformat(), "2026-10-03")
        listed = self.api("get", "/api/invoices/").json()["results"][0]
        self.assertEqual(listed["refunded_by_display"], "Omar")

    def test_suppliers_cannot_be_deleted(self):
        supplier = Supplier.objects.create(pharmacy=self.pharmacy, name="S1")
        r = self.api("delete", f"/api/suppliers/{supplier.pk}/")
        self.assertEqual(r.status_code, 405, r.content)
        self.assertTrue(Supplier.objects.filter(pk=supplier.pk).exists())
        # القراءة والتعديل يبقيان.
        self.assertEqual(self.api("get", f"/api/suppliers/{supplier.pk}/").status_code, 200)
        self.assertEqual(self.api("patch", f"/api/suppliers/{supplier.pk}/", {"name": "S1b"}).status_code, 200)

    def test_medicine_with_sales_cannot_be_deleted_clear_message(self):
        sold = self.create_medicine(quantity=5)
        self.checkout(sold)
        r = self.api("delete", f"/api/medicines/{sold.pk}/")
        self.assertEqual(r.status_code, 400, r.content)
        self.assertEqual(r.json(), [MEDICINE_IN_USE_MESSAGE])
        self.assertTrue(Medicine.objects.filter(pk=sold.pk).exists())

        r = self.api("post", "/api/medicines/", {"trade_name": "Mistake", "quantity": 0, "buy_price": "1", "sell_price": "2"})
        self.assertEqual(self.api("delete", f"/api/medicines/{r.json()['id']}/").status_code, 204)

    def test_medicine_search_for_damage_picker(self):
        for name, scientific, qty in [("Panadol", "Paracetamol", 5), ("Panadol Extra", "Paracetamol", 0), ("Augmentin", "Amoxicillin", 3)]:
            r = self.api("post", "/api/medicines/", {"trade_name": name, "scientific_name": scientific, "quantity": qty,
                                                     "buy_price": "100", "sell_price": "200"})
            self.assertEqual(r.status_code, 201, r.content)

        def names(**params):
            query = "&".join(f"{k}={v}" for k, v in params.items())
            return [m["trade_name"] for m in self.api("get", f"/api/medicines/?{query}").json()["results"]]

        self.assertEqual(names(search="pana"), ["Panadol", "Panadol Extra"])
        self.assertEqual(names(search="pana", in_stock=1), ["Panadol"])
        self.assertEqual(names(search="amoxi", in_stock=1), ["Augmentin"])
        self.assertEqual(len(names(search="a", page_size=1)), 1)
        self.assertEqual(len(names()), 3)  # بلا بحث: كالسابق
        self.assertEqual(Decimal(self.api("get", "/api/medicines/?search=pana").json()["results"][0]["sell_price"]), Decimal("200"))
