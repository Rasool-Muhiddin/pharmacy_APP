from rest_framework import serializers

from .models import Medicine


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