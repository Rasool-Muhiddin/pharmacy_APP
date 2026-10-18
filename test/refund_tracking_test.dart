import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/repository/Invoice_repository.dart';
import 'package:pharmacy_app/screens/sales_history_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// من أرجع الفاتورة ومتى: refunded_by/refunded_by_name/refunded_at — التسجيل
/// أوفلاين، كاش فواتير الخادم، الرفع الأولي، إضافة الأعمدة لقاعدة قائمة بلا
/// رفع رقم نسختها، والعرض في تفاصيل الفاتورة بسجل المبيعات.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pharmacyId = 1;
  const base = DatabaseHelper.localIdBase;
  late Directory tempDir;
  final helper = DatabaseHelper.instance;
  final repo = InvoiceRepository.instance;
  const refundColumns = ['refunded_by', 'refunded_by_name', 'refunded_at'];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_refund_tracking_test');
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
    await db.insert('users', {'id': 5, 'username': 'sara', 'password': '', 'full_name': 'Sara'});
    await db.insert('user_profile', {'id': 5, 'user_id': 5, 'pharmacy_id': pharmacyId, 'is_owner': 0});
    await db.insert('warehouses', {'id': base, 'pharmacy_id': pharmacyId, 'name': 'Main', 'is_main': 1, 'created_at': '2026-10-01T00:00:00'});
    await db.insert('medicine', {'id': base, 'pharmacy_id': pharmacyId, 'warehouse_id': base, 'trade_name': 'Med', 'quantity': 10});
    for (var n = 1; n <= 3; n++) {
      await db.insert('invoice', {
        'id': base + n,
        'pharmacy_id': pharmacyId,
        'invoice_number': 'INV-00000$n',
        'cashier_id': 5,
        'total_amount': 1000,
        'final_amount': 1000,
        'created_at': '2026-10-0${n}T10:00:00',
      });
      await db.insert('invoice_item', {
        'invoice_id': base + n,
        'medicine_id': base,
        'trade_name': 'Med',
        'quantity': 1,
        'unit_price': 1000,
        'total_price': 1000,
      });
    }
  }

  Future<Map<String, dynamic>> invoice(int n) async =>
      (await helper.queryInvoices(pharmacyId, ids: [base + n])).single;

  test('offline refund records who refunded and when', () async {
    await seed();
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    await repo.refund(pharmacyId: pharmacyId, isOnlineMode: false, invoiceId: base + 1, userId: 5);
    final row = await invoice(1);
    expect(row['is_refunded'], 1);
    expect(row['refunded_by'], 5);
    expect(row['refunded_by_display'], 'Sara');
    expect(DateTime.parse(row['refunded_at'] as String).isAfter(before), isTrue);
    expect(SalesHistoryScreen.refundInfoText(row), startsWith('تم الإرجاع بواسطة: Sara  •  بتاريخ: '));
  });

  test('unknown user still refunds and keeps the time', () async {
    await seed();
    await repo.refund(pharmacyId: pharmacyId, isOnlineMode: false, invoiceId: base + 2, userId: 999);
    final row = await invoice(2);
    expect(row['is_refunded'], 1);
    expect(row['refunded_by'], isNull);
    expect(row['refunded_at'], isNotNull);
    expect(SalesHistoryScreen.refundInfoText(row), contains('بواسطة: غير معروف'));
  });

  test('refund recorded before tracking shows a clear note', () async {
    await seed();
    final db = await helper.database;
    await db.update('invoice', {'is_refunded': 1}, where: 'id = ?', whereArgs: [base + 3]);
    expect(SalesHistoryScreen.refundInfoText(await invoice(3)), 'تم الإرجاع (قبل تسجيل المنفّذ)');
  });

  test('server invoices keep the server name and time', () async {
    await seed();
    helper.setSessionMode(isOnline: true);
    await helper.upsertInvoiceFromServer(pharmacyId: pharmacyId, serverData: {
      'id': 77,
      'invoice_number': 'INV-000077',
      'cashier_display_name': 'Ali',
      'total_amount': '500.00',
      'discount': '0.00',
      'final_amount': '500.00',
      'created_at': '2026-10-05T09:00:00+03:00',
      'is_refunded': true,
      'refunded_at': '2026-10-06T11:30:00+03:00',
      'refunded_by_display': 'Omar',
      'items': const [],
    });
    final row = (await helper.queryInvoices(pharmacyId, ids: [77])).single;
    expect(row['refunded_by'], isNull);
    expect(row['refunded_by_display'], 'Omar');
    expect(row['refunded_at'], '2026-10-06T11:30:00+03:00');
  });

  test('offline upload carries the refund name and time', () async {
    await seed();
    await repo.refund(pharmacyId: pharmacyId, isOnlineMode: false, invoiceId: base + 1, userId: 5);
    final payload = await helper.getOfflineMigrationPayload(pharmacyId);
    final invoices = (payload['invoices'] as List).cast<Map<String, dynamic>>();
    final refunded = invoices.singleWhere((i) => i['invoice_number'] == 'INV-000001');
    expect(refunded['is_refunded'], isTrue);
    expect(refunded['refunded_by_name'], 'Sara');
    expect(refunded['refunded_at'], isNotNull);
    final notRefunded = invoices.singleWhere((i) => i['invoice_number'] == 'INV-000002');
    expect(notRefunded['refunded_by_name'], '');
    expect(notRefunded['refunded_at'], isNull);
  });

  test('an existing database without the columns gets them on open (no version bump)', () async {
    final db = await helper.database;
    final version = await db.getVersion();
    for (final column in refundColumns) {
      await db.execute('ALTER TABLE invoice DROP COLUMN $column');
    }
    Future<Set<String>> columns(Database d) async =>
        {for (final r in await d.rawQuery('PRAGMA table_info(invoice)')) r['name'] as String};
    expect((await columns(db)).intersection(refundColumns.toSet()), isEmpty);

    await DatabaseHelper.resetForTesting(); // يغلق القاعدة؛ الملف يبقى.
    final reopened = await helper.database;
    expect(await columns(reopened), containsAll(refundColumns));
    expect(await reopened.getVersion(), version);

    // الفتح مرة ثالثة لا يضيف شيئاً ولا يفشل.
    await DatabaseHelper.resetForTesting();
    expect(await columns(await helper.database), containsAll(refundColumns));
  });

  testWidgets('Sales History invoice details show who refunded and when', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(seed);
    await tester.pumpWidget(const MaterialApp(
      home: SalesHistoryScreen(pharmacyId: pharmacyId, userId: 5),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await settle();
    // إرجاع من نافذة التفاصيل نفسها (المستخدم الحالي Sara).
    final detailsButtons = find.text('تفاصيل الفاتورة');
    await tester.tap(detailsButtons.first); // الأحدث أولاً = INV-000003
    await settle();
    expect(find.byKey(const Key('invoice-refund-info')), findsNothing);
    await tester.tap(find.text('استرجاع الفاتورة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('استرجاع'));
    await settle();

    await tester.tap(find.text('تفاصيل الفاتورة').first);
    await settle();
    final info = find.byKey(const Key('invoice-refund-info'));
    expect(info, findsOneWidget);
    expect(find.descendant(of: info, matching: find.textContaining('تم الإرجاع بواسطة: Sara')), findsOneWidget);
    expect(find.descendant(of: info, matching: find.textContaining('بتاريخ: ')), findsOneWidget);
  });
}
