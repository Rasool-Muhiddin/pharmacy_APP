import '../database/db_helper.dart';
import '../services/connectivity_service.dart';
import '../services/expense_api_service.dart';

class ExpenseRepositoryException implements Exception {
  final String message;

  const ExpenseRepositoryException(this.message);

  @override
  String toString() => message;
}

/// الطبقة الوحيدة التي يجب أن تستدعيها الشاشات لقراءة/تعديل المصروفات.
/// تُطبّق نفس القرارات المتفق عليها لوضع الأونلاين المطبَّقة في
/// MedicineRepository/InvoiceRepository (انظرهما لنفس الشرح بالتفصيل):
/// - السيرفر مصدر البيانات الوحيد؛ الكاش المحلي (expense) للقراءة فقط
///   ويُحدَّث فقط بعد نجاح عملية فعلية على السيرفر.
/// - عند انقطاع الاتصال أثناء وضع أونلاين: تُمنع كل عمليات الكتابة تماماً،
///   بلا قائمة انتظار محلية.
/// - في وضع أوفلاين (isOnlineMode = false): كل العمليات محلية مباشرة كما
///   كانت قبل هذا التعديل، بلا أي تغيير في السلوك.
class ExpenseRepository {
  ExpenseRepository._();

  static final ExpenseRepository instance = ExpenseRepository._();

  final DatabaseHelper _db = DatabaseHelper.instance;
  final ExpenseApiService _api = ExpenseApiService.instance;
  final ConnectivityService _connectivity = ConnectivityService.instance;

  /// أونلاين: يجلب كل صفحات المصروفات من السيرفر ويستبدل بها الكاش المحلي
  /// كاملاً (بلا فلترة على الخادم)، ثم يُطبَّق startDate/endDate/expenseType
  /// محلياً بنفس استعلام db_helper.getExpenses المستخدم أوفلاين — تماماً
  /// كما لا تُفلتر fetchMedicines/fetchInvoices على الخادم.
  Future<List<Map<String, dynamic>>> getExpenses({
    required int pharmacyId,
    required bool isOnlineMode,
    String? startDate,
    String? endDate,
    String? expenseType,
  }) async {
    if (isOnlineMode && await _connectivity.hasConnection()) {
      final serverItems = await _api.fetchExpenses();
      await _db.replaceExpensesCache(
        pharmacyId: pharmacyId,
        serverItems: serverItems,
      );
    }
    // أوفلاين، أو أونلاين بلا اتصال فعلي الآن: نعرض آخر نسخة محفوظة محلياً
    // (قراءة فقط) بدل شاشة فارغة — الكتابة تبقى ممنوعة (انظر addExpense/
    // updateExpense/deleteExpense أدناه).
    return _db.getExpenses(
      pharmacyId: pharmacyId,
      startDate: startDate,
      endDate: endDate,
      expenseType: expenseType,
    );
  }

  Future<Map<String, dynamic>> addExpense({
    required int pharmacyId,
    required bool isOnlineMode,
    required Map<String, dynamic> data,
  }) async {
    if (!isOnlineMode) {
      final id = await _db.addExpense({...data, 'pharmacy_id': pharmacyId});
      return _localRowById(id);
    }

    await _assertOnlineWritable();

    final created = await _api.createExpense(_toApiPayload(data));
    await _db.upsertExpenseFromServer(
      pharmacyId: pharmacyId,
      serverData: created,
    );
    return _localRowById(created['id'] as int);
  }

  Future<Map<String, dynamic>> updateExpense({
    required int pharmacyId,
    required bool isOnlineMode,
    required int id,
    required Map<String, dynamic> data,
  }) async {
    if (!isOnlineMode) {
      await _db.updateExpense(id, data);
      return _localRowById(id);
    }

    await _assertOnlineWritable();

    final updated = await _api.updateExpense(id, _toApiPayload(data));
    await _db.upsertExpenseFromServer(
      pharmacyId: pharmacyId,
      serverData: updated,
    );
    return _localRowById(id);
  }

  Future<void> deleteExpense({
    required bool isOnlineMode,
    required int id,
    required int pharmacyId,
  }) async {
    if (!isOnlineMode) {
      await _db.deleteExpense(id, pharmacyId);
      return;
    }

    await _assertOnlineWritable();

    // نحذف من السيرفر أولاً، ثم من الكاش المحلي فقط بعد نجاح ذلك — بنفس
    // منطق MedicineRepository.deleteMedicine تماماً.
    await _api.deleteExpense(id);
    await _db.deleteExpense(id, pharmacyId);
  }

  Future<void> _assertOnlineWritable() async {
    if (!await _connectivity.hasConnection()) {
      throw const ExpenseRepositoryException(
        'لا يوجد اتصال بالخادم حالياً. لا يمكن إجراء أي تعديل على المصروفات '
        'في وضع الأونلاين بدون اتصال فعلي بالسيرفر.',
      );
    }
  }

  Future<Map<String, dynamic>> _localRowById(int id) async {
    final db = await _db.database;
    final rows = await db.query('expense', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) {
      throw const ExpenseRepositoryException('تعذر العثور على المصروف بعد الحفظ.');
    }
    return rows.first;
  }

  /// يستبعد الحقول المحلية البحتة قبل الإرسال للسيرفر — نفس منطق
  /// MedicineRepository._toApiPayload تماماً.
  Map<String, dynamic> _toApiPayload(Map<String, dynamic> data) {
    final payload = Map<String, dynamic>.from(data);
    payload.remove('id');
    payload.remove('pharmacy_id');
    payload.remove('last_synced_at');
    return payload;
  }
}