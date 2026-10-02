import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/models/license_expiry.dart';
import 'package:pharmacy_app/widgets/license_expiry_banner.dart';

/// ترخيص Basic أوفلاين كما يعيده الخادم (license_payload) ويحفظه الجهاز.
Map<String, dynamic> basicOfflineLicense(String? expiresAt) => {
      'type': 'annual',
      'mode': 'offline',
      'plan': 'basic',
      'max_warehouses': 1,
      'status': 'active',
      'expires_at': expiresAt,
      'max_devices': 1,
    };

void main() {
  // منتصف النهار محلياً لتفادي حواف منتصف الليل.
  final now = DateTime(2026, 10, 2, 12);
  String inDays(int days, {int hour = 12}) =>
      DateTime(2026, 10, 2 + days, hour).toUtc().toIso8601String();

  group('LicenseExpiry', () {
    test('reads expires_at from a Basic offline license (server ISO format with offset)', () {
      final expiry = LicenseExpiry.fromLicense(basicOfflineLicense('2026-10-12T09:00:00+00:00'));
      expect(expiry.expiresAt, DateTime.utc(2026, 10, 12, 9).toLocal());
    });

    test('annual/trial without a usable expires_at are invalid like the server (expires_at is None), no warning', () {
      for (final type in ['annual', 'trial']) {
        for (final value in [null, '', 'not-a-date']) {
          final expiry = LicenseExpiry.fromLicense({...basicOfflineLicense(value), 'type': type});
          expect(expiry.isExpired(now), isTrue, reason: '$type $value');
          expect(expiry.daysRemaining(now), isNull, reason: '$type $value');
          expect(expiry.shouldWarn(now), isFalse, reason: '$type $value');
        }
      }
      // بلا type إطلاقاً: ليس lifetime، فيحتاج تاريخاً كما في الخادم.
      expect(LicenseExpiry.fromLicense({'status': 'active'}).isExpired(now), isTrue);
    });

    test('warns at 10 days or less, not at 11', () {
      expect(LicenseExpiry.fromLicense(basicOfflineLicense(inDays(11))).shouldWarn(now), isFalse);
      for (final days in [10, 5, 1]) {
        final expiry = LicenseExpiry.fromLicense(basicOfflineLicense(inDays(days)));
        expect(expiry.daysRemaining(now), days);
        expect(expiry.shouldWarn(now), isTrue, reason: '$days');
      }
    });

    test('counts calendar days: later today is 0, an early-morning expiry 10 days out still warns', () {
      expect(LicenseExpiry.fromLicense(basicOfflineLicense(inDays(0, hour: 23))).daysRemaining(now), 0);
      expect(LicenseExpiry.fromLicense(basicOfflineLicense(inDays(10, hour: 1))).daysRemaining(now), 10);
      expect(LicenseExpiry.fromLicense(basicOfflineLicense(inDays(11, hour: 1))).shouldWarn(now), isFalse);
    });

    test('once expired the warning stops (the existing lockout takes over)', () {
      final expiry = LicenseExpiry.fromLicense(basicOfflineLicense(inDays(0, hour: 11)));
      expect(expiry.daysRemaining(now), isNull);
      expect(expiry.shouldWarn(now), isFalse);
    });

    test('lifetime licenses never expire and never warn, whatever expires_at says (matches server is_valid)', () {
      for (final value in [inDays(-400), inDays(-1), inDays(0, hour: 23), inDays(3), null]) {
        final expiry = LicenseExpiry.fromLicense({...basicOfflineLicense(value), 'type': 'lifetime'});
        expect(expiry.expiresAt, isNull, reason: '$value');
        expect(expiry.isExpired(now), isFalse, reason: '$value');
        expect(expiry.shouldWarn(now), isFalse, reason: '$value');
      }
    });

    test('annual and trial: valid while now <= expires_at, expired right after (server: expires_at >= now)', () {
      final end = DateTime.utc(2026, 10, 5, 9);
      for (final type in ['annual', 'trial']) {
        final expiry = LicenseExpiry.fromLicense({...basicOfflineLicense(end.toIso8601String()), 'type': type});
        expect(expiry.isExpired(end.subtract(const Duration(days: 1))), isFalse, reason: type);
        expect(expiry.isExpired(end), isFalse, reason: '$type at the exact instant');
        expect(expiry.isExpired(end.add(const Duration(seconds: 1))), isTrue, reason: type);
        expect(expiry.shouldWarn(end.subtract(const Duration(days: 3))), isTrue, reason: type);
      }
    });

    test('the none() default (no known license) never expires', () {
      expect(const LicenseExpiry.none().isExpired(now), isFalse);
      expect(const LicenseExpiry.none().shouldWarn(now), isFalse);
    });

    test('renewal (a later expires_at saved by the next online login) clears the warning', () {
      expect(LicenseExpiry.fromLicense(basicOfflineLicense(inDays(3))).shouldWarn(now), isTrue);
      expect(LicenseExpiry.fromLicense(basicOfflineLicense(inDays(368))).shouldWarn(now), isFalse);
    });
  });

  group('LicenseExpiryBanner', () {
    Future<void> pumpBanner(WidgetTester tester, LicenseExpiry expiry, DateTime Function() clock) {
      return tester.pumpWidget(MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Column(children: [
              LicenseExpiryBanner(expiry: expiry, clock: clock),
              const Expanded(child: Center(child: Text('content'))),
            ]),
          ),
        ),
      ));
    }

    final banner = find.byKey(const ValueKey('license-expiry-banner'));

    testWidgets('shows days remaining, date and contact-support text without blocking content', (tester) async {
      final expiry = LicenseExpiry.fromLicense(basicOfflineLicense(inDays(7)));
      await pumpBanner(tester, expiry, () => now);

      expect(banner, findsOneWidget);
      expect(find.textContaining('ينتهي خلال 7 أيام'), findsOneWidget);
      expect(find.textContaining('2026-10-09'), findsOneWidget);
      expect(find.textContaining('التواصل مع الدعم الفني لتجديده'), findsOneWidget);
      expect(find.text('content'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing); // لا زر إغلاق
      await tester.pumpWidget(const SizedBox()); // يلغي المؤقت
    });

    testWidgets('wording for 2 days, tomorrow and today', (tester) async {
      for (final entry in {2: 'ينتهي خلال يومين', 1: 'ينتهي غداً', 0: 'ينتهي اليوم'}.entries) {
        await pumpBanner(tester, LicenseExpiry.fromLicense(basicOfflineLicense(inDays(entry.key, hour: 23))), () => now);
        expect(find.textContaining(entry.value), findsOneWidget, reason: '${entry.key}');
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('hidden when more than 10 days remain or there is no expiry', (tester) async {
      await pumpBanner(tester, LicenseExpiry.fromLicense(basicOfflineLicense(inDays(30))), () => now);
      expect(banner, findsNothing);
      await pumpBanner(tester, const LicenseExpiry.none(), () => now);
      expect(banner, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('appears, counts down and disappears on expiry while the app stays open', (tester) async {
      var current = now;
      final expiry = LicenseExpiry(DateTime(2026, 10, 13, 18)); // 11 يوماً
      await pumpBanner(tester, expiry, () => current);
      expect(banner, findsNothing);

      current = DateTime(2026, 10, 3, 9);
      await tester.pump(const Duration(minutes: 15));
      expect(find.textContaining('ينتهي خلال 10 أيام'), findsOneWidget);

      current = DateTime(2026, 10, 13, 17);
      await tester.pump(const Duration(minutes: 15));
      expect(find.textContaining('ينتهي اليوم'), findsOneWidget);

      current = DateTime(2026, 10, 13, 19);
      await tester.pump(const Duration(minutes: 15));
      expect(banner, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
