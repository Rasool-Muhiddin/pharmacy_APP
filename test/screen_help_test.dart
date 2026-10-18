import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/help/screen_help_content.dart';
import 'package:pharmacy_app/models/subscription_plan.dart';
import 'package:pharmacy_app/screens/main_layout.dart';
import 'package:pharmacy_app/widgets/app_header.dart';
import 'package:pharmacy_app/widgets/app_sidebar.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// زر "معلومات الشاشة": لكل شاشة في القائمة الجانبية شرح، والزر في الشريط
/// العلوي يفتحه بعنوانه وأقسامه ويُغلق.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final gold = SubscriptionEntitlements.fromLicense(const {'plan': 'gold'});

  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('every sidebar screen (owner, all features) has a help entry', (tester) async {
    bigView(tester);
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: AppSidebar(currentPage: 'الرئيسية', isOwner: true, entitlements: gold, onItemSelected: (_) {}),
        ),
      ),
    ));
    final titles = tester
        .widgetList<Text>(find.descendant(of: find.byType(ListView), matching: find.byType(Text)))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(titles, hasLength(8));
    for (final title in titles) {
      expect(screenHelp.containsKey(title), isTrue, reason: 'لا يوجد شرح لشاشة "$title"');
    }
    expect(screenHelp.keys.toSet(), titles.toSet());
  });

  test('help content is well-formed', () {
    for (final entry in screenHelp.entries) {
      final help = entry.value;
      expect(help.title.trim(), isNotEmpty, reason: entry.key);
      expect(help.summary.trim(), isNotEmpty, reason: entry.key);
      expect(help.points.isNotEmpty || help.sections.isNotEmpty, isTrue, reason: entry.key);
      void check(HelpSection s) {
        expect(s.title.trim(), isNotEmpty);
        expect(s.intro != null || s.points.isNotEmpty || s.children.isNotEmpty, isTrue, reason: s.title);
        s.children.forEach(check);
      }

      help.sections.forEach(check);
    }
    // الأولوية: التقارير والمخزن (قائمة المذخر) والمذاخر مفصّلة بأقسام فرعية.
    expect(screenHelp['التقارير والتحليلات']!.sections.length, greaterThanOrEqualTo(8));
    expect(screenHelp['المخزن والأدوية']!.sections.any((s) => s.children.length >= 5), isTrue);
    expect(screenHelp['المذاخر والمشتريات']!.sections.any((s) => s.children.isNotEmpty), isTrue);
  });

  for (final entry in screenHelp.entries) {
    testWidgets('header info button opens help for "${entry.key}"', (tester) async {
      bigView(tester);
      await tester.pumpWidget(MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(body: AppHeader(pharmacyName: 'صيدلية الشفاء', pageTitle: entry.key, help: entry.value)),
        ),
      ));
      final button = find.byKey(const Key('screen-help-button'));
      expect(button, findsOneWidget);
      expect(find.byTooltip('معلومات الشاشة'), findsOneWidget);
      // أقصى اليسار في الصف (RTL).
      expect(tester.getCenter(button).dx, lessThan(200));

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('screen-help-title')), findsOneWidget);
      expect(find.text(entry.value.title), findsWidgets);
      expect(find.text(entry.value.summary), findsOneWidget);

      if (entry.value.sections.isNotEmpty) {
        final first = entry.value.sections.first;
        await tester.tap(find.text(first.title));
        await tester.pumpAndSettle();
        final firstLine = first.intro ?? (first.points.isNotEmpty ? first.points.first : first.children.first.title);
        expect(find.text(firstLine), findsOneWidget);
      }
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('screen-help-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('screen-help-title')), findsNothing);
    });
  }

  testWidgets('long help scrolls without overflow in a small window, all sections expanded', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final help = screenHelp['التقارير والتحليلات']!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppHeader(pharmacyName: 'ص', pageTitle: 'التقارير', help: help)),
    ));
    await tester.tap(find.byKey(const Key('screen-help-button')));
    await tester.pumpAndSettle();
    for (final section in help.sections) {
      final title = find.text(section.title);
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      await tester.tap(title);
      await tester.pumpAndSettle();
    }
    expect(find.text(help.sections.last.points.last), findsOneWidget);
    expect(tester.takeException(), isNull);
    // زر الإغلاق ثابت أسفل النافذة ويبقى ظاهراً.
    expect(tester.getRect(find.byKey(const Key('screen-help-close'))).bottom, lessThanOrEqualTo(600));
  });

  testWidgets('header without help shows no info button', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AppHeader(pharmacyName: 'x', pageTitle: 'y'))));
    expect(find.byKey(const Key('screen-help-button')), findsNothing);
  });

  group('MainLayout', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pharmacy_screen_help_test');
      DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
      await DatabaseHelper.resetForTesting();
    });

    tearDown(() async {
      await DatabaseHelper.resetForTesting();
      await tempDir.delete(recursive: true);
    });

    Future<void> settleIo(WidgetTester tester) async {
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('the info button follows the current screen', (tester) async {
      bigView(tester);
      await tester.runAsync(() async {
        final db = await DatabaseHelper.instance.database;
        await db.insert('pharmacy_branch', {'id': 1, 'name': 'صيدلية الشفاء', 'created_at': '2026-10-01T00:00:00'});
      });
      await tester.pumpWidget(MaterialApp(home: MainLayout(pharmacyId: 1, entitlements: gold)));
      await settleIo(tester);

      Future<void> expectHelpFor(String page) async {
        await tester.tap(find.byKey(const Key('screen-help-button')));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(find.byKey(const Key('screen-help-title'))).data, screenHelp[page]!.title);
        await tester.tap(find.byKey(const Key('screen-help-close')));
        await tester.pumpAndSettle();
      }

      await expectHelpFor('الرئيسية');
      await tester.tap(find.text('المصروفات'));
      await settleIo(tester);
      await expectHelpFor('المصروفات');
    });
  });
}
