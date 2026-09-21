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