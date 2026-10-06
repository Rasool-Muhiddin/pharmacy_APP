import '../database/db_helper.dart';
import '../models/purchase_list.dart';
import '../services/connectivity_service.dart';
import '../services/damaged_api_service.dart';
import '../services/medicine_api_service.dart';
import 'warehouse_repository.dart';

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
  final DamagedApiService _damagedApi = DamagedApiService.instance;
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

    // المخازن أولاً: كل صف دواء يشير لمخزنه بقيد FOREIGN KEY.
    await WarehouseRepository.instance.syncFromServer(pharmacyId);
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

    _assertServerRecord(data['warehouse_id']);
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

    _assertServerRecord(id);
    await _assertOnlineWritable();

    final updated = await _api.updateMedicine(id, _toApiPayload(data));
    await _db.upsertMedicineFromServer(
      pharmacyId: pharmacyId,
      serverData: updated,
    );
    return _localRowById(id);
  }

  /// رصيد افتتاحي (المخزون الموجود على الرفوف عند بدء استخدام النظام): نفس
  /// أسطر قائمة المذخر بلا مذخر ولا فاتورة ولا دين، الكل أو لا شيء. أخطاء
  /// الأسطر ترمي [PurchaseListException] (line = السطر المرفوض).
  Future<void> createOpeningStock({
    required int pharmacyId,
    required bool isOnlineMode,
    required int warehouseId,
    required List<Map<String, dynamic>> items,
  }) async {
    if (!isOnlineMode) {
      await _db.createPurchaseList(
        pharmacyId: pharmacyId,
        mode: PurchaseListMode.openingStock,
        warehouseId: warehouseId,
        items: items,
      );
      return;
    }

    _assertServerRecord(warehouseId);
    for (final item in items) {
      _assertServerRecord(item['medicine_id']);
    }
    await _assertOnlineWritable();

    final Map<String, dynamic> result;
    try {
      result = await _api.createOpeningStock({'warehouse': warehouseId, 'items': items});
    } on MedicineApiException catch (e) {
      throw PurchaseListException(e.message, line: e.line);
    }
    await cacheServerMedicines(pharmacyId: pharmacyId, serverItems: result['medicines']);
  }

  /// يحدّث كاش المخزون المحلي بأصناف أعادها الخادم بعد عملية ناجحة (مع دفعاتها).
  Future<void> cacheServerMedicines({required int pharmacyId, required Object? serverItems}) async {
    if (serverItems is! List) return;
    for (final item in serverItems.whereType<Map<String, dynamic>>()) {
      await _db.upsertMedicineFromServer(pharmacyId: pharmacyId, serverData: item);
    }
  }

  /// إتلاف جزء من كمية دواء (خصم من المخزن + تسجيل السبب).
  ///
  /// أونلاين: طلب واحد ذرّي على الخادم (DamagedMedicineViewSet.create) يخصم
  /// الكمية من Medicine وينشئ سجل الإتلاف بنفس المعاملة، فلا نحسب الكمية
  /// الجديدة محلياً ثم نرسلها كما كان سابقاً (كان عرضة لتعارض حقيقي بين
  /// جهازين يتلفان نفس الدواء في نفس اللحظة). سبب/ملاحظات الإتلاف تُزامَن
  /// الآن أيضاً، وليست محلية فقط.
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

    _assertServerRecord(medicineId);
    await _assertOnlineWritable();

    final created = await _damagedApi.createDamagedMedicine({
      'medicine': medicineId,
      'quantity_damaged': quantityToDamage,
      'reason': reason,
      'notes': notes ?? '',
    });

    await _db.upsertDamagedMedicineFromServer(
      pharmacyId: pharmacyId,
      serverData: created,
    );

    // الخادم خصم الكمية من الدفعات (FEFO)؛ نُحدّث كاش المخزون كاملاً (مع
    // الدفعات) بنفس نمط البيع الأونلاين بدل تعديل الكمية وحدها محلياً.
    await getMedicines(pharmacyId: pharmacyId, isOnlineMode: true);

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

    _assertServerRecord(id);
    await _assertOnlineWritable();

    // نحذف من السيرفر أولاً، ثم من الكاش المحلي فقط بعد نجاح ذلك — لو فشل
    // الحذف على السيرفر (مثلاً الدواء مرتبط بفاتورة سابقة) يبقى الكاش
    // المحلي متطابقاً مع الحقيقة الفعلية على السيرفر.
    await _api.deleteMedicine(id);
    await _db.deleteMedicine(id);
  }

  /// وضع الأونلاين يعمل على صفوف الخادم فقط. صف محلي (أوفلاين، معرّف >=
  /// localIdBase) لا وجود له على الخادم، فإرسال معرّفه قد يعدّل سجلاً آخر
  /// بالخطأ أو يفشل — يُرفض هنا برسالة واضحة بدلاً من ذلك.
  void _assertServerRecord(Object? id) {
    if (id is int && DatabaseHelper.isLocalId(id)) {
      throw const MedicineRepositoryException(
        'هذا السجل محلي (أوفلاين) ولم يُرفع إلى الخادم بعد، فلا يمكن تعديله في وضع الأونلاين.',
      );
    }
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
  /// warehouse_id المحلي يُرسل باسم حقل الخادم "warehouse" (معرّف الخادم نفسه
  /// لأن قائمة المخازن أونلاين تأتي من كاش الخادم).
  Map<String, dynamic> _toApiPayload(Map<String, dynamic> data) {
    final payload = Map<String, dynamic>.from(data);
    payload.remove('id');
    payload.remove('pharmacy_id');
    payload.remove('last_synced_at');
    final warehouseId = payload.remove('warehouse_id');
    if (warehouseId != null) {
      payload['warehouse'] = warehouseId;
    }
    return payload;
  }
}