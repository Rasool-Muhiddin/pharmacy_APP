import '../database/db_helper.dart';
import '../services/connectivity_service.dart';
import '../services/suppliers_api_service.dart';

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

    await _assertOnlineReadable();
    final summary = await _api.fetchSuppliersSummary();
    return summary.map(_normalizeSupplierSummaryRow).toList();
  }

  Future<double> getTotalSuppliersDebt({
    required int pharmacyId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.getTotalSuppliersDebt(pharmacyId);
    }

    await _assertOnlineReadable();
    final summary = await _api.fetchSuppliersSummary();
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

    await _assertOnlineReadable();
    final summary = await _api.fetchSuppliersSummary();
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

    await _assertOnlineReadable();
    final invoices = await _api.fetchPurchaseInvoices(supplierId);
    return invoices.map(_normalizePurchaseInvoiceRow).toList();
  }

  Future<List<Map<String, dynamic>>> getSupplierStatementOfAccount({
    required int supplierId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.getSupplierStatementOfAccount(supplierId);
    }

    await _assertOnlineReadable();
    final rows = await _api.fetchSupplierStatement(supplierId);
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

  Future<void> insertPurchaseInvoice({
    required int pharmacyId,
    required bool isOnlineMode,
    required Map<String, dynamic> data,
  }) async {
    if (!isOnlineMode) {
      await _db.insertPurchaseInvoice({...data, 'pharmacy_id': pharmacyId});
      return;
    }

    await _assertOnlineWritable();
    await _api.createPurchaseInvoice({
      'supplier': data['supplier_id'],
      'invoice_number': data['invoice_number'] ?? '',
      'total_amount': data['total_amount'],
      'paid_amount': data['paid_amount'] ?? 0,
    });
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

  Future<void> addPurchaseInvoiceReturn({
    required int pharmacyId,
    required bool isOnlineMode,
    required int supplierId,
    required int purchaseInvoiceId,
    required double amount,
    String? notes,
  }) async {
    if (!isOnlineMode) {
      await _db.addPurchaseInvoiceReturn(
        pharmacyId: pharmacyId,
        supplierId: supplierId,
        purchaseInvoiceId: purchaseInvoiceId,
        amount: amount,
        notes: notes,
      );
      return;
    }

    await _assertOnlineWritable();
    await _api.addPurchaseInvoiceReturn(purchaseInvoiceId, amount: amount, notes: notes);
  }

  Future<void> settlePurchaseInvoiceCredit({
    required bool isOnlineMode,
    required int purchaseInvoiceId,
  }) async {
    if (!isOnlineMode) {
      await _db.settlePurchaseInvoiceCredit(purchaseInvoiceId);
      return;
    }

    await _assertOnlineWritable();
    await _api.settlePurchaseInvoiceCredit(purchaseInvoiceId);
  }

  // ================== أدوات مساعدة ==================

  Future<void> _assertOnlineWritable() async {
    if (!await _connectivity.hasConnection()) {
      throw const SuppliersRepositoryException(
        'لا يوجد اتصال بالخادم حالياً. لا يمكن إجراء أي تعديل على المذاخر '
        'في وضع الأونلاين بدون اتصال فعلي بالسيرفر.',
      );
    }
  }

  Future<void> _assertOnlineReadable() async {
    if (!await _connectivity.hasConnection()) {
      throw const SuppliersRepositoryException(
        'لا يوجد اتصال بالخادم حالياً لعرض بيانات المذاخر في وضع الأونلاين.',
      );
    }
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
    };
  }

  Map<String, dynamic> _normalizeStatementRow(Map<String, dynamic> row) {
    return {
      ...row,
      'amount': _numOf(row['amount']).toDouble(),
      'cash_paid': _numOf(row['cash_paid']).toDouble(),
      'debt_added': _numOf(row['debt_added']).toDouble(),
    };
  }
}