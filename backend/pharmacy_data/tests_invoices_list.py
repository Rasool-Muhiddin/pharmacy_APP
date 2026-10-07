from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import connection
from django.test.utils import CaptureQueriesContext

from pharmacy_data.models import Invoice, InvoiceItem, Medicine, Warehouse
from pharmacy_data.tests_reports import PASSWORD, ReportsTestBase

User = get_user_model()


class InvoiceListTests(ReportsTestBase):
    def setUp(self):
        super().setUp()
        warehouse = Warehouse.main_for(self.pharmacy)
        medicine = Medicine.objects.create(pharmacy=self.pharmacy, warehouse=warehouse, trade_name="Med",
                                           sell_price=Decimal("2"), quantity=100)
        self.sellers = [
            User.objects.create_user(f"seller{i}", password=PASSWORD, first_name=name)
            for i, name in enumerate(["Ali", "Sara", "Omar"])
        ]
        # 60 فاتورة على 6 أيام، 3 بائعين مختلفين، كل خامسة مسترجعة.
        for i in range(60):
            invoice = Invoice.objects.create(
                pharmacy=self.pharmacy, invoice_number=f"INV-{i:06d}", cashier=self.sellers[i % 3],
                total_amount=Decimal("10"), discount=Decimal("1"), final_amount=Decimal("9"),
                is_refunded=i % 5 == 0, created_at=self.at(-(i % 6), 10),
            )
            InvoiceItem.objects.create(invoice=invoice, medicine=medicine, trade_name="Med", quantity=1,
                                       unit_price=Decimal("10"), total_price=Decimal("10"))

    def list(self, token=None, **params):
        query = "&".join(f"{k}={v}" for k, v in params.items())
        return self.client.get(f"/api/invoices/?{query}", HTTP_AUTHORIZATION="Token " + (token or self.owner_token))

    def count_queries(self, **params):
        with CaptureQueriesContext(connection) as ctx:
            response = self.list(**params)
        self.assertEqual(response.status_code, 200)
        return len(ctx), response.json()

    def test_query_count_does_not_grow_with_page_size(self):
        small, small_body = self.count_queries(page_size=5)
        large, large_body = self.count_queries(page_size=50)
        self.assertEqual(len(small_body["results"]), 5)
        self.assertEqual(len(large_body["results"]), 50)
        self.assertEqual(small, large)
        self.assertEqual(large_body["results"][0]["cashier_display_name"], self.sellers[0].first_name)

    def test_page_size_is_capped(self):
        body = self.list(page_size=1000).json()
        self.assertEqual(len(body["results"]), 60)  # كل الموجود (< 200)
        self.assertEqual(body["count"], 60)

    def test_pagination_walks_all_invoices_newest_first(self):
        first = self.list(page_size=25).json()
        third = self.list(page_size=25, page=3).json()
        self.assertEqual(first["count"], 60)
        self.assertIsNotNone(first["next"])
        self.assertEqual(len(third["results"]), 10)
        self.assertIsNone(third["next"])
        dates = [r["created_at"] for r in first["results"]]
        self.assertEqual(dates, sorted(dates, reverse=True))

    def test_search_by_invoice_number_and_seller(self):
        self.assertEqual(self.list(search="INV-000007").json()["count"], 1)
        # البائع Sara = كل فاتورة i % 3 == 1.
        self.assertEqual(self.list(search="sara").json()["count"], 20)
        self.assertEqual(self.list(search="nobody").json()["count"], 0)

    def test_date_filter_is_inclusive_local_days(self):
        today = self.day(0).isoformat()
        two_days_ago = self.day(-2).isoformat()
        self.assertEqual(self.list(start=today, end=today).json()["count"], 10)
        self.assertEqual(self.list(start=two_days_ago, end=today).json()["count"], 30)
        self.assertEqual(self.list(start="2026-13-01").status_code, 400)

    def test_stats_for_today_available_to_staff(self):
        response = self.client.get("/api/invoices/stats/", HTTP_AUTHORIZATION="Token " + self.staff_token)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        # اليوم: i % 6 == 0 → 10 فواتير، منها المسترجعة i % 5 == 0 (i = 0, 30) → 8 صافية × 9.
        self.assertEqual(body["invoices_count"], 8)
        self.assertEqual(body["sales_total"], 72.0)
