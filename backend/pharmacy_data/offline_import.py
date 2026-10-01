"""
الرفع الأولي لبيانات صيدلية أوفلاين إلى الخادم (التحويل أوفلاين → أونلاين).

منطق مشترك واحد يستخدمه مساران فقط، بلا تكرار:
  - MigrationViewSet.upload_offline_data (من تطبيق المالك، استجابة NDJSON متدفقة)
  - أمر الإدارة migrate_offline_data (من ملف JSON على الخادم)

الحمولة بنفس شكل DatabaseHelper.getOfflineMigrationPayload في Flutter.

الترتيب صارم بسبب الاعتماديات: Warehouses → Suppliers → Medicines →
PurchaseInvoices (مع Payments/Returns متداخلة) → Invoices (مع Items متداخلة)
→ DamagedMedicines → Expenses → StockTransfers. القوائم المتداخلة تُرسَل ضمن
عنصرها الأب، فلا حاجة لجدول تحويل معرّفات إلا للمخازن/الموردين/الأدوية.
"""

from datetime import date, datetime
from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_date, parse_datetime
from rest_framework.exceptions import PermissionDenied, ValidationError

from desktop_api.permissions import ONLINE_PLAN_REQUIRED_MESSAGE, plan_allows_online

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

PAYLOAD_LIST_KEYS = (
    "warehouses", "suppliers", "medicines", "purchase_invoices",
    "invoices", "damaged_medicines", "expenses", "stock_transfers",
)


def has_existing_online_data(pharmacy):
    """
    بيانات أونلاين حقيقية مسجّلة مسبقاً لهذه الصيدلية. المخازن لا تُحتسب (المخزن
    الرئيسي يُنشأ تلقائياً عند أول طلب).
    """
    return (
        Medicine.objects.filter(pharmacy=pharmacy).exists()
        or Supplier.objects.filter(pharmacy=pharmacy).exists()
        or Invoice.objects.filter(pharmacy=pharmacy).exists()
        or Expense.objects.filter(pharmacy=pharmacy).exists()
        or DamagedMedicine.objects.filter(pharmacy=pharmacy).exists()
    )


def validate_offline_import(pharmacy, license, payload):
    """
    كل شروط قبول الرفع الأولي، مشتركة بين الـendpoint والأمر. ترفع
    PermissionDenied/ValidationError برسالة عربية جاهزة للعرض.
    """
    if license is None or not plan_allows_online(license):
        raise PermissionDenied(ONLINE_PLAN_REQUIRED_MESSAGE)
    if pharmacy.migrated_from_offline_at is not None:
        raise ValidationError("تم رفع بيانات هذه الصيدلية مسبقاً، لا يمكن تكرار العملية.")
    # رفض الترحيل إن وُجدت بيانات أونلاين حقيقية مسبقاً، حتى لو
    # migrated_from_offline_at غير مضبوط لسبب ما — تفادياً لدمج بيانات محلية
    # قديمة فوق بيانات أونلاين حية.
    if has_existing_online_data(pharmacy):
        raise ValidationError("توجد بيانات أونلاين مسجّلة مسبقاً لهذه الصيدلية، لا يمكن تنفيذ رفع أولي فوقها.")
    if not isinstance(payload, dict):
        raise ValidationError("صيغة البيانات المرفوعة غير صحيحة.")
    for key in PAYLOAD_LIST_KEYS:
        if key in payload and not isinstance(payload[key], list):
            raise ValidationError(f"صيغة {key} يجب أن تكون قائمة.")


def error_message(exc):
    """نص قابل للعرض من أي استثناء (أخطاء DRF تحمل detail كقائمة أو قاموس)."""
    detail = getattr(exc, "detail", None)
    if detail is None:
        return str(exc)
    if isinstance(detail, (list, tuple)):
        return " ".join(str(item) for item in detail)
    if isinstance(detail, dict):
        return " ".join(str(v) for values in detail.values() for v in (values if isinstance(values, list) else [values]))
    return str(detail)


def _parse_datetime(value):
    """يقبل ISO datetime أو date فقط؛ يرجع None لأي شيء غير مفهوم (يُطبَّق timezone.now() بدلاً منه)."""
    if not value or not isinstance(value, str):
        return None
    parsed = parse_datetime(value)
    if parsed is not None:
        return timezone.make_aware(parsed) if timezone.is_naive(parsed) else parsed
    d = parse_date(value)
    if d is not None:
        return timezone.make_aware(datetime.combine(d, datetime.min.time()))
    return None


def _parse_date(value):
    if not value or not isinstance(value, str):
        return None
    d = parse_date(value)
    if d is not None:
        return d
    dt = parse_datetime(value)
    return dt.date() if dt is not None else None


def iter_offline_import(pharmacy, payload):
    """
    ينفّذ الاستيراد كاملاً داخل معاملة ذرّية واحدة، ويُنتج أحداث تقدّم:
      {"event": "start", "overall_total": N}
      {"event": "progress", "stage": ..., "overall_done": n, "overall_total": N}
      {"event": "done", "ok": True, "summary": {...}}
    أي خطأ يُرفع كاستثناء بعد التراجع عن المعاملة كاملة (لا يُحفظ شيء). يجب
    استدعاء validate_offline_import قبله.

    ⚠️ المولّد يُبقي المعاملة مفتوحة بين كل حدث وآخر (حتى يتم استهلاكه كاملاً)؛
    مقصود لتحقيق معاملة واحدة + تقدّم حي في الاستجابة المتدفقة.
    """
    warehouses_in = payload.get("warehouses") or []
    suppliers_in = payload.get("suppliers") or []
    medicines_in = payload.get("medicines") or []
    purchase_invoices_in = payload.get("purchase_invoices") or []
    invoices_in = payload.get("invoices") or []
    damaged_in = payload.get("damaged_medicines") or []
    expenses_in = payload.get("expenses") or []
    transfers_in = payload.get("stock_transfers") or []

    # كل عنصر من المستويات العليا = وحدة تقدّم واحدة. العناصر
    # المتداخلة (payments/returns/items) لا تُحسَب في الإجمالي منفصلة —
    # تبسيط متعمَّد يبقي شريط التقدّم مفهوماً (فاتورة شراء واحدة = خطوة
    # واحدة، بصرف النظر عن عدد دفعاتها).
    overall_total = (
        len(warehouses_in) + len(suppliers_in) + len(medicines_in) + len(purchase_invoices_in)
        + len(invoices_in) + len(damaged_in) + len(expenses_in) + len(transfers_in)
    )
    overall_done = 0
    yield ({"event": "start", "overall_total": overall_total})

    with transaction.atomic():
        # المخازن أولاً لأن الأدوية تشير إليها. المخزن الرئيسي المحلي
        # يُطابَق مع الرئيسي على الخادم (يُنشأ إن لم يوجد) بدل إنشاء
        # رئيسي ثانٍ، والباقي تُنشأ كمخازن إضافية. لا يُفرض هنا حد
        # الباقة: البيانات أُنشئت أوفلاين ضمن نفس الحد أصلاً.
        main_warehouse = Warehouse.main_for(pharmacy)
        # مخزن إضافي أنشأه المالك أونلاين قبل الرفع بنفس الاسم يُعاد
        # استخدامه بدل إنشاء نسخة مكررة.
        existing_by_name = {
            w.name.strip().lower(): w
            for w in Warehouse.objects.filter(pharmacy=pharmacy, is_main=False)
        }
        warehouse_id_map = {}
        warehouse_names = {main_warehouse.pk: main_warehouse.name}
        for item in warehouses_in:
            local_id = item.get("local_id")
            if item.get("is_main"):
                warehouse = main_warehouse
            else:
                name = (item.get("name") or "").strip() or "مخزن إضافي"
                warehouse = existing_by_name.get(name.lower())
                if warehouse is None:
                    warehouse = Warehouse.objects.create(pharmacy=pharmacy, name=name, is_main=False)
                    existing_by_name[name.lower()] = warehouse
                warehouse_names[warehouse.pk] = warehouse.name
            if local_id is not None:
                warehouse_id_map[local_id] = warehouse.pk
            overall_done += 1
            yield ({"event": "progress", "stage": "warehouses", "overall_done": overall_done, "overall_total": overall_total})

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
            yield ({"event": "progress", "stage": "suppliers", "overall_done": overall_done, "overall_total": overall_total})

        medicine_id_map = {}
        seen_barcodes = set()
        for item in medicines_in:
            # عملاء أقدم لا يرسلون local_warehouse_id: كل أدويتهم للرئيسي.
            warehouse_id = warehouse_id_map.get(item.get("local_warehouse_id"), main_warehouse.pk)
            # الباركود فريد داخل المخزن؛ تكراره في بيانات الأوفلاين القديمة
            # كان يُسقط عملية الترحيل كلها. نحتفظ بأول ظهور ونُفرغ المكرر.
            barcode = str(item.get("barcode") or "").strip() or None
            if (warehouse_id, barcode) in seen_barcodes:
                barcode = None
            elif barcode:
                seen_barcodes.add((warehouse_id, barcode))
            medicine = Medicine.objects.create(
                pharmacy=pharmacy,
                warehouse_id=warehouse_id,
                trade_name=item.get("trade_name") or "",
                scientific_name=item.get("scientific_name") or "",
                category=item.get("category") or "",
                quantity=int(item.get("quantity") or 0),
                buy_price=Decimal(str(item.get("buy_price") or 0)),
                sell_price=Decimal(str(item.get("sell_price") or 0)),
                expiry_date=item.get("expiry_date") or None,
                shelf_location=item.get("shelf_location") or "",
                is_damaged=bool(item.get("is_damaged") or False),
                barcode=barcode,
            )
            local_id = item.get("local_id")
            if local_id is not None:
                medicine_id_map[local_id] = medicine.id
            overall_done += 1
            yield ({"event": "progress", "stage": "medicines", "overall_done": overall_done, "overall_total": overall_total})

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
                created_at=_parse_datetime(item.get("created_at")) or timezone.now(),
            )

            for p in item.get("payments") or []:
                SupplierPayment.objects.create(
                    pharmacy=pharmacy,
                    supplier_id=server_supplier_id,
                    purchase_invoice=purchase_invoice,
                    amount_paid=Decimal(str(p.get("amount_paid") or 0)),
                    notes=p.get("notes") or "",
                    paid_at=_parse_datetime(p.get("paid_at")) or timezone.now(),
                )
                payments_created += 1

            for r in item.get("returns") or []:
                PurchaseInvoiceReturn.objects.create(
                    pharmacy=pharmacy,
                    supplier_id=server_supplier_id,
                    purchase_invoice=purchase_invoice,
                    amount_returned=Decimal(str(r.get("amount_returned") or 0)),
                    notes=r.get("notes") or "",
                    returned_at=_parse_datetime(r.get("returned_at")) or timezone.now(),
                )
                returns_created += 1

            purchase_invoices_created += 1
            overall_done += 1
            yield ({"event": "progress", "stage": "purchase_invoices", "overall_done": overall_done, "overall_total": overall_total})

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
                created_at=_parse_datetime(item.get("created_at")) or timezone.now(),
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
            yield ({"event": "progress", "stage": "invoices", "overall_done": overall_done, "overall_total": overall_total})

        damaged_created = 0
        for item in damaged_in:
            local_medicine_id = item.get("local_medicine_id")
            server_medicine_id = medicine_id_map.get(local_medicine_id)
            if server_medicine_id is None:
                # سجل تالف يتيم (دواؤه غير موجود ضمن المرفوع) — يُتجاهَل
                # بدل إفشال كامل عملية الرفع من أجل سجل واحد شاذ.
                overall_done += 1
                yield ({"event": "progress", "stage": "damaged_medicines", "overall_done": overall_done, "overall_total": overall_total})
                continue
            DamagedMedicine.objects.create(
                pharmacy=pharmacy,
                medicine_id=server_medicine_id,
                quantity_damaged=int(item.get("quantity_damaged") or 0),
                reason=item.get("reason") or "",
                notes=item.get("notes") or "",
                damaged_at=_parse_date(item.get("damaged_at")) or date.today(),
            )
            damaged_created += 1
            overall_done += 1
            yield ({"event": "progress", "stage": "damaged_medicines", "overall_done": overall_done, "overall_total": overall_total})

        expenses_created = 0
        for item in expenses_in:
            Expense.objects.create(
                pharmacy=pharmacy,
                expense_type=item.get("expense_type") or "",
                expense_date=_parse_date(item.get("expense_date")) or date.today(),
                amount=Decimal(str(item.get("amount") or 0)),
                notes=item.get("notes") or "",
            )
            expenses_created += 1
            overall_done += 1
            yield ({"event": "progress", "stage": "expenses", "overall_done": overall_done, "overall_total": overall_total})

        # سجل النقل تاريخي فقط (لا يغيّر كميات — الكميات النهائية
        # مرفوعة أصلاً مع الأدوية). سجل يشير لمخزن غير مرفوع يُتجاهل.
        transfers_created = 0
        for item in transfers_in:
            from_id = warehouse_id_map.get(item.get("local_from_warehouse_id"))
            to_id = warehouse_id_map.get(item.get("local_to_warehouse_id"))
            quantity = int(item.get("quantity") or 0)
            if from_id is not None and to_id is not None and from_id != to_id and quantity > 0:
                StockTransfer.objects.create(
                    pharmacy=pharmacy,
                    from_warehouse_id=from_id,
                    to_warehouse_id=to_id,
                    from_warehouse_name=warehouse_names.get(from_id, ""),
                    to_warehouse_name=warehouse_names.get(to_id, ""),
                    trade_name=item.get("trade_name") or "",
                    barcode=(str(item.get("barcode") or "").strip() or None),
                    quantity=quantity,
                    notes=item.get("notes") or "",
                    transferred_at=_parse_datetime(item.get("transferred_at")) or timezone.now(),
                )
                transfers_created += 1
            overall_done += 1
            yield ({"event": "progress", "stage": "stock_transfers", "overall_done": overall_done, "overall_total": overall_total})

        pharmacy.migrated_from_offline_at = timezone.now()
        pharmacy.save(update_fields=["migrated_from_offline_at"])

        summary = {
            "warehouses_mapped": len(warehouse_id_map),
            "stock_transfers_created": transfers_created,
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

    yield {"event": "done", "ok": True, "summary": summary}


def run_offline_import(pharmacy, payload, on_event=None):
    """يستهلك iter_offline_import كاملاً ويرجع الملخص النهائي."""
    summary = None
    for event in iter_offline_import(pharmacy, payload):
        if on_event is not None:
            on_event(event)
        if event["event"] == "done":
            summary = event["summary"]
    return summary
