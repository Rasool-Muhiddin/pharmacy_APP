import json
from datetime import date, datetime, timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import Count, DecimalField, F, OuterRef, Subquery, Sum, Value
from django.db.models.functions import Coalesce
from django.http import StreamingHttpResponse
from django.utils import timezone
from django.utils.dateparse import parse_date, parse_datetime
from rest_framework import mixins, permissions, status, viewsets
from rest_framework.renderers import BaseRenderer
from rest_framework.decorators import action
from rest_framework.exceptions import NotFound, PermissionDenied, ValidationError
from rest_framework.response import Response

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
from .serializers import (
    CheckoutInputSerializer,
    DamagedMedicineSerializer,
    ExpenseSerializer,
    InvoiceSerializer,
    MedicineSerializer,
    PurchaseInvoiceSerializer,
    SupplierSerializer,
    SupplierSummarySerializer,
)


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


def _next_invoice_number(pharmacy):
    """
    يولَّد داخل معاملة تُقفل فيها الصيدلية أصلاً (انظر
    InvoiceViewSet.checkout)، فلا حاجة لقفل إضافي هنا. الصيغة نفس شكل
    الترقيم المحلي الحالي في Flutter (generateInvoiceNumber) للتناسق:
    "INV-" ثم رقم تسلسلي بمحاذاة 6 أصفار، لكن هنا لكل صيدلية على حدة.
    """

    last_count = Invoice.objects.filter(pharmacy=pharmacy).count()
    return f"INV-{last_count + 1:06d}"


class InvoiceViewSet(viewsets.ReadOnlyModelViewSet):
    """
    قراءة فقط لسجل المبيعات وتفاصيله (list/retrieve). لا يوجد create/update/
    delete عادي هنا: الإنشاء عبر checkout والإرجاع عبر refund فقط أدناه،
    لأن كليهما عملية مركّبة (فاتورة + أصناف + تعديل مخزون) تحتاج تحققاً
    ذرّياً، وليست إنشاء/تعديل صف واحد بسيط كما في Medicine.
    """

    serializer_class = InvoiceSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            return Invoice.objects.none()
        return (
            Invoice.objects.filter(pharmacy=membership.pharmacy)
            .prefetch_related("items")
            .order_by("-created_at")
        )

    def _membership(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            raise PermissionDenied("هذا الحساب غير مرتبط بأي صيدلية.")
        return membership

    @action(detail=False, methods=["post"])
    def checkout(self, request):
        """
        POST /api/invoices/checkout/  body: {"discount": 0, "items": [{"medicine_id": 1, "quantity": 2}, ...]}

        ينشئ فاتورة بيع كاملة بصورة ذرّية: يقفل صف الصيدلية وصفوف الأدوية
        المعنية، يتحقق من توفر الكمية لكل صنف، يحسب السعر من
        medicine.sell_price الحالي على الخادم (وليس مما يرسله العميل، منعاً
        لأي تلاعب بالسعر من جهاز مخترق)، يخصم المخزون، ويولّد رقم فاتورة
        فريد ضمن نفس الصيدلية — كل ذلك في معاملة واحدة.

        قفل صف الصيدلية يجعل كل عمليات الدفع لنفس الصيدلية تُنفَّذ بالتتابع
        لا بالتوازي؛ مقبول حالياً مع صيدليات وأجهزة قليلة (انظر ملاحظة
        الأداء في وصف المشروع)، وأبسط وأضمن من التنسيق بين أقفال متعددة.
        """

        membership = self._membership()
        input_serializer = CheckoutInputSerializer(data=request.data)
        input_serializer.is_valid(raise_exception=True)
        data = input_serializer.validated_data

        with transaction.atomic():
            pharmacy = (
                type(membership.pharmacy)
                .objects.select_for_update()
                .get(pk=membership.pharmacy_id)
            )

            requested_ids = [item["medicine_id"] for item in data["items"]]
            medicines = {
                medicine.id: medicine
                for medicine in Medicine.objects.select_for_update().filter(
                    pharmacy=pharmacy, id__in=requested_ids
                )
            }

            total_amount = Decimal("0")
            prepared_items = []

            for item in data["items"]:
                medicine = medicines.get(item["medicine_id"])
                if medicine is None:
                    raise ValidationError(
                        f"الدواء رقم {item['medicine_id']} غير موجود في هذه الصيدلية."
                    )
                if medicine.quantity < item["quantity"]:
                    raise ValidationError(
                        f"الكمية المتوفرة من {medicine.trade_name} غير كافية."
                    )

                unit_price = medicine.sell_price
                total_price = unit_price * item["quantity"]
                total_amount += total_price

                prepared_items.append(
                    {
                        "medicine": medicine,
                        "trade_name": medicine.trade_name,
                        "quantity": item["quantity"],
                        "unit_price": unit_price,
                        "total_price": total_price,
                    }
                )

            discount = data.get("discount") or Decimal("0")
            final_amount = total_amount - discount
            if final_amount < 0:
                raise ValidationError("قيمة الخصم أكبر من إجمالي الفاتورة.")

            invoice = Invoice.objects.create(
                pharmacy=pharmacy,
                invoice_number=_next_invoice_number(pharmacy),
                cashier=request.user,
                total_amount=total_amount,
                discount=discount,
                final_amount=final_amount,
            )

            for prepared in prepared_items:
                InvoiceItem.objects.create(
                    invoice=invoice,
                    medicine=prepared["medicine"],
                    trade_name=prepared["trade_name"],
                    quantity=prepared["quantity"],
                    unit_price=prepared["unit_price"],
                    total_price=prepared["total_price"],
                )
                Medicine.objects.filter(pk=prepared["medicine"].pk).update(
                    quantity=F("quantity") - prepared["quantity"]
                )

        invoice.refresh_from_db()
        return Response(InvoiceSerializer(invoice).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"])
    def refund(self, request, pk=None):
        """
        POST /api/invoices/<id>/refund/

        يعكس checkout بالضبط: يعيد كل كمية بيعت إلى المخزون ثم يعلّم
        الفاتورة كمسترجعة، ذرّياً وبنفس قفل الصيدلية.
        """

        membership = self._membership()

        with transaction.atomic():
            try:
                invoice = (
                    Invoice.objects.select_for_update()
                    .filter(pharmacy=membership.pharmacy)
                    .get(pk=pk)
                )
            except Invoice.DoesNotExist:
                raise NotFound("الفاتورة غير موجودة.")

            if invoice.is_refunded:
                raise ValidationError("هذه الفاتورة مسترجعة بالفعل.")

            for item in invoice.items.select_related("medicine"):
                Medicine.objects.filter(pk=item.medicine_id).update(
                    quantity=F("quantity") + item.quantity
                )

            invoice.is_refunded = True
            invoice.save(update_fields=["is_refunded", "updated_at"])

        invoice.refresh_from_db()
        return Response(InvoiceSerializer(invoice).data)


class SupplierViewSet(viewsets.ModelViewSet):
    """CRUD كامل للمذاخر، مقيَّد بصيدلية المستخدم فقط — نفس نمط MedicineViewSet."""

    serializer_class = SupplierSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            return Supplier.objects.none()
        return Supplier.objects.filter(pharmacy=membership.pharmacy).order_by("name")

    def perform_create(self, serializer):
        membership = self.request.user.pharmacymembership
        serializer.save(pharmacy=membership.pharmacy)

    def _membership(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            raise PermissionDenied("هذا الحساب غير مرتبط بأي صيدلية.")
        return membership

    @action(detail=False, methods=["get"])
    def summary(self, request):
        """
        GET /api/suppliers/summary/ — نسخة الخادم من getSuppliersWithFinancials
        المحلية: صافي المشتريات وعدد الفواتير والدين المتبقي لكل مذخر،
        محسوبة من الفواتير/الاسترجاعات/الدفعات الفعلية وليس عمود مخزَّن،
        لتفادي أي تعارض بين الأجهزة.
        """
        membership = self._membership()

        returns_subq = (
            PurchaseInvoiceReturn.objects.filter(purchase_invoice__supplier=OuterRef("pk"))
            .order_by()
            .values("purchase_invoice__supplier")
            .annotate(total=Sum("amount_returned"))
            .values("total")
        )

        suppliers = Supplier.objects.filter(pharmacy=membership.pharmacy).annotate(
            invoice_count=Count("purchase_invoices", distinct=True),
            total_invoiced=Coalesce(
                Sum("purchase_invoices__total_amount"),
                Value(0),
                output_field=DecimalField(max_digits=14, decimal_places=2),
            ),
            total_paid=Coalesce(
                Sum("purchase_invoices__paid_amount"),
                Value(0),
                output_field=DecimalField(max_digits=14, decimal_places=2),
            ),
            total_returned=Coalesce(
                Subquery(returns_subq, output_field=DecimalField(max_digits=14, decimal_places=2)),
                Value(0),
                output_field=DecimalField(max_digits=14, decimal_places=2),
            ),
        ).order_by("name")

        result = []
        for s in suppliers:
            net_purchases = s.total_invoiced - s.total_returned
            remaining = net_purchases - s.total_paid
            result.append(
                {
                    "id": s.id,
                    "name": s.name,
                    "phone": s.phone,
                    "invoice_count": s.invoice_count,
                    "total_purchases": net_purchases,
                    "remaining_debt": max(remaining, Decimal("0")),
                }
            )

        return Response(SupplierSummarySerializer(result, many=True).data)

    @action(detail=True, methods=["get"])
    def statement(self, request, pk=None):
        """GET /api/suppliers/<id>/statement/ — نسخة الخادم من getSupplierStatementOfAccount."""
        membership = self._membership()
        try:
            supplier = Supplier.objects.get(pk=pk, pharmacy=membership.pharmacy)
        except Supplier.DoesNotExist:
            raise NotFound("المذخر غير موجود.")

        rows = []

        invoices = supplier.purchase_invoices.annotate(
            returned=Coalesce(
                Sum("returns__amount_returned"),
                Value(0),
                output_field=DecimalField(max_digits=14, decimal_places=2),
            )
        )
        for inv in invoices:
            rows.append(
                {
                    "id": inv.id,
                    "transaction_type": "invoice",
                    "reference": inv.invoice_number or "فاتورة بدون رقم",
                    "amount": inv.total_amount - inv.returned,
                    "cash_paid": inv.paid_amount,
                    # total_amount الخام هنا وليس remaining_debt: الدفعات
                    # والاسترجاعات مُدرجة أصلاً كحركات منفصلة أدناه، فطرحها
                    # هنا أيضاً كان يسبب ازدواج الخصم في الحساب التراكمي
                    # بالنسخة المحلية.
                    "debt_added": inv.total_amount,
                    "date_time": inv.created_at,
                    "notes": "",
                }
            )

        for pay in supplier.payments.all():
            rows.append(
                {
                    "id": pay.id,
                    "transaction_type": "payment",
                    "reference": "تسديد دفعة",
                    "amount": pay.amount_paid,
                    "cash_paid": pay.amount_paid,
                    "debt_added": -pay.amount_paid,
                    "date_time": pay.paid_at,
                    "notes": pay.notes,
                }
            )

        for ret in supplier.returns.all():
            rows.append(
                {
                    "id": ret.id,
                    "transaction_type": "return",
                    "reference": "استرجاع من فاتورة شراء",
                    "amount": ret.amount_returned,
                    "cash_paid": 0,
                    "debt_added": -ret.amount_returned,
                    "date_time": ret.returned_at,
                    "notes": ret.notes,
                }
            )

        rows.sort(key=lambda r: r["date_time"], reverse=True)
        return Response(rows)


class PurchaseInvoiceViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    """
    لا update/destroy مباشر: total_amount/paid_amount يتغيران فقط عبر
    add_payment/add_return/settle_credit الذرّية أدناه — نفس نمط
    checkout/refund في InvoiceViewSet، لمنع أي تعديل غير متسق للأرصدة.
    """

    serializer_class = PurchaseInvoiceSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            return PurchaseInvoice.objects.none()
        qs = PurchaseInvoice.objects.filter(pharmacy=membership.pharmacy)
        supplier_id = self.request.query_params.get("supplier")
        if supplier_id:
            qs = qs.filter(supplier_id=supplier_id)
        return qs.order_by("-created_at")

    def perform_create(self, serializer):
        membership = self.request.user.pharmacymembership
        supplier_id = self.request.data.get("supplier")
        try:
            supplier = Supplier.objects.get(pk=supplier_id, pharmacy=membership.pharmacy)
        except (Supplier.DoesNotExist, TypeError, ValueError):
            raise ValidationError("المذخر غير موجود في هذه الصيدلية.")
        serializer.save(pharmacy=membership.pharmacy, supplier=supplier)

    def _membership(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            raise PermissionDenied("هذا الحساب غير مرتبط بأي صيدلية.")
        return membership

    def _locked_invoice(self, pk, membership):
        try:
            return (
                PurchaseInvoice.objects.select_for_update()
                .filter(pharmacy=membership.pharmacy)
                .get(pk=pk)
            )
        except PurchaseInvoice.DoesNotExist:
            raise NotFound("فاتورة الشراء غير موجودة.")

    @action(detail=True, methods=["post"])
    def add_payment(self, request, pk=None):
        """POST /api/purchase-invoices/<id>/add_payment/  body: {"amount": 1000, "notes": "..."}"""
        membership = self._membership()
        try:
            amount = Decimal(str(request.data.get("amount")))
        except Exception:
            raise ValidationError("قيمة الدفعة غير صحيحة.")
        if amount <= 0:
            raise ValidationError("يجب أن يكون مبلغ الدفعة أكبر من صفر.")
        notes = request.data.get("notes", "") or ""

        with transaction.atomic():
            invoice = self._locked_invoice(pk, membership)
            returned = invoice.returns.aggregate(s=Sum("amount_returned"))["s"] or Decimal("0")
            outstanding = invoice.total_amount - returned - invoice.paid_amount
            if amount > outstanding:
                raise ValidationError("مبلغ الدفعة أكبر من المتبقي لهذه الفاتورة.")

            SupplierPayment.objects.create(
                pharmacy=membership.pharmacy,
                supplier=invoice.supplier,
                purchase_invoice=invoice,
                amount_paid=amount,
                notes=notes,
            )
            invoice.paid_amount = F("paid_amount") + amount
            invoice.save(update_fields=["paid_amount", "updated_at"])

        invoice.refresh_from_db()
        return Response(PurchaseInvoiceSerializer(invoice).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"])
    def add_return(self, request, pk=None):
        """POST /api/purchase-invoices/<id>/add_return/  body: {"amount": 500, "notes": "..."}"""
        membership = self._membership()
        try:
            amount = Decimal(str(request.data.get("amount")))
        except Exception:
            raise ValidationError("قيمة الاسترجاع غير صحيحة.")
        if amount <= 0:
            raise ValidationError("يجب أن يكون مبلغ الاسترجاع أكبر من صفر.")
        notes = request.data.get("notes", "") or ""

        with transaction.atomic():
            invoice = self._locked_invoice(pk, membership)
            already_returned = invoice.returns.aggregate(s=Sum("amount_returned"))["s"] or Decimal("0")
            if already_returned + amount > invoice.total_amount:
                raise ValidationError("مجموع الاسترجاعات لا يمكن أن يتجاوز مبلغ الفاتورة الأصلي.")

            PurchaseInvoiceReturn.objects.create(
                pharmacy=membership.pharmacy,
                supplier=invoice.supplier,
                purchase_invoice=invoice,
                amount_returned=amount,
                notes=notes,
            )

        invoice.refresh_from_db()
        return Response(PurchaseInvoiceSerializer(invoice).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"])
    def settle_credit(self, request, pk=None):
        """POST /api/purchase-invoices/<id>/settle_credit/ — يقابل settlePurchaseInvoiceCredit المحلية."""
        membership = self._membership()
        with transaction.atomic():
            invoice = self._locked_invoice(pk, membership)
            returned = invoice.returns.aggregate(s=Sum("amount_returned"))["s"] or Decimal("0")
            invoice.paid_amount = invoice.total_amount - returned
            invoice.save(update_fields=["paid_amount", "updated_at"])

        invoice.refresh_from_db()
        return Response(PurchaseInvoiceSerializer(invoice).data)


class ExpenseViewSet(viewsets.ModelViewSet):
    """CRUD كامل للمصاريف، مقيَّد بصيدلية المستخدم فقط — نفس نمط SupplierViewSet/MedicineViewSet."""

    serializer_class = ExpenseSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            return Expense.objects.none()
        return Expense.objects.filter(pharmacy=membership.pharmacy)

    def perform_create(self, serializer):
        membership = self.request.user.pharmacymembership
        serializer.save(pharmacy=membership.pharmacy)


class DamagedMedicineViewSet(
    mixins.CreateModelMixin,
    mixins.ListModelMixin,
    mixins.RetrieveModelMixin,
    viewsets.GenericViewSet,
):
    """
    لا update/destroy: الإتلاف عملية نهائية كما في النسخة المحلية
    (processDamageMedicine)، فلا تراجع عنها من هذا الـAPI.

    create() مبنية يدوياً (لا perform_create بسيط) لأن إنشاء السجل هنا
    عملية مركّبة تُخصم فيها كمية المخزون ذرّياً في نفس المعاملة — تماماً
    كنمط InvoiceViewSet.checkout، وليست إدخال صف واحد بسيط.
    """

    serializer_class = DamagedMedicineSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            return DamagedMedicine.objects.none()
        return (
            DamagedMedicine.objects.filter(pharmacy=membership.pharmacy)
            .select_related("medicine")
            .order_by("-id")
        )

    def _membership(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            raise PermissionDenied("هذا الحساب غير مرتبط بأي صيدلية.")
        return membership

    def create(self, request, *args, **kwargs):
        membership = self._membership()
        input_serializer = self.get_serializer(data=request.data)
        input_serializer.is_valid(raise_exception=True)
        data = input_serializer.validated_data

        medicine_id = data["medicine"].pk
        quantity = data["quantity_damaged"]

        with transaction.atomic():
            try:
                medicine = Medicine.objects.select_for_update().get(
                    pk=medicine_id, pharmacy=membership.pharmacy
                )
            except Medicine.DoesNotExist:
                raise ValidationError("الدواء غير موجود في هذه الصيدلية.")

            if medicine.quantity < quantity:
                raise ValidationError(
                    f"الكمية المطلوب إتلافها ({quantity}) أكبر من المتوفر فعلياً ({medicine.quantity})."
                )

            Medicine.objects.filter(pk=medicine.pk).update(quantity=F("quantity") - quantity)

            record = DamagedMedicine.objects.create(
                pharmacy=membership.pharmacy,
                medicine=medicine,
                quantity_damaged=quantity,
                reason=data.get("reason", ""),
                notes=data.get("notes", ""),
            )
            medicine.refresh_from_db(fields=["quantity"])

        record.refresh_from_db()
        return Response(
            self.get_serializer(record).data, status=status.HTTP_201_CREATED
        )


class ReportsViewSet(viewsets.ViewSet):
    """
    كل التجميع يحدث على السيرفر عبر ORM aggregate/annotate — لا استعلام يجلب
    صفوفاً خاماً للعميل ليُجمِّعها هو، خلافاً لما كانت تفعله reports_screen.dart
    محلياً على SQLite. المخرجات مُسمّاة بنفس أسماء الحقول التي تستخدمها
    الشاشة حالياً (total_sales, total_invoices_count, ...) لتبقى شاشة
    Flutter قابلة للتحديث بأقل قدر من التغيير.

    لا queryset/basename تلقائي هنا (ViewSet عادية وليست ModelViewSet):
    كل التقرير أفعال إضافية (`summary`, `shifts`) لا CRUD قياسي على نموذج
    واحد.
    """

    permission_classes = [permissions.IsAuthenticated]

    def _membership(self, request):
        membership = getattr(request.user, "pharmacymembership", None)
        if membership is None:
            raise PermissionDenied("هذا الحساب غير مرتبط بأي صيدلية.")
        return membership

    def _date_range(self, request):
        """
        نفس الافتراضي المستخدم في reports_screen.dart (آخر 30 يوماً) إن لم
        يُمرَّر start/end. صيغة الإدخال ISO: YYYY-MM-DD.
        """
        today = date.today()
        start_raw = request.query_params.get("start")
        end_raw = request.query_params.get("end")

        try:
            start = date.fromisoformat(start_raw) if start_raw else today - timedelta(days=30)
            end = date.fromisoformat(end_raw) if end_raw else today
        except ValueError:
            raise ValidationError("صيغة التاريخ غير صحيحة، استخدم YYYY-MM-DD.")

        if start > end:
            raise ValidationError("تاريخ البداية يجب أن يسبق تاريخ النهاية.")

        return start, end

    @action(detail=False, methods=["get"])
    def summary(self, request):
        membership = self._membership(request)
        pharmacy = membership.pharmacy
        start, end = self._date_range(request)
        today = date.today()

        non_refunded_invoices = Invoice.objects.filter(
            pharmacy=pharmacy,
            is_refunded=False,
            created_at__date__gte=start,
            created_at__date__lte=end,
        )

        sales_summary = non_refunded_invoices.aggregate(
            total_cash_in_drawer=Coalesce(Sum("final_amount"), Value(0), output_field=DecimalField(max_digits=14, decimal_places=2)),
            total_count=Coalesce(Count("id"), 0),
            total_discounts=Coalesce(Sum("discount"), Value(0), output_field=DecimalField(max_digits=14, decimal_places=2)),
        )

        refunded_invoices_count = Invoice.objects.filter(
            pharmacy=pharmacy,
            is_refunded=True,
            created_at__date__gte=start,
            created_at__date__lte=end,
        ).count()

        total_expenses = Expense.objects.filter(
            pharmacy=pharmacy, expense_date__gte=start, expense_date__lte=end
        ).aggregate(total=Coalesce(Sum("amount"), Value(0), output_field=DecimalField(max_digits=14, decimal_places=2)))["total"]

        # ديون المذاخر: رصيد قائم حالياً (غير مقيّد بالفترة)، نفس ما تفعله
        # الشاشة الحالية (استعلام remaining_debt بلا فلتر تاريخ).
        purchase_totals = PurchaseInvoice.objects.filter(pharmacy=pharmacy).aggregate(
            total_amount=Coalesce(Sum("total_amount"), Value(0), output_field=DecimalField(max_digits=14, decimal_places=2)),
            total_paid=Coalesce(Sum("paid_amount"), Value(0), output_field=DecimalField(max_digits=14, decimal_places=2)),
        )
        total_returned = PurchaseInvoiceReturn.objects.filter(
            purchase_invoice__pharmacy=pharmacy
        ).aggregate(total=Coalesce(Sum("amount_returned"), Value(0), output_field=DecimalField(max_digits=14, decimal_places=2)))["total"]
        total_supplier_debt = (
            purchase_totals["total_amount"] - total_returned - purchase_totals["total_paid"]
        )

        # خسائر الأدوية المنتهية: نفس معيار الشاشة الحالية بالضبط — منتهية
        # فعلياً (قبل اليوم الحالي)، لا مجرد الوصول لتاريخ الانتهاء نفسه.
        expired_losses = Medicine.objects.filter(
            pharmacy=pharmacy,
            is_damaged=False,
            quantity__gt=0,
            expiry_date__gte=start,
            expiry_date__lte=end,
            expiry_date__lt=today,
        ).aggregate(
            total=Coalesce(
                Sum(F("quantity") * F("buy_price")), Value(0), output_field=DecimalField(max_digits=14, decimal_places=2)
            )
        )["total"]

        # خسائر التوالف: سجلات 'correction' مستبعدة لأنها تصحيح إدخال، لا خسارة فعلية.
        damaged_losses = (
            DamagedMedicine.objects.filter(pharmacy=pharmacy, damaged_at__gte=start, damaged_at__lte=end)
            .exclude(reason="correction")
            .aggregate(
                total=Coalesce(
                    Sum(F("quantity_damaged") * F("medicine__buy_price")),
                    Value(0),
                    output_field=DecimalField(max_digits=14, decimal_places=2),
                )
            )["total"]
        )

        top_selling_items = list(
            InvoiceItem.objects.filter(
                invoice__pharmacy=pharmacy,
                invoice__is_refunded=False,
                invoice__created_at__date__gte=start,
                invoice__created_at__date__lte=end,
            )
            .values("medicine_id", "medicine__trade_name", "medicine__scientific_name")
            .annotate(total_qty=Sum("quantity"), total_revenue=Sum("total_price"))
            .order_by("-total_qty")[:5]
        )
        top_selling_items = [
            {
                "trade_name": item["medicine__trade_name"],
                "scientific_name": item["medicine__scientific_name"],
                "total_qty": item["total_qty"],
                "total_revenue": item["total_revenue"],
            }
            for item in top_selling_items
        ]

        sold_medicine_ids = InvoiceItem.objects.filter(
            invoice__pharmacy=pharmacy,
            invoice__is_refunded=False,
            invoice__created_at__date__gte=start,
            invoice__created_at__date__lte=end,
        ).values("medicine_id")

        stagnant_medicines = list(
            Medicine.objects.filter(pharmacy=pharmacy, is_damaged=False, quantity__gt=0)
            .exclude(id__in=sold_medicine_ids)
            .values("id", "trade_name", "scientific_name", "quantity", "category")[:10]
        )

        invoices = list(
            non_refunded_invoices.order_by("-created_at").values(
                "id", "invoice_number", "created_at", "total_amount", "discount", "final_amount"
            )
        )

        return Response(
            {
                "start": start.isoformat(),
                "end": end.isoformat(),
                "total_sales": sales_summary["total_cash_in_drawer"],
                "total_invoices_count": sales_summary["total_count"],
                "total_discounts_given": sales_summary["total_discounts"],
                "refunded_invoices_count": refunded_invoices_count,
                "total_expenses": total_expenses,
                "total_supplier_debt": total_supplier_debt,
                "total_damage_losses": expired_losses + damaged_losses,
                "top_selling_items": top_selling_items,
                "stagnant_medicines": stagnant_medicines,
                "invoices": invoices,
            }
        )

    @action(detail=False, methods=["get"])
    def shifts(self, request):
        """تقرير شفتات/حسابات البائعين — حكر على المالك (تُفرَض من Flutter كما هي الآن)."""
        membership = self._membership(request)
        pharmacy = membership.pharmacy
        start, end = self._date_range(request)

        base_qs = Invoice.objects.filter(
            pharmacy=pharmacy,
            is_refunded=False,
            created_at__date__gte=start,
            created_at__date__lte=end,
        ).select_related("cashier")

        sellers = {}
        for invoice in base_qs.order_by("-created_at"):
            cashier = invoice.cashier
            if cashier is not None:
                seller_name = cashier.get_full_name() or cashier.username
            else:
                # فاتورة مرحَّلة من أوفلاين (لا حساب حقيقي وراءها) أو كاشير محذوف.
                seller_name = invoice.cashier_name or "بائع غير محدد"

            bucket = sellers.setdefault(
                seller_name, {"seller_name": seller_name, "invoices_count": 0, "total_amount": Decimal("0"), "invoices": []}
            )
            bucket["invoices_count"] += 1
            bucket["total_amount"] += invoice.final_amount
            bucket["invoices"].append(
                {
                    "id": invoice.id,
                    "invoice_number": invoice.invoice_number,
                    "created_at": invoice.created_at,
                    "total_amount": invoice.total_amount,
                    "discount": invoice.discount,
                    "final_amount": invoice.final_amount,
                }
            )

        sellers_list = sorted(sellers.values(), key=lambda s: s["total_amount"], reverse=True)
        return Response({"start": start.isoformat(), "end": end.isoformat(), "sellers": sellers_list})


class NDJSONRenderer(BaseRenderer):
    media_type = "application/x-ndjson"
    format = "ndjson"
    charset = "utf-8"

    def render(self, data, accepted_media_type=None, renderer_context=None):
        return json.dumps(data).encode("utf-8")


class MigrationViewSet(viewsets.ViewSet):
    """
    نقطة 5 (المواصفات الكاملة): تحويل صيدلية أوفلاين إلى أونلاين عبر رفع
    أولي شامل من جهاز المالك فقط، ضمن معاملة ذرّية واحدة، مع تقدّم حي عبر
    استجابة متدفقة (NDJSON: سطر JSON واحد لكل حدث)، بلا حذف أي شيء محلياً
    من جهة العميل بعد النجاح (النسخة المحلية تبقى كاشاً كباقي الأجهزة).

    الترتيب صارم بسبب الاعتماديات: Suppliers → Medicines → PurchaseInvoices
    (مع Payments/Returns متداخلة داخل كل فاتورة) → Invoices (مع Items
    متداخلة) → DamagedMedicines → Expenses. القوائم المتداخلة (payments,
    returns, items) تُرسَل ضمن كل عنصر أب مباشرة، لا كقوائم منفصلة على
    المستوى الأعلى، فلا حاجة لجدول تحويل معرّفات لفواتير الشراء/البيع نفسها
    — فقط لـsupplier/medicine اللذين تُشير إليهما سجلات أخرى بمعرّفها.

    ⚠️ اعتبار تشغيلي مهم: الاستجابة المتدفقة تُبقي معاملة قاعدة البيانات
    مفتوحة طوال مدة الرفع كاملة (قد تمتد لدقائق مع بيانات ضخمة)، لأن كل
    yield يُعلّق تنفيذ المولّد دون إغلاق المعاملة. هذا مقصود ليحقق الشرطين
    معاً (معاملة واحدة + تقدّم حي)، لكنه يعني حجز اتصال قاعدة بيانات واحد
    لكل عملية ترحيل جارية — مقبول لعملية تُنفَّذ مرة واحدة لكل صيدلية، لكن
    يستحق الانتباه إن جرت عدة عمليات ترحيل متزامنة على خادم بموارد محدودة.
    """

    permission_classes = [permissions.IsAuthenticated]

    def _membership(self, request):
        membership = getattr(request.user, "pharmacymembership", None)
        if membership is None:
            raise PermissionDenied("هذا الحساب غير مرتبط بأي صيدلية.")
        return membership

    @action(detail=False, methods=["get"])
    def status(self, request):
        """يفحصه Flutter عند كل دخول أونلاين للمالك ليقرر عرض اقتراح الرفع أو إخفاءه."""
        pharmacy = self._membership(request).pharmacy
        has_existing_online_data = self._has_existing_online_data(pharmacy)
        return Response(
            {
                "migrated": pharmacy.migrated_from_offline_at is not None,
                "migrated_at": (
                    pharmacy.migrated_from_offline_at.isoformat()
                    if pharmacy.migrated_from_offline_at
                    else None
                ),
                # true تعني: لا يمكن بدء رفع أولي جديد حتى لو migrated=false،
                # لوجود بيانات أونلاين حقيقية مسبقاً (راجع _has_existing_online_data).
                "has_existing_online_data": has_existing_online_data,
            }
        )

    def _has_existing_online_data(self, pharmacy):
        return (
            Medicine.objects.filter(pharmacy=pharmacy).exists()
            or Supplier.objects.filter(pharmacy=pharmacy).exists()
            or Invoice.objects.filter(pharmacy=pharmacy).exists()
            or Expense.objects.filter(pharmacy=pharmacy).exists()
            or DamagedMedicine.objects.filter(pharmacy=pharmacy).exists()
        )

    @staticmethod
    def _parse_datetime(value):
        """يقبل ISO datetime أو date فقط؛ يرجع None لأي شيء غير مفهوم (يُطبَّق timezone.now() بدلاً منه لاحقاً)."""
        if not value or not isinstance(value, str):
            return None
        parsed = parse_datetime(value)
        if parsed is not None:
            return timezone.make_aware(parsed) if timezone.is_naive(parsed) else parsed
        d = parse_date(value)
        if d is not None:
            return timezone.make_aware(datetime.combine(d, datetime.min.time()))
        return None

    @staticmethod
    def _parse_date(value):
        if not value or not isinstance(value, str):
            return None
        d = parse_date(value)
        if d is not None:
            return d
        dt = parse_datetime(value)
        return dt.date() if dt is not None else None

    def _migration_stream(self, pharmacy, payload):
        def line(obj):
            return json.dumps(obj, default=str) + "\n"

        suppliers_in = payload.get("suppliers") or []
        medicines_in = payload.get("medicines") or []
        purchase_invoices_in = payload.get("purchase_invoices") or []
        invoices_in = payload.get("invoices") or []
        damaged_in = payload.get("damaged_medicines") or []
        expenses_in = payload.get("expenses") or []

        # كل عنصر من المستويات العليا الستة = وحدة تقدّم واحدة. العناصر
        # المتداخلة (payments/returns/items) لا تُحسَب في الإجمالي منفصلة —
        # تبسيط متعمَّد يبقي شريط التقدّم مفهوماً (فاتورة شراء واحدة = خطوة
        # واحدة، بصرف النظر عن عدد دفعاتها).
        overall_total = (
            len(suppliers_in) + len(medicines_in) + len(purchase_invoices_in)
            + len(invoices_in) + len(damaged_in) + len(expenses_in)
        )
        overall_done = 0
        yield line({"event": "start", "overall_total": overall_total})

        try:
            with transaction.atomic():
                supplier_id_map = {}
                for item in suppliers_in:
                    supplier = Supplier.objects.create(
                        pharmacy=pharmacy,
                        name=item.get("name") or "",
                        phone=item.get("phone") or "",
                    )
                    local_id = item.get("local_id")
                    if local_id is not None:
                        supplier_id_map[local_id] = supplier.id
                    overall_done += 1
                    yield line({"event": "progress", "stage": "suppliers", "overall_done": overall_done, "overall_total": overall_total})

                medicine_id_map = {}
                for item in medicines_in:
                    medicine = Medicine.objects.create(
                        pharmacy=pharmacy,
                        trade_name=item.get("trade_name") or "",
                        scientific_name=item.get("scientific_name") or "",
                        category=item.get("category") or "",
                        quantity=int(item.get("quantity") or 0),
                        buy_price=Decimal(str(item.get("buy_price") or 0)),
                        sell_price=Decimal(str(item.get("sell_price") or 0)),
                        expiry_date=item.get("expiry_date") or None,
                        shelf_location=item.get("shelf_location") or "",
                        is_damaged=bool(item.get("is_damaged") or False),
                        barcode=item.get("barcode") or None,
                    )
                    local_id = item.get("local_id")
                    if local_id is not None:
                        medicine_id_map[local_id] = medicine.id
                    overall_done += 1
                    yield line({"event": "progress", "stage": "medicines", "overall_done": overall_done, "overall_total": overall_total})

                purchase_invoices_created = 0
                payments_created = 0
                returns_created = 0
                for item in purchase_invoices_in:
                    local_supplier_id = item.get("local_supplier_id")
                    server_supplier_id = supplier_id_map.get(local_supplier_id)
                    if server_supplier_id is None:
                        raise ValidationError(
                            f"فاتورة شراء تشير لمورد غير موجود ضمن قائمة الموردين المرفوعة (local_supplier_id={local_supplier_id})."
                        )

                    purchase_invoice = PurchaseInvoice.objects.create(
                        pharmacy=pharmacy,
                        supplier_id=server_supplier_id,
                        invoice_number=item.get("invoice_number") or "",
                        total_amount=Decimal(str(item.get("total_amount") or 0)),
                        paid_amount=Decimal(str(item.get("paid_amount") or 0)),
                        created_at=self._parse_datetime(item.get("created_at")) or timezone.now(),
                    )

                    for p in item.get("payments") or []:
                        SupplierPayment.objects.create(
                            pharmacy=pharmacy,
                            supplier_id=server_supplier_id,
                            purchase_invoice=purchase_invoice,
                            amount_paid=Decimal(str(p.get("amount_paid") or 0)),
                            notes=p.get("notes") or "",
                            paid_at=self._parse_datetime(p.get("paid_at")) or timezone.now(),
                        )
                        payments_created += 1

                    for r in item.get("returns") or []:
                        PurchaseInvoiceReturn.objects.create(
                            pharmacy=pharmacy,
                            supplier_id=server_supplier_id,
                            purchase_invoice=purchase_invoice,
                            amount_returned=Decimal(str(r.get("amount_returned") or 0)),
                            notes=r.get("notes") or "",
                            returned_at=self._parse_datetime(r.get("returned_at")) or timezone.now(),
                        )
                        returns_created += 1

                    purchase_invoices_created += 1
                    overall_done += 1
                    yield line({"event": "progress", "stage": "purchase_invoices", "overall_done": overall_done, "overall_total": overall_total})

                invoices_created = 0
                invoice_items_created = 0
                for item in invoices_in:
                    invoice = Invoice.objects.create(
                        pharmacy=pharmacy,
                        invoice_number=item.get("invoice_number") or f"MIGRATED-{overall_done + 1}",
                        cashier=None,
                        cashier_name=item.get("cashier_name") or "",
                        total_amount=Decimal(str(item.get("total_amount") or 0)),
                        discount=Decimal(str(item.get("discount") or 0)),
                        final_amount=Decimal(str(item.get("final_amount") or 0)),
                        created_at=self._parse_datetime(item.get("created_at")) or timezone.now(),
                        is_refunded=bool(item.get("is_refunded") or False),
                    )
                    for it in item.get("items") or []:
                        local_medicine_id = it.get("local_medicine_id")
                        server_medicine_id = medicine_id_map.get(local_medicine_id)
                        if server_medicine_id is None:
                            raise ValidationError(
                                f"عنصر فاتورة يشير لدواء غير موجود ضمن قائمة الأدوية المرفوعة (local_medicine_id={local_medicine_id})."
                            )
                        InvoiceItem.objects.create(
                            invoice=invoice,
                            medicine_id=server_medicine_id,
                            trade_name=it.get("trade_name") or "",
                            quantity=int(it.get("quantity") or 0),
                            unit_price=Decimal(str(it.get("unit_price") or 0)),
                            total_price=Decimal(str(it.get("total_price") or 0)),
                        )
                        invoice_items_created += 1

                    invoices_created += 1
                    overall_done += 1
                    yield line({"event": "progress", "stage": "invoices", "overall_done": overall_done, "overall_total": overall_total})

                damaged_created = 0
                for item in damaged_in:
                    local_medicine_id = item.get("local_medicine_id")
                    server_medicine_id = medicine_id_map.get(local_medicine_id)
                    if server_medicine_id is None:
                        # سجل تالف يتيم (دواؤه غير موجود ضمن المرفوع) — يُتجاهَل
                        # بدل إفشال كامل عملية الرفع من أجل سجل واحد شاذ.
                        overall_done += 1
                        yield line({"event": "progress", "stage": "damaged_medicines", "overall_done": overall_done, "overall_total": overall_total})
                        continue
                    DamagedMedicine.objects.create(
                        pharmacy=pharmacy,
                        medicine_id=server_medicine_id,
                        quantity_damaged=int(item.get("quantity_damaged") or 0),
                        reason=item.get("reason") or "",
                        notes=item.get("notes") or "",
                        damaged_at=self._parse_date(item.get("damaged_at")) or date.today(),
                    )
                    damaged_created += 1
                    overall_done += 1
                    yield line({"event": "progress", "stage": "damaged_medicines", "overall_done": overall_done, "overall_total": overall_total})

                expenses_created = 0
                for item in expenses_in:
                    Expense.objects.create(
                        pharmacy=pharmacy,
                        expense_type=item.get("expense_type") or "",
                        expense_date=self._parse_date(item.get("expense_date")) or date.today(),
                        amount=Decimal(str(item.get("amount") or 0)),
                        notes=item.get("notes") or "",
                    )
                    expenses_created += 1
                    overall_done += 1
                    yield line({"event": "progress", "stage": "expenses", "overall_done": overall_done, "overall_total": overall_total})

                pharmacy.migrated_from_offline_at = timezone.now()
                pharmacy.save(update_fields=["migrated_from_offline_at"])

                summary = {
                    "suppliers_created": len(supplier_id_map),
                    "medicines_created": len(medicine_id_map),
                    "purchase_invoices_created": purchase_invoices_created,
                    "supplier_payments_created": payments_created,
                    "purchase_invoice_returns_created": returns_created,
                    "invoices_created": invoices_created,
                    "invoice_items_created": invoice_items_created,
                    "damaged_records_created": damaged_created,
                    "expenses_created": expenses_created,
                    "migrated_at": pharmacy.migrated_from_offline_at.isoformat(),
                }
        except Exception as exc:
            message = str(getattr(exc, "detail", exc))
            yield line({"event": "error", "message": message})
            return

        yield line({"event": "done", "ok": True, "summary": summary})

    @action(detail=False, methods=["post"], renderer_classes=[NDJSONRenderer])
    def upload_offline_data(self, request):
        membership = self._membership(request)
        if not membership.is_owner:
            raise PermissionDenied("الرفع الأولي متاح لمالك الصيدلية فقط.")

        pharmacy = membership.pharmacy
        if pharmacy.migrated_from_offline_at is not None:
            raise ValidationError("تم رفع بيانات هذه الصيدلية مسبقاً، لا يمكن تكرار العملية.")

        # فحص الأمان المطلوب: رفض الترحيل إن وُجدت بيانات أونلاين حقيقية
        # مسبقاً لهذه الصيدلية، حتى لو migrated_from_offline_at غير مضبوط
        # لسبب ما — تفادياً لدمج بيانات محلية قديمة فوق بيانات أونلاين حية.
        if self._has_existing_online_data(pharmacy):
            raise ValidationError("توجد بيانات أونلاين مسجّلة مسبقاً لهذه الصيدلية، لا يمكن تنفيذ رفع أولي فوقها.")

        payload = request.data if isinstance(request.data, dict) else {}
        for key in ("suppliers", "medicines", "purchase_invoices", "invoices", "damaged_medicines", "expenses"):
            if key in payload and not isinstance(payload[key], list):
                raise ValidationError(f"صيغة {key} يجب أن تكون قائمة.")

        response = StreamingHttpResponse(
            self._migration_stream(pharmacy, payload),
            content_type="application/x-ndjson",
        )
        response["Cache-Control"] = "no-cache"
        # يمنع أي عكس وسيط (مثل nginx) من تجميع كامل الرد قبل بثه دفعة
        # واحدة، فيصل التقدّم حياً فعلاً بدل الظهور كله في اللحظة الأخيرة.
        response["X-Accel-Buffering"] = "no"
        return response