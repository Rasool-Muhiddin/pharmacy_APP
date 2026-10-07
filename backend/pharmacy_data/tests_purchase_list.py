"""
قائمة المذخر من المخزون (/api/purchase-invoices/from-list/) والرصيد الافتتاحي
(/api/medicines/opening-stock/): بونص، أصناف مجانية، تتبّع الدفعات، ذرّية
كاملة، وعزل الصيدليات. نفس السيناريوهات في test/purchase_list_db_test.dart.
"""

import json
import unittest
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, TransactionTestCase, override_settings
from django.utils import timezone

from desktop_api.models import DesktopLicense, DeviceActivation, Pharmacy, PharmacyMembership
from pharmacy_data.models import (
    Medicine,
    MedicineBatch,
    PurchaseInvoice,
    PurchaseInvoiceItem,
    Supplier,
    SupplierPayment,
    Warehouse,
)
from pharmacy_data.tests import PARITY_FIXTURE, PASSWORD

User = get_user_model()
COST = Decimal("0.0001")


def cost(value):
    return Decimal(str(value)).quantize(COST)


@override_settings(ALLOWED_HOSTS=["testserver"], PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class PurchaseListTestBase(TestCase):
    """الإعداد والأدوات المشتركة (بلا اختبارات) — يعيد استخدامها tests_supplier_returns."""

    LIST_URL = "/api/purchase-invoices/from-list/"
    OPENING_URL = "/api/medicines/opening-stock/"

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

    def expiry(self, days=365):
        return (self.today + timedelta(days=days)).isoformat()

    def create_medicine(self, trade_name="Panadol", quantity=10, buy="500", sell="1000", **extra):
        data = {"trade_name": trade_name, "quantity": quantity, "buy_price": buy, "sell_price": sell,
                "expiry_date": self.expiry(30)}
        data.update(extra)
        r = self.api("post", "/api/medicines/", data)
        self.assertEqual(r.status_code, 201, r.content)
        return Medicine.objects.get(pk=r.json()["id"])

    def line(self, trade_name, quantity=10, buy="1000", sell="1500", **extra):
        data = {"trade_name": trade_name, "quantity": quantity, "buy_price": buy, "sell_price": sell,
                "expiry_date": self.expiry()}
        data.update(extra)
        return data

    def free_line(self, trade_name, bonus, **extra):
        data = {"trade_name": trade_name, "is_free": True, "quantity": 0, "bonus_quantity": bonus,
                "expiry_date": self.expiry()}
        data.update(extra)
        return data

    def post_list(self, items, token=None, **header):
        body = {"supplier_name": "مذخر الشفاء", "invoice_number": "F-100", "items": items}
        body.update(header)
        return self.api("post", self.LIST_URL, body, token=token)

    def post_opening(self, items, token=None, **header):
        return self.api("post", self.OPENING_URL, {"items": items, **header}, token=token)

    def supplier_debt(self, name="مذخر الشفاء"):
        rows = self.api("get", "/api/suppliers/summary/").json()
        return Decimal(next(r for r in rows if r["name"] == name)["remaining_debt"])

    def assert_invariant(self, medicine):
        medicine.refresh_from_db()
        self.assertEqual(medicine.quantity, sum(b.quantity for b in medicine.batches.all()))



class PurchaseListTests(PurchaseListTestBase):
    # --- السيناريو الأساسي ---

    def test_new_and_existing_items_with_bonus(self):
        existing = self.create_medicine(quantity=10, buy="500", sell="1000")
        r = self.post_list([
            self.line("panadol", quantity=10, buy="1000", sell="1500", bonus_quantity=2),  # نفس الاسم بحالة أحرف مختلفة
            self.line("Brufen", quantity=4, buy="250", sell="400", barcode="999", category="tablet"),
        ], invoice_date=self.today.isoformat())
        self.assertEqual(r.status_code, 201, r.content)
        body = r.json()

        invoice = PurchaseInvoice.objects.get()
        self.assertEqual(invoice.total_amount, Decimal("11000.00"))  # 10×1000 + 4×250؛ البونص خارج الإجمالي
        self.assertEqual((invoice.item_count, invoice.source, invoice.invoice_date), (2, "inventory_list", self.today))
        self.assertEqual(body["purchase_invoice"]["item_count"], 2)
        self.assertEqual(len(body["medicines"]), 2)

        existing.refresh_from_db()
        self.assertEqual(existing.quantity, 22)  # 10 + 10 مدفوعة + 2 بونص
        self.assertEqual((existing.buy_price, existing.sell_price), (Decimal("1000.00"), Decimal("1500.00")))
        self.assertEqual(existing.avg_cost, Decimal("681.8182"))  # (10×500 + 12×833.3333) / 22
        new_batch = existing.batches.get(purchase_invoice=invoice)
        self.assertEqual((new_batch.quantity, new_batch.purchase_price), (12, Decimal("833.3333")))
        self.assertEqual((new_batch.supplier, new_batch.source), (invoice.supplier, "purchase_list"))
        self.assert_invariant(existing)

        brufen = Medicine.objects.get(trade_name="Brufen")
        self.assertEqual((brufen.quantity, brufen.avg_cost, brufen.barcode), (4, Decimal("250.0000"), "999"))
        self.assert_invariant(brufen)

        item = PurchaseInvoiceItem.objects.get(medicine=existing)
        self.assertEqual((item.quantity, item.bonus_quantity), (10, 2))  # البونص مخزَّن منفصلاً
        self.assertEqual((item.line_total, item.effective_unit_cost), (Decimal("10000.00"), Decimal("833.3333")))
        self.assertEqual(self.supplier_debt(), Decimal("11000.00"))

        listed = self.api("get", f"/api/medicines/{existing.pk}/").json()
        traced = next(b for b in listed["batches"] if b["purchase_invoice"] == invoice.pk)
        self.assertEqual((traced["supplier_name"], traced["purchase_invoice_number"]), ("مذخر الشفاء", "F-100"))

    def test_same_barcode_is_supply_not_duplicate(self):
        medicine = self.create_medicine("X", quantity=1, buy="10", sell="20", barcode="123")
        r = self.post_list([self.line("Other name", quantity=3, buy="10", sell="25", barcode="123")])
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(Medicine.objects.count(), 1)
        medicine.refresh_from_db()
        self.assertEqual((medicine.quantity, medicine.trade_name), (4, "X"))

    @unittest.skipUnless(PARITY_FIXTURE.exists(), "Flutter test fixture not available")
    def test_purchase_list_matches_shared_parity_fixture(self):
        scenario = json.loads(PARITY_FIXTURE.read_text(encoding="utf-8"))["purchase_list"]
        spec = scenario["existing"]
        self.create_medicine(spec["trade_name"], quantity=spec["quantity"], buy=str(spec["buy_price"]),
                             sell=str(spec["sell_price"]))
        lines = [
            {k: v for k, v in line.items() if k != "note" and v is not None} | {"expiry_date": self.expiry()}
            for line in scenario["lines"]
        ]
        r = self.post_list(lines)
        self.assertEqual(r.status_code, 201, r.content)
        expected = scenario["expected"]

        invoice = PurchaseInvoice.objects.get()
        self.assertEqual(invoice.total_amount, Decimal(str(expected["invoice_total"])))
        self.assertEqual(invoice.item_count, expected["item_count"])
        items = list(invoice.items.order_by("id"))
        self.assertEqual([i.line_total for i in items], [Decimal(str(v)) for v in expected["line_totals"]])
        self.assertEqual([i.effective_unit_cost for i in items], [cost(v) for v in expected["effective_unit_costs"]])
        self.assertEqual(self.supplier_debt(), Decimal(str(expected["invoice_total"])))

        for name, exp in expected["medicines"].items():
            medicine = Medicine.objects.get(trade_name=name)
            self.assertEqual(medicine.quantity, exp["quantity"], name)
            self.assertEqual(medicine.avg_cost, cost(exp["avg_cost"]), name)
            self.assertEqual(medicine.buy_price, Decimal(str(exp["buy_price"])), name)
            self.assertEqual(medicine.sell_price, Decimal(str(exp["sell_price"])), name)
            batch_costs = sorted(b.purchase_price for b in medicine.batches.all())
            self.assertEqual(batch_costs, [cost(c) for c in exp["batch_costs"]], name)
            self.assert_invariant(medicine)

        sale = [{"medicine_id": Medicine.objects.get(trade_name=s["medicine"]).pk, "quantity": s["quantity"]}
                for s in scenario["sale"]]
        self.assertEqual(self.api("post", "/api/invoices/checkout/", {"items": sale}).status_code, 201)
        report = self.api("get", "/api/reports/summary/").json()
        for key, value in expected["profit"].items():
            self.assertEqual(Decimal(str(report[key])), Decimal(str(value)), key)

    # --- الأصناف المجانية ---

    def test_free_line_on_existing_item(self):
        medicine = self.create_medicine(quantity=10, buy="500", sell="1000")
        r = self.post_list([self.free_line("Panadol", 5)])
        self.assertEqual(r.status_code, 201, r.content)
        medicine.refresh_from_db()
        self.assertEqual(medicine.quantity, 15)
        self.assertEqual(medicine.avg_cost, Decimal("333.3333"))  # (10×500 + 5×0) / 15
        self.assertEqual((medicine.buy_price, medicine.sell_price), (Decimal("500.00"), Decimal("1000.00")))
        batch = medicine.batches.get(purchase_invoice__isnull=False)
        self.assertEqual((batch.quantity, batch.purchase_price), (5, Decimal("0.0000")))
        invoice = PurchaseInvoice.objects.get()
        self.assertEqual((invoice.total_amount, invoice.item_count), (Decimal("0.00"), 1))
        self.assertTrue(invoice.items.get().is_free)
        self.assertEqual(self.supplier_debt(), Decimal("0"))

        self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": medicine.pk, "quantity": 3}]})
        report = self.api("get", "/api/reports/summary/").json()
        self.assertEqual(Decimal(report["cost_of_goods_sold"]), Decimal("1000.00"))  # 3 × 333.3333
        self.assertEqual(Decimal(report["gross_profit"]), Decimal("2000.00"))

    def test_free_line_new_item_requires_sell_price_and_has_zero_cost(self):
        r = self.post_list([self.free_line("Sample", 2)])
        self.assertEqual(r.status_code, 400, r.content)
        self.assertEqual(r.json()["line"], "0")
        r = self.post_list([self.free_line("Sample", 2, sell_price="300")])
        self.assertEqual(r.status_code, 201, r.content)
        medicine = Medicine.objects.get(trade_name="Sample")
        self.assertEqual((medicine.quantity, medicine.avg_cost, medicine.buy_price),
                         (2, Decimal("0.0000"), Decimal("0.00")))
        self.assertEqual(PurchaseInvoice.objects.get().total_amount, Decimal("0.00"))

    def test_line_validation(self):
        cases = [
            self.line("A", quantity=0),                                  # مدفوع بلا كمية
            self.line("A", buy="0"),                                     # مدفوع بلا سعر شراء
            self.line("A", sell="0"),                                    # بلا سعر بيع
            self.line("A", is_free=True, quantity=2, bonus_quantity=1),  # مجاني بكمية مدفوعة
            self.free_line("A", 0, sell_price="5"),                      # مجاني بلا كمية
            self.line("A", expiry_date=None),                            # بلا صلاحية
            self.line("", quantity=1),                                   # بلا اسم
        ]
        for case in cases:
            r = self.post_list([self.line("OK"), case])
            self.assertEqual(r.status_code, 400, (case, r.content))
            self.assertEqual(r.json()["line"], "1", case)
        for malformed in (self.line("A", bonus_quantity=-1), self.line("A", expiry_date="31-31-2030"),
                          self.line("A", quantity="abc")):
            r = self.post_list([self.line("OK"), malformed])
            self.assertEqual(r.status_code, 400, r.content)
            self.assertEqual(r.json()["line"], "1", malformed)
        self.assertEqual(self.post_list([self.line("A", expiry_date="")]).json()["line"], "0")
        self.assertEqual(self.post_list([]).status_code, 400)
        self.assertFalse(Medicine.objects.exists())
        self.assertFalse(PurchaseInvoice.objects.exists())

    # --- الدفع والتكرار والذرّية ---

    def test_initial_payment_creates_supplier_payment(self):
        r = self.post_list([self.line("A", quantity=10, buy="100")], paid_amount="400")
        self.assertEqual(r.status_code, 201, r.content)
        invoice = PurchaseInvoice.objects.get()
        self.assertEqual(invoice.paid_amount, Decimal("400.00"))
        self.assertEqual(SupplierPayment.objects.get().amount_paid, Decimal("400.00"))
        self.assertEqual(self.supplier_debt(), Decimal("600.00"))
        self.assertEqual(Decimal(r.json()["purchase_invoice"]["remaining_amount"]), Decimal("600.00"))
        r = self.api("post", f"/api/purchase-invoices/{invoice.pk}/add_payment/", {"amount": "600"})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(self.supplier_debt(), Decimal("0"))

    def test_statement_running_balance_matches_debt(self):
        r = self.post_list([self.line("A", quantity=10, buy="100")], paid_amount="400")
        invoice_id = r.json()["purchase_invoice"]["id"]
        supplier_id = r.json()["supplier"]["id"]
        self.api("post", f"/api/purchase-invoices/{invoice_id}/add_payment/", {"amount": "100"})
        self.api("post", f"/api/purchase-invoices/{invoice_id}/add_return/", {"amount": "50"})
        # فاتورة يدوية قديمة دُفع جزء منها عند إنشائها بلا سطر دفعة.
        PurchaseInvoice.objects.create(pharmacy=self.pharmacy, supplier_id=supplier_id, invoice_number="OLD",
                                       total_amount=Decimal("100"), paid_amount=Decimal("40"))
        rows = self.api("get", f"/api/suppliers/{supplier_id}/statement/").json()
        balance = sum(Decimal(str(row["debt_added"])) for row in rows)
        self.assertEqual(balance, Decimal("510.00"))  # (1000 − 400 − 100 − 50) + (100 − 40)
        self.assertEqual(self.supplier_debt(), Decimal("510.00"))

    def test_no_payment_creates_no_supplier_payment(self):
        self.assertEqual(self.post_list([self.line("A")]).status_code, 201)
        self.assertFalse(SupplierPayment.objects.exists())

    def test_overpayment_rolls_back(self):
        r = self.post_list([self.line("A", quantity=1, buy="100")], paid_amount="101")
        self.assertEqual(r.status_code, 400)
        self.assertFalse(Medicine.objects.exists())
        self.assertFalse(PurchaseInvoice.objects.exists())

    def test_duplicate_invoice_number_per_supplier_rejected(self):
        self.assertEqual(self.post_list([self.line("A")]).status_code, 201)
        supplier = Supplier.objects.get()
        r = self.post_list([self.line("B")], supplier=supplier.pk, supplier_name="")
        self.assertEqual(r.status_code, 400, r.content)
        self.assertIn("F-100", r.json()["detail"])
        self.assertFalse(Medicine.objects.filter(trade_name="B").exists())
        # نفس الاسم المكتوب يُعاد استخدامه بدل إنشاء مذخر مكرر، فيُرفض أيضاً.
        self.assertEqual(self.post_list([self.line("B")]).status_code, 400)
        self.assertEqual(Supplier.objects.count(), 1)
        # نفس الرقم لمذخر آخر مقبول؛ والرقم الفارغ مرفوض.
        self.assertEqual(self.post_list([self.line("B")], supplier_name="مذخر آخر").status_code, 201)
        self.assertEqual(self.post_list([self.line("C")], invoice_number="  ").status_code, 400)

    def test_failing_item_rolls_back_everything(self):
        medicine = self.create_medicine(quantity=10, buy="500", sell="1000")
        r = self.post_list([
            self.line("Panadol", quantity=5),
            self.line("Fresh", quantity=5),
            self.line("Broken", quantity=5, sell="0"),
        ], supplier_name="مذخر جديد", paid_amount="100")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["line"], "2")
        medicine.refresh_from_db()
        self.assertEqual((medicine.quantity, medicine.avg_cost, medicine.batches.count()),
                         (10, Decimal("500.0000"), 1))
        self.assertEqual(Medicine.objects.count(), 1)
        self.assertFalse(Supplier.objects.exists())
        self.assertFalse(PurchaseInvoice.objects.exists())
        self.assertFalse(PurchaseInvoiceItem.objects.exists())
        self.assertFalse(SupplierPayment.objects.exists())

    # --- العزل والصلاحيات ---

    def test_cross_pharmacy_ids_rejected(self):
        other = Pharmacy.objects.create(name="P2")
        other_wh = Warehouse.main_for(other)
        other_supplier = Supplier.objects.create(pharmacy=other, name="S2")
        other_med = Medicine.objects.create(pharmacy=other, warehouse=other_wh, trade_name="Z", sell_price=1)
        self.assertEqual(self.post_list([self.line("A")], supplier=other_supplier.pk).status_code, 400)
        self.assertEqual(self.post_list([self.line("A")], warehouse=other_wh.pk).status_code, 400)
        self.assertEqual(self.post_list([self.line("A", medicine_id=other_med.pk)]).status_code, 400)
        self.assertEqual(self.post_opening([self.line("A")], warehouse=other_wh.pk).status_code, 400)
        self.assertEqual(self.post_opening([self.line("A", medicine_id=other_med.pk)]).status_code, 400)
        other_invoice = PurchaseInvoice.objects.create(pharmacy=other, supplier=other_supplier, invoice_number="Q")
        self.assertEqual(self.api("get", f"/api/purchase-invoices/{other_invoice.pk}/items/").status_code, 404)
        self.assertEqual(self.api("get", f"/api/suppliers/{other_supplier.pk}/purchased-items/").status_code, 404)
        self.assertFalse(Medicine.objects.filter(pharmacy=self.pharmacy).exists())
        self.assertFalse(PurchaseInvoice.objects.filter(pharmacy=self.pharmacy).exists())
        self.assertEqual(Medicine.objects.get(pk=other_med.pk).quantity, 0)

    def test_secondary_warehouse_list(self):
        DesktopLicense.objects.filter(pharmacy=self.pharmacy).update(max_warehouses=2)
        second = self.api("post", "/api/warehouses/", {"name": "Second"}).json()["id"]
        main_med = self.create_medicine(quantity=1)
        r = self.post_list([self.line("Panadol", quantity=2)], warehouse=second)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(Medicine.objects.get(warehouse_id=second).quantity, 2)  # صنف جديد في المخزن الثاني
        main_med.refresh_from_db()
        self.assertEqual(main_med.quantity, 1)

    def test_staff_basic_and_offline_licenses_rejected(self):
        self.assertEqual(self.post_list([self.line("A")], token=self.staff_token).status_code, 403)
        self.assertEqual(self.post_opening([self.line("A")], token=self.staff_token).status_code, 403)
        DesktopLicense.objects.filter(pharmacy=self.pharmacy).update(plan="basic")
        self.assertEqual(self.post_list([self.line("A")]).status_code, 403)
        self.assertEqual(self.post_opening([self.line("A")]).status_code, 403)
        DesktopLicense.objects.filter(pharmacy=self.pharmacy).update(plan="gold", mode="offline")
        self.assertEqual(self.post_list([self.line("A")]).status_code, 403)
        self.assertEqual(self.post_opening([self.line("A")]).status_code, 403)
        self.assertFalse(Medicine.objects.exists())

    # --- الرصيد الافتتاحي ---

    def test_opening_stock_updates_stock_without_invoice_or_debt(self):
        existing = self.create_medicine(quantity=10, buy="500", sell="1000")
        r = self.post_opening([
            self.line("Panadol", quantity=10, buy="700", sell="1200"),
            self.line("Unknown cost", quantity=3, buy="0", sell="50"),
        ])
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(len(r.json()["medicines"]), 2)
        existing.refresh_from_db()
        self.assertEqual((existing.quantity, existing.avg_cost, existing.sell_price),
                         (20, Decimal("600.0000"), Decimal("1200.00")))
        batch = existing.batches.get(source="opening_stock")
        self.assertEqual((batch.supplier, batch.purchase_invoice, batch.purchase_price),
                         (None, None, Decimal("700.0000")))
        unknown = Medicine.objects.get(trade_name="Unknown cost")
        self.assertIsNone(unknown.avg_cost)  # سعر شراء 0 = كلفة غير معروفة (كالإضافة القديمة)
        self.assertEqual(unknown.quantity, 3)
        self.assertIsNone(unknown.batches.get().purchase_price)
        self.assertFalse(PurchaseInvoice.objects.exists())
        self.assertFalse(Supplier.objects.exists())
        self.assertFalse(SupplierPayment.objects.exists())
        listed = self.api("get", f"/api/medicines/{existing.pk}/").json()
        self.assertIn("opening_stock", [b["source"] for b in listed["batches"]])

    def test_opening_stock_rejects_bonus_free_and_rolls_back(self):
        for bad in (self.line("A", bonus_quantity=1), self.free_line("A", 2, sell_price="5"), self.line("A", sell="0")):
            r = self.post_opening([self.line("OK"), bad])
            self.assertEqual(r.status_code, 400, r.content)
            self.assertEqual(r.json()["line"], "1")
        self.assertFalse(Medicine.objects.exists())

    # --- العرض والتتبّع ---

    def test_invoice_items_and_supplier_purchased_items(self):
        self.post_list([self.line("A", quantity=2, bonus_quantity=1), self.free_line("Gift", 4, sell_price="10")])
        invoice = PurchaseInvoice.objects.get()
        items = self.api("get", f"/api/purchase-invoices/{invoice.pk}/items/").json()
        self.assertEqual([(i["trade_name"], i["quantity"], i["bonus_quantity"], i["is_free"]) for i in items],
                         [("A", 2, 1, False), ("Gift", 0, 4, True)])
        bought = self.api("get", f"/api/suppliers/{invoice.supplier_id}/purchased-items/").json()
        self.assertEqual(len(bought), 2)
        self.assertEqual({b["invoice_number"] for b in bought}, {"F-100"})

        # فاتورة يدوية قديمة بلا أصناف تبقى تعمل وتُحسب في الدين.
        legacy = PurchaseInvoice.objects.create(pharmacy=self.pharmacy, supplier=invoice.supplier,
                                                invoice_number="OLD", total_amount=500)
        self.assertEqual(self.api("get", f"/api/purchase-invoices/{legacy.pk}/items/").json(), [])
        listed = {i["invoice_number"]: i for i in self.api("get", "/api/purchase-invoices/").json()["results"]}
        self.assertEqual((listed["OLD"]["source"], listed["OLD"]["item_count"]), ("manual", 0))
        self.assertEqual(self.supplier_debt(), Decimal("2500.00"))  # 2×1000 + 500

    def test_deleting_medicine_keeps_invoice_history(self):
        self.post_list([self.line("A")])
        Medicine.objects.get(trade_name="A").delete()
        item = PurchaseInvoiceItem.objects.get()
        self.assertIsNone(item.medicine)
        self.assertEqual(item.trade_name, "A")

    def test_transfer_keeps_batch_source(self):
        DesktopLicense.objects.filter(pharmacy=self.pharmacy).update(max_warehouses=2)
        second = self.api("post", "/api/warehouses/", {"name": "Second"}).json()["id"]
        self.post_list([self.line("A", quantity=5)])
        medicine = Medicine.objects.get(trade_name="A")
        r = self.api("post", "/api/warehouses/transfer/",
                     {"medicine_id": medicine.pk, "to_warehouse_id": second, "quantity": 2})
        self.assertEqual(r.status_code, 201, r.content)
        moved = MedicineBatch.objects.get(medicine__warehouse_id=second)
        self.assertEqual((moved.supplier.name, moved.purchase_invoice.invoice_number, moved.source),
                         ("مذخر الشفاء", "F-100", "purchase_list"))

    def test_offline_import_carries_purchase_items_and_batch_links(self):
        exp = self.expiry()
        linked = {"source": "purchase_list", "local_supplier_id": 7, "local_purchase_invoice_id": 50,
                  "expiry_date": exp}
        payload = {
            "suppliers": [{"local_id": 7, "name": "S"}],
            "medicines": [
                {"local_id": 1, "trade_name": "A", "quantity": 15, "avg_cost": 600,
                 "batches": [{"quantity": 12, "purchase_price": 833.3333, **linked},
                             {"quantity": 3, "purchase_price": 0, **linked}]},
                {"local_id": 2, "trade_name": "B", "quantity": 1, "avg_cost": None,
                 "batches": [{"quantity": 1, "expiry_date": exp, "purchase_price": None, "source": "opening_stock"}]},
            ],
            "purchase_invoices": [
                {"local_id": 50, "local_supplier_id": 7, "invoice_number": "F1", "total_amount": 10000,
                 "paid_amount": 0, "invoice_date": self.today.isoformat(), "source": "inventory_list",
                 "item_count": 2,
                 "items": [{"local_medicine_id": 1, "trade_name": "A", "quantity": 10, "bonus_quantity": 2,
                            "buy_price": 1000, "effective_unit_cost": 833.3333, "sell_price": 1500,
                            "expiry_date": exp, "line_total": 10000},
                           {"local_medicine_id": None, "trade_name": "Deleted", "quantity": 0,
                            "bonus_quantity": 3, "buy_price": 0, "effective_unit_cost": 0, "sell_price": 10,
                            "line_total": 0}]},
                {"local_id": 51, "local_supplier_id": 7, "invoice_number": "F1", "total_amount": 5},
            ],
        }
        r = self.api("post", "/api/migration/upload_offline_data/", payload)
        self.assertIn('"event": "done"', b"".join(r.streaming_content).decode())
        invoice = PurchaseInvoice.objects.get(invoice_number="F1")
        self.assertEqual((invoice.source, invoice.item_count, invoice.invoice_date),
                         ("inventory_list", 2, self.today))
        self.assertEqual(PurchaseInvoice.objects.get(total_amount=5).invoice_number, "F1-2")  # مكرر قديم
        items = list(invoice.items.order_by("id"))
        self.assertEqual((items[0].bonus_quantity, items[0].medicine.trade_name), (2, "A"))
        self.assertIsNone(items[1].medicine)
        medicine = Medicine.objects.get(trade_name="A")
        self.assertEqual(medicine.avg_cost, Decimal("600.0000"))
        batches = list(medicine.batches.order_by("purchase_price"))
        self.assertEqual([b.purchase_price for b in batches], [Decimal("0.0000"), Decimal("833.3333")])
        self.assertTrue(all(b.purchase_invoice == invoice and b.supplier.name == "S" for b in batches))
        opening = Medicine.objects.get(trade_name="B").batches.get()
        self.assertEqual((opening.source, opening.purchase_price, opening.purchase_invoice),
                         ("opening_stock", None, None))


class PurchaseInvoiceDedupeMigrationTests(TransactionTestCase):
    # TransactionTestCase: محرّر مخطط SQLite لا يعمل داخل معاملة الاختبار.
    def test_duplicates_get_suffix_and_nothing_is_deleted(self):
        from importlib import import_module

        from django.apps import apps as global_apps
        from django.db import connection

        unique = next(c for c in PurchaseInvoice._meta.constraints
                      if c.name == "unique_purchase_invoice_number_per_supplier")
        pharmacy = Pharmacy.objects.create(name="M")
        supplier = Supplier.objects.create(pharmacy=pharmacy, name="S")
        other = Supplier.objects.create(pharmacy=pharmacy, name="S2")
        # القيد مفعّل في قاعدة الاختبار؛ يُزال مؤقتاً لمحاكاة بيانات ما قبل 0014.
        with connection.schema_editor() as editor:
            editor.remove_constraint(PurchaseInvoice, unique)
        try:
            def create(number="", owner=supplier):
                return PurchaseInvoice.objects.create(pharmacy=pharmacy, supplier=owner, invoice_number=number)

            first, taken, second, third = create("7"), create("7-2"), create("7"), create("7")
            elsewhere, blank1, blank2 = create("7", other), create(), create()
            import_module("pharmacy_data.migrations.0013_dedupe_purchase_invoice_numbers").dedupe(global_apps, None)

            def numbers(*objs):
                return [PurchaseInvoice.objects.get(pk=o.pk).invoice_number for o in objs]

            self.assertEqual(numbers(first, taken, second, third, elsewhere), ["7", "7-2", "7-3", "7-4", "7"])
            self.assertEqual(numbers(blank1, blank2), ["", ""])
            self.assertEqual(PurchaseInvoice.objects.count(), 7)
        finally:
            PurchaseInvoice.objects.all().delete()
            with connection.schema_editor() as editor:
                editor.add_constraint(PurchaseInvoice, unique)


class SupplierScreenApiTests(PurchaseListTestBase):
    """شاشة المذاخر: حقول الملخص الإضافية، وتصحيح اسم المذخر (الاسم فقط)."""

    def summary_row(self, name):
        return next(r for r in self.api("get", "/api/suppliers/summary/").json() if r["name"] == name)

    def test_summary_has_paid_last_invoice_date_and_month_purchases(self):
        r = self.post_list([self.line("Panadol", quantity=10, buy="1000")], paid_amount="4000",
                           invoice_date=self.today.isoformat())
        self.assertEqual(r.status_code, 201, r.content)
        old = (self.today.replace(day=1) - timedelta(days=40)).isoformat()
        r = self.post_list([self.line("Brufen", quantity=5, buy="1000")], invoice_number="F-OLD", invoice_date=old)
        self.assertEqual(r.status_code, 201, r.content)

        row = self.summary_row("مذخر الشفاء")
        self.assertEqual(Decimal(row["total_paid"]), Decimal("4000"))
        self.assertEqual(row["last_invoice_date"], self.today.isoformat())
        self.assertEqual(Decimal(row["month_purchases"]), Decimal("10000"))

        Supplier.objects.create(pharmacy=self.pharmacy, name="بلا فواتير")
        empty = self.summary_row("بلا فواتير")
        self.assertIsNone(empty["last_invoice_date"])
        self.assertEqual(Decimal(empty["month_purchases"]), Decimal("0"))

    def test_rename_supplier_name_only_with_validation(self):
        target = Supplier.objects.create(pharmacy=self.pharmacy, name="مذخر النور", phone="0770")
        Supplier.objects.create(pharmacy=self.pharmacy, name="Alpha")
        url = f"/api/suppliers/{target.pk}/"

        self.assertEqual(self.api("patch", url, {"name": "  "}).status_code, 400)
        self.assertEqual(self.api("patch", url, {"name": "alpha"}).status_code, 400)
        r = self.api("patch", url, {"name": "  مذخر النور الجديد "})
        self.assertEqual(r.status_code, 200, r.content)
        target.refresh_from_db()
        self.assertEqual(target.name, "مذخر النور الجديد")
        self.assertEqual(target.phone, "0770")
        # نفس الاسم لنفس المذخر (تغيير حالة الأحرف فقط) مسموح.
        self.assertEqual(self.api("patch", url, {"name": "مذخر النور الجديد"}).status_code, 200)
        # الإنشاء القديم (إصدارات سابقة من التطبيق) بلا تغيير.
        self.assertEqual(self.api("post", "/api/suppliers/", {"name": "Alpha", "phone": ""}).status_code, 201)
