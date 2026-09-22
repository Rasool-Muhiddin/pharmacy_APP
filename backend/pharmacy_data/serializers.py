from rest_framework import serializers

from .models import Invoice, InvoiceItem, Medicine


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

    class Meta:
        model = Invoice
        fields = [
            "id",
            "invoice_number",
            "cashier",
            "total_amount",
            "discount",
            "final_amount",
            "created_at",
            "is_refunded",
            "updated_at",
            "items",
        ]
        read_only_fields = fields


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