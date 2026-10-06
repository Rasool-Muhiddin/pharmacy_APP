import '../../models/report_period.dart';
import '../../repository/reports_repository.dart';

/// كاش أقسام التقرير للفترة الحالية: كل قسم يُطلب مرة واحدة (عند أول فتح
/// لتبويبه) ثم يُعاد استخدام نتيجته. الطلب الفاشل يُزال كي تعيد "إعادة
/// المحاولة" طلبه. يُمسح كاملاً عند تغيير الفترة أو التحديث.
class ReportsCache {
  final Map<String, Future<Map<String, dynamic>>> _futures = {};

  Future<Map<String, dynamic>> get(String key, Future<Map<String, dynamic>> Function() load) {
    final existing = _futures[key];
    if (existing != null) return existing;
    final future = load();
    _futures[key] = future;
    future.then((_) {}, onError: (Object _) {
      if (identical(_futures[key], future)) _futures.remove(key);
    });
    return future;
  }

  void invalidate(String key) => _futures.remove(key);

  void clear() => _futures.clear();
}

/// ما تحتاجه التبويبات من الشاشة.
class ReportsScope {
  const ReportsScope({
    required this.repo,
    required this.period,
    required this.cache,
    required this.pharmacyId,
    required this.isOnlineMode,
    required this.isOwner,
    required this.onDataChanged,
    required this.openTab,
  });

  final ReportsDataSource repo;
  final ReportPeriod period;
  final ReportsCache cache;
  final int pharmacyId;
  final bool isOnlineMode;
  final bool isOwner;

  /// بعد تعديل بيانات من داخل التقرير (سعر صنف، تسجيل تالف): يُعاد تحميل الكل.
  final void Function() onDataChanged;
  final void Function(int tab) openTab;

  String _key(String section) => '${period.cacheKey}|$section';

  Future<Map<String, dynamic>> load(String section, Future<Map<String, dynamic>> Function() fetch) =>
      cache.get(_key(section), fetch);

  void invalidate(String section) => cache.invalidate(_key(section));
}
