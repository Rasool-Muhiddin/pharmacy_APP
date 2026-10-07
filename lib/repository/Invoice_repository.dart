// ignore_for_file: file_names — اسم الملف قديم ومستورد في عدة شاشات واختبارات.
import '../database/db_helper.dart';
import '../services/api_http.dart';
import '../services/connectivity_service.dart';
import '../services/invoice_api_service.dart';
import 'medicine_repository.dart';

class InvoicePage {
  final List<Map<String, dynamic>> rows;
  final bool hasMore;

  /// أونلاين بلا اتصال: الصفحة من آخر كاش محلي محفوظ.
  final bool fromCache;

  const InvoicePage(this.rows, {required this.hasMore, this.fromCache = false});
}

class InvoiceRepositoryException implements Exception {
  final String message;

  const InvoiceRepositoryException(this.message);

  @override
  String toString() => message;
}

/// الطبقة الوحيدة التي يجب أن تستدعيها الشاشات لبيع فاتورة، إرجاعها، أو
/// عرض سجل الفواتير. تُطبّق نفس قرارات وضع الأونلاين المتفَق عليها تماماً
/// كما في MedicineRepository (انظره لنفس الشرح بالتفصيل):
/// - السيرفر مصدر البيانات الوحيد؛ الكاش المحلي (invoice/invoice_item)
///   للقراءة فقط ويُحدَّث فقط بعد نجاح عملية فعلية على السيرفر.
/// - عند انقطاع الاتصال أثناء وضع أونلاين: يُمنع البيع والإرجاع تماماً،
///   بلا قائمة انتظار محلية.
/// - في وضع أوفلاين (isOnlineMode = false): كل العمليات محلية مباشرة كما
///   كانت قبل هذا التعديل، بلا أي تغيير في السلوك.
class InvoiceRepository {
  InvoiceRepository._();

  static final InvoiceRepository instance = InvoiceRepository._();

  final DatabaseHelper _db = DatabaseHelper.instance;
  final InvoiceApiService _api = InvoiceApiService.instance;
  final ConnectivityService _connectivity = ConnectivityService.instance;

  /// صفحة من سجل المبيعات (الأحدث أولاً) بفلاتر البحث والتاريخ. أونلاين:
  /// الترقيم والفلترة على الخادم، وصفوف الصفحة تُحفظ في الكاش المحلي (لنافذة
  /// تفاصيل الفاتورة). بلا اتصال: نفس الصفحة من آخر كاش محفوظ (قراءة فقط —
  /// البيع والإرجاع يبقيان ممنوعين، انظر checkout/refund).
  Future<InvoicePage> getInvoicesPage({
    required int pharmacyId,
    required bool isOnlineMode,
    int page = 1,
    int pageSize = 50,
    String search = '',
    DateTime? start,
    DateTime? end,
  }) async {
    final startKey = start == null ? null : _dateKey(start);
    final endKey = end == null ? null : _dateKey(end);
    search = search.trim();

    if (isOnlineMode) {
      try {
        final body = await _api.fetchInvoicesPage(
          page: page,
          pageSize: pageSize,
          search: search,
          start: startKey,
          end: endKey,
        );
        final results = (body['results'] as List? ?? const []).whereType<Map<String, dynamic>>().toList();
        await _db.replaceInvoicesCache(pharmacyId: pharmacyId, serverItems: results);
        final rows = await _db.queryInvoices(
          pharmacyId,
          ids: [for (final r in results) r['id'] as int],
        );
        return InvoicePage(rows, hasMore: body['next'] != null);
      } catch (e) {
        if (!ApiHttp.isNetworkError(e)) rethrow;
      }
    }

    final rows = await _db.queryInvoices(
      pharmacyId,
      search: search,
      start: startKey,
      end: endKey,
      limit: pageSize + 1,
      offset: (page - 1) * pageSize,
    );
    return InvoicePage(
      rows.take(pageSize).toList(),
      hasMore: rows.length > pageSize,
      fromCache: isOnlineMode,
    );
  }

  /// آخر [limit] فواتير (لوحة "سجل الفواتير الأخيرة" في نقطة البيع): صفحة
  /// واحدة صغيرة بدل سجل المبيعات كاملاً.
  Future<List<Map<String, dynamic>>> getRecentInvoices({
    required int pharmacyId,
    required bool isOnlineMode,
    int limit = 20,
  }) async {
    final page = await getInvoicesPage(pharmacyId: pharmacyId, isOnlineMode: isOnlineMode, pageSize: limit);
    return page.rows;
  }

  /// مبيعات اليوم وعدد فواتيره (الشاشة الرئيسية). أونلاين من الخادم (كل
  /// أجهزة الصيدلية)؛ أوفلاين أو بلا اتصال من الجدول المحلي.
  Future<({double sales, int count})> getTodayStats({
    required int pharmacyId,
    required bool isOnlineMode,
  }) async {
    if (isOnlineMode) {
      try {
        final stats = await _api.fetchTodayStats();
        return (
          sales: (stats['sales_total'] as num? ?? 0).toDouble(),
          count: (stats['invoices_count'] as num? ?? 0).toInt(),
        );
      } catch (e) {
        if (!ApiHttp.isNetworkError(e)) rethrow;
      }
    }
    return (
      sales: await _db.totalSalesToday(pharmacyId),
      count: await _db.todayInvoiceCount(pharmacyId),
    );
  }

  String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// يبيع محتويات السلة الحالية وينشئ فاتورة، محلياً أو عبر السيرفر حسب
  /// isOnlineMode.
  ///
  /// - أوفلاين: [invoice] يجب أن يكون بصيغة جدول invoice المحلي كاملة
  ///   (invoice_number، cashier_id، created_at... كما في completeSale)،
  ///   و[items] بصيغة جدول invoice_item المحلي (medicine_id، quantity،
  ///   unit_price، total_price، trade_name).
  /// - أونلاين: لا حاجة لأكثر من invoice['discount'] و[items] — رقم
  ///   الفاتورة وسعر كل صنف يُحدَّدان من السيرفر دائماً (انظر
  ///   InvoiceApiService.checkout)، وتُقرأ منها فقط medicine_id/quantity.
  ///
  /// يُعيد بيانات الفاتورة النهائية (محلية الصيغة أوفلاين، أو رد السيرفر
  /// كما هو أونلاين — يحوي invoice_number الفعلي لعرضه للمستخدم).
  Future<Map<String, dynamic>> checkout({
    required int pharmacyId,
    required bool isOnlineMode,
    required Map<String, dynamic> invoice,
    required List<Map<String, dynamic>> items,
  }) async {
    // خصم سالب = لا بيع (أوفلاين وأونلاين)، قبل أي كتابة أو طلب شبكة.
    final discount = (invoice['discount'] as num?)?.toDouble() ?? 0;
    if (discount < 0) {
      throw const InvoiceRepositoryException('لا يمكن إتمام البيع: قيمة الخصم سالبة.');
    }

    if (!isOnlineMode) {
      await _db.completeSale(invoice: invoice, items: items);
      return invoice;
    }

    for (final item in items) {
      _assertServerRecord(item['medicine_id']);
    }
    await _assertOnlineWritable();

    final apiItems = items
        .map((item) => {
              'medicine_id': item['medicine_id'],
              'quantity': item['quantity'],
            })
        .toList();

    final created = await _api.checkout(discount: discount, items: apiItems);
    await _db.upsertInvoiceFromServer(pharmacyId: pharmacyId, serverData: created);

    // البيع الأونلاين يخصم الكميات من المخزون على السيرفر مباشرة؛ نُحدّث
    // كاش المخزون المحلي فوراً كي تعكس شاشة نقطة البيع الكميات الجديدة
    // دون انتظار فتح شاشة المخزون يدوياً.
    await MedicineRepository.instance.getMedicines(
      pharmacyId: pharmacyId,
      isOnlineMode: true,
    );

    return created;
  }

  /// يعكس checkout بالضبط، محلياً أو عبر السيرفر حسب isOnlineMode.
  Future<void> refund({
    required int pharmacyId,
    required bool isOnlineMode,
    required int invoiceId,
  }) async {
    if (!isOnlineMode) {
      await _db.refundInvoice(invoiceId);
      return;
    }

    _assertServerRecord(invoiceId);
    await _assertOnlineWritable();

    final updated = await _api.refundInvoice(invoiceId);
    await _db.upsertInvoiceFromServer(pharmacyId: pharmacyId, serverData: updated);

    await MedicineRepository.instance.getMedicines(
      pharmacyId: pharmacyId,
      isOnlineMode: true,
    );
  }

  /// نفس حماية MedicineRepository._assertServerRecord: لا معرّفات محلية في
  /// طلبات الخادم.
  void _assertServerRecord(Object? id) {
    if (id is int && DatabaseHelper.isLocalId(id)) {
      throw const InvoiceRepositoryException(
        'هذا السجل محلي (أوفلاين) ولم يُرفع إلى الخادم بعد، فلا يمكن استخدامه في وضع الأونلاين.',
      );
    }
  }

  Future<void> _assertOnlineWritable() async {
    if (!await _connectivity.hasConnection()) {
      throw const InvoiceRepositoryException(
        'لا يوجد اتصال بالخادم حالياً. لا يمكن إتمام أو إرجاع أي فاتورة '
        'في وضع الأونلاين بدون اتصال فعلي بالسيرفر.',
      );
    }
  }
}