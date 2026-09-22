from decimal import Decimal

from django.db import transaction
from django.db.models import F
from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import NotFound, PermissionDenied, ValidationError
from rest_framework.response import Response

from .models import Invoice, InvoiceItem, Medicine
from .serializers import CheckoutInputSerializer, InvoiceSerializer, MedicineSerializer


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