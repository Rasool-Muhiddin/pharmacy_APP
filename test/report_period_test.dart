import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/models/report_period.dart';

void main() {
  final now = DateTime(2026, 10, 7, 15, 30);

  tearDown(ReportPeriod.resetSessionForTesting);

  test('presets resolve to inclusive day ranges', () {
    String range(ReportPreset p) {
      final period = ReportPeriod.fromPreset(p, now: now);
      return '${period.startKey}..${period.endKey}';
    }

    expect(range(ReportPreset.today), '2026-10-07..2026-10-07');
    expect(range(ReportPreset.yesterday), '2026-10-06..2026-10-06');
    expect(range(ReportPreset.last7), '2026-10-01..2026-10-07');
    expect(range(ReportPreset.thisMonth), '2026-10-01..2026-10-07');
    expect(range(ReportPreset.lastMonth), '2026-09-01..2026-09-30');
    expect(range(ReportPreset.thisYear), '2026-01-01..2026-10-07');
    expect(ReportPeriod.fromPreset(ReportPreset.lastMonth, now: DateTime(2026, 1, 15)).startKey, '2025-12-01');
  });

  test('previous period has the same length, immediately before', () {
    final month = ReportPeriod.fromPreset(ReportPreset.thisMonth, now: now); // 7 أيام
    expect(month.days, 7);
    expect('${month.previous.startKey}..${month.previous.endKey}', '2026-09-24..2026-09-30');
    final today = ReportPeriod.fromPreset(ReportPreset.today, now: now);
    expect(today.previous.startKey, '2026-10-06');
    expect(today.previous.days, 1);
  });

  test('bucket size: daily < 60 days, weekly up to 180, monthly beyond', () {
    final d = ReportPeriod.custom(DateTime(2026, 8, 9), DateTime(2026, 10, 6)); // 59 يوماً
    expect(d.bucket, TrendBucket.day);
    expect(d.bucketKeys(), hasLength(59));

    final w = ReportPeriod.custom(DateTime(2026, 7, 10), DateTime(2026, 10, 7)); // 90 يوماً
    expect(w.bucket, TrendBucket.week);
    expect(w.bucketKeys(), hasLength(13));
    expect(w.bucketKeys().first, '2026-07-10');
    expect(w.bucketKeys()[1], '2026-07-17');

    final m = ReportPeriod.fromPreset(ReportPreset.thisYear, now: now);
    expect(m.bucket, TrendBucket.month);
    expect(m.bucketKeys(), hasLength(10));
    final partial = ReportPeriod.custom(DateTime(2025, 10, 15), DateTime(2026, 10, 7));
    expect(partial.bucketKeys().first, '2025-10-15'); // أول شهر جزئي يبدأ من start
    expect(partial.bucketKeys()[1], '2025-11-01');
  });

  test('session remembers the last preset; default is this month', () {
    expect(ReportPeriod.sessionPeriod(now: now).preset, ReportPreset.thisMonth);
    ReportPeriod.remember(ReportPeriod.fromPreset(ReportPreset.last7, now: now));
    // يُعاد حسابه لليوم الحالي.
    expect(ReportPeriod.sessionPeriod(now: DateTime(2026, 10, 9)).startKey, '2026-10-03');
    final custom = ReportPeriod.custom(DateTime(2026, 2, 1), DateTime(2026, 2, 10));
    ReportPeriod.remember(custom);
    expect(ReportPeriod.sessionPeriod(now: DateTime(2026, 10, 9)), custom);
  });

  test('custom range is normalised to dates in order', () {
    final p = ReportPeriod.custom(DateTime(2026, 3, 5, 18), DateTime(2026, 3, 1, 9));
    expect(p.startKey, '2026-03-01');
    expect(p.endKey, '2026-03-05');
    expect(p.days, 5);
  });
}
