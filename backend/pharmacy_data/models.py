from datetime import date

from django.conf import settings
from django.db import IntegrityError, models, transaction
from django.utils import timezone

from desktop_api.models import Pharmacy

MAIN_WAREHOUSE_NAME = "المخزن الرئيسي"


class Warehouse(models.Model):
    """
    يقابل جدول warehouses المحلي في Flutter. لكل صيدلية مخزن رئيسي واحد
    بالضبط (is_main=True) يُنشأ تلقائياً عند الحاجة (Warehouse.main_for)،
    والبيع (checkout) يتم منه حصراً. المخازن الإضافية خاصية Gold/Diamond
    وعددها محدود بـ desktop_api.permissions.max_warehouses_for.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="warehouses")
    name = models.CharField(max_length=120)
    is_main = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-is_main", "id"]
        constraints = [
            models.UniqueConstraint(
                fields=["pharmacy"],
                condition=models.Q(is_main=True),
                name="one_main_warehouse_per_pharmacy",
            ),
        ]

    def __str__(self):
        return f"{self.name} ({self.pharmacy.name})"

    @classmethod
    def main_for(cls, pharmacy):
        """يعيد المخزن الرئيسي للصيدلية، وينشئه إن لم يوجد (آمن مع التزامن)."""
        pharmacy_id = getattr(pharmacy, "pk", pharmacy)
        existing = cls.objects.filter(pharmacy_id=pharmacy_id, is_main=True).first()
        if existing is not None:
            return existing
        try:
            with transaction.atomic():
                return cls.objects.create(pharmacy_id=pharmacy_id, name=MAIN_WAREHOUSE_NAME, is_main=True)
        except IntegrityError:
            # طلب متزامن أنشأه للتو (قيد one_main_warehouse_per_pharmacy).
            return cls.objects.get(pharmacy_id=pharmacy_id, is_main=True)


class Medicine(models.Model):
    """
    يقابل جدول medicine في قاعدة بيانات Flutter المحلية (SQLite) حقلاً بحقل،
    لتبسيط المزامنة بين الطرفين دون تحويل أسماء.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="medicines")
    # PROTECT: لا يُحذف مخزن فيه أصناف — يجب نقلها أو تصفيرها أولاً
    # (راجع WarehouseViewSet.destroy).
    warehouse = models.ForeignKey(Warehouse, on_delete=models.PROTECT, related_name="medicines")
    trade_name = models.CharField(max_length=200)
    scientific_name = models.CharField(max_length=200, blank=True, default="")
    category = models.CharField(max_length=120, blank=True, default="")
    # مجموع كميات MedicineBatch دائماً (يحافظ عليه pharmacy_data.stock).
    quantity = models.IntegerField(default=0)
    # آخر سعر شراء مُدخل (للعرض فقط). كلفة الربح هي avg_cost.
    buy_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    sell_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    # متوسط الكلفة المرجّح، يُعاد حسابه مع كل توريد (stock.supply). 4 خانات
    # عشرية كي لا يتراكم خطأ التقريب في كلفة البضاعة المباعة. NULL = غير معروف.
    avg_cost = models.DecimalField(max_digits=14, decimal_places=4, null=True, blank=True)
    # أقرب تاريخ انتهاء بين الدفعات المتوفرة (مشتق، يحافظ عليه stock.refresh_stock).
    expiry_date = models.DateField(null=True, blank=True)
    shelf_location = models.CharField(max_length=120, blank=True, default="")
    is_damaged = models.BooleanField(default=False)
    # الباركود فريد داخل المخزن الواحد فقط (انظر constraints): نفس الصنف قد
    # يوجد في المخزن الرئيسي والمخزن الثانوي معاً بعد عملية نقل، تماماً كقيد
    # idx_medicine_warehouse_barcode في قاعدة Flutter المحلية. الباركود
    # الفارغ/NULL لا يتصادم أبداً.
    barcode = models.CharField(max_length=64, null=True, blank=True)

    # وقت آخر تعديل على السيرفر — يستخدمه تطبيق Flutter لمعرفة ما تغيّر منذ آخر مزامنة
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        indexes = [
            models.Index(fields=["pharmacy", "trade_name"]),
            models.Index(fields=["pharmacy", "scientific_name"]),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["warehouse", "barcode"],
                condition=models.Q(barcode__isnull=False) & ~models.Q(barcode=""),
                name="unique_medicine_barcode_per_warehouse",
            ),
            models.CheckConstraint(condition=models.Q(quantity__gte=0), name="medicine_quantity_gte_0"),
            models.CheckConstraint(condition=models.Q(buy_price__gte=0), name="medicine_buy_price_gte_0"),
            models.CheckConstraint(condition=models.Q(sell_price__gte=0), name="medicine_sell_price_gte_0"),
        ]

    def __str__(self):
        return self.trade_name

    def save(self, *args, **kwargs):
        # أي إنشاء لا يحدد مخزناً (عملاء Flutter قدامى، لوحة الأدمن، seed_demo)
        # يذهب للمخزن الرئيسي بدل الفشل بقيد NOT NULL.
        if self.warehouse_id is None and self.pharmacy_id is not None:
            self.warehouse = Warehouse.main_for(self.pharmacy_id)
        super().save(*args, **kwargs)


BATCH_SOURCE_PURCHASE_LIST = "purchase_list"
BATCH_SOURCE_OPENING_STOCK = "opening_stock"
BATCH_SOURCE_CHOICES = [
    (BATCH_SOURCE_PURCHASE_LIST, "قائمة مذخر"),
    (BATCH_SOURCE_OPENING_STOCK, "رصيد افتتاحي"),
]


class MedicineBatch(models.Model):
    """
    دفعة صلاحية مخفية عن المستخدم (يقابل جدول medicine_batch المحلي). البيع
    والإتلاف والنقل تخصم منها بترتيب FEFO (الأقرب انتهاءً أولاً)، ومجموع
    كمياتها = Medicine.quantity دائماً. تُدار حصراً عبر pharmacy_data.stock.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="medicine_batches")
    medicine = models.ForeignKey(Medicine, on_delete=models.CASCADE, related_name="batches")
    quantity = models.PositiveIntegerField()
    expiry_date = models.DateField(null=True, blank=True)
    purchase_price = models.DecimalField(max_digits=14, decimal_places=4, null=True, blank=True)
    created_at = models.DateTimeField(default=timezone.now)
    # مصدر الدفعة للتتبّع (إرجاع لمذخر/إيقاف التعامل معه). الدفعات الأقدم من
    # قوائم المذاخر تبقى فارغة/NULL. SET_NULL: حذف مذخر/فاتورة لا يمس المخزون.
    source = models.CharField(max_length=20, choices=BATCH_SOURCE_CHOICES, blank=True, default="")
    supplier = models.ForeignKey(
        "Supplier", on_delete=models.SET_NULL, null=True, blank=True, related_name="batches"
    )
    purchase_invoice = models.ForeignKey(
        "PurchaseInvoice", on_delete=models.SET_NULL, null=True, blank=True, related_name="batches"
    )

    class Meta:
        ordering = ["expiry_date", "id"]
        indexes = [models.Index(fields=["medicine", "expiry_date"])]

    def __str__(self):
        return f"{self.medicine_id} x{self.quantity} ({self.expiry_date})"


class StockTransfer(models.Model):
    """
    سجل عمليات نقل المخزون بين مخازن نفس الصيدلية (يقابل جدول stock_transfers
    المحلي). يُنشأ فقط عبر WarehouseViewSet.transfer داخل نفس معاملة تعديل
    الكميات. لا يُخزَّن معرّف الدواء لأن صف المصدر قد يُحذف بعد النقل الكامل.
    أسماء المخازن تُحفظ كنص وقت النقل، والمرجع نفسه SET_NULL، كي يبقى السجل
    مقروءاً ولا يمنع حذف مخزن إضافي فارغ لاحقاً.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="stock_transfers")
    from_warehouse = models.ForeignKey(
        Warehouse, on_delete=models.SET_NULL, null=True, blank=True, related_name="transfers_out"
    )
    to_warehouse = models.ForeignKey(
        Warehouse, on_delete=models.SET_NULL, null=True, blank=True, related_name="transfers_in"
    )
    from_warehouse_name = models.CharField(max_length=120, blank=True, default="")
    to_warehouse_name = models.CharField(max_length=120, blank=True, default="")
    trade_name = models.CharField(max_length=200)
    barcode = models.CharField(max_length=64, null=True, blank=True)
    quantity = models.PositiveIntegerField()
    notes = models.CharField(max_length=255, blank=True, default="")
    transferred_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True, blank=True, related_name="stock_transfers"
    )
    transferred_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-transferred_at", "-id"]
        indexes = [models.Index(fields=["pharmacy", "transferred_at"])]
        constraints = [
            models.CheckConstraint(condition=models.Q(quantity__gt=0), name="stock_transfer_quantity_gt_0"),
            models.CheckConstraint(
                condition=~models.Q(from_warehouse=models.F("to_warehouse")),
                name="stock_transfer_distinct_warehouses",
            ),
        ]

    def __str__(self):
        return f"{self.trade_name} x{self.quantity}"


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
    # اسم الكاشير كما كان محلياً وقت الترحيل، لفواتير مرحَّلة من أوفلاين لا
    # حساب Django حقيقي وراءها (MigrationViewSet يملأه ويترك cashier=None).
    # الفواتير الجديدة بعد الترحيل تُنشأ بـcashier حقيقي وتترك هذا فارغاً.
    cashier_name = models.CharField(max_length=150, blank=True, default="")
    # كان auto_now_add، فحُوِّل إلى default قابل للتجاوز صراحة: checkout()
    # العادي لا يمرر created_at فيُطبَّق نفس وقت الخادم كالسابق تماماً، بينما
    # MigrationViewSet وحدها تمرره صراحة لحفظ تاريخ الفاتورة التاريخي
    # الحقيقي القادم من الجهاز المحلي بدل تاريخ يوم الترحيل.
    created_at = models.DateTimeField(default=timezone.now)
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
    # لقطة من Medicine.avg_cost وقت البيع (يضبطها الخادم فقط، لا تُقبل من
    # العميل ولا تتغير بعدها). NULL = مبيعات قديمة بلا كلفة معروفة.
    unit_cost = models.DecimalField(max_digits=14, decimal_places=4, null=True, blank=True)

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


PURCHASE_SOURCE_MANUAL = "manual"
PURCHASE_SOURCE_INVENTORY_LIST = "inventory_list"
PURCHASE_SOURCE_CHOICES = [
    (PURCHASE_SOURCE_MANUAL, "يدوية"),
    (PURCHASE_SOURCE_INVENTORY_LIST, "من قائمة المخزون"),
]


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
    # تاريخ فاتورة المذخر الورقية (قد يختلف عن وقت إدخالها في النظام).
    invoice_date = models.DateField(null=True, blank=True)
    # manual = فاتورة قديمة أُدخلت يدوياً بلا أصناف؛ inventory_list = من قائمة المخزون.
    source = models.CharField(max_length=20, choices=PURCHASE_SOURCE_CHOICES, default=PURCHASE_SOURCE_MANUAL)
    item_count = models.PositiveIntegerField(default=0)
    # نفس منطق Invoice.created_at أعلاه: default بدل auto_now_add، لتتمكن
    # MigrationViewSet من حفظ تاريخ فاتورة الشراء التاريخي الحقيقي.
    created_at = models.DateTimeField(default=timezone.now)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [models.Index(fields=["pharmacy", "supplier"])]
        constraints = [
            # الأرقام المكررة القديمة أُعيدت تسميتها (-2، -3…) في الترحيل 0013.
            models.UniqueConstraint(
                fields=["pharmacy", "supplier", "invoice_number"],
                condition=~models.Q(invoice_number=""),
                name="unique_purchase_invoice_number_per_supplier",
            ),
            models.CheckConstraint(condition=models.Q(total_amount__gte=0), name="purchase_invoice_total_gte_0"),
            models.CheckConstraint(condition=models.Q(paid_amount__gte=0), name="purchase_invoice_paid_gte_0"),
        ]

    def __str__(self):
        return self.invoice_number or f"PI-{self.pk}"


class PurchaseInvoiceItem(models.Model):
    """
    سطر من قائمة المذخر (يقابل جدول purchase_invoice_item المحلي).
    quantity = المدفوع فقط، bonus_quantity = المجاني (بونص) منفصلاً. سطر
    "مجاني" بالكامل: quantity=0 وbonus_quantity>=1. line_total = quantity ×
    buy_price (البونص لا يدخل الإجمالي ولا الدين). effective_unit_cost = كلفة
    الوحدة بعد توزيع البونص (stock.effective_unit_cost).
    medicine SET_NULL + لقطة trade_name: حذف الدواء لا يمس تاريخ الفاتورة.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="purchase_invoice_items")
    purchase_invoice = models.ForeignKey(PurchaseInvoice, on_delete=models.CASCADE, related_name="items")
    medicine = models.ForeignKey(
        Medicine, on_delete=models.SET_NULL, null=True, blank=True, related_name="purchase_items"
    )
    trade_name = models.CharField(max_length=200)
    quantity = models.PositiveIntegerField(default=0)
    bonus_quantity = models.PositiveIntegerField(default=0)
    buy_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    effective_unit_cost = models.DecimalField(max_digits=14, decimal_places=4, default=0)
    sell_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    expiry_date = models.DateField(null=True, blank=True)
    line_total = models.DecimalField(max_digits=14, decimal_places=2, default=0)

    class Meta:
        ordering = ["id"]
        constraints = [
            models.CheckConstraint(
                condition=models.Q(quantity__gt=0) | models.Q(bonus_quantity__gt=0),
                name="purchase_invoice_item_qty_gt_0",
            ),
            models.CheckConstraint(condition=models.Q(line_total__gte=0), name="purchase_invoice_item_total_gte_0"),
        ]

    @property
    def is_free(self):
        return self.quantity == 0

    def __str__(self):
        return f"{self.trade_name} x{self.quantity}+{self.bonus_quantity}"


class SupplierPayment(models.Model):
    """يقابل جدول supplier_payment المحلي."""

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="supplier_payments")
    supplier = models.ForeignKey(Supplier, on_delete=models.CASCADE, related_name="payments")
    purchase_invoice = models.ForeignKey(
        PurchaseInvoice, on_delete=models.CASCADE, null=True, blank=True, related_name="payments"
    )
    amount_paid = models.DecimalField(max_digits=14, decimal_places=2)
    notes = models.CharField(max_length=255, blank=True, default="")
    paid_at = models.DateTimeField(default=timezone.now)

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
    # كلفة الإتلاف = الكمية × avg_cost وقت الإتلاف (NULL إن كانت الكلفة مجهولة).
    total_cost = models.DecimalField(max_digits=14, decimal_places=2, null=True, blank=True)
    reason = models.CharField(max_length=32, blank=True, default="")
    notes = models.CharField(max_length=255, blank=True, default="")
    # كان auto_now_add؛ حُوِّل إلى default قابل للتجاوز لنفس سبب Invoice.created_at:
    # DamagedMedicineViewSet.create لا تمرره فتُطبَّق قيمة اليوم كالسابق، بينما
    # MigrationViewSet تمرره صراحة لحفظ تاريخ الإتلاف التاريخي الحقيقي.
    damaged_at = models.DateField(default=date.today)

    class Meta:
        ordering = ["-id"]
        indexes = [models.Index(fields=["pharmacy", "damaged_at"])]
        constraints = [
            models.CheckConstraint(condition=models.Q(quantity_damaged__gt=0), name="damaged_medicine_quantity_gt_0"),
        ]

    def __str__(self):
        return f"{self.medicine.trade_name} x{self.quantity_damaged}"


class PurchaseInvoiceReturn(models.Model):
    """
    يقابل جدول purchase_invoice_return المحلي. amount_returned = قيمة الاسترجاع
    كاملة (رصيد المرتجع). excess_credit = ما زاد منها على متبقي فاتورتها فذهب
    لرصيد المذخر (سجلات قديمة: 0). الاسترجاع الجديد بالأصناف له أسطر
    (items)؛ القديم بالمبلغ فقط بلا أسطر ويبقى صالحاً كما هو.
    قيمة 0 مسموحة: استرجاع وحدات بونص/مجانية فقط.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="purchase_invoice_returns")
    supplier = models.ForeignKey(Supplier, on_delete=models.CASCADE, related_name="returns")
    purchase_invoice = models.ForeignKey(PurchaseInvoice, on_delete=models.CASCADE, related_name="returns")
    amount_returned = models.DecimalField(max_digits=14, decimal_places=2)
    excess_credit = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    notes = models.CharField(max_length=255, blank=True, default="")
    returned_at = models.DateTimeField(default=timezone.now)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=models.Q(amount_returned__gte=0), name="purchase_invoice_return_amount_gte_0"),
            models.CheckConstraint(
                condition=models.Q(excess_credit__gte=0) & models.Q(excess_credit__lte=models.F("amount_returned")),
                name="purchase_invoice_return_excess_valid",
            ),
        ]


class PurchaseInvoiceReturnItem(models.Model):
    """
    سطر استرجاع (دواء) من سطر فاتورة شراء. credited_quantity = الوحدات المحسوبة
    من الوحدات المدفوعة (البونص/المجاني بلا رصيد)؛ credit_amount =
    credited_quantity × unit_return_price. medicine SET_NULL + لقطة الاسم.
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="purchase_return_items")
    purchase_return = models.ForeignKey(PurchaseInvoiceReturn, on_delete=models.CASCADE, related_name="items")
    purchase_invoice_item = models.ForeignKey(
        PurchaseInvoiceItem, on_delete=models.CASCADE, related_name="return_items"
    )
    medicine = models.ForeignKey(
        Medicine, on_delete=models.SET_NULL, null=True, blank=True, related_name="purchase_return_items"
    )
    trade_name = models.CharField(max_length=200)
    quantity = models.PositiveIntegerField()
    credited_quantity = models.PositiveIntegerField(default=0)
    unit_return_price = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    credit_amount = models.DecimalField(max_digits=14, decimal_places=2, default=0)

    class Meta:
        ordering = ["id"]
        constraints = [
            models.CheckConstraint(condition=models.Q(quantity__gt=0), name="purchase_return_item_qty_gt_0"),
            models.CheckConstraint(
                condition=models.Q(credited_quantity__lte=models.F("quantity")),
                name="purchase_return_item_credited_lte_qty",
            ),
            models.CheckConstraint(condition=models.Q(credit_amount__gte=0), name="purchase_return_item_credit_gte_0"),
        ]

    def __str__(self):
        return f"{self.trade_name} x{self.quantity}"


class SupplierCreditApplication(models.Model):
    """
    استخدام رصيد المذخر (لصالح الصيدلية) لتخفيض متبقي فاتورة شراء ("خصم من رصيد
    سابق"). حركة غير نقدية: تنقل المال من الرصيد إلى الفاتورة ولا تغيّر رصيد
    المذخر الإجمالي (راجع supplier_ledger).
    """

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="supplier_credit_applications")
    supplier = models.ForeignKey(Supplier, on_delete=models.CASCADE, related_name="credit_applications")
    purchase_invoice = models.ForeignKey(
        PurchaseInvoice, on_delete=models.CASCADE, related_name="credit_applications"
    )
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    notes = models.CharField(max_length=255, blank=True, default="")
    applied_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["applied_at", "id"]
        constraints = [
            models.CheckConstraint(condition=models.Q(amount__gt=0), name="supplier_credit_application_amount_gt_0"),
        ]


class SupplierRefund(models.Model):
    """أموال استلمتها الصيدلية من المذخر مقابل رصيدها لديه ("استلام أموال من المذخر")."""

    pharmacy = models.ForeignKey(Pharmacy, on_delete=models.CASCADE, related_name="supplier_refunds")
    supplier = models.ForeignKey(Supplier, on_delete=models.CASCADE, related_name="refunds")
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    notes = models.CharField(max_length=255, blank=True, default="")
    received_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["received_at", "id"]
        constraints = [
            models.CheckConstraint(condition=models.Q(amount__gt=0), name="supplier_refund_amount_gt_0"),
        ]