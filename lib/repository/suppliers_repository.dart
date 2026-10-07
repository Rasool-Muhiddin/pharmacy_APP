import '../database/db_helper.dart';
import '../models/purchase_list.dart';
import '../services/connectivity_service.dart';
import '../services/suppliers_api_service.dart';
import 'medicine_repository.dart';
import '../services/api_http.dart';

class SuppliersRepositoryException implements Exception {
  final String message;

  const SuppliersRepositoryException(this.message);

  @override
  String toString() => message;
}

/// الطبقة الوحيدة التي يجب أن تستدعيها شاشة المذاخر لقراءة/تعديل المذاخر
/// وفواتير الشراء. نفس قرارات MedicineRepository (سيرفر = مصدر الحقيقة
/// الوحيد، منع الكتابة بلا اتصال في وضع الأونلاين)، مع فارق مهم واحد:
///
/// ⚠️ لا يوجد كاش محلي لبيانات summary/statement المُجمَّعة (بخلاف جدول
/// medicine الذي له كاش read-only حقيقي) — فهي أرقام محسوبة من عدة جداول
/// على السيرفر، وليست صفوفاً بسيطة قابلة لـ upsert. لذلك في وضع الأونلاين،
/// انقطاع الاتصال يمنع حتى القراءة (لا عرض "آخر نسخة معروفة")، بخلاف سلوك
/// المخزون. إن رغبت بنفس سلوك القراءة الاحتياطية لاحقاً، يلزم بناء جداول
/// كاش محلية مخصّصة (suppliers_cache، purchase_invoices_cache...).
class SuppliersRepository {
  SuppliersRepository._();

  static final SuppliersRepository instance = SuppliersRepository._();

  final DatabaseHelper _db = DatabaseHelper.instance;
  final SuppliersApiService _api = SuppliersApiService.instance;
  final ConnectivityService _connectivity = ConnectivityService.instance;

  // ================== القراءة ==================

  Future<List<Map<String, dynamic>>> getSuppliersWithFinancials({
    required int pharmacyId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.getSuppliersWithFinancials(pharmacyId);
    }

    final summary = await _summary();
    return summary.map(_normalizeSupplierSummaryRow).toList();
  }

  Future<double> getTotalSuppliersDebt({
    required int pharmacyId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.getTotalSuppliersDebt(pharmacyId);
    }

    final summary = await _summary();
    return summary.fold<double>(
      0.0,
      (sum, row) => sum + _numOf(row['remaining_debt']),
    );
  }

  Future<Map<String, dynamic>?> getTopSupplier({
    required int pharmacyId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.getTopSupplier(pharmacyId);
    }

    final summary = await _summary();
    final withPurchases =
        summary.where((row) => (row['invoice_count'] as num? ?? 0) > 0).toList();
    if (withPurchases.isEmpty) return null;

    withPurchases.sort(
      (a, b) => _numOf(b['total_purchases']).compareTo(_numOf(a['total_purchases'])),
    );
    return _normalizeSupplierSummaryRow(withPurchases.first);
  }

  Future<List<Map<String, dynamic>>> getPurchaseInvoicesBySupplier({
    required int supplierId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.getPurchaseInvoicesBySupplier(supplierId);
    }

    final invoices = await _read(() => _api.fetchPurchaseInvoices(supplierId));
    return invoices.map(_normalizePurchaseInvoiceRow).toList();
  }

  Future<List<Map<String, dynamic>>> getSupplierStatementOfAccount({
    required int supplierId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.getSupplierStatementOfAccount(supplierId);
    }

    final rows = await _read(() => _api.fetchSupplierStatement(supplierId));
    return rows.map(_normalizeStatementRow).toList();
  }

  // ================== الكتابة ==================

  Future<int> insertSupplier({
    required int pharmacyId,
    required bool isOnlineMode,
    required Map<String, dynamic> data,
  }) async {
    if (!isOnlineMode) {
      return _db.insertSupplier({...data, 'pharmacy_id': pharmacyId});
    }

    await _assertOnlineWritable();
    final created = await _api.createSupplier({
      'name': data['name'],
      'phone': data['phone'] ?? '',
    });
    return created['id'] as int;
  }

  /// تصحيح اسم المذخر (الاسم فقط). أخطاء التحقق ترمي [PurchaseListException].
  Future<void> renameSupplier({
    required bool isOnlineMode,
    required int id,
    required String name,
  }) async {
    if (!isOnlineMode) {
      await _db.updateSupplierName(id, name);
      return;
    }

    await _assertOnlineWritable();
    try {
      await _api.updateSupplierName(id, name.trim());
    } on SuppliersApiException catch (e) {
      throw PurchaseListException(e.message.replaceFirst(RegExp(r'^name: '), ''));
    }
  }

  Future<void> deleteSupplier({
    required bool isOnlineMode,
    required int id,
  }) async {
    if (!isOnlineMode) {
      await _db.deleteSupplier(id);
      return;
    }

    await _assertOnlineWritable();
    await _api.deleteSupplier(id);
  }

  /// قائمة مذخر كاملة من شاشة المخزون (الطريق الوحيد لإنشاء فاتورة شراء):
  /// المذخر (موجود [supplierId] أو جديد [supplierName]) ← الفاتورة ← توريد كل
  /// الأصناف (مع البونص) ← الدفعة الأولية [paidAmount]. الكل أو لا شيء؛ أخطاء
  /// الأسطر ترمي [PurchaseListException] (line = السطر المرفوض).
  ///
  /// أونلاين: طلب واحد ذرّي على الخادم، ثم تحديث كاش المخزون بالأصناف المعادة.
  Future<void> createPurchaseList({
    required int pharmacyId,
    required bool isOnlineMode,
    required int warehouseId,
    required String invoiceNumber,
    required List<Map<String, dynamic>> items,
    int? supplierId,
    String? supplierName,
    String? supplierPhone,
    String? invoiceDate,
    double paidAmount = 0,
  }) async {
    if (!isOnlineMode) {
      await _db.createPurchaseList(
        pharmacyId: pharmacyId,
        mode: PurchaseListMode.supplierList,
        warehouseId: warehouseId,
        items: items,
        supplierId: supplierId,
        supplierName: supplierName,
        supplierPhone: supplierPhone,
        invoiceNumber: invoiceNumber,
        invoiceDate: invoiceDate,
        paidAmount: paidAmount,
      );
      return;
    }

    if (DatabaseHelper.isLocalId(warehouseId) ||
        items.any((i) => i['medicine_id'] is int && DatabaseHelper.isLocalId(i['medicine_id'] as int))) {
      throw const SuppliersRepositoryException(
        'هذا السجل محلي (أوفلاين) ولم يُرفع إلى الخادم بعد، فلا يمكن تعديله في وضع الأونلاين.',
      );
    }
    await _assertOnlineWritable();

    final Map<String, dynamic> result;
    try {
      result = await _api.createPurchaseList({
        if (supplierId != null) 'supplier': supplierId,
        'supplier_name': supplierName ?? '',
        'supplier_phone': supplierPhone ?? '',
        'invoice_number': invoiceNumber,
        if (invoiceDate != null) 'invoice_date': invoiceDate,
        'warehouse': warehouseId,
        'paid_amount': paidAmount.toStringAsFixed(2),
        'items': items,
      });
    } on SuppliersApiException catch (e) {
      throw PurchaseListException(e.message, line: e.line);
    }
    await MedicineRepository.instance.cacheServerMedicines(
      pharmacyId: pharmacyId,
      serverItems: result['medicines'],
    );
  }

  /// أصناف فاتورة شراء (اسم، كمية مدفوعة، بونص، سعر، صلاحية، إجمالي السطر).
  Future<List<Map<String, dynamic>>> getPurchaseInvoiceItems({
    required int purchaseInvoiceId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return (await _db.getPurchaseInvoiceItems(purchaseInvoiceId)).map(_normalizePurchaseItemRow).toList();
    }
    final rows = await _read(() => _api.fetchPurchaseInvoiceItems(purchaseInvoiceId));
    return rows.map(_normalizePurchaseItemRow).toList();
  }

  /// الأصناف المشتراة من مذخر عبر كل فواتيره (لكشف الحساب).
  Future<List<Map<String, dynamic>>> getSupplierPurchasedItems({
    required int supplierId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return (await _db.getSupplierPurchasedItems(supplierId)).map(_normalizePurchaseItemRow).toList();
    }
    final rows = await _read(() => _api.fetchSupplierPurchasedItems(supplierId));
    return rows.map(_normalizePurchaseItemRow).toList();
  }

  Future<void> addPurchaseInvoicePayment({
    required int pharmacyId,
    required bool isOnlineMode,
    required int supplierId,
    required int purchaseInvoiceId,
    required double amount,
    String? notes,
  }) async {
    if (!isOnlineMode) {
      await _db.addPurchaseInvoicePayment(
        pharmacyId: pharmacyId,
        supplierId: supplierId,
        purchaseInvoiceId: purchaseInvoiceId,
        amount: amount,
        notes: notes,
      );
      return;
    }

    await _assertOnlineWritable();
    await _api.addPurchaseInvoicePayment(purchaseInvoiceId, amount: amount, notes: notes);
  }

  /// استرجاع أدوية للمذخر من فاتورة شراء (الاسترجاع بالأصناف فقط). [lines]:
  /// [{purchase_invoice_item_id, quantity, unit_price}]. الكل أو لا شيء؛ أخطاء
  /// الأسطر ترمي [PurchaseListException] (line = السطر المرفوض).
  /// أونلاين: طلب ذرّي على الخادم ثم تحديث كاش المخزون بالأصناف المعادة.
  Future<void> returnPurchaseItems({
    required int pharmacyId,
    required bool isOnlineMode,
    required int purchaseInvoiceId,
    required List<Map<String, dynamic>> lines,
    String? notes,
    DateTime? returnDate,
  }) async {
    if (!isOnlineMode) {
      await _db.returnPurchaseItems(
        pharmacyId: pharmacyId,
        purchaseInvoiceId: purchaseInvoiceId,
        lines: lines,
        notes: notes,
        returnDate: returnDate,
      );
      return;
    }

    await _assertOnlineWritable();
    final Map<String, dynamic> result;
    try {
      result = await _api.returnPurchaseItems(purchaseInvoiceId, {
        'items': [
          for (final line in lines)
            {
              'purchase_invoice_item': line['purchase_invoice_item_id'],
              'quantity': line['quantity'],
              if (line['unit_price'] != null) 'unit_price': (line['unit_price'] as num).toStringAsFixed(2),
            },
        ],
        'notes': notes ?? '',
        if (returnDate != null) 'return_date': _isoDate(returnDate),
      });
    } on SuppliersApiException catch (e) {
      throw PurchaseListException(e.message, line: e.line);
    }
    await MedicineRepository.instance.cacheServerMedicines(
      pharmacyId: pharmacyId,
      serverItems: result['medicines'],
    );
  }

  /// استلام أموال من المذخر (جزئي مسموح، لا يتجاوز رصيد الصيدلية المتاح لديه).
  Future<void> receiveSupplierRefund({
    required int pharmacyId,
    required bool isOnlineMode,
    required int supplierId,
    required double amount,
    String? notes,
    DateTime? receivedDate,
  }) async {
    if (!isOnlineMode) {
      await _db.receiveSupplierRefund(
        pharmacyId: pharmacyId,
        supplierId: supplierId,
        amount: amount,
        notes: notes,
        receivedDate: receivedDate,
      );
      return;
    }

    await _assertOnlineWritable();
    try {
      await _api.receiveSupplierRefund(supplierId, {
        'amount': amount.toStringAsFixed(2),
        'notes': notes ?? '',
        if (receivedDate != null) 'received_date': _isoDate(receivedDate),
      });
    } on SuppliersApiException catch (e) {
      throw PurchaseListException(e.message);
    }
  }

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ================== أدوات مساعدة ==================

  Future<void> _assertOnlineWritable() async {
    if (!await _connectivity.hasConnection()) {
      throw const SuppliersRepositoryException(
        'لا يوجد اتصال بالخادم حالياً. لا يمكن إجراء أي تعديل على المذاخر '
        'في وضع الأونلاين بدون اتصال فعلي بالسيرفر.',
      );
    }
  }

  /// القراءة تطلب الخادم مباشرة (بلا فحص /health/ مسبق)؛ فشل الشبكة يتحوّل
  /// لنفس الرسالة الواضحة (لا كاش محلي للمذاخر في وضع الأونلاين).
  Future<T> _read<T>(Future<T> Function() request) async {
    try {
      return await request();
    } catch (e) {
      if (!ApiHttp.isNetworkError(e)) rethrow;
      throw const SuppliersRepositoryException(
        'لا يوجد اتصال بالخادم حالياً لعرض بيانات المذاخر في وضع الأونلاين.',
      );
    }
  }

  Future<List<Map<String, dynamic>>>? _summaryInFlight;

  /// شاشة المذاخر تطلب القائمة والدين الكلي وأعلى مذخر معاً: طلب
  /// suppliers/summary/ واحد مشترك بينها بدل ثلاثة متطابقة.
  Future<List<Map<String, dynamic>>> _summary() {
    return _summaryInFlight ??=
        _read(_api.fetchSuppliersSummary).whenComplete(() => _summaryInFlight = null);
  }

  /// حقول Decimal في Django تصل كنص JSON (مثلاً "1500.00") لا كرقم، بخلاف
  /// medicine حيث SQLite يحوّلها تلقائياً بفضل affinity العمود عند upsert.
  /// هنا لا يوجد upsert محلي على الإطلاق في وضع الأونلاين، فالتحويل يدوي.
  num _numOf(dynamic value) {
    if (value is num) return value;
    return num.tryParse(value?.toString() ?? '') ?? 0;
  }

  Map<String, dynamic> _normalizeSupplierSummaryRow(Map<String, dynamic> row) {
    return {
      'id': row['id'],
      'name': row['name'],
      'phone': row['phone'],
      'invoice_count': (row['invoice_count'] as num? ?? 0).toInt(),
      'total_purchases': _numOf(row['total_purchases']).toDouble(),
      'remaining_debt': _numOf(row['remaining_debt']).toDouble(),
      'balance': _numOf(row['balance']).toDouble(),
      'credit_balance': _numOf(row['credit_balance']).toDouble(),
      'available_credit': _numOf(row['available_credit']).toDouble(),
      // null = خادم أقدم لا يرسل هذه الحقول.
      'total_paid': row['total_paid'] == null ? null : _numOf(row['total_paid']).toDouble(),
      'last_invoice_date': row['last_invoice_date'],
      'month_purchases': row['month_purchases'] == null ? null : _numOf(row['month_purchases']).toDouble(),
    };
  }

  Map<String, dynamic> _normalizePurchaseInvoiceRow(Map<String, dynamic> row) {
    return {
      ...row,
      'total_amount': _numOf(row['total_amount']).toDouble(),
      'paid_amount': _numOf(row['paid_amount']).toDouble(),
      'returned_amount': _numOf(row['returned_amount']).toDouble(),
      'net_amount': _numOf(row['net_amount']).toDouble(),
      'remaining_amount': _numOf(row['remaining_amount']).toDouble(),
      'credit_applied': _numOf(row['credit_applied']).toDouble(),
      'item_count': _numOf(row['item_count']).toInt(),
    };
  }

  /// سطر فاتورة شراء بشكل موحّد للوضعين (is_free = كمية مدفوعة 0).
  Map<String, dynamic> _normalizePurchaseItemRow(Map<String, dynamic> row) {
    final quantity = _numOf(row['quantity']).toInt();
    return {
      ...row,
      'quantity': quantity,
      'bonus_quantity': _numOf(row['bonus_quantity']).toInt(),
      'is_free': quantity == 0,
      'buy_price': _numOf(row['buy_price']).toDouble(),
      'effective_unit_cost': _numOf(row['effective_unit_cost']).toDouble(),
      'sell_price': _numOf(row['sell_price']).toDouble(),
      'line_total': _numOf(row['line_total']).toDouble(),
      'returned_quantity': _numOf(row['returned_quantity']).toInt(),
      // null = الصنف حُذف من المخزون (لا يمكن استرجاعه).
      'current_stock': row['current_stock'] == null ? null : _numOf(row['current_stock']).toInt(),
    };
  }

  Map<String, dynamic> _normalizeStatementRow(Map<String, dynamic> row) {
    final items = row['items'];
    return {
      ...row,
      'amount': _numOf(row['amount']).toDouble(),
      'cash_paid': _numOf(row['cash_paid']).toDouble(),
      'debt_added': _numOf(row['debt_added']).toDouble(),
      if (items is List)
        'items': items
            .whereType<Map>()
            .map((i) => {
                  ...Map<String, dynamic>.from(i),
                  'quantity': _numOf(i['quantity']).toInt(),
                  'credited_quantity': _numOf(i['credited_quantity']).toInt(),
                  'unit_return_price': _numOf(i['unit_return_price']).toDouble(),
                  'credit_amount': _numOf(i['credit_amount']).toDouble(),
                })
            .toList(),
    };
  }
}