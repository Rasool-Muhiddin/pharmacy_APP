from rest_framework.routers import DefaultRouter

from .views import InvoiceViewSet, MedicineViewSet, PurchaseInvoiceViewSet, SupplierViewSet

router = DefaultRouter()
router.register("medicines", MedicineViewSet, basename="medicine")
router.register("invoices", InvoiceViewSet, basename="invoice")
router.register("suppliers", SupplierViewSet, basename="supplier")
router.register("purchase-invoices", PurchaseInvoiceViewSet, basename="purchase-invoice")

urlpatterns = router.urls