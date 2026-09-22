from rest_framework.routers import DefaultRouter

from .views import InvoiceViewSet, MedicineViewSet

router = DefaultRouter()
router.register("medicines", MedicineViewSet, basename="medicine")
router.register("invoices", InvoiceViewSet, basename="invoice")

urlpatterns = router.urls