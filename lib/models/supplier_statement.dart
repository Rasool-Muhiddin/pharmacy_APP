import '../utils/formatters.dart';

/// كشف حساب المذخر بالطريقة المحاسبية المعتادة (Vendor statement): رصيد
/// افتتاحي، حركات مرتبة زمنياً بعمودَي "يزيد الدين" و"ينقص الدين" ورصيد جارٍ،
/// ثم رصيد ختامي وأعمار الديون. يُبنى من صفوف كشف الحساب الخام نفسها في
/// الوضعين (db_helper محلياً، `/api/suppliers/<id>/statement/` على الخادم).
///
/// الرصيد الموجب = دين على الصيدلية ("عليك")، السالب = رصيد لصالحها ("لك").
/// مجموع الحركات = رصيد المذخر في supplier_ledger (نفس الصيغة محلياً وعلى الخادم).

enum StatementEntryType { invoice, payment, purchaseReturn, creditApplied, refund }

const Map<StatementEntryType, String> statementTypeLabels = {
  StatementEntryType.invoice: 'فاتورة شراء',
  StatementEntryType.payment: 'دفعة',
  StatementEntryType.purchaseReturn: 'استرجاع',
  StatementEntryType.creditApplied: 'خصم من رصيد سابق',
  StatementEntryType.refund: 'استلام أموال',
};

/// ترتيب الحركات ذات اللحظة نفسها: الفاتورة قبل خصم الرصيد عليها ثم دفعتها
/// "المدفوعة الآن"، ثم الاسترجاع والاستلام.
const Map<StatementEntryType, int> _sameMomentRank = {
  StatementEntryType.invoice: 0,
  StatementEntryType.creditApplied: 1,
  StatementEntryType.payment: 2,
  StatementEntryType.purchaseReturn: 3,
  StatementEntryType.refund: 4,
};

double _num(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0;
}

/// لحظة الحركة بالتوقيت المحلي (الخادم يرسل UTC، المحلي بلا منطقة زمنية).
DateTime? statementMoment(Object? raw) => DateTime.tryParse(raw?.toString() ?? '')?.toLocal();

String statementAmount(double v) => AppFormatter.iqd(v.round());

/// الرصيد بكلمة دائماً: "عليك X" / "لك X" / "مسدد".
String balanceWords(double balance) {
  if (balance > 0.001) return 'عليك ${statementAmount(balance)}';
  if (balance < -0.001) return 'لك ${statementAmount(-balance)}';
  return 'مسدد';
}

class StatementEntry {
  StatementEntry({
    required this.type,
    required this.at,
    required this.id,
    required this.invoiceId,
    required this.invoiceNumber,
    required this.increase,
    required this.decrease,
    this.infoAmount = 0,
    this.itemCount = 0,
    this.items = const [],
    this.synthetic = false,
  });

  final StatementEntryType type;
  final DateTime at;
  final Object? id;
  final int? invoiceId;

  /// رقم الفاتورة المرتبطة (أو "#المعرّف" لفاتورة بلا رقم)؛ null لحركة غير مرتبطة.
  final String? invoiceNumber;

  /// يزيد الدين (+): فاتورة شراء، أموال مستلمة من المذخر.
  final double increase;

  /// ينقص الدين (−): دفعة، استرجاع.
  final double decrease;

  /// مبلغ "خصم من رصيد سابق": معلومة فقط، بلا أثر على الرصيد.
  final double infoAmount;
  final int itemCount;

  /// أصناف الاسترجاع (فارغة للاسترجاع القديم بالمبلغ).
  final List<Map<String, dynamic>> items;

  /// دفعة عند إدخال فاتورة قديمة بلا سطر دفعة (paid_amount غير مرتبط بدفعات).
  final bool synthetic;

  /// الرصيد بعد الحركة.
  double balance = 0;

  String get typeLabel => statementTypeLabels[type]!;

  String get description {
    final number = invoiceNumber;
    switch (type) {
      case StatementEntryType.invoice:
        return itemCount > 0 ? 'فاتورة شراء رقم $number — $itemCount صنف' : 'فاتورة شراء رقم $number';
      case StatementEntryType.payment:
        if (synthetic) return 'دفعة عند إدخال فاتورة رقم $number';
        return number == null ? 'دفعة للمذخر' : 'دفعة على فاتورة رقم $number';
      case StatementEntryType.purchaseReturn:
        final base = number == null ? 'استرجاع أصناف' : 'استرجاع أصناف من فاتورة رقم $number';
        return items.isEmpty ? base : '$base (${items.length} صنف)';
      case StatementEntryType.creditApplied:
        final target = number == null ? '' : ' على فاتورة رقم $number';
        return 'خصم من رصيد سابق$target: ${statementAmount(infoAmount)} د.ع';
      case StatementEntryType.refund:
        return 'استلام أموال من المذخر';
    }
  }

  /// أسطر أصناف الاسترجاع كما تظهر تحت سطره.
  List<String> get itemLines => [
        for (final item in items)
          '${item['trade_name']} × ${_num(item['quantity']).toInt()}'
              '${_num(item['credited_quantity']) < _num(item['quantity']) ? ' (${(_num(item['quantity']) - _num(item['credited_quantity'])).toInt()} بلا رصيد)' : ''}'
              ' — ${statementAmount(_num(item['credit_amount']))} د.ع',
      ];
}

StatementEntryType? _typeOf(Object? raw) => switch (raw) {
      'invoice' => StatementEntryType.invoice,
      'payment' => StatementEntryType.payment,
      'return' => StatementEntryType.purchaseReturn,
      'credit_applied' => StatementEntryType.creditApplied,
      'refund' => StatementEntryType.refund,
      _ => null,
    };

String? _invoiceLabel(Object? number, Object? id) {
  final text = number?.toString().trim() ?? '';
  if (text.isNotEmpty) return text;
  return id == null ? null : '#$id';
}

/// كل الحركات بالترتيب الزمني الحقيقي مع الرصيد الجاري من صفر. الحركة
/// المرتبطة بفاتورة لا تسبق فاتورتها أبداً (استرجاع بتاريخ سابق يُعرض بعدها)،
/// فلا يظهر رصيد وسيط لم يوجد فعلاً.
List<StatementEntry> statementEntries(List<Map<String, dynamic>> rows) {
  final entries = <StatementEntry>[];
  for (final row in rows) {
    final type = _typeOf(row['transaction_type']);
    var at = statementMoment(row['date_time']);
    if (type == null || at == null) continue;
    final amount = _num(row['amount']);
    final debtAdded = _num(row['debt_added']);
    final isInvoice = type == StatementEntryType.invoice;
    final invoiceId = isInvoice ? (row['purchase_invoice_id'] ?? row['id']) : row['purchase_invoice_id'];
    final invoiceIdInt = invoiceId is int ? invoiceId : int.tryParse(invoiceId?.toString() ?? '');
    final number = isInvoice
        ? _invoiceLabel(
            row.containsKey('invoice_number')
                ? row['invoice_number']
                : (row['reference']?.toString().contains('بدون رقم') ?? true ? null : row['reference']),
            row['id'])
        : _invoiceLabel(row['invoice_number'], invoiceIdInt);
    final invoiceAt = statementMoment(row['invoice_created_at']);
    if (!isInvoice && invoiceAt != null && at.isBefore(invoiceAt)) at = invoiceAt;

    switch (type) {
      case StatementEntryType.invoice:
        // الإجمالي في "يزيد الدين"، وما دُفع عند الإدخال بلا سطر دفعة (فواتير
        // يدوية قديمة) دفعةٌ مستقلة؛ خادم أقدم بلا total_amount: debt_added كما هو.
        final total = row.containsKey('total_amount') ? _num(row['total_amount']) : debtAdded;
        entries.add(StatementEntry(
          type: type,
          at: at,
          id: row['id'],
          invoiceId: invoiceIdInt,
          invoiceNumber: number,
          increase: total,
          decrease: 0,
          itemCount: _num(row['item_count']).toInt(),
        ));
        final unlinkedPaid = total - debtAdded;
        if (unlinkedPaid > 0.001) {
          entries.add(StatementEntry(
            type: StatementEntryType.payment,
            at: at,
            id: row['id'],
            invoiceId: invoiceIdInt,
            invoiceNumber: number,
            increase: 0,
            decrease: unlinkedPaid,
            synthetic: true,
          ));
        }
      case StatementEntryType.payment:
      case StatementEntryType.purchaseReturn:
        entries.add(StatementEntry(
          type: type,
          at: at,
          id: row['id'],
          invoiceId: invoiceIdInt,
          invoiceNumber: invoiceIdInt == null ? null : number,
          increase: 0,
          decrease: -debtAdded,
          items: row['items'] is List
              ? (row['items'] as List).whereType<Map>().map((i) => Map<String, dynamic>.from(i)).toList()
              : const [],
        ));
      case StatementEntryType.creditApplied:
        entries.add(StatementEntry(
          type: type,
          at: at,
          id: row['id'],
          invoiceId: invoiceIdInt,
          invoiceNumber: invoiceIdInt == null ? null : number,
          increase: 0,
          decrease: 0,
          infoAmount: amount,
        ));
      case StatementEntryType.refund:
        entries.add(StatementEntry(
          type: type,
          at: at,
          id: row['id'],
          invoiceId: null,
          invoiceNumber: null,
          increase: debtAdded,
          decrease: 0,
        ));
    }
  }

  int idOf(Object? id) => id is int ? id : int.tryParse(id?.toString() ?? '') ?? 0;
  entries.sort((a, b) {
    final byTime = a.at.compareTo(b.at);
    if (byTime != 0) return byTime;
    final byInvoice = (a.invoiceId ?? 1 << 62).compareTo(b.invoiceId ?? 1 << 62);
    if (byInvoice != 0) return byInvoice;
    final byRank = _sameMomentRank[a.type]!.compareTo(_sameMomentRank[b.type]!);
    if (byRank != 0) return byRank;
    return idOf(a.id).compareTo(idOf(b.id));
  });

  var running = 0.0;
  for (final e in entries) {
    running += e.increase - e.decrease;
    e.balance = running;
  }
  return entries;
}

enum StatementPreset { all, thisMonth, last3Months, thisYear, custom }

const Map<StatementPreset, String> statementPresetLabels = {
  StatementPreset.all: 'الكل',
  StatementPreset.thisMonth: 'هذا الشهر',
  StatementPreset.last3Months: 'آخر 3 أشهر',
  StatementPreset.thisYear: 'هذه السنة',
  StatementPreset.custom: 'فترة مخصصة',
};

/// فترة الكشف: [start] و[end] أيام كاملة (null = بلا حد).
class StatementPeriod {
  const StatementPeriod._(this.preset, this.start, this.end);

  const StatementPeriod.all() : this._(StatementPreset.all, null, null);

  factory StatementPeriod.custom(DateTime start, DateTime end) =>
      StatementPeriod._(StatementPreset.custom, _day(start), _day(end));

  /// "آخر 3 أشهر" = الشهر الحالي والشهران السابقان كاملين.
  factory StatementPeriod.fromPreset(StatementPreset preset, {DateTime? now}) {
    final today = _day(now ?? DateTime.now());
    switch (preset) {
      case StatementPreset.all:
      case StatementPreset.custom:
        return const StatementPeriod.all();
      case StatementPreset.thisMonth:
        return StatementPeriod._(preset, DateTime(today.year, today.month), today);
      case StatementPreset.last3Months:
        return StatementPeriod._(preset, DateTime(today.year, today.month - 2), today);
      case StatementPreset.thisYear:
        return StatementPeriod._(preset, DateTime(today.year), today);
    }
  }

  final StatementPreset preset;
  final DateTime? start;
  final DateTime? end;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  bool get isAll => start == null && end == null;

  /// نهاية الفترة الحصرية (بداية اليوم التالي لـ [end]).
  DateTime? get endExclusive => end == null ? null : DateTime(end!.year, end!.month, end!.day + 1);

  String get label {
    if (isAll) return 'كل الحركات';
    String f(DateTime d) => '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
    return 'من ${start == null ? 'البداية' : f(start!)} إلى ${end == null ? 'اليوم' : f(end!)}';
  }
}

class SupplierStatement {
  SupplierStatement({
    required this.period,
    required this.opening,
    required this.showOpening,
    required this.entries,
  });

  final StatementPeriod period;

  /// الرصيد قبل بداية الفترة.
  final double opening;

  /// يُخفى الرصيد الافتتاحي في "الكل" (لا شيء قبلها).
  final bool showOpening;
  final List<StatementEntry> entries;

  double get totalIncrease => entries.fold(0.0, (s, e) => s + e.increase);
  double get totalDecrease => entries.fold(0.0, (s, e) => s + e.decrease);

  /// الرصيد الافتتاحي + الحركات = الرصيد الختامي.
  double get closing => opening + totalIncrease - totalDecrease;
}

SupplierStatement buildSupplierStatement(List<Map<String, dynamic>> rows, StatementPeriod period) {
  final all = statementEntries(rows);
  final start = period.start;
  final endExclusive = period.endExclusive;
  var opening = 0.0;
  var hasEarlier = false;
  final inPeriod = <StatementEntry>[];
  for (final e in all) {
    if (start != null && e.at.isBefore(start)) {
      opening = e.balance;
      hasEarlier = true;
    } else if (endExclusive == null || e.at.isBefore(endExclusive)) {
      inPeriod.add(e);
    }
  }
  return SupplierStatement(
    period: period,
    opening: opening,
    showOpening: !period.isAll || hasEarlier,
    entries: inPeriod,
  );
}

/// أعمار الديون: متبقي الفواتير المفتوحة حسب عمرها من تاريخ الفاتورة.
class AgingBucket {
  AgingBucket(this.label);

  final String label;
  double amount = 0;
  int count = 0;
}

List<AgingBucket> computeAging(List<Map<String, dynamic>> invoices, {DateTime? today}) {
  final now = today ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final buckets = [
    AgingBucket('0–30 يوم'),
    AgingBucket('31–60 يوم'),
    AgingBucket('61–90 يوم'),
    AgingBucket('أكثر من 90 يوم'),
  ];
  for (final invoice in invoices) {
    final remaining = _num(invoice['remaining_amount']);
    if (remaining <= 0.001) continue;
    final rawDate = (invoice['invoice_date']?.toString().isNotEmpty ?? false)
        ? invoice['invoice_date']
        : invoice['created_at'];
    final date = statementMoment(rawDate);
    final age = date == null ? 0 : day.difference(DateTime(date.year, date.month, date.day)).inDays;
    final bucket = age <= 30
        ? buckets[0]
        : age <= 60
            ? buckets[1]
            : age <= 90
                ? buckets[2]
                : buckets[3];
    bucket.amount += remaining;
    bucket.count++;
  }
  return buckets;
}
