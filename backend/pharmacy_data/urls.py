from rest_framework.routers import DefaultRouter

from .views import (
    DamagedMedicineViewSet,
    ExpenseViewSet,
    InvoiceViewSet,
    MedicineViewSet,
    PurchaseInvoiceViewSet,
    ReportsViewSet,
    SupplierViewSet,
)

router = DefaultRouter()
router.register("medicines", MedicineViewSet, basename="medicine")
router.register("invoices", InvoiceViewSet, basename="invoice")
router.register("suppliers", SupplierViewSet, basename="supplier")
router.register("purchase-invoices", PurchaseInvoiceViewSet, basename="purchase-invoice")
router.register("expenses", ExpenseViewSet, basename="expense")
router.register("damaged-medicines", DamagedMedicineViewSet, basename="damaged-medicine")
router.register("reports", ReportsViewSet, basename="report")

urlpatterns = router.urls