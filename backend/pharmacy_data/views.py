import json
from datetime import date, timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import Count, DecimalField, F, OuterRef, Q, Subquery, Sum, Value
from django.db.models.functions import Coalesce, Length
from django.http import StreamingHttpResponse
from django.utils import timezone
from rest_framework import mixins, permissions, status, viewsets
from rest_framework.renderers import BaseRenderer
from rest_framework.decorators import action
from rest_framework.exceptions import NotFound, PermissionDenied, ValidationError
from rest_framework.response import Response

from desktop_api.models import Pharmacy
from desktop_api.permissions import (
    FEATURE_MULTI_WAREHOUSE,
    IsActiveOnlineMember,
    IsActiveOnlineOwner,
    max_warehouses_for,
    plan_allows,
    resolve_context,
)
from .models import (
    DamagedMedicine,
    Expense,
    Invoice,
    InvoiceItem,
    Medicine,
    PurchaseInvoice,
    PurchaseInvoiceReturn,
    StockTransfer,
    Supplier,
    SupplierPayment,
    Warehouse,
)
from .offline_import import (
    error_message,
    has_existing_online_data,
    iter_offline_import,
    validate_offline_import,
)
from .serializers import (
    CheckoutInputSerializer,
    DamagedMedicineSerializer,
    ExpenseSerializer,
    InvoiceSerializer,
    MedicineSerializer,
    PurchaseInvoiceSerializer,
    StockTransferInputSerializer,
    StockTransferSerializer,
    SupplierSerializer,
    SupplierSummarySerializer,
    WarehouseSerializer,
)


class MedicineViewSet(viewsets.ModelViewSet):
    """
    CRUD كامل لجدول المخزون، مقيَّد دائماً بصيدلية المستخدم المسجّل دخوله فقط
    عبر PharmacyMembership — لا يمكن لأي مستخدم رؤية أو تعديل مخزون صيدلية أخرى.
    """

    serializer_class = MedicineSerializer
    # القراءة لكل أعضاء الصيدلية (الموظف يحتاجها للبيع)، والكتابة للمالك فقط
    # — مطابق لما تعرضه شاشة المخزون في Flutter (أزرار الإضافة/التعديل/الحذف للمالك).
    def get_permissions(self):
        if self.action in ("list", "retrieve"):
            return [IsActiveOnlineMember()]
        return [IsActiveOnlineOwner()]

    def get_queryset(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            return Medicine.objects.none()
        qs = Medicine.objects.filter(pharmacy=membership.pharmacy)
        warehouse_id = self.request.query_params.get("warehouse")
        if warehouse_id:
            if not str(warehouse_id).isdigit():
                raise ValidationError("معرّف المخزن غير صحيح.")
            qs = qs.filter(warehouse_id=warehouse_id)
        return qs.order_by("trade_name")

    def perform_create(self, serializer):
        membership = self.request.user.pharmacymembership
        warehouse = serializer.validated_data.get("warehouse") or Warehouse.main_for(membership.pharmacy)
        serializer.save(pharmacy=membership.pharmacy, warehouse=warehouse)


def _is_referenced(medicine):
    """صف دواء له سجل مبيعات أو إتلاف (PROTECT) لا يُحذف — يُصفَّر بدلاً من ذلك."""
    return medicine.invoice_items.exists() or medicine.damaged_records.exists()


class WarehouseViewSet(viewsets.ModelViewSet):
    """
    مخازن الصيدلية (خاصية Gold/Diamond: AppFeature.multiWarehouse).

    - list/retrieve: لكل الأعضاء؛ يضمن وجود المخزن الرئيسي دائماً.
    - create: للمالك فقط، بشرط سماح الباقة وعدم تجاوز max_warehouses_for.
    - update: إعادة تسمية فقط.
    - destroy: مخزن إضافي فارغ فقط (لا يُحذف الرئيسي أبداً).
    - transfer: نقل كمية صنف بين مخزنين لنفس الصيدلية ذرّياً + سجل.
    - transfers: سجل عمليات النقل.
    """

    serializer_class = WarehouseSerializer
    http_method_names = ["get", "post", "patch", "delete", "head", "options"]

    def get_permissions(self):
        if self.action in ("list", "retrieve"):
            return [IsActiveOnlineMember()]
        return [IsActiveOnlineOwner()]

    def get_queryset(self):
        membership = getattr(self.request.user, "pharmacymembership", None)
        if membership is None:
            return Warehouse.objects.none()
        return Warehouse.objects.filter(pharmacy=membership.pharmacy).order_by("-is_main", "id")

    def list(self, request, *args, **kwargs):
        membership, _ = resolve_context(request)
        Warehouse.main_for(membership.pharmacy)
        # قائمة صغيرة (حد أقصى بضعة مخازن) — بلا ترقيم صفحات.
        return Response(self.get_serializer(self.get_queryset(), many=True).data)

    def create(self, request, *args, **kwargs):
        membership, license = resolve_context(request)
        if not plan_allows(license, FEATURE_MULTI_WAREHOUSE):
            raise PermissionDenied("باقتك الحالية لا تسمح بإضافة مخازن. قم بالترقية إلى الباقة الذهبية.")

        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        with transaction.atomic():
            # قفل صف الصيدلية يمنع طلبين متزامنين من تجاوز الحد معاً.
            pharmacy = Pharmacy.objects.select_for_update().get(pk=membership.pharmacy_id)
            Warehouse.main_for(pharmacy)
            limit = max_warehouses_for(license)
            if Warehouse.objects.filter(pharmacy=pharmacy).count() >= limit:
                raise ValidationError(f"وصلت للحد الأقصى لعدد المخازن في باقتك ({limit}).")
            serializer.save(pharmacy=pharmacy, is_main=False)

        return Response(serializer.data, status=status.HTTP_201_CREATED)

    def destroy(self, request, *args, **kwargs):
        warehouse = self.get_object()
        if warehouse.is_main:
            raise ValidationError("لا يمكن حذف المخزن الرئيسي.")

        with transaction.atomic():
            medicines = list(Medicine.objects.select_for_update().filter(warehouse=warehouse))
            if any(m.quantity > 0 for m in medicines):
                raise ValidationError("لا يمكن حذف مخزن يحتوي على كمية مخزون. انقل الأصناف أولاً.")
            # أصناف بكمية صفر: تُحذف إن لم يكن لها سجل، وإلا يبقى المخزن.
            for medicine in medicines:
                if _is_referenced(medicine):
                    raise ValidationError(
                        f"لا يمكن حذف المخزن: الصنف {medicine.trade_name} فيه له سجل مبيعات أو إتلاف."
                    )
                medicine.delete()
            # سجل النقل يبقى (أسماء المخازن محفوظة نصاً فيه، والمرجع SET_NULL).
            warehouse.delete()

        return Response(status=status.HTTP_204_NO_CONTENT)

    @action(detail=False, methods=["post"])
    def transfer(self, request):
        """
        POST /api/warehouses/transfer/
        body: {"medicine_id": 1, "to_warehouse_id": 2, "quantity": 5, "notes": ""}

        نفس منطق DatabaseHelper.transferStock المحلي تماماً: إن وُجد في المخزن
        الهدف صنف بنفس الباركود (أو بنفس الاسم إن كان بلا باركود) تُزاد كميته،
        وإلا يُنشأ صف جديد. صف المصدر يُحذف إن صار صفراً، إلا إن كان له سجل
        مبيعات/إتلاف فيبقى بكمية صفر. إن لم تسمح الباقة بتعدد المخازن (مثلاً
        بعد تخفيضها) يُسمح فقط بالنقل *إلى* المخزن الرئيسي لتفريغ المخازن الأخرى.
        """
        membership, license = resolve_context(request)
        data = StockTransferInputSerializer(data=request.data)
        data.is_valid(raise_exception=True)
        data = data.validated_data
        quantity = data["quantity"]

        with transaction.atomic():
            pharmacy = Pharmacy.objects.select_for_update().get(pk=membership.pharmacy_id)
            try:
                source = Medicine.objects.select_for_update().get(pk=data["medicine_id"], pharmacy=pharmacy)
            except Medicine.DoesNotExist:
                raise ValidationError("الصنف غير موجود في هذه الصيدلية.")
            try:
                destination = Warehouse.objects.get(pk=data["to_warehouse_id"], pharmacy=pharmacy)
            except Warehouse.DoesNotExist:
                raise ValidationError("المخزن الهدف غير موجود في هذه الصيدلية.")

            if destination.pk == source.warehouse_id:
                raise ValidationError("المخزن المصدر والهدف متطابقان.")
            if not destination.is_main and not plan_allows(license, FEATURE_MULTI_WAREHOUSE):
                raise PermissionDenied("باقتك الحالية تسمح فقط بالنقل إلى المخزن الرئيسي.")
            if quantity > source.quantity:
                raise ValidationError("الكمية المطلوب نقلها أكبر من الكمية المتوفرة.")

            barcode = (source.barcode or "").strip() or None
            if barcode:
                target = Medicine.objects.select_for_update().filter(warehouse=destination, barcode=barcode).first()
            else:
                target = (
                    Medicine.objects.select_for_update()
                    .filter(warehouse=destination, trade_name=source.trade_name)
                    .filter(Q(barcode__isnull=True) | Q(barcode=""))
                    .first()
                )

            if target is not None:
                Medicine.objects.filter(pk=target.pk).update(quantity=F("quantity") + quantity)
            else:
                target = Medicine.objects.create(
                    pharmacy=pharmacy,
                    warehouse=destination,
                    trade_name=source.trade_name,
                    scientific_name=source.scientific_name,
                    category=source.category,
                    quantity=quantity,
                    buy_price=source.buy_price,
                    sell_price=source.sell_price,
                    expiry_date=source.expiry_date,
                    shelf_location=source.shelf_location,
                    is_damaged=False,
                    barcode=barcode,
                )

            source_warehouse = source.warehouse
            remaining = source.quantity - quantity
            source_deleted = False
            if remaining > 0 or _is_referenced(source):
                Medicine.objects.filter(pk=source.pk).update(quantity=remaining)
            else:
                source.delete()
                source_deleted = True

            record = StockTransfer.objects.create(
                pharmacy=pharmacy,
                from_warehouse=source_warehouse,
                to_warehouse=destination,
                from_warehouse_name=source_warehouse.name,
                to_warehouse_name=destination.name,
                trade_name=source.trade_name,
                barcode=barcode,
                quantity=quantity,
                notes=data.get("notes") or "",
                transferred_by=request.user,
            )

        target.refresh_from_db()
        context = self.get_serializer_context()
        return Response(
            {
                "transfer": StockTransferSerializer(record, context=context).data,
                "source": None if source_deleted else MedicineSerializer(
                    Medicine.objects.get(pk=data["medicine_id"]), context=context
                ).data,
                "source_deleted": source_deleted,
                "source_id": data["medicine_id"],
                "destination": MedicineSerializer(target, context=context).data,
            },
            status=status.HTTP_201_CREATED,
        )

    @action(detail=False, methods=["get"])
    def transfers(self, request):
        membership, _ = resolve_context(request)
        qs = StockTransfer.objects.filter(pharmacy=membership.pharmacy).select_related("from_warehouse", "to_warehouse")
        page = self.paginate_queryset(qs)
        if page is not None:
            return self.get_paginated_response(StockTransferSerializer(page, many=True).data)
        return Response(StockTransferSerializer(qs, many=True).data)


def _next_invoice_number(pharmacy):
    """
    يولَّد داخل معاملة تُقفل فيها الصيدلية أصلاً (انظر InvoiceViewSet.checkout)،
    فلا حاجة لقفل إضافي هنا. الصيغة: "INV-" ثم رقم بمحاذاة 6 أصفار، لكل صيدلية.

    كان الرقم يُحسب بـ count()+1، فيتكرر رقم موجود (وينهار البيع بخطأ 500 بسبب
    قيد unique_invoice_number_per_pharmacy) في حالتين: بعد حذف أي فاتورة من
    لوحة الأدمن، أو بعد ترحيل فواتير أوفلاين بترقيمها المحلي الذي فيه فجوات.
    الآن: أكبر رقم INV-<n> موجود + 1، مع التأكد أنه غير مستخدم.
    """

    last = (
        Invoice.objects.filter(pharmacy=pharmacy, invoice_number__regex=r"^INV-[0-9]+$")
        .annotate(number_length=Length("invoice_number"))
        .order_by("-number_length", "-invoice_number")
        .values_list("invoice_number", flat=True)
        .first()
    )
    candidate = int(last[len("INV-"):]) + 1 if last else 1
    while Invoice.objects.filter(pharmacy=pharmacy, invoice_number=f"INV-{candidate:06d}").exists():
        candidate += 1
    return f"INV-{candidate:06d}"


class InvoiceViewSet(viewsets.ReadOnlyModelViewSet):
    """
    قراءة فقط لسجل المبيعات وتفاصيله (list/retrieve). لا يوجد create/update/
    delete عادي هنا: الإنشاء عبر checkout والإرجاع عبر refund فقط أدناه،
    لأن كليهما عملية مركّبة (فاتورة + أصناف + تعديل مخزون) تحتاج تحققاً
    ذرّياً، وليست إنشاء/تعديل صف واحد بسيط كما في Medicine.
    """

    serializer_class = InvoiceSerializer
    # القراءة والبيع (checkout) للمالك والموظف، أما الإرجاع (refund) فللمالك فقط.
    def get_permissions(self):
        if self.action == "refund":
            return [IsActiveOnlineOwner()]
        return [IsActiveOnlineMember()]

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

        # دمج الأسطر المكررة لنفس الدواء قبل فحص الكمية. بدون هذا كان الفحص
        # يقارن كل سطر بالمخزون الأصلي منفصلاً (4+4 من مخزون 5 يمر كلاهما)، ثم
        # يفشل الخصم بقيد قاعدة البيانات فيرجع خطأ 500 بدل رسالة واضحة.
        merged_quantities = {}
        for line in data["items"]:
            merged_quantities[line["medicine_id"]] = (
                merged_quantities.get(line["medicine_id"], 0) + line["quantity"]
            )
        checkout_items = [
            {"medicine_id": medicine_id, "quantity": quantity}
            for medicine_id, quantity in merged_quantities.items()
        ]

        with transaction.atomic():
            pharmacy = (
                type(membership.pharmacy)
                .objects.select_for_update()
                .get(pk=membership.pharmacy_id)
            )

            requested_ids = [item["medicine_id"] for item in checkout_items]
            medicines = {
                medicine.id: medicine
                for medicine in Medicine.objects.select_for_update().filter(
                    pharmacy=pharmacy, id__in=requested_ids
                )
            }

            total_amount = Decimal("0")
            prepared_items = []
            # البيع من المخزن الرئيسي حصراً (نفس قاعدة شاشة POS في Flutter)؛
            # المخازن الإضافية للتخزين فقط ويُنقل منها للرئيسي قبل البيع.
            main_warehouse = Warehouse.main_for(pharmacy)

            for item in checkout_items:
                medicine = medicines.get(item["medicine_id"])
                if medicine is None:
                    raise ValidationError(
                        f"الدواء رقم {item['medicine_id']} غير موجود في هذه الصيدلية."
                    )
                if medicine.warehouse_id != main_warehouse.pk:
                    raise ValidationError(
                        f"{medicine.trade_name} ليس في المخزن الرئيسي. انقله إلى المخزن الرئيسي قبل البيع."
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
    permission_classes = [IsActiveOnlineOwner]

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
    permission_classes = [IsActiveOnlineOwner]

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
    permission_classes = [IsActiveOnlineOwner]

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
    permission_classes = [IsActiveOnlineOwner]

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

    permission_classes = [IsActiveOnlineOwner]

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

    permission_classes = [IsActiveOnlineOwner]

    def _membership(self, request):
        membership = getattr(request.user, "pharmacymembership", None)
        if membership is None:
            raise PermissionDenied("هذا الحساب غير مرتبط بأي صيدلية.")
        return membership

    @action(detail=False, methods=["get"])
    def status(self, request):
        """يفحصه Flutter عند كل دخول أونلاين للمالك ليقرر عرض اقتراح الرفع أو إخفاءه."""
        pharmacy = self._membership(request).pharmacy
        existing_online_data = has_existing_online_data(pharmacy)
        return Response(
            {
                "migrated": pharmacy.migrated_from_offline_at is not None,
                "migrated_at": (
                    pharmacy.migrated_from_offline_at.isoformat()
                    if pharmacy.migrated_from_offline_at
                    else None
                ),
                # true تعني: لا يمكن بدء رفع أولي جديد حتى لو migrated=false،
                # لوجود بيانات أونلاين حقيقية مسبقاً (راجع offline_import.has_existing_online_data).
                "has_existing_online_data": existing_online_data,
            }
        )

    def _migration_stream(self, pharmacy, payload):
        """يحوّل أحداث iter_offline_import إلى أسطر NDJSON، والخطأ إلى حدث error."""
        def line(obj):
            return json.dumps(obj, default=str) + "\n"

        try:
            for event in iter_offline_import(pharmacy, payload):
                yield line(event)
        except Exception as exc:
            # المعاملة أُلغيت كاملة داخل iter_offline_import قبل وصول الاستثناء.
            yield line({"event": "error", "message": error_message(exc)})

    @action(detail=False, methods=["post"], renderer_classes=[NDJSONRenderer])
    def upload_offline_data(self, request):
        membership = self._membership(request)
        if not membership.is_owner:
            raise PermissionDenied("الرفع الأولي متاح لمالك الصيدلية فقط.")

        _, license = resolve_context(request)
        pharmacy = membership.pharmacy
        payload = request.data if isinstance(request.data, dict) else {}
        # نفس شروط أمر migrate_offline_data: الباقة، عدم التكرار، لا بيانات
        # أونلاين قائمة، وصيغة القوائم.
        validate_offline_import(pharmacy, license, payload)

        response = StreamingHttpResponse(
            self._migration_stream(pharmacy, payload),
            content_type="application/x-ndjson",
        )
        response["Cache-Control"] = "no-cache"
        # يمنع أي عكس وسيط (مثل nginx) من تجميع كامل الرد قبل بثه دفعة
        # واحدة، فيصل التقدّم حياً فعلاً بدل الظهور كله في اللحظة الأخيرة.
        response["X-Accel-Buffering"] = "no"
        return response