/// فترة التقرير: أيام كاملة شاملة [start, end] بالتوقيت المحلي، والفترة
/// السابقة بنفس الطول مباشرة قبلها، وحجم أعمدة الرسم البياني. نفس الصيغ في
/// pharmacy_data/reports.py (previous_period / bucket_kind / bucket_key).
library;

enum ReportPreset { today, yesterday, last7, thisMonth, lastMonth, thisYear, custom }

const Map<ReportPreset, String> reportPresetLabels = {
  ReportPreset.today: 'اليوم',
  ReportPreset.yesterday: 'أمس',
  ReportPreset.last7: 'آخر 7 أيام',
  ReportPreset.thisMonth: 'هذا الشهر',
  ReportPreset.lastMonth: 'الشهر الماضي',
  ReportPreset.thisYear: 'هذه السنة',
  ReportPreset.custom: 'فترة مخصصة',
};

enum TrendBucket { day, week, month }

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// YYYY-MM-DD.
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime addDays(DateTime d, int days) => DateTime(d.year, d.month, d.day + days);

/// عدد الأيام بين يومين (بالتقويم، لا يتأثر بالتوقيت الصيفي).
int daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

class ReportPeriod {
  final DateTime start;
  final DateTime end;
  final ReportPreset preset;

  ReportPeriod._(DateTime start, DateTime end, this.preset)
      : start = dateOnly(start),
        end = dateOnly(end);

  factory ReportPeriod.custom(DateTime start, DateTime end) {
    final a = dateOnly(start), b = dateOnly(end);
    return b.isBefore(a) ? ReportPeriod._(b, a, ReportPreset.custom) : ReportPeriod._(a, b, ReportPreset.custom);
  }

  factory ReportPeriod.fromPreset(ReportPreset preset, {DateTime? now}) {
    final today = dateOnly(now ?? DateTime.now());
    switch (preset) {
      case ReportPreset.today:
        return ReportPeriod._(today, today, preset);
      case ReportPreset.yesterday:
        final y = addDays(today, -1);
        return ReportPeriod._(y, y, preset);
      case ReportPreset.last7:
        return ReportPeriod._(addDays(today, -6), today, preset);
      case ReportPreset.thisMonth:
        return ReportPeriod._(DateTime(today.year, today.month, 1), today, preset);
      case ReportPreset.lastMonth:
        return ReportPeriod._(
            DateTime(today.year, today.month - 1, 1), DateTime(today.year, today.month, 0), preset);
      case ReportPreset.thisYear:
        return ReportPeriod._(DateTime(today.year, 1, 1), today, preset);
      case ReportPreset.custom:
        // بلا مدى محدد: يبدأ كهذا الشهر حتى يختار المستخدم المدى.
        return ReportPeriod._(DateTime(today.year, today.month, 1), today, preset);
    }
  }

  /// آخر فترة اختارها المالك خلال جلسة التطبيق الحالية (الافتراضي: هذا الشهر).
  static ReportPeriod? _session;

  static ReportPeriod sessionPeriod({DateTime? now}) {
    final saved = _session;
    if (saved == null) return ReportPeriod.fromPreset(ReportPreset.thisMonth, now: now);
    // الفترات الجاهزة تُعاد حسابها لليوم الحالي، والمخصصة تبقى كما هي.
    return saved.preset == ReportPreset.custom ? saved : ReportPeriod.fromPreset(saved.preset, now: now);
  }

  static void remember(ReportPeriod period) => _session = period;

  static void resetSessionForTesting() => _session = null;

  int get days => daysBetween(start, end) + 1;

  String get startKey => dayKey(start);
  String get endKey => dayKey(end);

  /// الفترة السابقة بنفس الطول مباشرة قبل start.
  ReportPeriod get previous {
    final prevEnd = addDays(start, -1);
    return ReportPeriod._(addDays(prevEnd, -(days - 1)), prevEnd, ReportPreset.custom);
  }

  TrendBucket get bucket {
    if (days < 60) return TrendBucket.day;
    if (days <= 180) return TrendBucket.week;
    return TrendBucket.month;
  }

  /// مفتاح العمود الذي يقع فيه [day]: اليوم نفسه، أو بداية كتلة 7 أيام من start،
  /// أو أول الشهر (ولا يسبق start).
  DateTime bucketStart(DateTime day) {
    switch (bucket) {
      case TrendBucket.day:
        return dateOnly(day);
      case TrendBucket.week:
        return addDays(start, (daysBetween(start, day) ~/ 7) * 7);
      case TrendBucket.month:
        final first = DateTime(day.year, day.month, 1);
        return first.isBefore(start) ? start : first;
    }
  }

  List<String> bucketKeys() {
    final keys = <String>[];
    for (var d = start; !d.isAfter(end); d = addDays(d, 1)) {
      final key = dayKey(bucketStart(d));
      if (keys.isEmpty || keys.last != key) keys.add(key);
    }
    return keys;
  }

  /// مفتاح ثابت للكاش.
  String get cacheKey => '$startKey..$endKey';

  @override
  bool operator ==(Object other) =>
      other is ReportPeriod && other.start == start && other.end == end && other.preset == preset;

  @override
  int get hashCode => Object.hash(start, end, preset);
}
