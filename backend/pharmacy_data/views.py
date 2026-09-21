from rest_framework import viewsets, permissions

from .models import Medicine
from .serializers import MedicineSerializer


class MedicineViewSet(viewsets.ModelViewSet):
    """
    CRUD كامل لجدول المخزون، مقيَّد دائماً بصيدلية المستخدم المسجّل دخوله فقط
    عبر PharmacyMembership — لا يمكن لأي مستخدم رؤية أو تعديل مخزون صيدلية أخرى.
    """

    serializer_class = MedicineSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            return Medicine.objects.none()
        return Medicine.objects.filter(pharmacy=membership.pharmacy).order_by("trade_name")

    def perform_create(self, serializer):
        membership = self.request.user.pharmacymembership
        serializer.save(pharmacy=membership.pharmacy)