from django.db.models import Sum
from rest_framework import serializers

from .models import DamagedMedicine, Expense, Invoice, InvoiceItem, Medicine, PurchaseInvoice, Supplier


class MedicineSerializer(serializers.ModelSerializer):
    class Meta:
        model = Medicine
        fields = [
            "id",
            "trade_name",
            "scientific_name",
            "category",
            "quantity",
            "buy_price",
            "sell_price",
            "expiry_date",
            "shelf_location",
            "is_damaged",
            "barcode",
            "updated_at",
        ]
        # pharmacy لا يُرسَل من العميل إطلاقاً — يُحدَّد تلقائياً من صيدلية المستخدم المسجّل دخوله
        # (انظر MedicineViewSet.perform_create)، منعاً لأي محاولة لكتابة بيانات في صيدلية أخرى.
        read_only_fields = ["id", "updated_at"]


class InvoiceItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = InvoiceItem
        fields = ["id", "medicine", "trade_name", "quantity", "unit_price", "total_price"]
        read_only_fields = fields


class InvoiceSerializer(serializers.ModelSerializer):
    """
    للقراءة فقط بالكامل — الفاتورة تُنشأ حصراً عبر
    InvoiceViewSet.checkout، وليس عبر POST/PATCH عادي على هذا الـSerializer.
    """

    items = InvoiceItemSerializer(many=True, read_only=True)
    # الفواتير الجديدة: cashier حقيقي فحساب المستخدم يُعطي الاسم. الفواتير
    # المُرحَّلة من أوفلاين: cashier=None وcashier_name نص محفوظ من الجهاز
    # المحلي وقت الترحيل. هذا الحقل يوحّد الاثنين لعرض واحد في الواجهة.
    cashier_display_name = serializers.SerializerMethodField()

    class Meta:
        model = Invoice
        fields = [
            "id",
            "invoice_number",
            "cashier",
            "cashier_name",
            "cashier_display_name",
            "total_amount",
            "discount",
            "final_amount",
            "created_at",
            "is_refunded",
            "updated_at",
            "items",
        ]
        read_only_fields = fields

    def get_cashier_display_name(self, obj):
        if obj.cashier is not None:
            return obj.cashier.get_full_name() or obj.cashier.username
        return obj.cashier_name or "بائع غير محدد"


class CheckoutItemInputSerializer(serializers.Serializer):
    medicine_id = serializers.IntegerField()
    quantity = serializers.IntegerField(min_value=1)


class CheckoutInputSerializer(serializers.Serializer):
    """بيانات الدخل لـ /api/invoices/checkout/ فقط — ليست موديل."""

    discount = serializers.DecimalField(
        max_digits=12, decimal_places=2, min_value=0, required=False, default=0
    )
    items = CheckoutItemInputSerializer(many=True)

    def validate_items(self, value):
        if not value:
            raise serializers.ValidationError("لا يمكن إتمام فاتورة بلا أصناف.")
        return value


class SupplierSerializer(serializers.ModelSerializer):
    class Meta:
        model = Supplier
        fields = ["id", "name", "phone", "created_at", "updated_at"]
        # pharmacy يُحدَّد تلقائياً من صيدلية المستخدم — نفس نمط MedicineSerializer.
        read_only_fields = ["id", "created_at", "updated_at"]


class SupplierSummarySerializer(serializers.Serializer):
    """
    للقراءة فقط — شكل نتيجة SupplierViewSet.summary (قائمة مذاخر مع
    إحصاءاتها المالية المحسوبة)، وليست مرتبطة بموديل مباشرة.
    """

    id = serializers.IntegerField()
    name = serializers.CharField()
    phone = serializers.CharField(allow_blank=True)
    invoice_count = serializers.IntegerField()
    total_purchases = serializers.DecimalField(max_digits=14, decimal_places=2)
    remaining_debt = serializers.DecimalField(max_digits=14, decimal_places=2)


class PurchaseInvoiceSerializer(serializers.ModelSerializer):
    """
    returned_amount/net_amount/remaining_amount محسوبة ديناميكياً من
    الاسترجاعات المرتبطة (وليست أعمدة مخزَّنة)، لتبقى متسقة دائماً مع
    آخر حالة فعلية للفاتورة.
    """

    returned_amount = serializers.SerializerMethodField()
    net_amount = serializers.SerializerMethodField()
    remaining_amount = serializers.SerializerMethodField()

    class Meta:
        model = PurchaseInvoice
        fields = [
            "id",
            "supplier",
            "invoice_number",
            "total_amount",
            "paid_amount",
            "returned_amount",
            "net_amount",
            "remaining_amount",
            "created_at",
            "updated_at",
        ]
        # supplier يُحدَّد يدوياً في PurchaseInvoiceViewSet.perform_create بعد
        # التحقق من ملكيته لصيدلية المستخدم — لا PrimaryKeyRelatedField عام
        # كان سيسمح نظرياً بأي معرّف مذخر من صيدلية أخرى. total_amount/
        # paid_amount قابلان للكتابة فقط عند الإنشاء؛ بعد ذلك يتغيران حصراً
        # عبر add_payment/add_return/settle_credit (انظر views.py).
        read_only_fields = [
            "id",
            "supplier",
            "returned_amount",
            "net_amount",
            "remaining_amount",
            "created_at",
            "updated_at",
        ]

    def get_returned_amount(self, obj):
        return obj.returns.aggregate(s=Sum("amount_returned"))["s"] or 0

    def get_net_amount(self, obj):
        return obj.total_amount - self.get_returned_amount(obj)

    def get_remaining_amount(self, obj):
        return self.get_net_amount(obj) - obj.paid_amount


class ExpenseSerializer(serializers.ModelSerializer):
    class Meta:
        model = Expense
        fields = [
            "id",
            "expense_type",
            "expense_date",
            "amount",
            "notes",
            "created_at",
            "updated_at",
        ]
        # pharmacy يُحدَّد تلقائياً من صيدلية المستخدم — نفس نمط MedicineSerializer/SupplierSerializer.
        read_only_fields = ["id", "created_at", "updated_at"]

    def validate_amount(self, value):
        if value <= 0:
            raise serializers.ValidationError("يجب أن يكون مبلغ المصروف أكبر من صفر.")
        return value


class DamagedMedicineSerializer(serializers.ModelSerializer):
    """
    medicine مقبول ككتابة (معرّف الدواء)، لكن DamagedMedicineViewSet.create
    هي من تتحقق من ملكيته لصيدلية المستخدم وتخصم الكمية ذرّياً — نفس نمط
    PurchaseInvoiceViewSet.perform_create مع supplier. medicine_new_quantity
    تُرجع الكمية المتبقية بعد الخصم مباشرة، ليحدّث تطبيق Flutter كاش الدواء
    المحلي من نفس الاستجابة بلا طلب إضافي لجلب الدواء.
    """

    medicine_new_quantity = serializers.SerializerMethodField()

    class Meta:
        model = DamagedMedicine
        fields = [
            "id",
            "medicine",
            "medicine_new_quantity",
            "quantity_damaged",
            "reason",
            "notes",
            "damaged_at",
        ]
        read_only_fields = ["id", "medicine_new_quantity", "damaged_at"]

    def get_medicine_new_quantity(self, obj):
        return obj.medicine.quantity