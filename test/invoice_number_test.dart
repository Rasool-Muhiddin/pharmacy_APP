import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// رقم الفاتورة التالي يُحسب بـ MAX داخل SQLite (لا قراءة كل الفواتير)، بنفس
/// قواعد الطريقة السابقة: أرقام محلية فقط، لاحقة رقمية فقط، وتخطّي المستخدم.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const base = DatabaseHelper.localIdBase;
  late Directory tempDir;
  final helper = DatabaseHelper.instance;
  var nextId = base;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pharmacy_invoice_number_test');
    DatabaseHelper.databasePathOverride = '${tempDir.path}${Platform.pathSeparator}pharmacy.db';
    await DatabaseHelper.resetForTesting();
    helper.setSessionMode(isOnline: false);
    nextId = base;
    final db = await helper.database;
    await db.insert('pharmacy_branch', {'id': 1, 'name': 'P', 'created_at': '2026-10-01T00:00:00'});
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> invoice(String number, {bool server = false}) async {
    final db = await helper.database;
    await db.insert('invoice', {
      'id': server ? 500 + nextId - base : nextId,
      'pharmacy_id': 1,
      'invoice_number': number,
      'created_at': '2026-10-01T10:00:00',
    });
    nextId++;
  }

  test('starts at 1 and follows the highest local number, ignoring gaps', () async {
    expect(await helper.generateInvoiceNumber(), 'INV-000001');
    await invoice('INV-000001');
    await invoice('INV-000007');
    await invoice('INV-000003');
    expect(await helper.generateInvoiceNumber(), 'INV-000008');
  });

  test('ignores server invoices and non-numeric suffixes', () async {
    await invoice('INV-000004');
    await invoice('INV-000999', server: true); // كاش الخادم: ترقيم آخر
    await invoice('INV-000050x'); // لاحقة غير رقمية (كان int.tryParse يتجاهلها)
    await invoice('MANUAL-77');
    expect(await helper.generateInvoiceNumber(), 'INV-000005');
  });

  test('numbers past 999999 stay numeric (not text order)', () async {
    await invoice('INV-999999');
    await invoice('INV-1000000');
    expect(await helper.generateInvoiceNumber(), 'INV-1000001');
  });
}
