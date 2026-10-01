import '../database/db_helper.dart';
import '../models/subscription_plan.dart';
import '../services/connectivity_service.dart';
import '../services/warehouse_api_service.dart';

class WarehouseRepositoryException implements Exception {
  final String message;

  const WarehouseRepositoryException(this.message);

  @override
  String toString() => message;
}

/// الطبقة الوحيدة التي يجب أن تستدعيها الشاشات لإدارة المخازن ونقل المخزون
/// بينها (خاصية Gold: AppFeature.multiWarehouse). نفس قرارات
/// MedicineRepository:
/// - أوفلاين: SQLite المحلي هو مصدر الحقيقة، مع فرض نفس قواعد الخادم
///   (الحد الأقصى، الرئيسي لا يُحذف، النقل داخل نفس الصيدلية فقط).
/// - أونلاين: الخادم مصدر الحقيقة الوحيد، والكاش المحلي (warehouses بصفوف
///   last_synced_at غير NULL) للقراءة فقط ويُحدَّث بعد كل عملية ناجحة. بلا
///   اتصال: القراءة من الكاش، والكتابة ممنوعة تماماً.
class WarehouseRepository {
  WarehouseRepository._();

  static final WarehouseRepository instance = WarehouseRepository._();

  final DatabaseHelper _db = DatabaseHelper.instance;
  final WarehouseApiService _api = WarehouseApiService.instance;
  final ConnectivityService _connectivity = ConnectivityService.instance;

  Future<List<Map<String, dynamic>>> getWarehouses({
    required int pharmacyId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      await _db.ensureMainWarehouse(pharmacyId);
      return _db.getWarehouses(pharmacyId);
    }

    if (await _connectivity.hasConnection()) {
      await syncFromServer(pharmacyId);
    }
    return _db.getWarehouses(pharmacyId, syncedOnly: true);
  }

  /// يجلب مخازن الخادم ويستبدل بها الكاش. يُستدعى أيضاً من
  /// MedicineRepository.getMedicines قبل تحديث كاش الأدوية (قيد FOREIGN KEY).
  Future<void> syncFromServer(int pharmacyId) async {
    final serverItems = await _api.fetchWarehouses();
    await _db.replaceWarehousesCache(pharmacyId: pharmacyId, serverItems: serverItems);
  }

  /// معرّف المخزن الرئيسي — البيع (POS) يتم منه حصراً. أونلاين: من كاش
  /// الخادم (يُزامَن إن لم يكن مخزَّناً بعد).
  Future<int> getMainWarehouseId({
    required int pharmacyId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.ensureMainWarehouse(pharmacyId);
    }

    final cached = await _db.getMainWarehouseId(pharmacyId, syncedOnly: true);
    if (cached != null) return cached;

    await _assertOnline('لا يوجد اتصال بالخادم حالياً لتحميل بيانات المخازن.');
    await syncFromServer(pharmacyId);
    final synced = await _db.getMainWarehouseId(pharmacyId, syncedOnly: true);
    if (synced == null) {
      throw const WarehouseRepositoryException('تعذر تحديد المخزن الرئيسي من الخادم.');
    }
    return synced;
  }

  Future<void> addWarehouse({
    required int pharmacyId,
    required bool isOnlineMode,
    required SubscriptionEntitlements entitlements,
    required String name,
  }) async {
    if (!entitlements.allows(AppFeature.multiWarehouse)) {
      throw const WarehouseRepositoryException(
        'باقتك الحالية لا تسمح بإضافة مخازن. قم بالترقية إلى الباقة الذهبية.',
      );
    }

    if (!isOnlineMode) {
      try {
        await _db.addWarehouse(
          pharmacyId: pharmacyId,
          name: name,
          maxWarehouses: entitlements.maxWarehouses,
        );
      } on StateError catch (e) {
        throw WarehouseRepositoryException(e.message);
      }
      return;
    }

    await _assertOnlineWritable();
    await _api.createWarehouse(name.trim());
    await syncFromServer(pharmacyId);
  }

  Future<void> renameWarehouse({
    required int pharmacyId,
    required bool isOnlineMode,
    required int warehouseId,
    required String name,
  }) async {
    if (!isOnlineMode) {
      try {
        await _db.renameWarehouse(warehouseId, name);
      } on StateError catch (e) {
        throw WarehouseRepositoryException(e.message);
      }
      return;
    }

    _assertServerRecord(warehouseId);
    await _assertOnlineWritable();
    await _api.renameWarehouse(warehouseId, name.trim());
    await syncFromServer(pharmacyId);
  }

  Future<void> deleteWarehouse({
    required int pharmacyId,
    required bool isOnlineMode,
    required int warehouseId,
  }) async {
    if (!isOnlineMode) {
      try {
        await _db.deleteWarehouse(warehouseId);
      } on StateError catch (e) {
        throw WarehouseRepositoryException(e.message);
      }
      return;
    }

    _assertServerRecord(warehouseId);
    await _assertOnlineWritable();
    await _api.deleteWarehouse(warehouseId);
    // الخادم حذف أيضاً أصناف المخزن ذات الكمية صفر؛ نزيلها من الكاش قبل
    // المخزن نفسه (قيد FOREIGN KEY).
    final db = await _db.database;
    await db.delete(
      'medicine',
      where: 'warehouse_id = ? AND id < ${DatabaseHelper.localIdBase} AND quantity = 0 '
          'AND id NOT IN (SELECT medicine_id FROM invoice_item) '
          'AND id NOT IN (SELECT medicine_id FROM damaged_medicine)',
      whereArgs: [warehouseId],
    );
    await syncFromServer(pharmacyId);
  }

  /// نقل كمية صنف بين مخزنين لنفس الصيدلية. إن لم تسمح الباقة بتعدد
  /// المخازن (مثلاً بعد تخفيضها) يُسمح فقط بالنقل *إلى* المخزن الرئيسي، كي
  /// يستطيع المالك تفريغ المخازن الأخرى وبيع مخزونها — نفس قاعدة الخادم.
  Future<void> transferStock({
    required int pharmacyId,
    required bool isOnlineMode,
    required SubscriptionEntitlements entitlements,
    required int medicineId,
    required int toWarehouseId,
    required int quantity,
    String? notes,
  }) async {
    if (quantity <= 0) {
      throw const WarehouseRepositoryException('الكمية المنقولة يجب أن تكون أكبر من صفر.');
    }

    if (!entitlements.allows(AppFeature.multiWarehouse)) {
      final mainId = await getMainWarehouseId(pharmacyId: pharmacyId, isOnlineMode: isOnlineMode);
      if (toWarehouseId != mainId) {
        throw const WarehouseRepositoryException('باقتك الحالية تسمح فقط بالنقل إلى المخزن الرئيسي.');
      }
    }

    if (!isOnlineMode) {
      try {
        await _db.transferStock(
          sourceMedicineId: medicineId,
          toWarehouseId: toWarehouseId,
          quantity: quantity,
          notes: notes,
        );
      } on StateError catch (e) {
        throw WarehouseRepositoryException(e.message);
      }
      return;
    }

    _assertServerRecord(medicineId);
    _assertServerRecord(toWarehouseId);
    await _assertOnlineWritable();
    final response = await _api.transferStock(
      medicineId: medicineId,
      toWarehouseId: toWarehouseId,
      quantity: quantity,
      notes: notes,
    );
    await _db.applyServerTransfer(pharmacyId: pharmacyId, response: response);
  }

  void _assertServerRecord(int id) {
    if (DatabaseHelper.isLocalId(id)) {
      throw const WarehouseRepositoryException(
        'هذا السجل محلي (أوفلاين) ولم يُرفع إلى الخادم بعد، فلا يمكن استخدامه في وضع الأونلاين.',
      );
    }
  }

  Future<void> _assertOnlineWritable() => _assertOnline(
        'لا يوجد اتصال بالخادم حالياً. لا يمكن تعديل المخازن أو نقل المخزون '
        'في وضع الأونلاين بدون اتصال فعلي بالسيرفر.',
      );

  Future<void> _assertOnline(String message) async {
    if (!await _connectivity.hasConnection()) {
      throw WarehouseRepositoryException(message);
    }
  }
}
