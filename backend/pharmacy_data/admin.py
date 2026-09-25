from django.contrib import admin

from .models import (
    DamagedMedicine,
    Expense,
    Invoice,
    InvoiceItem,
    Medicine,
    PurchaseInvoice,
    PurchaseInvoiceReturn,
    Supplier,
    SupplierPayment,
)


@admin.register(Medicine)
class MedicineAdmin(admin.ModelAdmin):
    list_display = ("trade_name", "scientific_name", "pharmacy", "quantity", "buy_price", "sell_price", "expiry_date", "is_damaged")
    list_filter = ("pharmacy", "is_damaged")
    search_fields = ("trade_name", "scientific_name", "barcode")


@admin.register(Supplier)
class SupplierAdmin(admin.ModelAdmin):
    list_display = ("name", "phone", "pharmacy", "created_at")
    list_filter = ("pharmacy",)
    search_fields = ("name", "phone")


class SupplierPaymentInline(admin.TabularInline):
    """يُظهر كل دفعة تخص فاتورة الشراء مباشرة تحتها — مفيد للتحقق من دقة الترحيل."""
    model = SupplierPayment
    extra = 0
    fields = ("amount_paid", "notes", "paid_at")


class PurchaseInvoiceReturnInline(admin.TabularInline):
    """يُظهر كل مرتجع يخص فاتورة الشراء مباشرة تحتها — مفيد للتحقق من دقة الترحيل."""
    model = PurchaseInvoiceReturn
    extra = 0
    fields = ("amount_returned", "notes", "returned_at")


@admin.register(PurchaseInvoice)
class PurchaseInvoiceAdmin(admin.ModelAdmin):
    list_display = ("invoice_number", "pharmacy", "supplier", "total_amount", "paid_amount", "created_at")
    list_filter = ("pharmacy",)
    search_fields = ("invoice_number", "supplier__name")
    date_hierarchy = "created_at"
    inlines = (SupplierPaymentInline, PurchaseInvoiceReturnInline)


@admin.register(SupplierPayment)
class SupplierPaymentAdmin(admin.ModelAdmin):
    list_display = ("supplier", "purchase_invoice", "amount_paid", "paid_at")
    list_filter = ("pharmacy",)
    search_fields = ("supplier__name", "purchase_invoice__invoice_number")


@admin.register(PurchaseInvoiceReturn)
class PurchaseInvoiceReturnAdmin(admin.ModelAdmin):
    list_display = ("supplier", "purchase_invoice", "amount_returned", "returned_at")
    list_filter = ("pharmacy",)
    search_fields = ("supplier__name", "purchase_invoice__invoice_number")


class InvoiceItemInline(admin.TabularInline):
    """يُظهر كل عنصر يخص فاتورة البيع مباشرة تحتها — مفيد للتحقق من دقة الترحيل."""
    model = InvoiceItem
    extra = 0
    fields = ("trade_name", "medicine", "quantity", "unit_price", "total_price")


@admin.register(Invoice)
class InvoiceAdmin(admin.ModelAdmin):
    # cashier_display_name (وليس cashier_name وحده) يوضّح فوراً إن كانت الفاتورة
    # جديدة (حساب حقيقي) أو مرحَّلة من أوفلاين (اسم نصي بلا حساب).
    list_display = ("invoice_number", "pharmacy", "cashier", "cashier_name", "total_amount", "discount", "final_amount", "is_refunded", "created_at")
    list_filter = ("pharmacy", "is_refunded")
    search_fields = ("invoice_number", "cashier_name", "cashier__username")
    date_hierarchy = "created_at"
    inlines = (InvoiceItemInline,)


@admin.register(InvoiceItem)
class InvoiceItemAdmin(admin.ModelAdmin):
    list_display = ("invoice", "trade_name", "medicine", "quantity", "unit_price", "total_price")
    search_fields = ("trade_name", "invoice__invoice_number")


@admin.register(DamagedMedicine)
class DamagedMedicineAdmin(admin.ModelAdmin):
    list_display = ("medicine", "pharmacy", "quantity_damaged", "reason", "damaged_at")
    list_filter = ("pharmacy", "reason")
    search_fields = ("medicine__trade_name",)
    date_hierarchy = "damaged_at"


@admin.register(Expense)
class ExpenseAdmin(admin.ModelAdmin):
    list_display = ("expense_type", "pharmacy", "amount", "expense_date")
    list_filter = ("pharmacy", "expense_type")
    search_fields = ("expense_type", "notes")
    date_hierarchy = "expense_date"