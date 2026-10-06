"""
الرفع الأولي لبيانات صيدلية أوفلاين إلى الخادم (التحويل أوفلاين → أونلاين).

منطق مشترك واحد يستخدمه مساران فقط، بلا تكرار:
  - MigrationViewSet.upload_offline_data (من تطبيق المالك، استجابة NDJSON متدفقة)
  - أمر الإدارة migrate_offline_data (من ملف JSON على الخادم)

الحمولة بنفس شكل DatabaseHelper.getOfflineMigrationPayload في Flutter.

الترتيب صارم بسبب الاعتماديات: Warehouses → Suppliers → Medicines (مع
Batches) → PurchaseInvoices (مع Items/Payments/Returns متداخلة) → Invoices (مع
Items متداخلة) → DamagedMedicines → Expenses → StockTransfers. القوائم
المتداخلة تُرسَل ضمن عنصرها الأب، فلا حاجة لجدول تحويل معرّفات إلا للمخازن/
الموردين/الأدوية/فواتير الشراء (الأخيرة لربط الدفعات بفاتورتها بعد إنشائها).
"""

import logging
from datetime import date, datetime
from decimal import Decimal

from django.db import transaction
from django.utils import timezone
from django.utils.dateparse import parse_date, parse_datetime
from rest_framework.exceptions import PermissionDenied, ValidationError

from desktop_api.permissions import ONLINE_PLAN_REQUIRED_MESSAGE, plan_allows_online

from . import stock
from .models import (
    DamagedMedicine,
    Expense,
    Invoice,
    InvoiceItem,
    Medicine,
    MedicineBatch,
    BATCH_SOURCE_CHOICES,
    PURCHASE_SOURCE_CHOICES,
    PURCHASE_SOURCE_MANUAL,
    PurchaseInvoice,
    PurchaseInvoiceItem,
    PurchaseInvoiceReturn,
    PurchaseInvoiceReturnItem,
    StockTransfer,
    Supplier,
    SupplierCreditApplication,
    SupplierPayment,
    SupplierRefund,
    Warehouse,
)

logger = logging.getLogger(__name__)

PAYLOAD_LIST_KEYS = (
    "warehouses", "suppliers", "medicines", "purchase_invoices",
    "invoices", "damaged_medicines", "expenses", "stock_transfers", "supplier_refunds",
)


def has_existing_online_data(pharmacy):
    """
    بيانات أونلاين حقيقية مسجّلة مسبقاً لهذه الصيدلية. المخازن لا تُحتسب (المخزن
    الرئيسي يُنشأ تلقائياً عند أول طلب).

    هذا هو الشرط الحاسم لمنع تكرار الرفع، لا migrated_from_offline_at وحده:
    علَم بلا أي بيانات (رفع فارغ قديم، أو ضبطه يدوياً، أو حذف البيانات بعده)
    كان يقفل الصيدلية نهائياً فتظهر فارغة أونلاين رغم وجود بياناتها محلياً.
    """
    return (
        Medicine.objects.filter(pharmacy=pharmacy).exists()
        or Supplier.objects.filter(pharmacy=pharmacy).exists()
        or Invoice.objects.filter(pharmacy=pharmacy).exists()
        or Expense.objects.filter(pharmacy=pharmacy).exists()
        or DamagedMedicine.objects.filter(pharmacy=pharmacy).exists()
        or PurchaseInvoice.objects.filter(pharmacy=pharmacy).exists()
        or StockTransfer.objects.filter(pharmacy=pharmacy).exists()
    )


def payload_has_records(payload):
    return any(payload.get(key) for key in PAYLOAD_LIST_KEYS)


def validate_offline_import(pharmacy, license, payload):
    """
    كل شروط قبول الرفع الأولي، مشتركة بين الـendpoint والأمر. ترفع
    PermissionDenied/ValidationError برسالة عربية جاهزة للعرض.
    """
    if license is None or not plan_allows_online(license):
        raise PermissionDenied(ONLINE_PLAN_REQUIRED_MESSAGE)
    # رفض الترحيل إن وُجدت بيانات أونلاين حقيقية مسبقاً — تفادياً للتكرار أو
    # لدمج بيانات محلية قديمة فوق بيانات أونلاين حية. العلَم وحده بلا بيانات
    # لا يمنع (راجع has_existing_online_data).
    if has_existing_online_data(pharmacy):
        if pharmacy.migrated_from_offline_at is not None:
            raise ValidationError("تم رفع بيانات هذه الصيدلية مسبقاً، لا يمكن تكرار العملية.")
        raise ValidationError("توجد بيانات أونلاين مسجّلة مسبقاً لهذه الصيدلية، لا يمكن تنفيذ رفع أولي فوقها.")
    if not isinstance(payload, dict):
        raise ValidationError("صيغة البيانات المرفوعة غير صحيحة.")
    for key in PAYLOAD_LIST_KEYS:
        if key in payload and not isinstance(payload[key], list):
            raise ValidationError(f"صيغة {key} يجب أن تكون قائمة.")
    # رفع فارغ كان "ينجح" ويضبط migrated_from_offline_at بلا أي سجل، فيستهلك
    # الرفع الأولي الوحيد ويُخفي التطبيق اقتراح الرفع بعدها.
    if not payload_has_records(payload):
        raise ValidationError("لا توجد بيانات محلية لرفعها.")


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


def _cost(value):
    """
    كلفة اختيارية من الجهاز: None/فارغ/غير رقمي/سالب = غير معروفة. الصفر كلفة
    معروفة (صنف مجاني من المذخر)؛ الجهاز لم يخزّن 0 كلفةً قط قبل ذلك (كان NULL).
    """
    if value is None or value == "":
        return None
    try:
        cost = Decimal(str(value))
    except Exception:
        return None
    return stock.to_cost(cost) if cost.is_finite() and cost >= 0 else None


_BATCH_SOURCES = {key for key, _ in BATCH_SOURCE_CHOICES}
_PURCHASE_SOURCES = {key for key, _ in PURCHASE_SOURCE_CHOICES}


def _unique_invoice_number(taken, supplier_id, number):
    """احتياط لبيانات أقدم: رقم مكرر لنفس المذخر يُعطى لاحقة -2، -3… كترحيل 0013."""
    if not number:
        return number
    candidate, suffix = number, 2
    while (supplier_id, candidate) in taken:
        candidate = f"{number}-{suffix}"[:60]
        suffix += 1
    taken.add((supplier_id, candidate))
    return candidate


def _money_or_none(value):
    cost = _cost(value)
    return stock.to_money(cost) if cost is not None else None


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
    refunds_in = payload.get("supplier_refunds") or []

    # كل عنصر من المستويات العليا = وحدة تقدّم واحدة. العناصر
    # المتداخلة (payments/returns/items) لا تُحسَب في الإجمالي منفصلة —
    # تبسيط متعمَّد يبقي شريط التقدّم مفهوماً (فاتورة شراء واحدة = خطوة
    # واحدة، بصرف النظر عن عدد دفعاتها).
    overall_total = (
        len(warehouses_in) + len(suppliers_in) + len(medicines_in) + len(purchase_invoices_in)
        + len(invoices_in) + len(damaged_in) + len(expenses_in) + len(transfers_in) + len(refunds_in)
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
        # (دفعة الخادم، معرّف فاتورة الشراء المحلي): تُربط بعد إنشاء الفواتير.
        batches_pending_invoice = []
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
                avg_cost=_cost(item.get("avg_cost")),
            )
            # دفعات الصلاحية كما هي على الجهاز؛ عملاء أقدم بلا "batches" تُنشأ
            # لهم دفعة واحدة بالكمية والصلاحية الحاليتين.
            batches = item.get("batches")
            if isinstance(batches, list):
                for b in batches:
                    qty = int(b.get("quantity") or 0)
                    if qty > 0:
                        source = b.get("source") or ""
                        batch = MedicineBatch.objects.create(
                            pharmacy=pharmacy,
                            medicine=medicine,
                            quantity=qty,
                            expiry_date=_parse_date(b.get("expiry_date")),
                            purchase_price=_cost(b.get("purchase_price")),
                            source=source if source in _BATCH_SOURCES else "",
                            supplier_id=supplier_id_map.get(b.get("local_supplier_id")),
                        )
                        if b.get("local_purchase_invoice_id") is not None:
                            batches_pending_invoice.append((batch.pk, b["local_purchase_invoice_id"]))
                stock.reconcile(medicine)
                stock.refresh_stock(medicine)
            else:
                stock.create_initial_batch(medicine)
            local_id = item.get("local_id")
            if local_id is not None:
                medicine_id_map[local_id] = medicine.id
            overall_done += 1
            yield ({"event": "progress", "stage": "medicines", "overall_done": overall_done, "overall_total": overall_total})

        purchase_invoices_created = 0
        purchase_items_created = 0
        return_items_created = 0
        credit_applications_created = 0
        payments_created = 0
        returns_created = 0
        purchase_invoice_id_map = {}
        taken_numbers = set()
        for item in purchase_invoices_in:
            local_supplier_id = item.get("local_supplier_id")
            server_supplier_id = supplier_id_map.get(local_supplier_id)
            if server_supplier_id is None:
                raise ValidationError(
                    f"فاتورة شراء تشير لمورد غير موجود ضمن قائمة الموردين المرفوعة (local_supplier_id={local_supplier_id})."
                )

            source = item.get("source") or PURCHASE_SOURCE_MANUAL
            items_in = item.get("items") or []
            purchase_invoice = PurchaseInvoice.objects.create(
                pharmacy=pharmacy,
                supplier_id=server_supplier_id,
                invoice_number=_unique_invoice_number(
                    taken_numbers, server_supplier_id, (item.get("invoice_number") or "").strip()
                ),
                invoice_date=_parse_date(item.get("invoice_date")),
                source=source if source in _PURCHASE_SOURCES else PURCHASE_SOURCE_MANUAL,
                item_count=int(item.get("item_count") or len(items_in)),
                total_amount=Decimal(str(item.get("total_amount") or 0)),
                paid_amount=Decimal(str(item.get("paid_amount") or 0)),
                created_at=_parse_datetime(item.get("created_at")) or timezone.now(),
            )
            if item.get("local_id") is not None:
                purchase_invoice_id_map[item["local_id"]] = purchase_invoice.pk

            item_id_map = {}
            for it in items_in:
                # الصنف قد يكون حُذف محلياً (SET_NULL): يبقى السطر بلقطة الاسم.
                created_item = PurchaseInvoiceItem.objects.create(
                    pharmacy=pharmacy,
                    purchase_invoice=purchase_invoice,
                    medicine_id=medicine_id_map.get(it.get("local_medicine_id")),
                    trade_name=it.get("trade_name") or "",
                    quantity=int(it.get("quantity") or 0),
                    bonus_quantity=int(it.get("bonus_quantity") or 0),
                    buy_price=Decimal(str(it.get("buy_price") or 0)),
                    effective_unit_cost=_cost(it.get("effective_unit_cost")) or Decimal(0),
                    sell_price=Decimal(str(it.get("sell_price") or 0)),
                    expiry_date=_parse_date(it.get("expiry_date")),
                    line_total=Decimal(str(it.get("line_total") or 0)),
                )
                if it.get("local_id") is not None:
                    item_id_map[it["local_id"]] = created_item
                purchase_items_created += 1

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
                returned = Decimal(str(r.get("amount_returned") or 0))
                record = PurchaseInvoiceReturn.objects.create(
                    pharmacy=pharmacy,
                    supplier_id=server_supplier_id,
                    purchase_invoice=purchase_invoice,
                    amount_returned=returned,
                    excess_credit=min(Decimal(str(r.get("excess_credit") or 0)), returned),
                    notes=r.get("notes") or "",
                    returned_at=_parse_datetime(r.get("returned_at")) or timezone.now(),
                )
                returns_created += 1
                # أسطر الاسترجاع بالأصناف (الاسترجاع القديم بالمبلغ فقط بلا أسطر).
                for line in r.get("items") or []:
                    source_item = item_id_map.get(line.get("local_purchase_invoice_item_id"))
                    if source_item is None:
                        raise ValidationError("سطر استرجاع يشير لصنف غير موجود ضمن أصناف فاتورته المرفوعة.")
                    quantity = int(line.get("quantity") or 0)
                    PurchaseInvoiceReturnItem.objects.create(
                        pharmacy=pharmacy,
                        purchase_return=record,
                        purchase_invoice_item=source_item,
                        medicine_id=medicine_id_map.get(line.get("local_medicine_id")),
                        trade_name=line.get("trade_name") or source_item.trade_name,
                        quantity=quantity,
                        credited_quantity=min(int(line.get("credited_quantity") or 0), quantity),
                        unit_return_price=Decimal(str(line.get("unit_return_price") or 0)),
                        credit_amount=Decimal(str(line.get("credit_amount") or 0)),
                    )
                    return_items_created += 1

            # "خصم من رصيد سابق" / تسوية فائض مرتجع على هذه الفاتورة.
            for a in item.get("credit_applications") or []:
                SupplierCreditApplication.objects.create(
                    pharmacy=pharmacy,
                    supplier_id=server_supplier_id,
                    purchase_invoice=purchase_invoice,
                    amount=Decimal(str(a.get("amount") or 0)),
                    notes=a.get("notes") or "",
                    applied_at=_parse_datetime(a.get("applied_at")) or timezone.now(),
                )
                credit_applications_created += 1

            purchase_invoices_created += 1
            overall_done += 1
            yield ({"event": "progress", "stage": "purchase_invoices", "overall_done": overall_done, "overall_total": overall_total})

        for batch_id, local_invoice_id in batches_pending_invoice:
            server_invoice_id = purchase_invoice_id_map.get(local_invoice_id)
            if server_invoice_id is not None:
                MedicineBatch.objects.filter(pk=batch_id).update(purchase_invoice_id=server_invoice_id)

        refunds_created = 0
        for item in refunds_in:
            server_supplier_id = supplier_id_map.get(item.get("local_supplier_id"))
            if server_supplier_id is None:
                raise ValidationError("مبلغ مستلم من مذخر يشير لمورد غير موجود ضمن قائمة الموردين المرفوعة.")
            SupplierRefund.objects.create(
                pharmacy=pharmacy,
                supplier_id=server_supplier_id,
                amount=Decimal(str(item.get("amount") or 0)),
                notes=item.get("notes") or "",
                received_at=_parse_datetime(item.get("received_at")) or timezone.now(),
            )
            refunds_created += 1
            overall_done += 1
            yield ({"event": "progress", "stage": "supplier_refunds", "overall_done": overall_done, "overall_total": overall_total})

        invoices_created = 0
        invoice_items_created = 0
        for item in invoices_in:
            discount = Decimal(str(item.get("discount") or 0))
            if discount < 0:
                # بيانات تاريخية من نسخ أقدم سمحت بخصم سالب: لا يمكن رفضها، فتُصفَّر
                # (final_amount يبقى المبلغ المحصَّل فعلاً) ويُسجَّل ذلك.
                logger.warning(
                    "offline import: pharmacy %s invoice %s had negative discount %s; clamped to 0",
                    pharmacy.pk, item.get("invoice_number"), discount,
                )
                discount = Decimal("0")
            invoice = Invoice.objects.create(
                pharmacy=pharmacy,
                invoice_number=item.get("invoice_number") or f"MIGRATED-{overall_done + 1}",
                cashier=None,
                cashier_name=item.get("cashier_name") or "",
                total_amount=Decimal(str(item.get("total_amount") or 0)),
                discount=discount,
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
                    unit_cost=_cost(it.get("unit_cost")),
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
                total_cost=_money_or_none(item.get("total_cost")),
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
            "purchase_invoice_items_created": purchase_items_created,
            "purchase_return_items_created": return_items_created,
            "supplier_credit_applications_created": credit_applications_created,
            "supplier_refunds_created": refunds_created,
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
