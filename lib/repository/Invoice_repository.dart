import '../database/db_helper.dart';
import '../services/connectivity_service.dart';
import '../services/invoice_api_service.dart';
import 'medicine_repository.dart';

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

  Future<List<Map<String, dynamic>>> getInvoices({
    required int pharmacyId,
    required bool isOnlineMode,
  }) async {
    if (!isOnlineMode) {
      return _db.getInvoices(pharmacyId);
    }

    if (!await _connectivity.hasConnection()) {
      // بلا اتصال فعلي الآن: نعرض آخر نسخة مزامَنة محفوظة في الكاش المحلي
      // بدل شاشة فارغة، لكن هذا قراءة فقط — البيع والإرجاع يبقيان ممنوعين
      // (انظر checkout/refund أدناه).
      return _db.getInvoices(pharmacyId);
    }

    final serverItems = await _api.fetchInvoices();
    await _db.replaceInvoicesCache(
      pharmacyId: pharmacyId,
      serverItems: serverItems,
    );
    return _db.getInvoices(pharmacyId);
  }

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
    if (!isOnlineMode) {
      await _db.completeSale(invoice: invoice, items: items);
      return invoice;
    }

    await _assertOnlineWritable();

    final discount = (invoice['discount'] as num).toDouble();
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

    await _assertOnlineWritable();

    final updated = await _api.refundInvoice(invoiceId);
    await _db.upsertInvoiceFromServer(pharmacyId: pharmacyId, serverData: updated);

    await MedicineRepository.instance.getMedicines(
      pharmacyId: pharmacyId,
      isOnlineMode: true,
    );
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