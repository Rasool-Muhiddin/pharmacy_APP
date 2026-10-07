import '../database/db_helper.dart';
import '../models/report_period.dart';
import '../services/invoice_api_service.dart';
import '../services/reports_api_service.dart';
import '../services/reports_local_service.dart';
import 'medicine_repository.dart';

/// مصدر بيانات شاشة التقارير: قسم لكل دالة بنفس شكل JSON في الوضعين.
///
/// أونلاين: التجميع بالكامل على الخادم (/api/reports/*) — بيانات كل أجهزة
/// الصيدلية، وعند فشل الاتصال يُرمى الخطأ لتعرض الشاشة رسالة بدل أرقام قديمة
/// مضلِّلة. أوفلاين: ReportsLocalService على SQLite المحلي بنفس الصيغ.
abstract class ReportsDataSource {
  Future<Map<String, dynamic>> kpis(ReportPeriod period);
  Future<Map<String, dynamic>> trend(ReportPeriod period);
  Future<Map<String, dynamic>> categories(ReportPeriod period);
  Future<Map<String, dynamic>> hours(ReportPeriod period);
  Future<Map<String, dynamic>> items(ReportPeriod period, {String sort = 'qty'});
  /// [pageSize] null = الحجم الافتراضي للشاشة؛ التصدير يطلب صفحات أكبر.
  Future<Map<String, dynamic>> stagnant(ReportPeriod period, {int page = 1, int? pageSize});
  Future<Map<String, dynamic>> inventory({int days = 30});
  Future<Map<String, dynamic>> purchases(ReportPeriod period);
  Future<Map<String, dynamic>> losses(ReportPeriod period);
  Future<Map<String, dynamic>> invoices(
    ReportPeriod period, {
    int page = 1,
    int? pageSize,
    String query = '',
    String seller = '',
    bool refunded = false,
  });
  Future<Map<String, dynamic>> sellers(ReportPeriod period);

  /// أسطر فاتورة لنافذة التفاصيل.
  Future<List<Map<String, dynamic>>> invoiceItems(int invoiceId);

  /// صف الدواء كاملاً لنافذتي التعديل والإتلاف (null إن لم يعد موجوداً).
  Future<Map<String, dynamic>?> medicine(int medicineId);
}

class ReportsRepository implements ReportsDataSource {
  ReportsRepository({required this.pharmacyId, required this.isOnlineMode, ReportsLocalService? local})
      : _local = local ?? ReportsLocalService();

  final int pharmacyId;
  final bool isOnlineMode;
  final ReportsLocalService _local;

  ReportsApiService get _api => ReportsApiService.instance;

  Future<Map<String, dynamic>> _section(
    String name,
    ReportPeriod? period,
    Future<Map<String, dynamic>> Function() offline, [
    Map<String, String> params = const {},
  ]) {
    if (!isOnlineMode) return offline();
    return _api.fetchSection(name, start: period?.start, end: period?.end, params: params);
  }

  @override
  Future<Map<String, dynamic>> kpis(ReportPeriod period) =>
      _section('kpis', period, () => _local.kpis(pharmacyId, period));

  @override
  Future<Map<String, dynamic>> trend(ReportPeriod period) =>
      _section('trend', period, () => _local.trend(pharmacyId, period));

  @override
  Future<Map<String, dynamic>> categories(ReportPeriod period) =>
      _section('categories', period, () => _local.categories(pharmacyId, period));

  @override
  Future<Map<String, dynamic>> hours(ReportPeriod period) =>
      _section('hours', period, () => _local.hours(pharmacyId, period));

  @override
  Future<Map<String, dynamic>> items(ReportPeriod period, {String sort = 'qty'}) =>
      _section('items', period, () => _local.items(pharmacyId, period, sort: sort), {'sort': sort});

  @override
  Future<Map<String, dynamic>> stagnant(ReportPeriod period, {int page = 1, int? pageSize}) => _section(
        'stagnant',
        period,
        () => _local.stagnant(pharmacyId, period,
            page: page, pageSize: pageSize ?? ReportsLocalService.defaultPageSize),
        {'page': '$page', if (pageSize != null) 'page_size': '$pageSize'},
      );

  @override
  Future<Map<String, dynamic>> inventory({int days = 30}) =>
      _section('inventory', null, () => _local.inventory(pharmacyId, days: days), {'days': '$days'});

  @override
  Future<Map<String, dynamic>> purchases(ReportPeriod period) =>
      _section('purchases', period, () => _local.purchases(pharmacyId, period));

  @override
  Future<Map<String, dynamic>> losses(ReportPeriod period) =>
      _section('losses', period, () => _local.losses(pharmacyId, period));

  @override
  Future<Map<String, dynamic>> invoices(
    ReportPeriod period, {
    int page = 1,
    int? pageSize,
    String query = '',
    String seller = '',
    bool refunded = false,
  }) =>
      _section(
        'invoices',
        period,
        () => _local.invoices(pharmacyId, period,
            page: page,
            pageSize: pageSize ?? ReportsLocalService.defaultPageSize,
            query: query,
            seller: seller,
            refunded: refunded),
        {
          'page': '$page',
          if (pageSize != null) 'page_size': '$pageSize',
          if (query.trim().isNotEmpty) 'q': query.trim(),
          if (seller.trim().isNotEmpty) 'seller': seller.trim(),
          if (refunded) 'refunded': '1',
        },
      );

  @override
  Future<Map<String, dynamic>> sellers(ReportPeriod period) =>
      _section('sellers', period, () => _local.sellers(pharmacyId, period));

  @override
  Future<List<Map<String, dynamic>>> invoiceItems(int invoiceId) async {
    if (!isOnlineMode) return _local.invoiceItems(invoiceId);
    final invoice = await InvoiceApiService.instance.fetchInvoice(invoiceId);
    return List<Map<String, dynamic>>.from(invoice['items'] as List? ?? const []);
  }

  @override
  Future<Map<String, dynamic>?> medicine(int medicineId) async {
    Future<Map<String, dynamic>?> cached() async {
      final db = await DatabaseHelper.instance.database;
      final rows = await db.query('medicine', where: 'id = ?', whereArgs: [medicineId], limit: 1);
      return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
    }

    if (!isOnlineMode) return cached();
    // أونلاين: تحديث كاش المخزون من الخادم أولاً حتى تفتح النافذة بآخر سعر/كمية.
    await MedicineRepository.instance.getMedicines(pharmacyId: pharmacyId, isOnlineMode: true);
    return cached();
  }
}
