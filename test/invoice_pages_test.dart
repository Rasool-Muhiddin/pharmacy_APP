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
    await db.insert('warehouses', {'id': base, 'pharmacy_id': pharmacyId, 'name': 'Main', 'is_main': 1, 'created_at': '2026-10-01T00:00:00'});
    await db.insert('medicine', {'id': base, 'pharmacy_id': pharmacyId, 'warehouse_id': base, 'trade_name': 'Med'});
    // 25 فاتورة على 5 أيام (1–5 أكتوبر)، البائعة Sara لكل ثالثة (الباقي بلا
    // بائع)، الزوجية بخصم، كل خامسة مسترجعة، والفاتورة 7 فيها "Panadol" أيضاً.
    for (var i = 0; i < 25; i++) {
      await db.insert('invoice', {
        'id': base + i,
        'pharmacy_id': pharmacyId,
        'invoice_number': 'INV-${i.toString().padLeft(6, '0')}',
        'cashier_id': i % 3 == 0 ? 5 : null,
        'discount': i.isEven ? 1 : 0,
        'final_amount': 10,
        'is_refunded': i % 5 == 0 ? 1 : 0,
        'created_at': '2026-10-0${i % 5 + 1}T1${i % 10}:00:00',
      });
      for (final name in i == 7 ? ['Med', 'Panadol'] : ['Med']) {
        await db.insert('invoice_item', {
          'invoice_id': base + i,
          'medicine_id': base,
          'trade_name': name,
          'quantity': 1,
          'unit_price': 10,
          'total_price': 10,
        });
      }
    }
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<InvoicePage> page(
    int n, {
    String search = '',
    DateTime? start,
    DateTime? end,
    String? seller,
    bool? refunded,
    bool? hasDiscount,
    int pageSize = 10,
  }) =>
      repo.getInvoicesPage(
        pharmacyId: pharmacyId,
        isOnlineMode: false,
        page: n,
        pageSize: pageSize,
        search: search,
        start: start,
        end: end,
        seller: seller,
        refunded: refunded,
        hasDiscount: hasDiscount,
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

  test('search matches invoice number or a sold medicine name', () async {
    expect((await page(1, search: 'INV-000007')).rows.single['invoice_number'], 'INV-000007');
    expect((await page(1, search: 'panadol')).rows.single['invoice_number'], 'INV-000007');
    // صنفان مطابقان في الفاتورة 7 لا يكرّرانها.
    expect((await page(1, search: 'med', pageSize: 50)).rows, hasLength(25));
    expect((await page(1, search: 'sara')).rows, isEmpty);
  });

  test('seller list and filter include unspecified seller', () async {
    final sellers = await repo.getSellers(pharmacyId: pharmacyId, isOnlineMode: false);
    expect(sellers, unorderedEquals(['Sara', DatabaseHelper.unknownSeller]));
    final sara = await page(1, seller: 'Sara', pageSize: 50);
    expect(sara.rows, hasLength(9));
    expect(sara.rows.every((r) => r['cashier_name'] == 'Sara'), isTrue);
    expect((await page(1, seller: DatabaseHelper.unknownSeller, pageSize: 50)).rows, hasLength(16));
  });

  test('status, discount, seller and search filters combine', () async {
    expect((await page(1, refunded: true, pageSize: 50)).rows, hasLength(5));
    expect((await page(1, refunded: false, pageSize: 50)).rows, hasLength(20));
    expect((await page(1, hasDiscount: true, pageSize: 50)).rows, hasLength(13));
    expect((await page(1, hasDiscount: false, pageSize: 50)).rows, hasLength(12));
    // Sara (i % 3 == 0) + بخصم (زوجي) + مكتملة (i % 5 != 0) → 6، 12، 18، 24.
    final combined = await page(1, seller: 'Sara', hasDiscount: true, refunded: false, pageSize: 50);
    expect(combined.rows.map((r) => r['invoice_number']),
        unorderedEquals(['INV-000006', 'INV-000012', 'INV-000018', 'INV-000024']));
    final withSearch = await page(1, seller: 'Sara', hasDiscount: true, refunded: false, search: '0001');
    expect(withSearch.rows.map((r) => r['invoice_number']), unorderedEquals(['INV-000012', 'INV-000018']));
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
