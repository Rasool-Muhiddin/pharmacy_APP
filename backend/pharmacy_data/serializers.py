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
    PurchaseInvoiceItem,
    PurchaseInvoiceReturnItem,
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
    owner_only_fields = ("purchase_price", "supplier_name", "purchase_invoice_number")
    # مصدر الدفعة للتتبّع: اسم المذخر ورقم فاتورته (أو "رصيد افتتاحي" عبر source).
    supplier_name = serializers.CharField(source="supplier.name", default=None, read_only=True)
    purchase_invoice_number = serializers.CharField(
        source="purchase_invoice.invoice_number", default=None, read_only=True
    )

    class Meta:
        model = MedicineBatch
        fields = [
            "id",
            "quantity",
            "expiry_date",
            "purchase_price",
            "created_at",
            "source",
            "supplier",
            "supplier_name",
            "purchase_invoice",
            "purchase_invoice_number",
        ]
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
    # رصيد المذخر الموحّد (موجب دين، سالب لصالح الصيدلية)، ورصيد الصيدلية لديه،
    # والمتاح منه للاستخدام/الاستلام (supplier_ledger).
    balance = serializers.DecimalField(max_digits=14, decimal_places=2)
    credit_balance = serializers.DecimalField(max_digits=14, decimal_places=2)
    available_credit = serializers.DecimalField(max_digits=14, decimal_places=2)


class PurchaseListItemInputSerializer(serializers.Serializer):
    """سطر واحد من قائمة المذخر/الرصيد الافتتاحي (التحقق التجاري في purchase_list)."""

    medicine_id = serializers.IntegerField(required=False, allow_null=True)
    trade_name = serializers.CharField(max_length=200, required=False, allow_blank=True, default="")
    scientific_name = serializers.CharField(max_length=200, required=False, allow_blank=True, default="")
    category = serializers.CharField(max_length=120, required=False, allow_blank=True, default="")
    barcode = serializers.CharField(max_length=64, required=False, allow_blank=True, allow_null=True, default=None)
    shelf_location = serializers.CharField(max_length=120, required=False, allow_blank=True, default="")
    quantity = serializers.IntegerField(min_value=0, default=0)
    bonus_quantity = serializers.IntegerField(min_value=0, default=0)
    is_free = serializers.BooleanField(default=False)
    buy_price = serializers.DecimalField(max_digits=12, decimal_places=2, min_value=0, required=False, allow_null=True)
    sell_price = serializers.DecimalField(max_digits=12, decimal_places=2, required=False, allow_null=True)
    expiry_date = serializers.DateField(required=False, allow_null=True)

    def to_internal_value(self, data):
        # تاريخ فارغ = غير محدد (يُرفض لاحقاً برسالة "يرجى تحديد تاريخ الانتهاء" للسطر).
        if isinstance(data, dict) and data.get("expiry_date") == "":
            data = {**data, "expiry_date": None}
        return super().to_internal_value(data)


class OpeningStockInputSerializer(serializers.Serializer):
    """بيانات الدخل لـ POST /api/medicines/opening-stock/."""

    warehouse = serializers.IntegerField(required=False, allow_null=True)
    items = PurchaseListItemInputSerializer(many=True)

    def validate_items(self, value):
        if not value:
            raise serializers.ValidationError("لا يمكن حفظ قائمة بلا أصناف.")
        return value


class PurchaseListInputSerializer(OpeningStockInputSerializer):
    """بيانات الدخل لـ POST /api/purchase-invoices/from-list/ — لا مجاميع من العميل."""

    supplier = serializers.IntegerField(required=False, allow_null=True)
    supplier_name = serializers.CharField(max_length=150, required=False, allow_blank=True, default="")
    supplier_phone = serializers.CharField(max_length=30, required=False, allow_blank=True, default="")
    invoice_number = serializers.CharField(max_length=60, allow_blank=True)
    invoice_date = serializers.DateField(required=False, allow_null=True)
    paid_amount = serializers.DecimalField(max_digits=14, decimal_places=2, min_value=0, required=False, default=0)


class PurchaseInvoiceItemSerializer(serializers.ModelSerializer):
    invoice_number = serializers.CharField(source="purchase_invoice.invoice_number", read_only=True)
    # للاسترجاع: المسترجع سابقاً من السطر، ومخزون الصنف الحالي (null إن حُذف).
    returned_quantity = serializers.SerializerMethodField()
    current_stock = serializers.IntegerField(source="medicine.quantity", default=None, read_only=True)
    invoice_date = serializers.DateField(source="purchase_invoice.invoice_date", read_only=True)
    invoice_created_at = serializers.DateTimeField(source="purchase_invoice.created_at", read_only=True)
    is_free = serializers.BooleanField(read_only=True)

    class Meta:
        model = PurchaseInvoiceItem
        fields = [
            "id",
            "purchase_invoice",
            "invoice_number",
            "invoice_date",
            "invoice_created_at",
            "medicine",
            "trade_name",
            "quantity",
            "bonus_quantity",
            "is_free",
            "buy_price",
            "effective_unit_cost",
            "sell_price",
            "expiry_date",
            "line_total",
            "returned_quantity",
            "current_stock",
        ]
        read_only_fields = fields

    def get_returned_quantity(self, obj):
        annotated = getattr(obj, "returned_quantity_total", None)
        if annotated is not None:
            return annotated
        return obj.return_items.aggregate(total=Sum("quantity"))["total"] or 0


class PurchaseReturnItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = PurchaseInvoiceReturnItem
        fields = [
            "id",
            "purchase_invoice_item",
            "medicine",
            "trade_name",
            "quantity",
            "credited_quantity",
            "unit_return_price",
            "credit_amount",
        ]
        read_only_fields = fields


class ReturnItemLineInputSerializer(serializers.Serializer):
    purchase_invoice_item = serializers.IntegerField()
    quantity = serializers.IntegerField(min_value=1)
    # اختياري: بدونه يُستخدم سعر شراء السطر الأصلي.
    unit_price = serializers.DecimalField(max_digits=12, decimal_places=2, min_value=0, required=False, allow_null=True)


class ReturnItemsInputSerializer(serializers.Serializer):
    """بيانات الدخل لـ POST /api/purchase-invoices/<id>/return-items/ — لا مجاميع من العميل."""

    items = ReturnItemLineInputSerializer(many=True)
    notes = serializers.CharField(max_length=255, required=False, allow_blank=True, default="")
    return_date = serializers.DateField(required=False, allow_null=True)

    def validate_items(self, value):
        if not value:
            raise serializers.ValidationError("اختر صنفاً واحداً على الأقل لاسترجاعه.")
        return value


class SupplierRefundInputSerializer(serializers.Serializer):
    amount = serializers.DecimalField(max_digits=14, decimal_places=2)
    notes = serializers.CharField(max_length=255, required=False, allow_blank=True, default="")
    received_date = serializers.DateField(required=False, allow_null=True)


class PurchaseInvoiceSerializer(serializers.ModelSerializer):
    """
    للقراءة فقط: فواتير الشراء تُنشأ حصراً من قوائم المخزون
    (PurchaseInvoiceViewSet.from_list). returned_amount/net_amount/
    remaining_amount محسوبة ديناميكياً من الاسترجاعات المرتبطة (وليست أعمدة
    مخزَّنة)، لتبقى متسقة دائماً مع آخر حالة فعلية للفاتورة.
    """

    returned_amount = serializers.SerializerMethodField()
    net_amount = serializers.SerializerMethodField()
    credit_applied = serializers.SerializerMethodField()
    remaining_amount = serializers.SerializerMethodField()

    class Meta:
        model = PurchaseInvoice
        fields = [
            "id",
            "supplier",
            "invoice_number",
            "invoice_date",
            "source",
            "item_count",
            "total_amount",
            "paid_amount",
            "returned_amount",
            "net_amount",
            "credit_applied",
            "remaining_amount",
            "created_at",
            "updated_at",
        ]
        read_only_fields = fields

    def _figures(self, obj):
        # الفواتير من PurchaseInvoiceViewSet مُعلَّمة مسبقاً؛ غيرها يُحسب مرة واحدة.
        if not hasattr(obj, "returned_on_invoice"):
            from .supplier_ledger import annotate_invoices

            annotated = annotate_invoices(PurchaseInvoice.objects.filter(pk=obj.pk)).get()
            for field in ("returned_total", "returned_on_invoice", "applied_in", "linked_paid"):
                setattr(obj, field, getattr(annotated, field))
        return obj

    def get_returned_amount(self, obj):
        return self._figures(obj).returned_total

    def get_net_amount(self, obj):
        return obj.total_amount - self.get_returned_amount(obj)

    def get_credit_applied(self, obj):
        return self._figures(obj).applied_in

    def get_remaining_amount(self, obj):
        from .supplier_ledger import remaining_of

        return max(remaining_of(self._figures(obj)), 0)


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