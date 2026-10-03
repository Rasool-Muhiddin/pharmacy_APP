from decimal import ROUND_HALF_UP, Decimal

from django.db.models import Sum
from rest_framework import serializers

from .models import (
    DamagedMedicine,
    Expense,
    Invoice,
    InvoiceItem,
    Medicine,
    MedicineBatch,
    PurchaseInvoice,
    StockTransfer,
    Supplier,
    Warehouse,
)


def _request_pharmacy(serializer):
    request = serializer.context.get("request")
    membership = getattr(getattr(request, "user", None), "pharmacymembership", None)
    return membership.pharmacy if membership is not None else None


def _request_is_owner(serializer):
    """الكلفة وسعر الشراء للمالك فقط؛ بلا طلب معروف (سياق ناقص) تُخفى احتياطاً."""
    request = serializer.context.get("request")
    membership = getattr(getattr(request, "user", None), "pharmacymembership", None)
    return membership is not None and membership.is_owner


class OwnerOnlyFieldsMixin:
    """يحذف owner_only_fields من المخرجات لغير المالك."""

    owner_only_fields = ()

    def to_representation(self, instance):
        data = super().to_representation(instance)
        if not _request_is_owner(self):
            for field in self.owner_only_fields:
                data.pop(field, None)
        return data


class WarehouseSerializer(serializers.ModelSerializer):
    class Meta:
        model = Warehouse
        fields = ["id", "name", "is_main", "created_at", "updated_at"]
        # is_main لا يُضبط من العميل: الرئيسي يُنشأ تلقائياً وحده، وكل مخزن
        # يُضاف عبر API هو مخزن إضافي.
        read_only_fields = ["id", "is_main", "created_at", "updated_at"]

    def validate_name(self, value):
        value = (value or "").strip()
        if not value:
            raise serializers.ValidationError("اسم المخزن مطلوب.")
        pharmacy = _request_pharmacy(self)
        if pharmacy is not None:
            duplicates = Warehouse.objects.filter(pharmacy=pharmacy, name__iexact=value)
            if self.instance is not None:
                duplicates = duplicates.exclude(pk=self.instance.pk)
            if duplicates.exists():
                raise serializers.ValidationError("يوجد مخزن آخر بنفس الاسم في صيدليتك.")
        return value


class StockTransferSerializer(serializers.ModelSerializer):
    class Meta:
        model = StockTransfer
        fields = [
            "id",
            "from_warehouse",
            "from_warehouse_name",
            "to_warehouse",
            "to_warehouse_name",
            "trade_name",
            "barcode",
            "quantity",
            "notes",
            "transferred_at",
        ]
        read_only_fields = fields


class StockTransferInputSerializer(serializers.Serializer):
    """بيانات الدخل لـ POST /api/warehouses/transfer/ فقط."""

    medicine_id = serializers.IntegerField()
    to_warehouse_id = serializers.IntegerField()
    quantity = serializers.IntegerField(min_value=1)
    notes = serializers.CharField(max_length=255, required=False, allow_blank=True, default="")


class MedicineBatchSerializer(OwnerOnlyFieldsMixin, serializers.ModelSerializer):
    owner_only_fields = ("purchase_price",)

    class Meta:
        model = MedicineBatch
        fields = ["id", "quantity", "expiry_date", "purchase_price", "created_at"]
        read_only_fields = fields


class MedicineSerializer(OwnerOnlyFieldsMixin, serializers.ModelSerializer):
    owner_only_fields = ("avg_cost", "buy_price")
    # اختياري عند الإنشاء (الافتراضي: المخزن الرئيسي، لتوافق عملاء Flutter
    # القدامى). لا يُغيَّر بعد الإنشاء — النقل بين المخازن حصراً عبر
    # /api/warehouses/transfer/ ليبقى له سجل وتبقى الكميات متسقة.
    warehouse = serializers.PrimaryKeyRelatedField(queryset=Warehouse.objects.none(), required=False)
    batches = serializers.SerializerMethodField()

    class Meta:
        model = Medicine
        fields = [
            "id",
            "warehouse",
            "trade_name",
            "scientific_name",
            "category",
            "quantity",
            "buy_price",
            "sell_price",
            "avg_cost",
            "batches",
            "expiry_date",
            "shelf_location",
            "is_damaged",
            "barcode",
            "updated_at",
        ]
        # pharmacy لا يُرسَل من العميل إطلاقاً — يُحدَّد تلقائياً من صيدلية المستخدم المسجّل دخوله
        # (انظر MedicineViewSet.perform_create)، منعاً لأي محاولة لكتابة بيانات في صيدلية أخرى.
        # avg_cost يُحسب على الخادم فقط (التوريد/الإنشاء)، ولا يُقبل من العميل.
        read_only_fields = ["id", "avg_cost", "updated_at"]
        # DRF يولّد تلقائياً مدقِّق فرادة من قيد (warehouse, barcode) يجعل
        # warehouse إلزامياً؛ الفحص نفسه مطبَّق يدوياً في validate() مع مراعاة
        # المخزن الرئيسي الافتراضي.
        validators = []

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # المخازن المقبولة = مخازن صيدلية المستخدم فقط، لا أي معرّف عام.
        pharmacy = _request_pharmacy(self)
        if pharmacy is not None:
            self.fields["warehouse"].queryset = Warehouse.objects.filter(pharmacy=pharmacy)

    def get_batches(self, obj):
        batches = [b for b in obj.batches.all() if b.quantity > 0]
        return MedicineBatchSerializer(batches, many=True, context=self.context).data

    def validate_barcode(self, value):
        return (value or "").strip() or None

    def update(self, instance, validated_data):
        # الكمية والصلاحية بعد الإنشاء مشتقتان من الدفعات: تتغيران فقط عبر
        # التوريد/البيع/الإتلاف/النقل. تُتجاهَل هنا (عملاء أقدم يرسلون expiry_date
        # مع التعديل) كي لا ينكسر تطابق الكمية مع مجموع الدفعات.
        validated_data.pop("quantity", None)
        validated_data.pop("expiry_date", None)
        return super().update(instance, validated_data)

    def validate(self, attrs):
        if self.instance is not None and "warehouse" in attrs and attrs["warehouse"].pk != self.instance.warehouse_id:
            raise serializers.ValidationError(
                {"warehouse": "لا يمكن تغيير مخزن الصنف مباشرة. استخدم عملية نقل المخزون."}
            )

        barcode = attrs.get("barcode")
        if barcode:
            pharmacy = _request_pharmacy(self)
            if self.instance is not None:
                warehouse = self.instance.warehouse
            else:
                warehouse = attrs.get("warehouse") or (Warehouse.main_for(pharmacy) if pharmacy else None)
            if warehouse is not None:
                duplicates = Medicine.objects.filter(warehouse=warehouse, barcode=barcode)
                if self.instance is not None:
                    duplicates = duplicates.exclude(pk=self.instance.pk)
                if duplicates.exists():
                    raise serializers.ValidationError(
                        {"barcode": "هذا الباركود مستخدم لدواء آخر في نفس المخزن."}
                    )
        return attrs


class InvoiceItemSerializer(OwnerOnlyFieldsMixin, serializers.ModelSerializer):
    owner_only_fields = ("unit_cost",)

    class Meta:
        model = InvoiceItem
        fields = ["id", "medicine", "trade_name", "quantity", "unit_price", "total_price", "unit_cost"]
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


class SupplyInputSerializer(serializers.Serializer):
    """بيانات الدخل لـ POST /api/medicines/<id>/supply/ فقط."""

    quantity = serializers.IntegerField(min_value=1)
    expiry_date = serializers.DateField(required=False, allow_null=True)
    # اختياري: بدونه يُستخدم avg_cost الحالي (ويُرفض إن كانت الكلفة مجهولة).
    purchase_price = serializers.DecimalField(max_digits=14, decimal_places=4, required=False, allow_null=True)
    sale_price = serializers.DecimalField(max_digits=12, decimal_places=2)

    def validate_purchase_price(self, value):
        if value is not None and value <= 0:
            raise serializers.ValidationError("سعر الشراء يجب أن يكون أكبر من صفر.")
        return value

    def validate_sale_price(self, value):
        if value <= 0:
            raise serializers.ValidationError("سعر البيع يجب أن يكون أكبر من صفر.")
        return value


class CheckoutItemInputSerializer(serializers.Serializer):
    medicine_id = serializers.IntegerField()
    quantity = serializers.IntegerField(min_value=1)


class RoundingDecimalField(serializers.DecimalField):
    """
    DecimalField يقرّب الخانات العشرية الزائدة (حسب rounding) بدل رفضها.
    DRF يتحقق من عدد الخانات (validate_precision) قبل التقريب، فـ rounding وحده
    لا يمنع الخطأ 400 — هنا يُقرَّب أولاً ثم يُتحقق. min_value وغيره يبقى كما هو.
    """

    def validate_precision(self, value):
        if self.decimal_places is not None and value.is_finite():
            value = value.quantize(Decimal(1).scaleb(-self.decimal_places), rounding=self.rounding)
        return super().validate_precision(value)


class CheckoutInputSerializer(serializers.Serializer):
    """بيانات الدخل لـ /api/invoices/checkout/ فقط — ليست موديل."""

    # خصم على مستوى الفاتورة فقط. نسخ التطبيق الأقدم قد ترسل خصماً نسبياً بأكثر
    # من خانتين (156.875) فيُقرَّب نصف-للأعلى بدل رفض البيع؛ السالب يُرفض دائماً.
    discount = RoundingDecimalField(
        max_digits=12, decimal_places=2, min_value=0, rounding=ROUND_HALF_UP, required=False, default=0
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

    def validate(self, attrs):
        total = attrs.get("total_amount", 0)
        paid = attrs.get("paid_amount", 0)
        if total < 0 or paid < 0:
            raise serializers.ValidationError("المبالغ لا يمكن أن تكون سالبة.")
        if paid > total:
            raise serializers.ValidationError("المبلغ المدفوع أكبر من إجمالي الفاتورة.")
        return attrs

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


class DamagedMedicineSerializer(OwnerOnlyFieldsMixin, serializers.ModelSerializer):
    """
    medicine مقبول ككتابة (معرّف الدواء)، لكن DamagedMedicineViewSet.create
    هي من تتحقق من ملكيته لصيدلية المستخدم وتخصم الكمية ذرّياً — نفس نمط
    PurchaseInvoiceViewSet.perform_create مع supplier. medicine_new_quantity
    تُرجع الكمية المتبقية بعد الخصم مباشرة، ليحدّث تطبيق Flutter كاش الدواء
    المحلي من نفس الاستجابة بلا طلب إضافي لجلب الدواء.
    """

    owner_only_fields = ("total_cost",)
    medicine_new_quantity = serializers.SerializerMethodField()

    class Meta:
        model = DamagedMedicine
        fields = [
            "id",
            "medicine",
            "medicine_new_quantity",
            "quantity_damaged",
            "total_cost",
            "reason",
            "notes",
            "damaged_at",
        ]
        read_only_fields = ["id", "medicine_new_quantity", "total_cost", "damaged_at"]

    def get_medicine_new_quantity(self, obj):
        return obj.medicine.quantity