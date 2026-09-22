import '../database/db_helper.dart';
import '../services/connectivity_service.dart';
import '../services/medicine_api_service.dart';

class MedicineRepositoryException implements Exception {
  final String message;

  const MedicineRepositoryException(this.message);

  @override
  String toString() => message;
}

/// الطبقة الوحيدة التي يجب أن تستدعيها الشاشات لقراءة/تعديل جدول المخزون.
/// تُطبّق القرارات المتفق عليها لوضع الأونلاين:
/// - السيرفر مصدر البيانات الوحيد؛ الكاش المحلي (medicine) للقراءة فقط
///   ويُحدَّث فقط بعد نجاح عملية فعلية على السيرفر.
/// - عند انقطاع الاتصال أثناء وضع أونلاين: تُمنع كل عمليات الكتابة تماماً،
///   بلا قائمة انتظار محلية (لا يُسمح بإضافة/تعديل/حذف بلا سيرفر).
/// - في وضع أوفلاين (isOnlineMode = false): كل العمليات محلية مباشرة كما
///   كانت قبل هذا التعديل، بلا أي تغيير في السلوك.
class MedicineRepository {
  MedicineRepository._();

  static final MedicineRepository instance = MedicineRepository._();

  final DatabaseHelper _db = DatabaseHelper.instance;
  final MedicineApiService _api = MedicineApiService.instance;
  final ConnectivityService _connectivity = ConnectivityService.instance;

  Future<List<Map<String, dynamic>>> getMedicines({
    required int pharmacyId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.getMedicines(pharmacyId);
    }

    if (!await _connectivity.hasConnection()) {
      // بلا اتصال فعلي الآن: نعرض آخر نسخة مزامَنة محفوظة في الكاش المحلي
      // بدل شاشة فارغة، لكن هذا القراءة فقط — الكتابة تبقى ممنوعة (انظر
      // addMedicine/updateMedicine/deleteMedicine أدناه).
      return _db.getMedicines(pharmacyId);
    }

    final serverItems = await _api.fetchMedicines();
    await _db.replaceMedicinesCache(
      pharmacyId: pharmacyId,
      serverItems: serverItems,
    );
    return _db.getMedicines(pharmacyId);
  }

  Future<Map<String, dynamic>> addMedicine({
    required int pharmacyId,
    required bool isOnlineMode,
    required Map<String, dynamic> data,
  }) async {
    if (!isOnlineMode) {
      final id = await _db.insertMedicine({...data, 'pharmacy_id': pharmacyId});
      return _localRowById(id);
    }

    await _assertOnlineWritable();

    final created = await _api.createMedicine(_toApiPayload(data));
    await _db.upsertMedicineFromServer(
      pharmacyId: pharmacyId,
      serverData: created,
    );
    return _localRowById(created['id'] as int);
  }

  Future<Map<String, dynamic>> updateMedicine({
    required int pharmacyId,
    required bool isOnlineMode,
    required int id,
    required Map<String, dynamic> data,
  }) async {
    if (!isOnlineMode) {
      await _db.updateMedicine(id, data);
      return _localRowById(id);
    }

    await _assertOnlineWritable();

    final updated = await _api.updateMedicine(id, _toApiPayload(data));
    await _db.upsertMedicineFromServer(
      pharmacyId: pharmacyId,
      serverData: updated,
    );
    return _localRowById(id);
  }

  /// زيادة كمية دواء موجود (شحنة توريد جديدة)، مع تحديث اختياري لتاريخ الصلاحية.
  ///
  /// ⚠️ أونلاين: هذه قراءة-ثم-كتابة (read-modify-write) وليست عملية ذرية على
  /// السيرفر — لا يوجد endpoint مخصص للزيادة النسبية بعد، فنحسب الكمية
  /// الجديدة من آخر قيمة معروفة في الكاش المحلي ثم نرسلها كقيمة مطلقة. لو
  /// عدّل جهاز آخر نفس الدواء بين قراءتك وحفظك، قد تُفقد إحدى الزيادتين.
  /// مقبول حالياً لأن تزامن العرض بين الأجهزة يدوي أصلاً (لا واقعية بديلة
  /// بلا endpoint ذري على الخادم)، لكن يستحق أن يُبنى لاحقاً كخطوة عرضة أقل.
  Future<Map<String, dynamic>> supplyMedicine({
    required int pharmacyId,
    required bool isOnlineMode,
    required int medicineId,
    required int addedQuantity,
    String? newExpiryDate,
  }) async {
    if (!isOnlineMode) {
      await _db.supplyMedicine(
        medicineId: medicineId,
        addedQuantity: addedQuantity,
        newExpiryDate: newExpiryDate,
      );
      return _localRowById(medicineId);
    }

    await _assertOnlineWritable();

    final current = await _localRowById(medicineId);
    final newQuantity = (current['quantity'] as int) + addedQuantity;

    final payload = <String, dynamic>{'quantity': newQuantity};
    if (newExpiryDate != null && newExpiryDate.isNotEmpty) {
      payload['expiry_date'] = newExpiryDate;
    }

    final updated = await _api.updateMedicine(medicineId, payload);
    await _db.upsertMedicineFromServer(
      pharmacyId: pharmacyId,
      serverData: updated,
    );
    return _localRowById(medicineId);
  }

  /// إتلاف جزء من كمية دواء (خصم من المخزن + تسجيل السبب).
  ///
  /// ⚠️ أونلاين حالياً: الكمية الجديدة تُرسَل للسيرفر فتتزامن بين الأجهزة،
  /// لكن سبب/ملاحظات الإتلاف نفسها تُحفظ في جدول damaged_medicine المحلي
  /// فقط — لا يوجد له مقابل على السيرفر بعد (جدول لاحق ضمن الخطة)، فلن
  /// يظهر هذا السجل التفصيلي على جهاز آخر لنفس الصيدلية حتى يُبنى.
  Future<Map<String, dynamic>> damageMedicine({
    required int pharmacyId,
    required bool isOnlineMode,
    required int medicineId,
    required int quantityToDamage,
    required String reason,
    String? notes,
  }) async {
    if (!isOnlineMode) {
      await _db.processDamageMedicine(
        medicineId: medicineId,
        pharmacyId: pharmacyId,
        quantityToDamage: quantityToDamage,
        reason: reason,
        notes: notes,
      );
      return _localRowById(medicineId);
    }

    await _assertOnlineWritable();

    final current = await _localRowById(medicineId);
    final newQuantity = (current['quantity'] as int) - quantityToDamage;
    if (newQuantity < 0) {
      throw const MedicineRepositoryException('الكمية المراد إتلافها أكبر من المتاح فعلياً.');
    }

    final updated = await _api.updateMedicine(medicineId, {'quantity': newQuantity});
    await _db.upsertMedicineFromServer(
      pharmacyId: pharmacyId,
      serverData: updated,
    );

    // السجل التفصيلي محلي فقط حالياً (انظر التنبيه أعلى الدالة).
    final db = await _db.database;
    await db.insert('damaged_medicine', {
      'pharmacy_id': pharmacyId,
      'medicine_id': medicineId,
      'quantity_damaged': quantityToDamage,
      'reason': reason,
      'notes': notes ?? '',
      'damaged_at': DateTime.now().toIso8601String().split('T').first,
    });

    return _localRowById(medicineId);
  }

  Future<void> deleteMedicine({
    required bool isOnlineMode,
    required int id,
  }) async {
    if (!isOnlineMode) {
      await _db.deleteMedicine(id);
      return;
    }

    await _assertOnlineWritable();

    // نحذف من السيرفر أولاً، ثم من الكاش المحلي فقط بعد نجاح ذلك — لو فشل
    // الحذف على السيرفر (مثلاً الدواء مرتبط بفاتورة سابقة) يبقى الكاش
    // المحلي متطابقاً مع الحقيقة الفعلية على السيرفر.
    await _api.deleteMedicine(id);
    await _db.deleteMedicine(id);
  }

  Future<void> _assertOnlineWritable() async {
    if (!await _connectivity.hasConnection()) {
      throw const MedicineRepositoryException(
        'لا يوجد اتصال بالخادم حالياً. لا يمكن إجراء أي تعديل على المخزون '
        'في وضع الأونلاين بدون اتصال فعلي بالسيرفر.',
      );
    }
  }

  Future<Map<String, dynamic>> _localRowById(int id) async {
    final db = await _db.database;
    final rows = await db.query('medicine', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) {
      throw const MedicineRepositoryException('تعذر العثور على الدواء بعد الحفظ.');
    }
    return rows.first;
  }

  /// يستبعد الحقول المحلية البحتة (pharmacy_id, id, last_synced_at) قبل
  /// الإرسال للسيرفر — السيرفر يحدد pharmacy تلقائياً من صاحب التوكن
  /// (انظر MedicineViewSet.perform_create)، ولا يقبل id عند الإنشاء أصلاً.
  Map<String, dynamic> _toApiPayload(Map<String, dynamic> data) {
    final payload = Map<String, dynamic>.from(data);
    payload.remove('id');
    payload.remove('pharmacy_id');
    payload.remove('last_synced_at');
    return payload;
  }
}