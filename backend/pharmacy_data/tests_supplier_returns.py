"""
استرجاع الأصناف للمذخر، رصيد الصيدلية لدى المذخر، استخدامه التلقائي، واستلام
الأموال منه. نفس السيناريوهات في test/supplier_returns_db_test.dart.
"""

import json
import unittest
from datetime import timedelta
from decimal import Decimal

from django.test import TransactionTestCase

from desktop_api.models import DesktopLicense, Pharmacy
from pharmacy_data import supplier_ledger
from pharmacy_data.models import (
    Medicine,
    MedicineBatch,
    PurchaseInvoice,
    PurchaseInvoiceItem,
    PurchaseInvoiceReturn,
    PurchaseInvoiceReturnItem,
    Supplier,
    SupplierCreditApplication,
    SupplierPayment,
    SupplierRefund,
    Warehouse,
)
from pharmacy_data.tests import PARITY_FIXTURE
from pharmacy_data.tests_purchase_list import PurchaseListTestBase


class SupplierReturnsTests(PurchaseListTestBase):
    def supplier(self, name="مذخر الشفاء"):
        return Supplier.objects.get(pharmacy=self.pharmacy, name=name)

    def figures(self, name="مذخر الشفاء"):
        return supplier_ledger.figures_for(self.supplier(name))

    def summary_row(self, name="مذخر الشفاء"):
        return next(r for r in self.api("get", "/api/suppliers/summary/").json() if r["name"] == name)

    def statement_balance(self, name="مذخر الشفاء"):
        rows = self.api("get", f"/api/suppliers/{self.supplier(name).pk}/statement/").json()
        return sum((Decimal(str(r["debt_added"])) for r in rows), Decimal("0"))

    def assert_balance(self, expected, name="مذخر الشفاء"):
        expected = Decimal(str(expected))
        row = self.summary_row(name)
        self.assertEqual(Decimal(row["balance"]), expected)
        self.assertEqual(Decimal(row["remaining_debt"]), max(expected, Decimal("0")))
        self.assertEqual(Decimal(row["credit_balance"]), max(-expected, Decimal("0")))
        self.assertEqual(self.statement_balance(name), expected, "statement final balance must equal supplier balance")

    def invoice(self, number):
        return PurchaseInvoice.objects.get(pharmacy=self.pharmacy, invoice_number=number)

    def item(self, invoice_number, trade_name):
        return PurchaseInvoiceItem.objects.get(purchase_invoice__invoice_number=invoice_number, trade_name=trade_name)

    def remaining(self, number):
        r = self.api("get", f"/api/purchase-invoices/{self.invoice(number).pk}/").json()
        return Decimal(r["remaining_amount"])

    def post_return(self, number, lines, **extra):
        body = {"items": [
            {"purchase_invoice_item": self.item(number, name).pk, "quantity": qty, **({"unit_price": price} if price is not None else {})}
            for name, qty, price in lines
        ], **extra}
        return self.api("post", f"/api/purchase-invoices/{self.invoice(number).pk}/return-items/", body)

    def receive(self, amount, name="مذخر الشفاء", token=None):
        return self.api("post", f"/api/suppliers/{self.supplier(name).pk}/receive-refund/", {"amount": str(amount)}, token=token)

    def stock_of(self, name):
        return Medicine.objects.get(pharmacy=self.pharmacy, trade_name=name).quantity

    # --- السيناريو المشترك مع Flutter ---

    @unittest.skipUnless(PARITY_FIXTURE.exists(), "Flutter test fixture not available")
    def test_shared_parity_scenario(self):
        steps = json.loads(PARITY_FIXTURE.read_text(encoding="utf-8"))["supplier_returns"]["steps"]
        names = {}
        for step in steps:
            if step["op"] == "list":
                lines = []
                for line in step["lines"]:
                    names[line["key"]] = line["trade_name"]
                    data = {k: v for k, v in line.items() if k != "key" and v is not None}
                    lines.append(data | {"expiry_date": self.expiry()})
                r = self.post_list(lines, invoice_number=step["invoice"], paid_amount=str(step["paid"]))
                self.assertEqual(r.status_code, 201, r.content)
            elif step["op"] == "return":
                r = self.post_return(step["invoice"], [(names[l["key"]], l["quantity"], l.get("unit_price")) for l in step["lines"]])
                self.assertEqual(r.status_code, 201, r.content)
                exp = step["expect"]
                self.assertEqual(Decimal(r.json()["return"]["amount_returned"]), Decimal(str(exp["return_credit"])))
                self.assertEqual(Decimal(r.json()["return"]["excess_credit"]), Decimal(str(exp["return_excess"])))
            elif step["op"] == "refund":
                self.assertEqual(self.receive(step["amount"]).status_code, 201)
            exp = step["expect"]
            self.assert_balance(exp["balance"])
            self.assertEqual(self.figures()["available_credit"], Decimal(str(exp["available_credit"])), step)
            for number, value in exp.get("remaining", {}).items():
                self.assertEqual(self.remaining(number), Decimal(str(value)), (step, number))
            for name, value in exp.get("stock", {}).items():
                self.assertEqual(self.stock_of(name), value, (step, name))
            for number, value in exp.get("credit_applied", {}).items():
                applied = sum(a.amount for a in SupplierCreditApplication.objects.filter(purchase_invoice=self.invoice(number)))
                self.assertEqual(applied, Decimal(str(value)))
        # avg_cost لا يتغير بالاسترجاع (كالبيع والإتلاف).
        self.assertEqual(Medicine.objects.get(trade_name="A").avg_cost, Decimal("833.3333"))

    # --- حدود الكمية والسعر ---

    def test_return_within_limits_reduces_stock_debt_and_prefers_invoice_batches(self):
        medicine = self.create_medicine("A", quantity=5, buy="800", sell="1200")  # دفعة سابقة أقرب انتهاءً
        self.post_list([self.line("A", quantity=10, buy="1000", sell="1500")])
        r = self.post_return("F-100", [("A", 3, None)], notes="تالف بالشحن")
        self.assertEqual(r.status_code, 201, r.content)
        medicine.refresh_from_db()
        self.assertEqual(medicine.quantity, 12)
        # الخصم من دفعة هذه الفاتورة أولاً، لا من الأقرب انتهاءً.
        self.assertEqual(MedicineBatch.objects.get(medicine=medicine, purchase_invoice=self.invoice("F-100")).quantity, 7)
        self.assertEqual(MedicineBatch.objects.get(medicine=medicine, purchase_invoice__isnull=True).quantity, 5)
        self.assertEqual(self.remaining("F-100"), Decimal("7000.00"))
        self.assert_balance(7000)
        line = PurchaseInvoiceReturnItem.objects.get()
        self.assertEqual((line.quantity, line.credited_quantity, line.unit_return_price, line.credit_amount),
                         (3, 3, Decimal("1000.00"), Decimal("3000.00")))
        self.assertEqual(PurchaseInvoiceReturn.objects.get().notes, "تالف بالشحن")
        items = self.api("get", f"/api/purchase-invoices/{self.invoice('F-100').pk}/items/").json()
        self.assertEqual((items[0]["returned_quantity"], items[0]["current_stock"]), (3, 12))
        # الخصم يكمل من دفعات الصنف الأخرى بعد نفاد دفعة الفاتورة.
        self.assertEqual(self.post_return("F-100", [("A", 7, None)]).status_code, 201)
        self.assertEqual(MedicineBatch.objects.filter(medicine=medicine).count(), 1)

    def test_return_above_stock_or_above_bought_is_rejected(self):
        self.post_list([self.line("A", quantity=10, buy="1000", sell="1500", bonus_quantity=2)])
        medicine = Medicine.objects.get(trade_name="A")
        self.api("post", "/api/invoices/checkout/", {"items": [{"medicine_id": medicine.pk, "quantity": 5}]})
        r = self.post_return("F-100", [("A", 8, None)])  # المخزون 7 فقط
        self.assertEqual(r.status_code, 400, r.content)
        self.assertEqual(r.json()["line"], "0")
        self.assertIn("7", r.json()["detail"])
        self.assertEqual(self.post_return("F-100", [("A", 7, None)]).status_code, 201)
        # شراء جديد يرفع المخزون، لكن المتبقي من السطر 12 − 7 = 5 فقط.
        self.post_list([self.line("A", quantity=20, buy="1000", sell="1500")], invoice_number="F-200")
        self.assertEqual(self.post_return("F-100", [("A", 6, None)]).status_code, 400)
        self.assertEqual(self.post_return("F-100", [("A", 5, None)]).status_code, 201)
        self.assertEqual(self.post_return("F-100", [("A", 1, None)]).status_code, 400)
        self.assertEqual(self.post_return("F-100", [("A", 0, None)]).status_code, 400)

    def test_edited_price_and_paid_units_first(self):
        self.post_list([self.line("A", quantity=10, buy="1000", sell="1500", bonus_quantity=2)])
        r = self.post_return("F-100", [("A", 4, "750")])
        self.assertEqual(Decimal(r.json()["return"]["amount_returned"]), Decimal("3000.00"))  # 4 × 750
        # 8 متبقية: 6 مدفوعة + 2 بونص → الرصيد للمدفوعة فقط.
        r = self.post_return("F-100", [("A", 8, None)])
        line = PurchaseInvoiceReturnItem.objects.order_by("-id").first()
        self.assertEqual((line.quantity, line.credited_quantity, line.credit_amount), (8, 6, Decimal("6000.00")))

    def test_free_line_returns_give_zero_credit(self):
        self.post_list([self.line("A", quantity=1, buy="100", sell="150"), self.free_line("Gift", 4, sell_price="10")])
        r = self.post_return("F-100", [("Gift", 4, "999")])
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(Decimal(r.json()["return"]["amount_returned"]), Decimal("0.00"))
        self.assertEqual(self.stock_of("Gift"), 0)
        self.assert_balance(100)

    # --- الرصيد لصالح الصيدلية ---

    def test_excess_settles_other_open_invoices_first_then_becomes_credit(self):
        self.post_list([self.line("A", quantity=10, buy="100", sell="150")], invoice_number="OLD", paid_amount="0")
        self.post_list([self.line("B", quantity=10, buy="100", sell="150")], invoice_number="NEW", paid_amount="1000")
        self.assert_balance(1000)  # OLD مفتوحة بالكامل، NEW مدفوعة
        r = self.post_return("NEW", [("B", 10, "150")])  # 1500 على فاتورة متبقيها 0
        self.assertEqual(Decimal(r.json()["return"]["excess_credit"]), Decimal("1500.00"))
        self.assertEqual(self.remaining("OLD"), Decimal("0.00"))  # 1000 من الفائض سدّدت OLD
        self.assertEqual(self.remaining("NEW"), Decimal("0.00"))
        self.assertEqual(self.figures()["available_credit"], Decimal("500.00"))
        self.assert_balance(-500)
        self.assertEqual(SupplierCreditApplication.objects.get().purchase_invoice, self.invoice("OLD"))

    def test_return_larger_than_remaining_creates_credit_and_list_uses_it(self):
        self.post_list([self.line("A", quantity=10, buy="1000", sell="1500")], paid_amount="9500")
        self.post_return("F-100", [("A", 3, None)])  # 3000 مقابل متبقٍّ 500
        self.assert_balance(-2500)
        self.assertEqual(self.remaining("F-100"), Decimal("0.00"))
        # قائمة جديدة 1000: خصم كامل من الرصيد، والمدفوع الآن ممنوع فوق المتبقي (0).
        r = self.post_list([self.line("B", quantity=1, buy="1000", sell="1500")], invoice_number="F-2", paid_amount="1")
        self.assertEqual(r.status_code, 400, r.content)
        self.assertFalse(Medicine.objects.filter(trade_name="B").exists())
        r = self.post_list([self.line("B", quantity=1, buy="1000", sell="1500")], invoice_number="F-2")
        self.assertEqual(Decimal(r.json()["purchase_invoice"]["credit_applied"]), Decimal("1000.00"))
        self.assertEqual(Decimal(r.json()["purchase_invoice"]["remaining_amount"]), Decimal("0.00"))
        self.assert_balance(-1500)
        rows = self.api("get", f"/api/suppliers/{self.supplier().pk}/statement/").json()
        applied = [r for r in rows if r["transaction_type"] == "credit_applied"]
        self.assertEqual(len(applied), 1)
        self.assertIn("خصم من رصيد سابق", applied[0]["reference"])
        self.assertEqual(Decimal(str(applied[0]["debt_added"])), Decimal("0"))

    def test_receive_refund_limits(self):
        self.post_list([self.line("A", quantity=10, buy="100", sell="150")], paid_amount="1000")
        self.assertEqual(self.receive(1).status_code, 400)  # لا رصيد
        self.post_return("F-100", [("A", 4, None)])
        self.assert_balance(-400)
        self.assertEqual(self.receive(401).status_code, 400)
        self.assertEqual(self.receive(0).status_code, 400)
        self.assertEqual(self.receive(150, token=self.staff_token).status_code, 403)
        r = self.receive(150)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(Decimal(r.json()["available_credit"]), Decimal("250.00"))
        self.assert_balance(-250)
        self.assertEqual(self.receive(250).status_code, 201)
        self.assert_balance(0)
        self.assertEqual(SupplierRefund.objects.count(), 2)
        rows = self.api("get", f"/api/suppliers/{self.supplier().pk}/statement/").json()
        self.assertEqual(len([r for r in rows if r["transaction_type"] == "refund"]), 2)

    def test_total_debt_does_not_net_credit_against_other_suppliers(self):
        self.post_list([self.line("A", quantity=10, buy="100", sell="150")], paid_amount="1000")
        self.post_return("F-100", [("A", 4, None)])  # رصيد 400 لصالحنا
        self.post_list([self.line("B", quantity=10, buy="100", sell="150")], supplier_name="آخر", invoice_number="X")
        self.assertEqual(supplier_ledger.total_debt(self.pharmacy), Decimal("1000.00"))
        report = self.api("get", "/api/reports/summary/").json()
        self.assertEqual(Decimal(str(report["total_supplier_debt"])), Decimal("1000.00"))

    # --- السجلات القديمة والذرّية والعزل ---

    def test_legacy_amount_returns_and_manual_invoices_still_work(self):
        supplier = Supplier.objects.create(pharmacy=self.pharmacy, name="قديم")
        manual = PurchaseInvoice.objects.create(pharmacy=self.pharmacy, supplier=supplier, invoice_number="M1",
                                                total_amount=Decimal("1000"), paid_amount=Decimal("200"))
        PurchaseInvoiceReturn.objects.create(pharmacy=self.pharmacy, supplier=supplier, purchase_invoice=manual,
                                             amount_returned=Decimal("100"))
        self.assert_balance(700, "قديم")
        self.assertEqual(self.api("get", f"/api/purchase-invoices/{manual.pk}/items/").json(), [])
        r = self.api("post", f"/api/purchase-invoices/{manual.pk}/add_payment/", {"amount": "700"})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(self.api("post", f"/api/purchase-invoices/{manual.pk}/add_payment/", {"amount": "1"}).status_code, 400)
        # المسار القديم لنسخ التطبيق الأقدم: الفائض يصبح رصيداً، والمتبقي لا يقل عن 0.
        r = self.api("post", f"/api/purchase-invoices/{manual.pk}/add_return/", {"amount": "300"})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(Decimal(r.json()["remaining_amount"]), Decimal("0"))
        self.assert_balance(-300, "قديم")

    def test_failing_line_rolls_back_whole_return(self):
        self.post_list([self.line("A", quantity=5, buy="100", sell="150"), self.line("B", quantity=5, buy="100", sell="150")])
        r = self.post_return("F-100", [("A", 2, None), ("B", 9, None)])
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["line"], "1")
        self.assertEqual((self.stock_of("A"), self.stock_of("B")), (5, 5))
        self.assertFalse(PurchaseInvoiceReturn.objects.exists())
        self.assertFalse(PurchaseInvoiceReturnItem.objects.exists())
        self.assert_balance(1000)
        # سطر مكرر، وسعر سالب، وصنف حُذف من المخزون.
        item = self.item("F-100", "A").pk
        body = {"items": [{"purchase_invoice_item": item, "quantity": 1}, {"purchase_invoice_item": item, "quantity": 1}]}
        self.assertEqual(self.api("post", f"/api/purchase-invoices/{self.invoice('F-100').pk}/return-items/", body).status_code, 400)
        self.assertEqual(self.post_return("F-100", [("A", 1, "-1")]).status_code, 400)
        Medicine.objects.filter(trade_name="B").delete()
        self.assertEqual(self.post_return("F-100", [("B", 1, None)]).status_code, 400)
        future = (self.today + timedelta(days=2)).isoformat()
        self.assertEqual(self.post_return("F-100", [("A", 1, None)], return_date=future).status_code, 400)

    def test_cross_pharmacy_ids_rejected(self):
        self.post_list([self.line("A", quantity=5, buy="100", sell="150")])
        other = Pharmacy.objects.create(name="P2")
        DesktopLicense.objects.create(pharmacy=other, mode="online", plan="gold", max_devices=1)
        other_supplier = Supplier.objects.create(pharmacy=other, name="S2")
        wh = Warehouse.main_for(other)
        other_invoice = PurchaseInvoice.objects.create(pharmacy=other, supplier=other_supplier, invoice_number="Q",
                                                       total_amount=100)
        other_med = Medicine.objects.create(pharmacy=other, warehouse=wh, trade_name="Z", quantity=0)
        other_item = PurchaseInvoiceItem.objects.create(pharmacy=other, purchase_invoice=other_invoice, medicine=other_med,
                                                        trade_name="Z", quantity=1, buy_price=100, line_total=100)
        r = self.api("post", f"/api/purchase-invoices/{other_invoice.pk}/return-items/",
                     {"items": [{"purchase_invoice_item": other_item.pk, "quantity": 1}]})
        self.assertEqual(r.status_code, 404)
        # صنف من فاتورة أخرى على فاتورتنا.
        r = self.api("post", f"/api/purchase-invoices/{self.invoice('F-100').pk}/return-items/",
                     {"items": [{"purchase_invoice_item": other_item.pk, "quantity": 1}]})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(self.api("post", f"/api/suppliers/{other_supplier.pk}/receive-refund/", {"amount": "1"}).status_code, 404)
        self.assertFalse(PurchaseInvoiceReturn.objects.exists())

    def test_offline_import_carries_return_lines_credit_and_refunds(self):
        exp = self.expiry()
        payload = {
            "suppliers": [{"local_id": 7, "name": "S"}],
            "medicines": [{"local_id": 1, "trade_name": "A", "quantity": 6, "avg_cost": 100,
                           "batches": [{"quantity": 6, "expiry_date": exp, "purchase_price": 100}]}],
            "purchase_invoices": [
                {"local_id": 50, "local_supplier_id": 7, "invoice_number": "F1", "total_amount": 1000, "paid_amount": 1000,
                 "source": "inventory_list", "item_count": 1,
                 "items": [{"local_id": 501, "local_medicine_id": 1, "trade_name": "A", "quantity": 10, "bonus_quantity": 0,
                            "buy_price": 100, "effective_unit_cost": 100, "sell_price": 150, "line_total": 1000}],
                 "returns": [{"amount_returned": 400, "excess_credit": 400, "notes": "", "returned_at": exp,
                              "items": [{"local_purchase_invoice_item_id": 501, "local_medicine_id": 1, "trade_name": "A",
                                         "quantity": 4, "credited_quantity": 4, "unit_return_price": 100,
                                         "credit_amount": 400}]}]},
                {"local_id": 51, "local_supplier_id": 7, "invoice_number": "F2", "total_amount": 300, "paid_amount": 0,
                 "credit_applications": [{"amount": 300, "notes": "خصم من رصيد سابق"}]},
            ],
            "supplier_refunds": [{"local_supplier_id": 7, "amount": 50, "notes": "نقداً"}],
        }
        r = self.api("post", "/api/migration/upload_offline_data/", payload)
        body = b"".join(r.streaming_content).decode()
        self.assertIn('"event": "done"', body, body)
        supplier = Supplier.objects.get(name="S")
        figures = supplier_ledger.figures_for(supplier)
        self.assertEqual((figures["balance"], figures["available_credit"]), (Decimal("-50.00"), Decimal("50.00")))
        line = PurchaseInvoiceReturnItem.objects.get()
        self.assertEqual((line.quantity, line.purchase_invoice_item.trade_name, line.medicine.trade_name), (4, "A", "A"))
        self.assertEqual(SupplierRefund.objects.get().amount, Decimal("50.00"))
        self.assertEqual(SupplierCreditApplication.objects.get().purchase_invoice.invoice_number, "F2")


class LegacyNegativeRemainderMigrationTests(TransactionTestCase):
    """ترحيل 0016: المتبقي السالب القديم يصبح رصيداً، ورصيد كل مذخر لا يتغير إطلاقاً."""

    def test_balances_unchanged_and_negatives_become_credit(self):
        from importlib import import_module

        from django.apps import apps as global_apps

        pharmacy = Pharmacy.objects.create(name="M")
        s1 = Supplier.objects.create(pharmacy=pharmacy, name="سالب مع فواتير مفتوحة")
        s2 = Supplier.objects.create(pharmacy=pharmacy, name="سالب فقط")
        s3 = Supplier.objects.create(pharmacy=pharmacy, name="عادي")

        def invoice(supplier, number, total, paid, returns=(), days=0):
            inv = PurchaseInvoice.objects.create(pharmacy=pharmacy, supplier=supplier, invoice_number=number,
                                                 total_amount=Decimal(total), paid_amount=Decimal(paid))
            PurchaseInvoice.objects.filter(pk=inv.pk).update(created_at=inv.created_at - timedelta(days=days))
            for i, amount in enumerate(returns):
                PurchaseInvoiceReturn.objects.create(pharmacy=pharmacy, supplier=supplier, purchase_invoice=inv,
                                                     amount_returned=Decimal(amount))
            return inv

        a = invoice(s1, "A", "1000", "900", returns=("150", "200"), days=30)  # متبقٍّ −250
        b = invoice(s1, "B", "500", "400", days=20)                          # مفتوحة 100
        c = invoice(s1, "C", "300", "0", days=10)                            # مفتوحة 300
        d = invoice(s2, "D", "100", "100", returns=("40",))                   # متبقٍّ −40
        SupplierPayment.objects.create(pharmacy=pharmacy, supplier=s2, purchase_invoice=d, amount_paid=Decimal("100"))
        e = invoice(s3, "E", "700", "100", returns=("50",))                   # عادي 550

        suppliers = [s1, s2, s3]
        ids = [s.pk for s in suppliers]
        before = {sid: f["balance"] for sid, f in supplier_ledger.supplier_figures(ids).items()}
        import_module("pharmacy_data.migrations.0016_legacy_negative_remainders_to_credit").convert(global_apps, None)
        after = supplier_ledger.supplier_figures(ids)

        for sid in ids:
            self.assertEqual(after[sid]["balance"], before[sid], sid)
        self.assertEqual(before[s1.pk], Decimal("150"))  # 1800 − 1300 − 350
        remaining = {inv.invoice_number: supplier_ledger.invoice_remaining(inv) for inv in (a, b, c, d, e)}
        self.assertEqual(remaining, {"A": 0, "B": 0, "C": 150, "D": 0, "E": 550})
        self.assertEqual(after[s1.pk]["available_credit"], Decimal("0"))   # الفائض 250 سدّد B (100) ثم جزءاً من C
        self.assertEqual(after[s2.pk]["available_credit"], Decimal("40"))  # لا فواتير مفتوحة: رصيد لصالح الصيدلية
        # الفائض على أحدث استرجاع أولاً.
        self.assertEqual(list(a.returns.order_by("id").values_list("excess_credit", flat=True)), [Decimal("50"), Decimal("200")])
        self.assertEqual(PurchaseInvoiceReturn.objects.count(), 4)  # لا حذف
