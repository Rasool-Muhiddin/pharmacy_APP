// أداة اختبار الحمل — إعدادات وأدوات مشتركة. تعمل عبر مشغّل flutter test كي
// تستخدم منطق التطبيق نفسه (DatabaseHelper والمستودعات) على قاعدة محلية حقيقية.
// لا كلمات مرور هنا: الأداة تكتب مباشرة في قاعدة SQLite المحلية، وتحتاج فقط
// أسماء المستخدمين لربط الفواتير بحساباتهم المحلية (user_profile).

import 'dart:convert';
import 'dart:io';

import 'package:pharmacy_app/database/db_helper.dart';

/// المعاملات تُمرَّر كـ --dart-define=LT_...=...
class LoadTestConfig {
  static const action = String.fromEnvironment('LT_ACTION'); // generate | cleanup | restore | measure
  static const dbPath = String.fromEnvironment('LT_DB');
  static const pharmacyId = int.fromEnvironment('LT_PHARMACY');
  static const ownerUsername = String.fromEnvironment('LT_OWNER');
  static const staffUsername = String.fromEnvironment('LT_STAFF');
  static const seed = int.fromEnvironment('LT_SEED', defaultValue: 20261018);
  static const days = int.fromEnvironment('LT_DAYS', defaultValue: 365);
  static const medicines = int.fromEnvironment('LT_MEDICINES', defaultValue: 1000);
  static const invoicesPerDay = int.fromEnvironment('LT_INVOICES_PER_DAY', defaultValue: 40);
  static const backupPath = String.fromEnvironment('LT_BACKUP'); // restore فقط

  /// ملف حالة التوليد (خارج المستودع، بجانب القاعدة): نقاط البداية لكل جدول
  /// للتنظيف، والنسخة الاحتياطية المأخوذة قبل الكتابة.
  static String get stateFile => '${File(dbPath).parent.path}${Platform.pathSeparator}load_test_backups'
      '${Platform.pathSeparator}load_test_state_$pharmacyId.json';

  static void require(bool ok, String message) {
    if (!ok) throw StateError('LoadTest: $message');
  }

  static void validate({bool users = false}) {
    require(dbPath.isNotEmpty && File(dbPath).existsSync(), 'LT_DB غير موجود: "$dbPath"');
    require(pharmacyId > 0, 'LT_PHARMACY مطلوب');
    if (users) require(ownerUsername.isNotEmpty && staffUsername.isNotEmpty, 'LT_OWNER و LT_STAFF مطلوبان');
  }
}

/// كل جداول البيانات التي قد تكتبها الأداة، بترتيب الحذف الآمن (الأبناء أولاً).
const List<String> generatedTables = [
  'invoice_item',
  'invoice',
  'purchase_invoice_return_item',
  'purchase_invoice_return',
  'supplier_credit_application',
  'supplier_refund',
  'supplier_payment',
  'purchase_invoice_item',
  'damaged_medicine',
  'medicine_batch',
  'purchase_invoice',
  'medicine',
  'pharmacy_supplier',
  'expense',
];

/// لا كتابة والتطبيق مفتوح (قد يحتفظ بالقاعدة مفتوحة ويكتب فوق الأداة).
Future<void> assertAppClosed() async {
  if (!Platform.isWindows) return;
  final result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq pharmacy_APP.exe']);
  final out = result.stdout.toString().toLowerCase();
  LoadTestConfig.require(!out.contains('pharmacy_app.exe'), 'التطبيق pharmacy_APP.exe يعمل الآن — أغلقه قبل الكتابة.');
}

Future<Map<String, int>> tableWatermarks() async {
  final db = await DatabaseHelper.instance.database;
  return {
    for (final t in generatedTables)
      t: ((await db.rawQuery('SELECT COALESCE(MAX(id), 0) AS m FROM $t')).first['m'] as num).toInt(),
  };
}

Future<Map<String, int>> tableCounts({int? pharmacyId}) async {
  final db = await DatabaseHelper.instance.database;
  Future<int> count(String sql, [List<Object?> args = const []]) async =>
      ((await db.rawQuery(sql, args)).first['c'] as num).toInt();
  final p = pharmacyId ?? LoadTestConfig.pharmacyId;
  return {
    'medicines': await count('SELECT COUNT(*) c FROM medicine WHERE pharmacy_id = ?', [p]),
    'batches': await count('SELECT COUNT(*) c FROM medicine_batch b JOIN medicine m ON m.id = b.medicine_id WHERE m.pharmacy_id = ?', [p]),
    'suppliers': await count('SELECT COUNT(*) c FROM pharmacy_supplier WHERE pharmacy_id = ?', [p]),
    'purchase_invoices': await count('SELECT COUNT(*) c FROM purchase_invoice WHERE pharmacy_id = ?', [p]),
    'purchase_lines': await count('SELECT COUNT(*) c FROM purchase_invoice_item WHERE pharmacy_id = ?', [p]),
    'supplier_payments': await count('SELECT COUNT(*) c FROM supplier_payment WHERE pharmacy_id = ?', [p]),
    'supplier_returns': await count('SELECT COUNT(*) c FROM purchase_invoice_return WHERE pharmacy_id = ?', [p]),
    'supplier_refunds_received': await count('SELECT COUNT(*) c FROM supplier_refund WHERE pharmacy_id = ?', [p]),
    'sales_invoices': await count('SELECT COUNT(*) c FROM invoice WHERE pharmacy_id = ?', [p]),
    'sales_lines': await count('SELECT COUNT(*) c FROM invoice_item ii JOIN invoice i ON i.id = ii.invoice_id WHERE i.pharmacy_id = ?', [p]),
    'refunded_invoices': await count('SELECT COUNT(*) c FROM invoice WHERE pharmacy_id = ? AND is_refunded = 1', [p]),
    'damaged_entries': await count('SELECT COUNT(*) c FROM damaged_medicine WHERE pharmacy_id = ?', [p]),
    'expenses': await count('SELECT COUNT(*) c FROM expense WHERE pharmacy_id = ?', [p]),
  };
}

Map<String, dynamic>? readState() {
  final file = File(LoadTestConfig.stateFile);
  return file.existsSync() ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic> : null;
}

void writeState(Map<String, dynamic> state) {
  final file = File(LoadTestConfig.stateFile);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(state));
}

String fileSizeMb(String path) => (File(path).lengthSync() / (1024 * 1024)).toStringAsFixed(2);

String stamp(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}_'
    '${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}${d.second.toString().padLeft(2, '0')}';

String dayKeyOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
