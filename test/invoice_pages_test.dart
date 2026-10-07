import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/repository/Invoice_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سجل المبيعات مُرقَّم ومفلتر (أوفلاين على الجدول المحلي — أونلاين نفس
/// الفلاتر على الخادم، انظر backend/pharmacy_data/tests_invoices_list.py).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pharmacyId = 1;
  const base = DatabaseHelper.localIdBase;
  late Directory tempDir;
  final helper = DatabaseHelper.instance;
  final repo = InvoiceRepository.instance;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_invoice_pages_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);

    final db = await helper.database;
    await db.insert('pharmacy_branch', {'id': pharmacyId, 'name': 'P', 'created_at': '2026-10-01T00:00:00'});
    await db.insert('users', {'id': 5, 'username': 'sara', 'password': '', 'full_name': 'Sara'});
    await db.insert('user_profile', {'id': 5, 'user_id': 5, 'pharmacy_id': pharmacyId, 'is_owner': 0});
    // 25 فاتورة على 5 أيام (1–5 أكتوبر)، البائعة Sara لكل ثالثة.
    for (var i = 0; i < 25; i++) {
      await db.insert('invoice', {
        'id': base + i,
        'pharmacy_id': pharmacyId,
        'invoice_number': 'INV-${i.toString().padLeft(6, '0')}',
        'cashier_id': i % 3 == 0 ? 5 : null,
        'final_amount': 10,
        'created_at': '2026-10-0${i % 5 + 1}T1${i % 10}:00:00',
      });
    }
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<InvoicePage> page(int n, {String search = '', DateTime? start, DateTime? end}) => repo.getInvoicesPage(
        pharmacyId: pharmacyId,
        isOnlineMode: false,
        page: n,
        pageSize: 10,
        search: search,
        start: start,
        end: end,
      );

  test('pages walk all invoices newest first without overlap', () async {
    final pages = [await page(1), await page(2), await page(3)];
    expect(pages.map((p) => p.rows.length), [10, 10, 5]);
    expect(pages.map((p) => p.hasMore), [true, true, false]);
    final all = [for (final p in pages) ...p.rows];
    expect(all.map((r) => r['id']).toSet(), hasLength(25));
    final dates = all.map((r) => r['created_at'] as String).toList();
    expect(dates, [...dates]..sort((a, b) => b.compareTo(a)));
  });

  test('search matches invoice number or seller name', () async {
    expect((await page(1, search: 'INV-000007')).rows.single['invoice_number'], 'INV-000007');
    final sara = await page(1, search: 'sara');
    expect(sara.rows, hasLength(9));
    expect(sara.rows.every((r) => r['cashier_name'] == 'Sara'), isTrue);
  });

  test('date range is inclusive by local invoice date', () async {
    final oneDay = await page(1, start: DateTime(2026, 10, 2), end: DateTime(2026, 10, 2));
    expect(oneDay.rows, hasLength(5));
    final twoDays = await page(1, start: DateTime(2026, 10, 4), end: DateTime(2026, 10, 5));
    expect(twoDays.rows, hasLength(10));
  });

  test('recent invoices returns only the requested count', () async {
    final recent = await repo.getRecentInvoices(pharmacyId: pharmacyId, isOnlineMode: false, limit: 5);
    expect(recent, hasLength(5));
  });
}
