import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/screens/expenses_screen.dart';
import 'package:pharmacy_app/widgets/stat_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// شاشة المصروفات (أوفلاين): بطاقات الملخص المشتركة (نفس شاشة التوالف)
/// بحجم مختصر ومتساوية الارتفاع، وبلا تجاوز للعرض على أحجام النوافذ الشائعة.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pharmacyId = 1;
  late Directory tempDir;
  final helper = DatabaseHelper.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_expenses_screen_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> seed() async {
    final db = await helper.database;
    await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': '2026-10-01T00:00:00'});
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    for (final (type, amount) in [('إيجار', 250000.0), ('كهرباء', 45000.0), ('رواتب', 1200000.0)]) {
      await db.insert('expense', {
        'id': DatabaseHelper.localIdBase + amount.toInt(),
        'pharmacy_id': pharmacyId,
        'expense_type': type,
        'expense_date': today,
        'amount': amount,
      });
    }
  }

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  for (final size in const [Size(1366, 768), Size(1100, 700), Size(800, 700)]) {
    testWidgets('compact aligned cards and no overflow at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(seed);
      await tester.pumpWidget(const MaterialApp(home: ExpensesScreen(pharmacyId: pharmacyId, isOnlineMode: false)));
      await settleIo(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('1,495,000 د.ع'), findsOneWidget);
      expect(find.text('3 عملية'), findsOneWidget);

      final cards = find.byType(StatCard);
      expect(cards, findsNWidgets(2));
      final first = tester.getRect(cards.at(0));
      final second = tester.getRect(cards.at(1));
      // كانت 150px؛ الآن بحجم بطاقات التوالف، متساوية ومتحاذية في صف واحد.
      expect(first.height, lessThan(90));
      expect(first.height, second.height);
      expect(first.top, second.top);

      await tester.scrollUntilVisible(find.text('تحليل المصروفات حسب النوع'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
