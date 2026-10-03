import json
import unittest
from datetime import timedelta
from decimal import Decimal
from pathlib import Path

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone

from desktop_api.models import DesktopLicense, DeviceActivation, Pharmacy, PharmacyMembership
from pharmacy_data import stock
from pharmacy_data.models import (
    DamagedMedicine,
    Expense,
    Invoice,
    InvoiceItem,
    Medicine,
    MedicineBatch,
    Warehouse,
)

User = get_user_model()
PASSWORD = "Passw0rd!x-test"
# نفس الملف تقرؤه test/profit_tracking_test.dart في Flutter: الحسابان يجب أن يتطابقا.
PARITY_FIXTURE = Path(settings.BASE_DIR).parent / "test" / "fixtures" / "profit_parity.json"


@override_settings(ALLOWED_HOSTS=["testserver"], PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class ProfitTrackingTests(TestCase):
    """متوسط الكلفة المرجّح + لقطة unit_cost + دفعات FEFO المخفية + تقرير الربح."""

    def setUp(self):
        cache.clear()
        self.pharmacy = Pharmacy.objects.create(name="P1")
        license = DesktopLicense.objects.create(pharmacy=self.pharmacy, mode="online", plan="gold", max_devices=3)
        DeviceActivation.objects.create(license=license, device_fingerprint="d1")
        for username, role in (("owner", "owner"), ("staff", "staff")):
            user = User.objects.create_user(username, password=PASSWORD)
            PharmacyMembership.objects.create(user=user, pharmacy=self.pharmacy, role=role)
        self.owner_token = self.login("owner")
        self.staff_token = self.login("staff")
        self.today = timezone.localdate()

    def login(self, username):
        r = self.client.post(
            "/api/desktop/login/",
            json.dumps({"username": username, "password": PASSWORD, "device_fingerprint": "d1"}),
            content_type="application/json",
        )
        return r.json()["api_token"]

    def api(self, method, path, data=None, token=None):
        kwargs = {"HTTP_AUTHORIZATION": "Token " + (token or self.owner_token)}
        if data is not None:
            kwargs.update(data=json.dumps(data), content_type="application/json")
        return getattr(self.client, method)(path, **kwargs)

    def create_medicine(self, quantity=10, buy="500", sell="1000", expiry_days=100):
        r = self.api("post", "/api/medicines/", {
            "trade_name": "Panadol", "quantity": quantity, "buy_price": buy, "sell_price": sell,
            "expiry_date": (self.today + timedelta(days=expiry_days)).isoformat(),
        })
        self.assertEqual(r.status_code, 201, r.content)
        return Medicine.objects.get(pk=r.json()["id"])

    def assert_invariant(self, medicine):
        medicine.refresh_from_db()
        batch_total = sum(b.quantity for b in medicine.batches.all())
        self.assertEqual(medicine.quantity, batch_total)

    def test_acceptance_scenario(self):
        # 10 وحدات بكلفة 500 وسعر 1000.
        medicine = self.create_medicine(quantity=10, buy="500", sell="1000", expiry_days=60)
        self.assertEqual(medicine.avg_cost, Decimal("500.0000"))
        self.assertEqual(medicine.batches.count(), 1)

        # توريد 20 بكلفة 750 وسعر 1250 (صلاحية أبعد).
        later = (self.today + timedelta(days=400)).isoformat()
        r = self.api("post", f"/api/medicines/{medicine.pk}/supply/",
                     {"quantity": 20, "expiry_date": later, "purchase_price": "750", "sale_price": "1250"})
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        self.assertEqual(Decimal(body["avg_cost"]).quantize(Decimal("0.01")), Decimal("666.67"))
        self.assertEqual(body["quantity"], 30)
        self.assertEqual(Decimal(body["sell_price"]), Decimal("1250"))
        self.assertEqual(len(body["batches"]), 2)
        self.assert_invariant(medicine)

        # بيع كل الـ30 بسعر 1250: FEFO يستنفد الدفعة الأقرب انتهاءً أولاً.
        r = self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": medicine.pk, "quantity": 10}]})
        self.assertEqual(r.status_code, 201, r.content)
        remaining = list(medicine.batches.values_list("expiry_date", "quantity"))
        self.assertEqual([(d.isoformat(), q) for d, q in remaining], [(later, 20)])  # الأقرب استُنفدت أولاً
        r = self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": medicine.pk, "quantity": 20}]})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertFalse(medicine.batches.exists())
        self.assert_invariant(medicine)

        report = self.api("get", "/api/reports/summary/").json()
        self.assertEqual(Decimal(report["revenue"]), Decimal("37500.00"))
        self.assertAlmostEqual(Decimal(report["gross_profit"]), Decimal("17500"), delta=Decimal("0.01"))
        self.assertEqual(report["items_without_cost"], 0)

        # تغيير سعر البيع لاحقاً لا يمس unit_cost ولا ربح المبيعات السابقة.
        costs_before = list(InvoiceItem.objects.order_by("id").values_list("unit_cost", flat=True))
        self.assertEqual(self.api("patch", f"/api/medicines/{medicine.pk}/", {"sell_price": "2000"}).status_code, 200)
        self.assertEqual(list(InvoiceItem.objects.order_by("id").values_list("unit_cost", flat=True)), costs_before)
        self.assertEqual(self.api("get", "/api/reports/summary/").json()["gross_profit"], report["gross_profit"])

    def test_first_supply_without_cost_requires_purchase_price_and_validates_prices(self):
        medicine = self.create_medicine(quantity=0, buy="0", sell="100")
        self.assertIsNone(medicine.avg_cost)
        url = f"/api/medicines/{medicine.pk}/supply/"
        self.assertEqual(self.api("post", url, {"quantity": 5, "sale_price": "100"}).status_code, 400)
        self.assertEqual(self.api("post", url, {"quantity": 5, "purchase_price": "0", "sale_price": "100"}).status_code, 400)
        self.assertEqual(self.api("post", url, {"quantity": 5, "purchase_price": "50", "sale_price": "0"}).status_code, 400)
        r = self.api("post", url, {"quantity": 5, "purchase_price": "50", "sale_price": "100"})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(Decimal(r.json()["avg_cost"]), Decimal("50"))
        # بلا purchase_price بعد معرفة الكلفة: يُستخدم avg_cost الحالي.
        r = self.api("post", url, {"quantity": 5, "sale_price": "100"})
        self.assertEqual(Decimal(r.json()["avg_cost"]), Decimal("50"))
        self.assertEqual(r.json()["quantity"], 10)

    def test_supply_is_owner_only_and_staff_never_sees_costs(self):
        medicine = self.create_medicine()
        url = f"/api/medicines/{medicine.pk}/supply/"
        self.assertEqual(self.api("post", url, {"quantity": 1, "sale_price": "1000"}, token=self.staff_token).status_code, 403)

        listed = self.api("get", "/api/medicines/", token=self.staff_token).json()["results"][0]
        self.assertNotIn("avg_cost", listed)
        self.assertNotIn("buy_price", listed)
        self.assertNotIn("purchase_price", listed["batches"][0])
        self.assertIn("avg_cost", self.api("get", "/api/medicines/").json()["results"][0])

        sold = self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": medicine.pk, "quantity": 1}]},
                        token=self.staff_token).json()
        self.assertNotIn("unit_cost", sold["items"][0])
        owner_view = self.api("get", f"/api/invoices/{sold['id']}/").json()
        self.assertEqual(Decimal(owner_view["items"][0]["unit_cost"]), Decimal("500"))
        self.assertEqual(self.api("get", "/api/reports/summary/", token=self.staff_token).status_code, 403)

    def test_client_cannot_set_costs_or_bypass_batches(self):
        medicine = self.create_medicine()
        self.api("patch", f"/api/medicines/{medicine.pk}/", {"avg_cost": "1", "quantity": 999, "expiry_date": "2099-01-01"})
        medicine.refresh_from_db()
        self.assertEqual((medicine.avg_cost, medicine.quantity), (Decimal("500.0000"), 10))
        self.assert_invariant(medicine)
        r = self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": medicine.pk, "quantity": 1, "unit_cost": "1"}]})
        self.assertEqual(InvoiceItem.objects.get(invoice_id=r.json()["id"]).unit_cost, Decimal("500.0000"))

    def test_sale_skips_expired_batches_damage_takes_them_first(self):
        medicine = self.create_medicine(quantity=3, expiry_days=200)
        MedicineBatch.objects.create(pharmacy=self.pharmacy, medicine=medicine, quantity=4,
                                     expiry_date=self.today - timedelta(days=1), purchase_price=Decimal("500"))
        stock.refresh_stock(medicine)
        self.assertEqual(medicine.quantity, 7)

        r = self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": medicine.pk, "quantity": 4}]})
        self.assertEqual(r.status_code, 400)  # 3 صالحة فقط
        self.assertEqual(self.api("post", "/api/invoices/checkout/",
                                  {"items": [{"medicine_id": medicine.pk, "quantity": 3}]}).status_code, 201)
        medicine.refresh_from_db()
        self.assertEqual(medicine.quantity, 4)  # بقيت الدفعة المنتهية فقط

        r = self.api("post", "/api/damaged-medicines/", {"medicine": medicine.pk, "quantity_damaged": 4, "reason": "expired"})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(Decimal(r.json()["total_cost"]), Decimal("2000.00"))
        self.assertFalse(medicine.batches.exists())
        self.assert_invariant(medicine)

    def test_refund_restores_latest_batch_keeps_avg_cost_and_reverses_profit(self):
        medicine = self.create_medicine(quantity=10, expiry_days=30)
        later = (self.today + timedelta(days=300)).isoformat()
        self.api("post", f"/api/medicines/{medicine.pk}/supply/",
                 {"quantity": 10, "expiry_date": later, "purchase_price": "700", "sale_price": "1000"})
        sold = self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": medicine.pk, "quantity": 12}]}).json()
        self.assertGreater(Decimal(self.api("get", "/api/reports/summary/").json()["gross_profit"]), 0)
        avg_before = Medicine.objects.get(pk=medicine.pk).avg_cost

        self.assertEqual(self.api("post", f"/api/invoices/{sold['id']}/refund/").status_code, 200)
        medicine.refresh_from_db()
        self.assertEqual(medicine.avg_cost, avg_before)
        self.assertEqual(medicine.quantity, 20)
        self.assertEqual(list(medicine.batches.values_list("quantity", flat=True)), [20])  # عادت للدفعة الأبعد
        self.assertEqual(Decimal(self.api("get", "/api/reports/summary/").json()["gross_profit"]), 0)

    def test_net_profit_discount_expenses_damage_and_missing_cost_warning(self):
        medicine = self.create_medicine(quantity=10, buy="400", sell="1000")
        self.api("post", "/api/invoices/checkout/", {"discount": "100", "items": [{"medicine_id": medicine.pk, "quantity": 2}]})
        legacy = self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": medicine.pk, "quantity": 1}]}).json()
        InvoiceItem.objects.filter(invoice_id=legacy["id"]).update(unit_cost=None)  # مبيعات قديمة بلا كلفة
        self.api("post", "/api/expenses/", {"expense_type": "rent", "expense_date": self.today.isoformat(), "amount": "50"})
        self.api("post", "/api/damaged-medicines/", {"medicine": medicine.pk, "quantity_damaged": 1, "reason": "broken"})

        report = self.api("get", "/api/reports/summary/").json()
        self.assertEqual(Decimal(report["revenue"]), Decimal("2900.00"))
        self.assertEqual(Decimal(report["cost_of_goods_sold"]), Decimal("800.00"))
        self.assertEqual(Decimal(report["gross_profit"]), Decimal("1100.00"))  # 2000 - 100 خصم - 800
        self.assertEqual(Decimal(report["damage_cost"]), Decimal("400.00"))
        self.assertEqual(Decimal(report["net_profit"]), Decimal("650.00"))  # 1100 - 50 - 400
        self.assertEqual(report["items_without_cost"], 1)

    def test_transfer_moves_batches_and_weights_target_cost(self):
        DesktopLicense.objects.filter(pharmacy=self.pharmacy).update(max_warehouses=2)
        medicine = self.create_medicine(quantity=10, expiry_days=50)
        second = self.api("post", "/api/warehouses/", {"name": "Second"}).json()["id"]
        r = self.api("post", "/api/warehouses/transfer/", {"medicine_id": medicine.pk, "to_warehouse_id": second, "quantity": 4})
        self.assertEqual(r.status_code, 201, r.content)
        target = Medicine.objects.get(warehouse_id=second)
        self.assertEqual(target.avg_cost, Decimal("500.0000"))
        self.assertEqual([(b.quantity, b.expiry_date) for b in target.batches.all()],
                         [(4, self.today + timedelta(days=50))])
        self.assert_invariant(target)
        self.assert_invariant(medicine)

    def test_offline_import_carries_costs_and_batches(self):
        exp = (self.today + timedelta(days=90)).isoformat()
        payload = {
            "medicines": [{"local_id": 1, "trade_name": "A", "quantity": 5, "avg_cost": 120.5,
                           "batches": [{"quantity": 2, "expiry_date": exp, "purchase_price": 100},
                                       {"quantity": 3, "expiry_date": None, "purchase_price": 134.1667}]}],
            "invoices": [{"invoice_number": "INV-000001", "total_amount": 200, "final_amount": 200,
                          "items": [{"local_medicine_id": 1, "trade_name": "A", "quantity": 1, "unit_price": 200,
                                     "total_price": 200, "unit_cost": 120.5}]}],
            "damaged_medicines": [{"local_medicine_id": 1, "quantity_damaged": 1, "total_cost": 120.5}],
        }
        r = self.api("post", "/api/migration/upload_offline_data/", payload)
        self.assertIn('"event": "done"', b"".join(r.streaming_content).decode())
        medicine = Medicine.objects.get(trade_name="A")
        self.assertEqual(medicine.avg_cost, Decimal("120.5000"))
        self.assertEqual(medicine.batches.count(), 2)
        self.assert_invariant(medicine)
        self.assertEqual(InvoiceItem.objects.get().unit_cost, Decimal("120.5000"))
        self.assertEqual(DamagedMedicine.objects.get().total_cost, Decimal("120.50"))

    # --- الخصومات ---

    def test_checkout_rounds_fractional_discount_half_up_and_rejects_negative(self):
        medicine = self.create_medicine(quantity=10, buy="500", sell="1255")
        # نسخة أقدم من التطبيق ترسل 12.5% من 1255 كما هي (156.875).
        r = self.api("post", "/api/invoices/checkout/",
                     {"discount": 156.875, "items": [{"medicine_id": medicine.pk, "quantity": 1}]})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual((Decimal(r.json()["discount"]), Decimal(r.json()["final_amount"])),
                         (Decimal("156.88"), Decimal("1098.12")))

        before = Invoice.objects.count()
        r = self.api("post", "/api/invoices/checkout/",
                     {"discount": "-1", "items": [{"medicine_id": medicine.pk, "quantity": 1}]})
        self.assertEqual(r.status_code, 400, r.content)
        self.assertIn("discount", r.json())
        self.assertEqual(Invoice.objects.count(), before)  # لا بيع
        medicine.refresh_from_db()
        self.assertEqual(medicine.quantity, 9)

    def test_offline_import_clamps_negative_discount_and_logs_it(self):
        payload = {
            "medicines": [{"local_id": 1, "trade_name": "A", "quantity": 5, "avg_cost": 100}],
            "invoices": [{"invoice_number": "INV-000009", "total_amount": 200, "discount": -40, "final_amount": 240,
                          "items": [{"local_medicine_id": 1, "trade_name": "A", "quantity": 1, "unit_price": 200,
                                     "total_price": 200, "unit_cost": 100}]}],
        }
        with self.assertLogs("pharmacy_data.offline_import", level="WARNING") as logs:
            r = self.api("post", "/api/migration/upload_offline_data/", payload)
            body = b"".join(r.streaming_content).decode()
        self.assertIn('"event": "done"', body)
        self.assertIn("INV-000009", logs.output[0])
        invoice = Invoice.objects.get(invoice_number="INV-000009")
        self.assertEqual((invoice.discount, invoice.final_amount), (Decimal("0"), Decimal("240")))

    def test_refund_of_discounted_invoice_reverses_exactly_its_own_profit(self):
        medicine = self.create_medicine(quantity=10, buy="400", sell="1000")
        keep = self.api("post", "/api/invoices/checkout/",
                        {"discount": "150", "items": [{"medicine_id": medicine.pk, "quantity": 2}]}).json()
        keep_profit = Decimal(self.api("get", "/api/reports/summary/").json()["gross_profit"])
        self.assertEqual(keep_profit, Decimal("1050.00"))  # 2000 - 150 - 800
        refunded = self.api("post", "/api/invoices/checkout/",
                            {"discount": "75", "items": [{"medicine_id": medicine.pk, "quantity": 3}]}).json()
        self.assertEqual(Decimal(self.api("get", "/api/reports/summary/").json()["gross_profit"]),
                         keep_profit + Decimal("1725.00"))  # 3000 - 75 - 1200
        self.assertEqual(self.api("post", f"/api/invoices/{refunded['id']}/refund/").status_code, 200)
        report = self.api("get", "/api/reports/summary/").json()
        self.assertEqual(Decimal(report["gross_profit"]), keep_profit)
        self.assertEqual(Decimal(report["revenue"]), Decimal(keep["final_amount"]))

    @unittest.skipUnless(PARITY_FIXTURE.exists(), "Flutter test fixture not available")
    def test_profit_summary_matches_shared_parity_fixture(self):
        fixture = json.loads(PARITY_FIXTURE.read_text(encoding="utf-8"))
        warehouse = Warehouse.main_for(self.pharmacy)
        medicines = {
            key: Medicine.objects.create(
                pharmacy=self.pharmacy, warehouse=warehouse, trade_name=key,
                avg_cost=None if spec["avg_cost"] is None else Decimal(str(spec["avg_cost"])),
            )
            for key, spec in fixture["medicines"].items()
        }
        for inv in fixture["invoices"]:
            total = sum(Decimal(str(it["unit_price"])) * it["quantity"] for it in inv["items"])
            discount = Decimal(str(inv["discount"]))
            invoice = Invoice.objects.create(
                pharmacy=self.pharmacy, invoice_number=inv["number"], total_amount=total,
                discount=discount, final_amount=total - discount, is_refunded=inv["is_refunded"],
            )
            for it in inv["items"]:
                InvoiceItem.objects.create(
                    invoice=invoice, medicine=medicines[it["medicine"]], trade_name=it["medicine"],
                    quantity=it["quantity"], unit_price=Decimal(str(it["unit_price"])),
                    total_price=Decimal(str(it["unit_price"])) * it["quantity"],
                    unit_cost=None if it["unit_cost"] is None else Decimal(str(it["unit_cost"])),
                )
        for amount in fixture["expenses"]:
            Expense.objects.create(pharmacy=self.pharmacy, expense_type="x", expense_date=self.today,
                                   amount=Decimal(str(amount)))
        for d in fixture["damaged"]:
            DamagedMedicine.objects.create(
                pharmacy=self.pharmacy, medicine=medicines[d["medicine"]], quantity_damaged=d["quantity"],
                total_cost=None if d["total_cost"] is None else Decimal(str(d["total_cost"])), reason=d["reason"],
            )

        report = self.api("get", "/api/reports/summary/").json()
        for key, expected in fixture["expected"].items():
            self.assertEqual(Decimal(str(report[key])), Decimal(str(expected)), key)


class WeightedAverageTests(TestCase):
    def test_formula(self):
        self.assertEqual(stock.weighted_avg_cost(10, Decimal("500"), 20, Decimal("750")), Decimal("666.6667"))
        self.assertEqual(stock.weighted_avg_cost(0, Decimal("500"), 5, Decimal("750")), Decimal("750.0000"))
        self.assertEqual(stock.weighted_avg_cost(10, None, 5, Decimal("750")), Decimal("750.0000"))

    def test_data_migration_backfill(self):
        from importlib import import_module

        from django.apps import apps as global_apps

        pharmacy = Pharmacy.objects.create(name="M")
        warehouse = Warehouse.main_for(pharmacy)
        with_cost = Medicine.objects.create(pharmacy=pharmacy, warehouse=warehouse, trade_name="A", quantity=4,
                                            buy_price=Decimal("10"), expiry_date=timezone.localdate())
        no_cost = Medicine.objects.create(pharmacy=pharmacy, warehouse=warehouse, trade_name="B", quantity=0,
                                          buy_price=Decimal("0"))
        backfill = import_module("pharmacy_data.migrations.0011_backfill_avg_cost_and_batches").backfill
        backfill(global_apps, None)
        with_cost.refresh_from_db(); no_cost.refresh_from_db()
        self.assertEqual(with_cost.avg_cost, Decimal("10.0000"))
        self.assertEqual(list(with_cost.batches.values_list("quantity", "expiry_date")), [(4, timezone.localdate())])
        self.assertIsNone(no_cost.avg_cost)
        self.assertFalse(no_cost.batches.exists())
