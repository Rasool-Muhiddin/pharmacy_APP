from django.conf import settings
from django.db import models

from desktop_api.models import Pharmacy


class Medicine(models.Model):
    """
    يقابل جدول medicine في قاعدة بيانات Flutter المحلية (SQLite) حقلاً بحقل،
    لتبسيط المزامنة بين الطرفين دون تحويل أسماء.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="medicines")
    trade_name = models.CharField(max_length=200)
    scientific_name = models.CharField(max_length=200, blank=True, default="")
    category = models.CharField(max_length=120, blank=True, default="")
    quantity = models.IntegerField(default=0)
    buy_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    sell_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    expiry_date = models.DateField(null=True, blank=True)
    shelf_location = models.CharField(max_length=120, blank=True, default="")
    is_damaged = models.BooleanField(default=False)
    barcode = models.CharField(max_length=64, unique=True, null=True, blank=True)

    # وقت آخر تعديل على السيرفر — يستخدمه تطبيق Flutter لمعرفة ما تغيّر منذ آخر مزامنة
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        indexes = [
            models.Index(fields=["pharmacy", "trade_name"]),
            models.Index(fields=["pharmacy", "scientific_name"]),
        ]
        constraints = [
            models.CheckConstraint(condition=models.Q(quantity__gte=0), name="medicine_quantity_gte_0"),
            models.CheckConstraint(condition=models.Q(buy_price__gte=0), name="medicine_buy_price_gte_0"),
            models.CheckConstraint(condition=models.Q(sell_price__gte=0), name="medicine_sell_price_gte_0"),
        ]

    def __str__(self):
        return self.trade_name


class Invoice(models.Model):
    """
    يقابل جدول invoice في قاعدة بيانات Flutter المحلية. يُنشأ فقط عبر
    InvoiceViewSet.checkout (عملية ذرّية تخصم المخزون في نفس المعاملة)،
    وليس عبر إنشاء/تعديل مباشر كما في Medicine — لذلك لا يوجد له Serializer
    قابل للكتابة، وكل الحقول هنا للقراءة من جهة العميل.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="invoices")
    invoice_number = models.CharField(max_length=40)
    # يُترك فارغاً لو حُذف حساب الكاشير لاحقاً، بدل حذف سجل المبيعات نفسه.
    cashier = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="invoices_cashiered",
    )
    total_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    discount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    final_amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    # وقت الخادم عند الإنشاء (auto_now_add) لا وقت العميل المُرسَل، لأن ساعة
    # جهاز العميل قد تكون غير دقيقة ولأن ترتيب الفواتير بين الأجهزة يجب أن
    # يعتمد على مرجع واحد موثوق.
    created_at = models.DateTimeField(auto_now_add=True)
    is_refunded = models.BooleanField(default=False)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(fields=["pharmacy", "invoice_number"], name="unique_invoice_number_per_pharmacy"),
        ]
        indexes = [
            models.Index(fields=["pharmacy", "created_at"]),
        ]

    def __str__(self):
        return self.invoice_number


class InvoiceItem(models.Model):
    """يقابل جدول invoice_item المحلي. يُنشأ فقط من داخل checkout."""

    invoice = models.ForeignKey(Invoice, on_delete=models.CASCADE, related_name="items")
    # PROTECT: يمنع حذف دواء له سجل مبيعات، بنفس أثر القيد المحلي
    # (FOREIGN KEY بلا ON DELETE CASCADE) الذي يرفض الحذف ضمنياً في SQLite.
    medicine = models.ForeignKey(Medicine, on_delete=models.PROTECT, related_name="invoice_items")
    # نسخة من اسم الدواء وقت البيع، لتبقى الفاتورة قابلة للقراءة حتى لو
    # عُدِّل اسم الدواء لاحقاً في المخزون.
    trade_name = models.CharField(max_length=200)
    quantity = models.PositiveIntegerField()
    unit_price = models.DecimalField(max_digits=12, decimal_places=2)
    total_price = models.DecimalField(max_digits=12, decimal_places=2)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=models.Q(quantity__gt=0), name="invoice_item_quantity_gt_0"),
            models.CheckConstraint(condition=models.Q(unit_price__gte=0), name="invoice_item_unit_price_gte_0"),
            models.CheckConstraint(condition=models.Q(total_price__gte=0), name="invoice_item_total_price_gte_0"),
        ]

    def __str__(self):
        return f"{self.trade_name} x{self.quantity}"

class Supplier(models.Model):
    """يقابل جدول pharmacy_supplier المحلي."""

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="suppliers")
    name = models.CharField(max_length=200)
    phone = models.CharField(max_length=50, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        indexes = [models.Index(fields=["pharmacy", "name"])]

    def __str__(self):
        return self.name


class PurchaseInvoice(models.Model):
    """
    يقابل جدول purchase_invoice المحلي. total_amount وpaid_amount حقلان
    مباشران يُحدَّثان فقط عبر add_payment/add_return/settle_credit
    (انظر PurchaseInvoiceViewSet) — لا تعديل مباشر عليهما بأي طريقة أخرى.
    الاسترجاعات محسوبة من PurchaseInvoiceReturn المرتبطة وليست عموداً
    مخزَّناً، تفادياً لازدواج مصدر الحقيقة.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="purchase_invoices")
    supplier = models.ForeignKey(Supplier, on_delete=models.CASCADE, related_name="purchase_invoices")
    invoice_number = models.CharField(max_length=60, blank=True, default="")
    total_amount = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    paid_amount = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["pharmacy", "supplier"])]
        constraints = [
            models.CheckConstraint(condition=models.Q(total_amount__gte=0), name="purchase_invoice_total_gte_0"),
            models.CheckConstraint(condition=models.Q(paid_amount__gte=0), name="purchase_invoice_paid_gte_0"),
        ]

    def __str__(self):
        return self.invoice_number or f"PI-{self.pk}"


class SupplierPayment(models.Model):
    """يقابل جدول supplier_payment المحلي."""

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="supplier_payments")
    supplier = models.ForeignKey(Supplier, on_delete=models.CASCADE, related_name="payments")
    purchase_invoice = models.ForeignKey(
        PurchaseInvoice, on_delete=models.CASCADE, null=True, blank=True, related_name="payments"
    )
    amount_paid = models.DecimalField(max_digits=14, decimal_places=2)
    notes = models.CharField(max_length=255, blank=True, default="")
    paid_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=models.Q(amount_paid__gt=0), name="supplier_payment_amount_gt_0"),
        ]


class Expense(models.Model):
    """
    يقابل جدول expense المحلي في Flutter (db_helper.dart) حقلاً بحقل:
    expense_type, expense_date, amount, notes — بنفس تسمية الأعمدة
    المستخدمة في upsertExpenseFromServer/replaceExpensesCache، لتبقى
    استجابة الـSerializer قابلة للاستهلاك مباشرة بلا أي تحويل أسماء.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="expenses")
    expense_type = models.CharField(max_length=120)
    expense_date = models.DateField()
    amount = models.DecimalField(max_digits=12, decimal_places=2)
    notes = models.CharField(max_length=255, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-expense_date", "-id"]
        indexes = [models.Index(fields=["pharmacy", "expense_date"])]
        constraints = [
            models.CheckConstraint(condition=models.Q(amount__gt=0), name="expense_amount_gt_0"),
        ]

    def __str__(self):
        return f"{self.expense_type} - {self.amount}"


class DamagedMedicine(models.Model):
    """
    يقابل جدول damaged_medicine المحلي (medicine_id, quantity_damaged,
    reason, notes, damaged_at). يُنشأ فقط عبر DamagedMedicineViewSet.create
    التي تخصم الكمية من Medicine وتُنشئ هذا السجل ذرّياً في نفس المعاملة
    (نفس نمط checkout) — لا تعديل/حذف مباشر بعد الإنشاء، فالإتلاف عملية
    نهائية كما في النسخة المحلية.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="damaged_medicines")
    # PROTECT: نفس منطق InvoiceItem.medicine — يمنع حذف دواء له سجل إتلاف.
    medicine = models.ForeignKey(Medicine, on_delete=models.PROTECT, related_name="damaged_records")
    quantity_damaged = models.PositiveIntegerField()
    reason = models.CharField(max_length=32, blank=True, default="")
    notes = models.CharField(max_length=255, blank=True, default="")
    damaged_at = models.DateField(auto_now_add=True)

    class Meta:
        ordering = ["-id"]
        indexes = [models.Index(fields=["pharmacy", "damaged_at"])]
        constraints = [
            models.CheckConstraint(condition=models.Q(quantity_damaged__gt=0), name="damaged_medicine_quantity_gt_0"),
        ]

    def __str__(self):
        return f"{self.medicine.trade_name} x{self.quantity_damaged}"


class PurchaseInvoiceReturn(models.Model):
    """يقابل جدول purchase_invoice_return المحلي."""

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="purchase_invoice_returns")
    supplier = models.ForeignKey(Supplier, on_delete=models.CASCADE, related_name="returns")
    purchase_invoice = models.ForeignKey(PurchaseInvoice, on_delete=models.CASCADE, related_name="returns")
    amount_returned = models.DecimalField(max_digits=14, decimal_places=2)
    notes = models.CharField(max_length=255, blank=True, default="")
    returned_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=models.Q(amount_returned__gt=0), name="purchase_invoice_return_amount_gt_0"),
        ]