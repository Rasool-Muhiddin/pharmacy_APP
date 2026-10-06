import json
import unittest
from datetime import datetime, time, timedelta
from decimal import Decimal
from pathlib import Path

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone

from desktop_api.models import DesktopLicense, DeviceActivation, Pharmacy, PharmacyMembership
from pharmacy_data import reports
from pharmacy_data.models import (
    DamagedMedicine,
    Expense,
    Invoice,
    InvoiceItem,
    Medicine,
    MedicineBatch,
    PurchaseInvoice,
    PurchaseInvoiceReturn,
    Supplier,
    SupplierPayment,
    Warehouse,
)

User = get_user_model()
PASSWORD = "Passw0rd!x-test"
# نفس الملف تقرؤه test/reports_local_service_test.dart في Flutter: الحسابان يجب أن يتطابقا.
PARITY_FIXTURE = Path(settings.BASE_DIR).parent / "test" / "fixtures" / "reports_parity.json"

SECTIONS = ["kpis", "trend", "categories", "hours", "items", "stagnant", "inventory", "purchases", "losses", "invoices", "sellers"]


def D(value):
    return None if value is None else Decimal(str(value))


def num(value):
    return round(float(value), 2)


@override_settings(ALLOWED_HOSTS=["testserver"], PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class ReportsTestBase(TestCase):
    def setUp(self):
        cache.clear()
        self.pharmacy, self.owner_token, self.staff_token = self.make_pharmacy("P1", "owner", "staff", "d1")
        self.today = timezone.localdate()

    def make_pharmacy(self, name, owner, staff, device, mode="online"):
        pharmacy = Pharmacy.objects.create(name=name)
        license = DesktopLicense.objects.create(pharmacy=pharmacy, mode=mode, plan="gold", max_devices=3)
        DeviceActivation.objects.create(license=license, device_fingerprint=device)
        tokens = []
        for username, role in ((owner, "owner"), (staff, "staff")):
            user = User.objects.create_user(username, password=PASSWORD)
            PharmacyMembership.objects.create(user=user, pharmacy=pharmacy, role=role)
            tokens.append(self.login(username, device))
        return pharmacy, tokens[0], tokens[1]

    def login(self, username, device="d1"):
        r = self.client.post(
            "/api/desktop/login/",
            json.dumps({"username": username, "password": PASSWORD, "device_fingerprint": device}),
            content_type="application/json",
        )
        return r.json().get("api_token")

    def get(self, section, token=None, **params):
        query = "&".join(f"{k}={v}" for k, v in params.items())
        return self.client.get(
            f"/api/reports/{section}/?{query}", HTTP_AUTHORIZATION="Token " + (token or self.owner_token)
        )

    def day(self, offset):
        return self.today + timedelta(days=offset)

    def at(self, offset, hour=12):
        return timezone.make_aware(datetime.combine(self.day(offset), time(hour)), timezone.get_current_timezone())

    def period(self, start_offset, end_offset):
        return {"start": self.day(start_offset).isoformat(), "end": self.day(end_offset).isoformat()}

    def load_fixture(self, pharmacy=None):
        """يبني بيانات reports_parity.json ويعيد {اسم: Medicine}."""
        pharmacy = pharmacy or self.pharmacy
        fixture = json.loads(PARITY_FIXTURE.read_text(encoding="utf-8"))
        warehouse = Warehouse.main_for(pharmacy)
        suppliers = {name: Supplier.objects.create(pharmacy=pharmacy, name=name) for name in fixture["suppliers"]}
        sellers = {
            name: User.objects.create_user(f"{pharmacy.pk}-{name.lower()}", password=PASSWORD, first_name=name)
            for name in fixture["sellers"]
        }
        medicines = {}
        for key, spec in fixture["medicines"].items():
            medicine = Medicine.objects.create(
                pharmacy=pharmacy, warehouse=warehouse, trade_name=key, category=spec["category"],
                buy_price=D(spec["buy_price"]), sell_price=D(spec["sell_price"]), avg_cost=D(spec["avg_cost"]),
                quantity=sum(b["quantity"] for b in spec["batches"]),
            )
            for b in spec["batches"]:
                MedicineBatch.objects.create(
                    pharmacy=pharmacy, medicine=medicine, quantity=b["quantity"],
                    expiry_date=self.day(b["expiry_offset"]), purchase_price=D(b["purchase_price"]),
                    supplier=suppliers.get(b["supplier"]),
                )
            medicines[key] = medicine
        for inv in fixture["invoices"]:
            total = sum(D(it["unit_price"]) * it["quantity"] for it in inv["items"])
            discount = D(inv["discount"])
            invoice = Invoice.objects.create(
                pharmacy=pharmacy, invoice_number=inv["number"], cashier=sellers[inv["seller"]],
                total_amount=total, discount=discount, final_amount=total - discount,
                is_refunded=inv["is_refunded"], created_at=self.at(inv["day_offset"], inv["hour"]),
            )
            for it in inv["items"]:
                InvoiceItem.objects.create(
                    invoice=invoice, medicine=medicines[it["medicine"]], trade_name=it["medicine"],
                    quantity=it["quantity"], unit_price=D(it["unit_price"]),
                    total_price=D(it["unit_price"]) * it["quantity"], unit_cost=D(it["unit_cost"]),
                )
        for e in fixture["expenses"]:
            Expense.objects.create(pharmacy=pharmacy, expense_type=e["type"], amount=D(e["amount"]),
                                   expense_date=self.day(e["day_offset"]))
        for d in fixture["damaged"]:
            DamagedMedicine.objects.create(
                pharmacy=pharmacy, medicine=medicines[d["medicine"]], quantity_damaged=d["quantity"],
                total_cost=D(d["total_cost"]), reason=d["reason"], damaged_at=self.day(d["day_offset"]),
            )
        for p in fixture["purchase_invoices"]:
            supplier = suppliers[p["supplier"]]
            invoice = PurchaseInvoice.objects.create(
                pharmacy=pharmacy, supplier=supplier, invoice_number=p["number"], total_amount=D(p["total"]),
                paid_amount=sum((D(x["amount"]) for x in p["payments"]), Decimal("0")),
                created_at=self.at(p["day_offset"]),
            )
            for x in p["payments"]:
                SupplierPayment.objects.create(pharmacy=pharmacy, supplier=supplier, purchase_invoice=invoice,
                                               amount_paid=D(x["amount"]), paid_at=self.at(x["day_offset"]))
            for x in p["returns"]:
                PurchaseInvoiceReturn.objects.create(pharmacy=pharmacy, supplier=supplier, purchase_invoice=invoice,
                                                     amount_returned=D(x["amount"]), returned_at=self.at(x["day_offset"]))
        return fixture, medicines


@unittest.skipUnless(PARITY_FIXTURE.exists(), "Flutter test fixture not available")
class ReportsParityTests(ReportsTestBase):
    """كل قسم يطابق expected في reports_parity.json (نفس ما يتحقق منه اختبار Flutter)."""

    def setUp(self):
        super().setUp()
        self.fixture, self.medicines = self.load_fixture()
        self.expected = self.fixture["expected"]
        p = self.fixture["period"]
        self.params = self.period(p["start_offset"], p["end_offset"])

    def section(self, name, **extra):
        r = self.get(name, **self.params, **extra)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def assert_money(self, actual, expected):
        self.assertEqual(num(actual), num(expected))

    def assert_figures(self, actual, expected):
        for key, value in expected.items():
            self.assertEqual(num(actual[key]), num(value), key)

    def test_kpis_with_previous_period_and_alerts(self):
        data = self.section("kpis")
        self.assertEqual(data["previous_start"], self.day(-13).isoformat())
        self.assertEqual(data["previous_end"], self.day(-7).isoformat())
        self.assert_figures(data["current"], self.expected["kpis"]["current"])
        self.assert_figures(data["previous"], self.expected["kpis"]["previous"])
        self.assert_figures(data["alerts"], self.expected["kpis"]["alerts"])

    def test_net_profit_matches_existing_summary_field(self):
        summary = self.client.get(
            "/api/reports/summary/?start={start}&end={end}".format(**self.params),
            HTTP_AUTHORIZATION="Token " + self.owner_token,
        ).json()
        kpis = self.section("kpis")["current"]
        for key in ("gross_profit", "net_profit", "cost_of_goods_sold", "damage_cost"):
            self.assert_money(summary[key], kpis[key])

    def test_trend_buckets(self):
        data = self.section("trend")
        expected = self.expected["trend"]
        self.assertEqual(data["bucket"], expected["bucket"])
        points = {p["key"]: p for p in data["points"]}
        self.assertEqual(len(points), len(expected["points_by_offset"]))
        for offset, (net, gross) in expected["points_by_offset"].items():
            point = points[self.day(int(offset)).isoformat()]
            self.assert_money(point["net_sales"], net)
            self.assert_money(point["gross_profit"], gross)

    def test_categories_and_hours(self):
        categories = self.section("categories")["categories"]
        self.assertEqual(
            [(c["category"], num(c["net_sales"]), c["quantity"]) for c in categories],
            [(c["category"], num(c["net_sales"]), c["quantity"]) for c in self.expected["categories"]],
        )
        hours = self.section("hours")["hours"]
        self.assertEqual(len(hours), 24)
        for h in hours:
            count, net = self.expected["hours"].get(str(h["hour"]), [0, 0])
            self.assertEqual(h["invoices_count"], count)
            self.assert_money(h["net_sales"], net)

    def test_items_sorting_profit_and_below_cost(self):
        expected = self.expected["items"]
        for sort in ("qty", "revenue", "profit"):
            data = self.section("items", sort=sort)
            self.assertEqual([i["trade_name"] for i in data["items"]], expected[sort], sort)
        rows = {i["trade_name"]: i for i in self.section("items")["items"]}
        for name, row in expected["rows"].items():
            self.assert_figures(rows[name], row)
        below = self.section("items")["below_cost"]
        self.assertEqual(len(below), len(expected["below_cost"]))
        for actual, exp in zip(below, expected["below_cost"]):
            self.assertEqual(actual["medicine_id"], self.medicines[exp["medicine"]].pk)
            self.assert_figures(actual, {k: v for k, v in exp.items() if k != "medicine"})

    def test_stagnant_value_and_last_sale(self):
        data = self.section("stagnant")
        expected = self.expected["stagnant"]
        self.assertEqual(data["count"], expected["count"])
        self.assert_money(data["total_value"], expected["total_value"])
        for actual, exp in zip(data["results"], expected["results"]):
            self.assertEqual(actual["trade_name"], exp["medicine"])
            self.assertEqual(actual["quantity"], exp["quantity"])
            self.assertEqual(actual["category"], exp["category"])
            self.assert_money(actual["stock_value"], exp["stock_value"])
            self.assertEqual(actual["last_sale"], self.day(exp["last_sale_offset"]).isoformat())

    def test_inventory_current_state(self):
        expected = self.expected["inventory"]
        data = self.client.get(
            f"/api/reports/inventory/?days={expected['days']}", HTTP_AUTHORIZATION="Token " + self.owner_token
        ).json()
        for key in ("stock_cost_value", "stock_sell_value", "expected_profit", "expiring_value", "expired_value"):
            self.assert_money(data[key], expected[key])
        for list_key in ("expiring", "expired"):
            self.assertEqual(len(data[list_key]), len(expected[list_key]))
            for actual, exp in zip(data[list_key], expected[list_key]):
                self.assertEqual(actual["trade_name"], exp["medicine"])
                self.assertEqual(actual["quantity"], exp["quantity"])
                self.assertEqual(actual["supplier_name"], exp["supplier_name"])
                self.assertEqual(actual["expiry_date"], self.day(exp["expiry_offset"]).isoformat())
                self.assert_money(actual["value"], exp["value"])
        self.assertEqual([m["trade_name"] for m in data["low_stock"]], expected["low_stock"])
        self.assertEqual(data["low_stock_threshold"], reports.LOW_STOCK_THRESHOLD)

    def test_purchases_period_and_current_debt(self):
        data = self.section("purchases")
        expected = self.expected["purchases"]
        for key in ("purchases_total", "returns_total", "payments_total", "refunds_received", "total_debt", "total_credit"):
            self.assert_money(data[key], expected[key])
        self.assertEqual(data["invoices_count"], expected["invoices_count"])
        self.assertEqual(
            [(s["name"], s["invoices_count"], num(s["total"]), num(s["returns"])) for s in data["by_supplier"]],
            [(s["name"], s["invoices_count"], num(s["total"]), num(s["returns"])) for s in expected["by_supplier"]],
        )
        self.assertEqual([(d["name"], num(d["debt"])) for d in data["top_debtors"]],
                         [(d["name"], num(d["debt"])) for d in expected["top_debtors"]])

    def test_losses_by_type_and_reason(self):
        data = self.section("losses")
        expected = self.expected["losses"]
        for key in ("expenses_total", "damage_total", "expired_recorded", "expired_not_disposed_value"):
            self.assert_money(data[key], expected[key])
        self.assertEqual([(e["type"], num(e["total"]), e["count"]) for e in data["expenses_by_type"]],
                         [(e["type"], num(e["total"]), e["count"]) for e in expected["expenses_by_type"]])
        self.assertEqual(
            [(d["reason"], num(d["total"]), d["quantity"], d["count"]) for d in data["damage_by_reason"]],
            [(d["reason"], num(d["total"]), d["quantity"], d["count"]) for d in expected["damage_by_reason"]],
        )

    def test_invoices_filters_and_sellers(self):
        expected = self.expected["invoices"]
        cases = {"all": {}, "seller_ali": {"seller": "Ali"}, "search_000002": {"q": "000002"}, "refunded": {"refunded": "1"}}
        for name, params in cases.items():
            data = self.section("invoices", **params)
            self.assertEqual(data["count"], expected[name]["count"], name)
            self.assertEqual([i["invoice_number"] for i in data["results"]], expected[name]["numbers"], name)
        first = self.section("invoices")["results"][0]
        self.assertEqual(first["seller_name"], "Ali")
        self.assertTrue(first["created_at"].startswith(f"{self.today.isoformat()}T10:00:00"))
        self.assert_money(self.section("invoices")["total_amount"], expected["all"]["total_amount"])
        sellers = self.section("sellers")["sellers"]
        self.assertEqual([(s["seller_name"], s["invoices_count"], num(s["net_sales"])) for s in sellers],
                         [(s["seller_name"], s["invoices_count"], num(s["net_sales"])) for s in self.expected["sellers"]])


class ReportsBehaviourTests(ReportsTestBase):
    def create_invoice(self, number, offset=0, amount="1000", pharmacy=None):
        return Invoice.objects.create(
            pharmacy=pharmacy or self.pharmacy, invoice_number=number, total_amount=Decimal(amount),
            final_amount=Decimal(amount), created_at=self.at(offset),
        )

    def test_owner_only_and_online_license_required(self):
        for section in SECTIONS:
            self.assertEqual(self.get(section).status_code, 200, section)
            self.assertEqual(self.get(section, token=self.staff_token).status_code, 403, section)
        _, offline_owner, _ = self.make_pharmacy("Offline", "o2", "s2", "d2", mode="offline")
        for section in SECTIONS:
            self.assertIn(self.get(section, token=offline_owner).status_code, (401, 403), section)

    def test_pharmacy_scoping(self):
        other, other_owner, _ = self.make_pharmacy("P2", "owner2", "staff2", "d3")
        self.create_invoice("MINE", amount="1000")
        self.create_invoice("THEIRS", amount="7000", pharmacy=other)
        params = self.period(-1, 0)
        self.assertEqual(num(self.get("kpis", **params).json()["current"]["net_sales"]), 1000)
        self.assertEqual(num(self.get("kpis", token=other_owner, **params).json()["current"]["net_sales"]), 7000)
        numbers = [i["invoice_number"] for i in self.get("invoices", **params).json()["results"]]
        self.assertEqual(numbers, ["MINE"])

    def test_previous_period_comparison_has_equal_length(self):
        self.create_invoice("NOW", offset=-2, amount="300")
        self.create_invoice("BEFORE", offset=-12, amount="200")
        self.create_invoice("TOO-OLD", offset=-20, amount="999")
        data = self.get("kpis", **self.period(-9, 0)).json()  # 10 أيام → السابقة [-19, -10]
        self.assertEqual(data["previous_start"], self.day(-19).isoformat())
        self.assertEqual(num(data["current"]["net_sales"]), 300)
        self.assertEqual(num(data["previous"]["net_sales"]), 200)

    def test_inclusive_days_in_local_time(self):
        tz = timezone.get_current_timezone()
        late = timezone.make_aware(datetime.combine(self.today, time(23, 59)), tz)
        early = timezone.make_aware(datetime.combine(self.today, time(0, 1)), tz)
        for number, when in (("LATE", late), ("EARLY", early)):
            Invoice.objects.create(pharmacy=self.pharmacy, invoice_number=number, total_amount=Decimal("100"),
                                   final_amount=Decimal("100"), created_at=when)
        data = self.get("kpis", **self.period(0, 0)).json()
        self.assertEqual(data["current"]["invoices_count"], 2)
        self.assertEqual(self.get("kpis", **self.period(-1, -1)).json()["current"]["invoices_count"], 0)

    def test_invoices_pagination(self):
        for n in range(7):
            self.create_invoice(f"INV-{n:03d}", offset=-(n % 3))
        params = self.period(-5, 0)
        page1 = self.get("invoices", page=1, page_size=3, **params).json()
        page3 = self.get("invoices", page=3, page_size=3, **params).json()
        self.assertEqual(page1["count"], 7)
        self.assertEqual(len(page1["results"]), 3)
        self.assertEqual(len(page3["results"]), 1)
        all_numbers = [i["invoice_number"] for p in (1, 2, 3)
                       for i in self.get("invoices", page=p, page_size=3, **params).json()["results"]]
        self.assertEqual(sorted(all_numbers), sorted(f"INV-{n:03d}" for n in range(7)))
        self.assertEqual(self.get("invoices", page_size=10_000, **params).json()["page_size"], reports.MAX_PAGE_SIZE)

    def test_stagnant_pagination_has_no_hard_limit(self):
        warehouse = Warehouse.main_for(self.pharmacy)
        for n in range(12):
            medicine = Medicine.objects.create(pharmacy=self.pharmacy, warehouse=warehouse, trade_name=f"M{n:02d}",
                                               quantity=1, buy_price=Decimal(n + 1), avg_cost=Decimal(n + 1))
            MedicineBatch.objects.create(pharmacy=self.pharmacy, medicine=medicine, quantity=1,
                                         expiry_date=self.day(300), purchase_price=Decimal(n + 1))
        first = self.get("stagnant", page=1, page_size=5, **self.period(-6, 0)).json()
        last = self.get("stagnant", page=3, page_size=5, **self.period(-6, 0)).json()
        self.assertEqual(first["count"], 12)
        self.assertEqual(first["results"][0]["trade_name"], "M11")  # الأعلى قيمة أولاً
        self.assertEqual(len(last["results"]), 2)
        self.assertIsNone(first["results"][0]["last_sale"])

    def test_trend_bucket_size_follows_period_length(self):
        self.assertEqual(self.get("trend", **self.period(-29, 0)).json()["bucket"], "day")
        weekly = self.get("trend", **self.period(-89, 0)).json()
        self.assertEqual(weekly["bucket"], "week")
        self.assertEqual(len(weekly["points"]), 13)
        monthly = self.get("trend", **self.period(-364, 0)).json()
        self.assertEqual(monthly["bucket"], "month")
        self.assertEqual(monthly["points"][0]["key"], self.day(-364).isoformat())

    def test_invalid_parameters(self):
        self.assertEqual(self.get("kpis", start="2026-13-01").status_code, 400)
        self.assertEqual(self.get("kpis", **self.period(0, -1)).status_code, 400)
        self.assertEqual(self.get("inventory", days="abc").status_code, 400)
        self.assertEqual(self.get("inventory", days="0").status_code, 400)

    def test_summary_keeps_existing_fields(self):
        data = self.get("summary").json()
        for key in ("total_sales", "total_invoices_count", "total_discounts_given", "refunded_invoices_count",
                    "total_expenses", "total_supplier_debt", "total_damage_losses", "top_selling_items",
                    "stagnant_medicines", "invoices", "revenue", "cost_of_goods_sold", "gross_profit",
                    "damage_cost", "net_profit", "items_without_cost"):
            self.assertIn(key, data)
        self.assertIn("sellers", self.get("shifts").json())
