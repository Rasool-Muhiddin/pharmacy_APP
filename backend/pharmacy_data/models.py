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