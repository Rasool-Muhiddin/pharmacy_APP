import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:convert';
import 'dart:io'; 
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

import '../models/purchase_list.dart';
import '../models/purchase_return.dart';

/// حد "المخزون المنخفض": الصنف بكمية <= هذا الحد يُعدّ شحيحاً (نقطة البيع،
/// المخزون، لوحة التحكم، تنبيهات التقارير). نفس LOW_STOCK_THRESHOLD في pharmacy_data/reports.py.
const int kLowStockThreshold = 10;

class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static Database? _database;
  static const String _dbName = "pharmacy.db";

  //====================================================
  // استراتيجية المعرّفات (منع تصادم بيانات الأوفلاين مع كاش الخادم)
  //
  // الجداول التي تستقبل صفوفاً من الخادم (medicine, invoice, expense,
  // damaged_medicine, warehouses) تحتوي نوعين من الصفوف في نفس الجدول:
  //  - صفوف كاش الخادم: معرّفها = معرّف الخادم نفسه، ودائماً < [localIdBase].
  //  - صفوف محلية (أُنشئت أوفلاين): معرّفها >= [localIdBase]، يولّده عدّاد
  //    AUTOINCREMENT المحلي المضبوط على هذا النطاق (_ensureLocalIdSequences).
  // النطاقان منفصلان تماماً، فلا يمكن لأي مزامنة أو تسجيل دخول أن يكتب صف
  // خادم فوق صف محلي أو العكس، مهما كانت المعرّفات. أي معرّف خادم >= هذا
  // الحد يُرفض صراحة (_serverId) بدل المخاطرة بالكتابة فوق بيانات محلية.
  //
  // القراءة مقيّدة بالمصدر حسب وضع الجلسة ([setSessionMode]): الأونلاين يعرض
  // صفوف الخادم فقط، والأوفلاين يعرض الصفوف المحلية فقط — كي لا تظهر نسخة
  // الأوفلاين المحفوظة بعد الرفع الأولي كتكرار بجانب نسختها على الخادم.
  //====================================================

  /// بداية نطاق المعرّفات المحلية (10^12). معرّفات الخادم (BigAutoField)
  /// لن تصل إليه عملياً، وأي معرّف خادم يتجاوزه يُرفض.
  static const int localIdBase = 1000000000000;

  /// الجداول التي تتشارك صفوفاً محلية وصفوف كاش خادم.
  static const List<String> sharedOriginTables = [
    'warehouses',
    'medicine',
    'invoice',
    'expense',
    'damaged_medicine',
  ];

  static bool isLocalId(int id) => id >= localIdBase;

  bool _sessionIsOnline = false;

  /// يُضبط عند فتح الواجهة الرئيسية لجلسة الدخول (MainLayout) بحسب
  /// license.mode، ويحدد أي الصفوف تقرؤها دوال العرض.
  void setSessionMode({required bool isOnline}) => _sessionIsOnline = isOnline;

  bool get sessionIsOnline => _sessionIsOnline;

  /// شرط SQL يقيّد الصفوف بمصدر الجلسة الحالية. [alias] اسم مستعار للجدول
  /// إن وُجد (مثلاً 'i.').
  String originFilter([String alias = '']) => _sessionIsOnline
      ? '${alias}id < $localIdBase'
      : '${alias}id >= $localIdBase';

  /// شرط SQL للصفوف المحلية فقط (أوفلاين)، بغض النظر عن وضع الجلسة — للرفع
  /// الأولي وفحص وجود بيانات أوفلاين.
  static String localOnly([String alias = '']) => '${alias}id >= $localIdBase';

  /// يتحقق أن معرّفاً قادماً من الخادم يقع في نطاق الخادم.
  static int _serverId(dynamic value) {
    final id = (value as num).toInt();
    if (id <= 0 || id >= localIdBase) {
      throw StateError('معرّف خادم غير صالح ($id) — رُفضت المزامنة حمايةً للبيانات المحلية.');
    }
    return id;
  }

  /// للاختبارات فقط: مسار قاعدة بيانات بديل بدل مجلد التطبيق (path_provider
  /// غير متاح في `flutter test`).
  @visibleForTesting
  static String? databasePathOverride;

  /// للاختبارات فقط: يغلق الاتصال الحالي كي يُعاد فتح القاعدة (وتشغيل
  /// onUpgrade) في الاستدعاء التالي.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    await _database?.close();
    _database = null;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();

    return _database!;
  }

Future<Database> _initDatabase() async {
  String path;
  final overridePath = databasePathOverride;
  if (overridePath != null) {
    path = overridePath;
  } else {
    final directory = await getApplicationSupportDirectory();

    if (!await Directory(directory.path).exists()) {
      await Directory(directory.path).create(recursive: true);
    }

    path = join(directory.path, _dbName);
  }

  return openDatabase(
    path,
    version: 13,
    onConfigure: (db) async {
      // ترقيات v7 و v9 تعيد بناء جداول (medicine/invoice: DROP + RENAME) وتنقل
      // معرّفات صفوف تشير إليها جداول أخرى. PRAGMA foreign_keys لا يمكن تغييره
      // داخل معاملة onUpgrade، لذا يبقى معطّلاً من هنا حتى تكتمل الترقية،
      // ويُفعَّل في onOpen. بدون ذلك تفشل الترقية ("FOREIGN KEY constraint
      // failed" عند COMMIT) على أي جهاز فيه مبيعات أو تالف.
      final currentVersion = await db.getVersion();
      final needsTableRebuild = currentVersion > 0 && currentVersion < 9;
      if (!needsTableRebuild) {
        await db.execute('PRAGMA foreign_keys = ON');
      }
    },
    onCreate: _onCreate,
    onUpgrade: _onUpgrade,
    onOpen: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
      // احتياط: يضمن أن أي صف محلي جديد يُعطى معرّفاً في النطاق المحلي.
      await _ensureLocalIdSequences(db);
    },
  );
}
  
Future<void> _onCreate(Database db, int version) async {
  // تفعيل القيود الخاصة بالمفاتيح الأجنبية
  await db.execute('PRAGMA foreign_keys = ON;');

  // 1. جدول الفروع
  await db.execute('''
    CREATE TABLE pharmacy_branch(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL
    )
  ''');

  // 2. جدول ملفات المستخدمين (الصيادلة)
  await db.execute('''
    CREATE TABLE user_profile(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      pharmacy_id INTEGER NOT NULL,
      is_owner INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id)
    )
  ''');

  // 3. جدول حسابات المستخدمين (لتسجيل الدخول)
  await db.execute('''
    CREATE TABLE users(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE,
      password TEXT NOT NULL,
      full_name TEXT
    )
  ''');

  // 3ب. جدول المخازن (خاصية الباقة الذهبية: عدة مخازن لكل صيدلية حتى
  // SubscriptionEntitlements.maxWarehouses، الرئيسي is_main = 1 ويُستخدم حصراً
  // في عملية البيع). last_synced_at: NULL = مخزن محلي (أوفلاين)، غير NULL =
  // صف كاش قادم من الخادم (أونلاين) بمعرّف الخادم نفسه.
  await db.execute('''
    CREATE TABLE warehouses(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      is_main INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      last_synced_at TEXT,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id)
    )
  ''');

  // 4. جدول الأدوية
  // ⚠️ barcode لم يعد UNIQUE على مستوى الجدول كله (كان يمنع وجود نفس
  // الصنف بمخزنين منفصلين لنفس الصيدلية). التفرّد الآن ضمن نفس
  // المخزن فقط، عبر idx_medicine_warehouse_barcode أدناه (فهرس جزئي
  // يتجاهل القيم الفارغة/الفارغة النصية حتى لا يمنع تعدد الأدوية بلا باركود).
  await db.execute('''
    CREATE TABLE medicine(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      warehouse_id INTEGER NOT NULL,
      trade_name TEXT NOT NULL,
      scientific_name TEXT,
      category TEXT,
      quantity INTEGER NOT NULL DEFAULT 0 CHECK(quantity >= 0),
      buy_price REAL NOT NULL DEFAULT 0 CHECK(buy_price >= 0),
      sell_price REAL NOT NULL DEFAULT 0 CHECK(sell_price >= 0),
      expiry_date TEXT,
      shelf_location TEXT,
      is_damaged INTEGER DEFAULT 0,
      barcode TEXT,
      last_synced_at TEXT,
      avg_cost REAL,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(warehouse_id) REFERENCES warehouses(id)
    )
  ''');
  await _createMedicineBatchTable(db);

  // 5. جدول الموردين (المذاخر)
  await db.execute('''
    CREATE TABLE pharmacy_supplier(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      phone TEXT,
      created_at TEXT,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id)
    )
  ''');

  // 6. جدول الفواتير (الرئيسي للمبيعات)
  await _createInvoiceTable(db, 'invoice');

  // 7. جدول تفاصيل الفاتورة (العناصر المباعة)
  await db.execute('''
    CREATE TABLE invoice_item(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      invoice_id INTEGER NOT NULL,
      trade_name TEXT NOT NULL,
      medicine_id INTEGER NOT NULL,
      quantity INTEGER NOT NULL,
      unit_price REAL NOT NULL,
      total_price REAL NOT NULL,
      unit_cost REAL,
      FOREIGN KEY(invoice_id) REFERENCES invoice(id) ON DELETE CASCADE,
      FOREIGN KEY(medicine_id) REFERENCES medicine(id)
    )
  ''');

  // 8. جدول الأدوية التالفة
  await db.execute('''
    CREATE TABLE damaged_medicine(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      medicine_id INTEGER NOT NULL,
      quantity_damaged INTEGER NOT NULL,
      reason TEXT,
      notes TEXT,
      damaged_at TEXT NOT NULL,
      total_cost REAL,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(medicine_id) REFERENCES medicine(id)
    )
  ''');

  // 9. جدول القاموس الشامل للأدوية المعتمدة
  await db.execute('''
    CREATE TABLE master_medicines(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      trade_name TEXT NOT NULL,
      scientific_name TEXT,
      category TEXT
    )
  ''');

  // 10. جدول فواتير الشراء والتوريد من المذاخر
  await db.execute('''
    CREATE TABLE purchase_invoice (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      supplier_id INTEGER NOT NULL,
      invoice_number TEXT,
      total_amount REAL NOT NULL DEFAULT 0,
      paid_amount REAL NOT NULL DEFAULT 0,
      remaining_debt REAL NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      invoice_date TEXT,
      source TEXT NOT NULL DEFAULT 'manual',
      item_count INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(supplier_id) REFERENCES pharmacy_supplier(id) ON DELETE CASCADE
    )
  ''');
  await _createPurchaseInvoiceItemTable(db);

  // 11. جدول دفعات تسديد الديون للمذاخر
  await db.execute('''
    CREATE TABLE supplier_payment (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      supplier_id INTEGER NOT NULL,
      purchase_invoice_id INTEGER,
      amount_paid REAL NOT NULL,
      notes TEXT,
      paid_at TEXT NOT NULL,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(supplier_id) REFERENCES pharmacy_supplier(id) ON DELETE CASCADE,
      FOREIGN KEY(purchase_invoice_id) REFERENCES purchase_invoice(id) ON DELETE CASCADE
    )
  ''');

  // 12. سجل الاسترجاعات من فواتير الشراء + أسطرها، واستخدام رصيد المذخر
  // والمبالغ المستلمة منه (v12).
  await _createPurchaseReturnTable(db, 'purchase_invoice_return');
  await _createSupplierCreditTables(db);

  await db.execute('''
    CREATE TABLE expense(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      expense_type TEXT NOT NULL,
      expense_date TEXT NOT NULL,
      amount REAL NOT NULL CHECK(amount > 0),
      notes TEXT NOT NULL DEFAULT '',
      last_synced_at TEXT,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id) ON DELETE CASCADE
    )
  ''');

  // 13. سجل عمليات نقل المخزون بين مخازن نفس الصيدلية.
  await _createStockTransfersTable(db);

  // إنشاء الفهارس (Indexes) لتسريع عمليات البحث في قاعدة البيانات
  await db.execute('CREATE INDEX idx_barcode ON medicine(barcode);');
  await db.execute('CREATE INDEX idx_medicine_warehouse ON medicine(warehouse_id);');
  // فريد ضمن نفس المخزن فقط، ويتجاهل الباركود الفارغ/NULL حتى لا يمنع
  // إدخال أكثر من صنف بلا باركود في نفس المخزن.
  await db.execute('''
    CREATE UNIQUE INDEX idx_medicine_warehouse_barcode
    ON medicine(warehouse_id, barcode)
    WHERE barcode IS NOT NULL AND barcode != ''
  ''');
  await db.execute('CREATE INDEX idx_warehouses_pharmacy ON warehouses(pharmacy_id);');
  await db.execute('CREATE INDEX idx_trade_name ON medicine(trade_name);');
  await db.execute('CREATE INDEX idx_scientific_name ON medicine(scientific_name);');
  await _createInvoiceIndexes(db);
  await _createReportIndexes(db);
  await db.execute('CREATE INDEX idx_purchase_invoice_supplier ON purchase_invoice(supplier_id);');
  await _createPurchaseInvoiceNumberIndex(db);
  await db.execute('CREATE INDEX idx_supplier_payment_supplier ON supplier_payment(supplier_id);');
  await db.execute('CREATE INDEX idx_supplier_payment_invoice ON supplier_payment(purchase_invoice_id);');
  await db.execute('CREATE INDEX idx_purchase_invoice_return_invoice ON purchase_invoice_return(purchase_invoice_id);');
  await db.execute('CREATE INDEX idx_expense_pharmacy_date ON expense(pharmacy_id, expense_date);');

  // 🔴 فهرس لتسريع البحث اللحظي في القاموس أثناء الكتابة
  await db.execute('CREATE INDEX idx_master_trade_name ON master_medicines(trade_name);');

  // 🚀 تعبئة القاموس تلقائياً بالـ 1000 دواء من ملف الـ JSON
  await _seedMasterMedicines(db);

  await _ensureLocalIdSequences(db);
}

/// جدول الفواتير. invoice_number لم يعد UNIQUE على مستوى الجدول كله: فاتورة
/// أوفلاين محلية وفاتورة خادم قد تحملان نفس الرقم (مثلاً INV-000001) بعد
/// الرفع الأولي أو على أجهزة مختلفة، وكان القيد يُسقط فاتورة الخادم بصمت
/// (INSERT OR IGNORE) ثم يُفشل مزامنة أصنافها. الفرادة الآن ضمن نفس المصدر
/// فقط (راجع _createInvoiceIndexes).
Future<void> _createInvoiceTable(DatabaseExecutor db, String name) async {
  await db.execute('''
    CREATE TABLE $name(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      invoice_number TEXT NOT NULL,
      cashier_id INTEGER,
      cashier_name_synced TEXT,
      total_amount REAL NOT NULL DEFAULT 0,
      discount REAL NOT NULL DEFAULT 0,
      final_amount REAL NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      is_refunded INTEGER NOT NULL DEFAULT 0,
      last_synced_at TEXT,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(cashier_id) REFERENCES user_profile(id)
    )
  ''');
}

Future<void> _createInvoiceIndexes(DatabaseExecutor db) async {
  await db.execute('CREATE INDEX idx_invoice_number ON invoice(invoice_number);');
  await db.execute('CREATE INDEX idx_invoice_date ON invoice(created_at);');
  await db.execute('''
    CREATE UNIQUE INDEX idx_invoice_number_local
    ON invoice(pharmacy_id, invoice_number) WHERE id >= $localIdBase
  ''');
  await db.execute('''
    CREATE UNIQUE INDEX idx_invoice_number_server
    ON invoice(pharmacy_id, invoice_number) WHERE id < $localIdBase
  ''');
}

/// v13: فهارس شاشة التقارير — كل استعلاماتها مقيّدة بالصيدلية ونطاق تاريخ
/// (created_at >= بداية اليوم الأول AND < بداية اليوم التالي للأخير)، أو تجمع
/// أسطر الفواتير حسب الفاتورة/الدواء.
Future<void> _createReportIndexes(DatabaseExecutor db) async {
  await db.execute('CREATE INDEX IF NOT EXISTS idx_invoice_pharmacy_date ON invoice(pharmacy_id, created_at);');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_invoice_item_invoice ON invoice_item(invoice_id);');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_invoice_item_medicine ON invoice_item(medicine_id);');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_damaged_pharmacy_date ON damaged_medicine(pharmacy_id, damaged_at);');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_purchase_invoice_pharmacy_date ON purchase_invoice(pharmacy_id, created_at);');
}

/// يضبط عدّاد AUTOINCREMENT لكل جدول مشترك بحيث يكون أي معرّف محلي جديد
/// >= [localIdBase]. إدراج صف خادم بمعرّفه الصريح (أصغر) لا يُنقص العدّاد،
/// فيبقى النطاقان منفصلين دائماً. آمن للاستدعاء المتكرر.
Future<void> _ensureLocalIdSequences(DatabaseExecutor db) async {
  for (final table in sharedOriginTables) {
    final updated = await db.rawUpdate(
      'UPDATE sqlite_sequence SET seq = ? WHERE name = ? AND seq < ?',
      [localIdBase - 1, table, localIdBase - 1],
    );
    if (updated == 0) {
      final exists = await db.rawQuery('SELECT 1 FROM sqlite_sequence WHERE name = ?', [table]);
      if (exists.isEmpty) {
        await db.rawInsert('INSERT INTO sqlite_sequence(name, seq) VALUES (?, ?)', [table, localIdBase - 1]);
      }
    }
  }
}

// نقطة بداية نظيفة (Version 1) - أول نسخة توصل فعلياً لأي عميل.
// كل الجداول موجودة بـ _onCreate. هذي الدالة فاضية الآن، وتُستخدم فقط
// عند إصدار تحديث مستقبلي فيه تغيير على السكيمة (جدول جديد، عمود جديد...).
//
// مثال جاهز يوم تحتاجه:
//
// Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
//   if (oldVersion < 2) {
//     await db.execute('''
//       CREATE TABLE new_table_name(
//         id INTEGER PRIMARY KEY AUTOINCREMENT,
//         pharmacy_id INTEGER NOT NULL,
//         FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id)
//       )
//     ''');
//   }
// }
Future<void> _onUpgrade(
  Database db,
  int oldVersion,
  int newVersion,
) async {
  if (oldVersion < 2) {
    await db.execute('''
      CREATE TABLE expense(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pharmacy_id INTEGER NOT NULL,
        expense_type TEXT NOT NULL,
        expense_date TEXT NOT NULL,
        amount REAL NOT NULL CHECK(amount > 0),
        notes TEXT NOT NULL DEFAULT '',
        FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_expense_pharmacy_date ON expense(pharmacy_id, expense_date);');
  }

  if (oldVersion < 3) {
    // عمود جديد فقط، بلا قيمة افتراضية غير NULL — الصفوف الموجودة مسبقاً
    // (كل بيانات الأوفلاين الحالية) تبقى NULL فيه، وهذا صحيح تماماً:
    // معناه "لم تُزامن مع السيرفر بعد"، لا خطأ.
    await db.execute('ALTER TABLE medicine ADD COLUMN last_synced_at TEXT;');
  }

  if (oldVersion < 4) {
    // نفس منطق عمود medicine.last_synced_at أعلاه، لكن لجدول الفواتير هذه
    // المرة — يبقى NULL لكل الفواتير الأوفلاين الحالية (لم تُزامن بعد).
    await db.execute('ALTER TABLE invoice ADD COLUMN last_synced_at TEXT;');
  }

  if (oldVersion < 5) {
    // نفس المنطق تماماً، لكن لجدول المصروفات — يبقى NULL لكل المصروفات
    // الأوفلاين الحالية (لم تُزامن بعد).
    await db.execute('ALTER TABLE expense ADD COLUMN last_synced_at TEXT;');
  }

  if (oldVersion < 6) {
    // يحل قيد معروف: فواتير أونلاين تُخزَّن بـ cashier_id = NULL دائماً
    // (مساحة أرقام user.id على السيرفر مختلفة عن user_profile.id المحلي)،
    // فكان اسم البائع يظهر "غير محدد" دائماً في سجل المبيعات رغم أن
    // السيرفر يُرجع اسماً جاهزاً (cashier_display_name) في كل فاتورة. هذا
    // العمود يخزّن ذلك النص كما هو، ويُستخدم كبديل احتياطي في استعلام
    // sales_history_screen.dart عندما لا يوجد cashier_id محلي مطابق.
    await db.execute('ALTER TABLE invoice ADD COLUMN cashier_name_synced TEXT;');
  }

  if (oldVersion < 7) {
    // خاصية الباقة الذهبية: تعدد المخازن (راجع
    // subscription_plan.dart: AppFeature.multiWarehouse).

    // أ) جدول المخازن، وإنشاء "المخزن الرئيسي" تلقائياً لكل صيدلية موجودة
    // مسبقاً حتى لا تفقد بياناتها الحالية أي مرجعية مخزن.
    await db.execute('''
      CREATE TABLE warehouses(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pharmacy_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        is_main INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id)
      )
    ''');
    await db.execute('CREATE INDEX idx_warehouses_pharmacy ON warehouses(pharmacy_id);');

    final nowIso = DateTime.now().toIso8601String();
    await db.rawInsert('''
      INSERT INTO warehouses (pharmacy_id, name, is_main, created_at)
      SELECT id, 'المخزن الرئيسي', 1, ? FROM pharmacy_branch
    ''', [nowIso]);

    // ب) (جدولا ربط الصيدليات وسجل النقل يُنشآن/يُزالان في خطوة v8 أدناه.)

    // ج) إعادة بناء جدول medicine بالكامل: إضافة warehouse_id (وربط كل
    // صف حالي بالمخزن الرئيسي لنفس صيدليته)، وإزالة قيد UNIQUE عن barcode
    // على مستوى الجدول كله (كان يمنع تكرار نفس الباركود بين مخزنين).
    // SQLite لا يدعم تعديل/حذف قيد عمود مباشرة، فلازم إعادة بناء الجدول.
    //
    // ⚠️ invoice_item/damaged_medicine تشير لـ medicine.id، فيفشل DROP TABLE
    // لو كانت قيود FOREIGN KEY مفعّلة. "PRAGMA foreign_keys = OFF" يُتجاهَل
    // بصمت داخل معاملة onUpgrade، لذلك يُترك معطّلاً من onConfigure لهذه
    // الترقية تحديداً ويُعاد تفعيله في onOpen (راجع _initDatabase). المعرّفات
    // تُنسخ كما هي، فتبقى كل المراجع صحيحة بعد إعادة التسمية.

    await db.execute('''
      CREATE TABLE medicine_new(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pharmacy_id INTEGER NOT NULL,
        warehouse_id INTEGER NOT NULL,
        trade_name TEXT NOT NULL,
        scientific_name TEXT,
        category TEXT,
        quantity INTEGER NOT NULL DEFAULT 0 CHECK(quantity >= 0),
        buy_price REAL NOT NULL DEFAULT 0 CHECK(buy_price >= 0),
        sell_price REAL NOT NULL DEFAULT 0 CHECK(sell_price >= 0),
        expiry_date TEXT,
        shelf_location TEXT,
        is_damaged INTEGER DEFAULT 0,
        barcode TEXT,
        last_synced_at TEXT,
        FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
        FOREIGN KEY(warehouse_id) REFERENCES warehouses(id)
      )
    ''');

    await db.rawInsert('''
      INSERT INTO medicine_new (
        id, pharmacy_id, warehouse_id, trade_name, scientific_name, category,
        quantity, buy_price, sell_price, expiry_date, shelf_location,
        is_damaged, barcode, last_synced_at
      )
      SELECT
        m.id, m.pharmacy_id, w.id, m.trade_name, m.scientific_name, m.category,
        m.quantity, m.buy_price, m.sell_price, m.expiry_date, m.shelf_location,
        m.is_damaged, m.barcode, m.last_synced_at
      FROM medicine m
      INNER JOIN warehouses w ON w.pharmacy_id = m.pharmacy_id AND w.is_main = 1
    ''');

    await db.execute('DROP TABLE medicine;');
    await db.execute('ALTER TABLE medicine_new RENAME TO medicine;');

    await db.execute('CREATE INDEX idx_barcode ON medicine(barcode);');
    await db.execute('CREATE INDEX idx_trade_name ON medicine(trade_name);');
    await db.execute('CREATE INDEX idx_scientific_name ON medicine(scientific_name);');
    await db.execute('CREATE INDEX idx_medicine_warehouse ON medicine(warehouse_id);');
    await db.execute('''
      CREATE UNIQUE INDEX idx_medicine_warehouse_barcode
      ON medicine(warehouse_id, barcode)
      WHERE barcode IS NOT NULL AND barcode != ''
    ''');
  }

  if (oldVersion < 8) {
    // أ) إزالة خاصية ربط الصيدليات بالكامل.
    await db.execute('DROP TABLE IF EXISTS pharmacy_links;');

    // ب) تمييز كاش المخازن القادم من الخادم (أونلاين) عن المخازن المحلية.
    await db.execute('ALTER TABLE warehouses ADD COLUMN last_synced_at TEXT;');

    // ج) سجل النقل بالشكل الجديد: pharmacy_id + أسماء المخازن محفوظة نصاً
    // والمراجع ON DELETE SET NULL، حتى لا يمنع السجلُّ حذفَ مخزن إضافي
    // فارغ. تُنقل السجلات القديمة (v7) إن وُجدت.
    final hasOldTransfers = (await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'stock_transfers'",
    )).isNotEmpty;
    if (hasOldTransfers) {
      await db.execute('ALTER TABLE stock_transfers RENAME TO stock_transfers_v7;');
      await db.execute('DROP INDEX IF EXISTS idx_stock_transfers_from;');
      await db.execute('DROP INDEX IF EXISTS idx_stock_transfers_to;');
    }
    await _createStockTransfersTable(db);
    if (hasOldTransfers) {
      await db.rawInsert('''
        INSERT INTO stock_transfers (
          id, pharmacy_id, from_warehouse_id, to_warehouse_id,
          from_warehouse_name, to_warehouse_name, trade_name, barcode,
          quantity, transferred_at, notes
        )
        SELECT
          st.id, wf.pharmacy_id, st.from_warehouse_id, st.to_warehouse_id,
          COALESCE(wf.name, ''), COALESCE(wt.name, ''), st.trade_name, st.barcode,
          st.quantity, st.transferred_at, st.notes
        FROM stock_transfers_v7 st
        JOIN warehouses wf ON wf.id = st.from_warehouse_id
        LEFT JOIN warehouses wt ON wt.id = st.to_warehouse_id
        -- سجل نقل قديم بين صيدليتين (خاصية الربط المُزالة) يُنسب لصيدلية
        -- مخزن المصدر.
      ''');
      await db.execute('DROP TABLE stock_transfers_v7;');
    }
  }

  if (oldVersion < 9) {
    await _upgradeToSeparateIdRanges(db);
  }

  if (oldVersion < 10) {
    await _upgradeToCostAndBatches(db);
  }

  if (oldVersion < 11) {
    await _upgradeToPurchaseLists(db);
  }

  if (oldVersion < 12) {
    await _upgradeToSupplierCredit(db);
  }

  if (oldVersion < 13) {
    await _createReportIndexes(db);
  }
}

/// سجل الاسترجاع. amount_returned = قيمة الاسترجاع كاملة (0 مسموح: بونص/مجاني
/// فقط)، excess_credit = ما زاد على متبقي فاتورته فذهب لرصيد المذخر.
Future<void> _createPurchaseReturnTable(DatabaseExecutor db, String name) async {
  await db.execute('''
    CREATE TABLE $name (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      supplier_id INTEGER NOT NULL,
      purchase_invoice_id INTEGER NOT NULL,
      amount_returned REAL NOT NULL CHECK(amount_returned >= 0),
      excess_credit REAL NOT NULL DEFAULT 0 CHECK(excess_credit >= 0 AND excess_credit <= amount_returned),
      notes TEXT,
      returned_at TEXT NOT NULL,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(supplier_id) REFERENCES pharmacy_supplier(id) ON DELETE CASCADE,
      FOREIGN KEY(purchase_invoice_id) REFERENCES purchase_invoice(id) ON DELETE CASCADE
    )
  ''');
}

/// أسطر الاسترجاع بالأصناف، استخدام رصيد المذخر ("خصم من رصيد سابق")، والمبالغ
/// المستلمة منه — نفس PurchaseInvoiceReturnItem/SupplierCreditApplication/SupplierRefund.
Future<void> _createSupplierCreditTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS purchase_invoice_return_item(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      purchase_return_id INTEGER NOT NULL,
      purchase_invoice_item_id INTEGER NOT NULL,
      medicine_id INTEGER,
      trade_name TEXT NOT NULL,
      quantity INTEGER NOT NULL CHECK(quantity > 0),
      credited_quantity INTEGER NOT NULL DEFAULT 0 CHECK(credited_quantity >= 0 AND credited_quantity <= quantity),
      unit_return_price REAL NOT NULL DEFAULT 0,
      credit_amount REAL NOT NULL DEFAULT 0 CHECK(credit_amount >= 0),
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(purchase_return_id) REFERENCES purchase_invoice_return(id) ON DELETE CASCADE,
      FOREIGN KEY(purchase_invoice_item_id) REFERENCES purchase_invoice_item(id) ON DELETE CASCADE,
      FOREIGN KEY(medicine_id) REFERENCES medicine(id) ON DELETE SET NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_credit_application(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      supplier_id INTEGER NOT NULL,
      purchase_invoice_id INTEGER NOT NULL,
      amount REAL NOT NULL CHECK(amount > 0),
      notes TEXT,
      applied_at TEXT NOT NULL,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(supplier_id) REFERENCES pharmacy_supplier(id) ON DELETE CASCADE,
      FOREIGN KEY(purchase_invoice_id) REFERENCES purchase_invoice(id) ON DELETE CASCADE
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS supplier_refund(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      supplier_id INTEGER NOT NULL,
      amount REAL NOT NULL CHECK(amount > 0),
      notes TEXT,
      received_at TEXT NOT NULL,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(supplier_id) REFERENCES pharmacy_supplier(id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_return_item_return ON purchase_invoice_return_item(purchase_return_id);');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_return_item_invoice_item ON purchase_invoice_return_item(purchase_invoice_item_id);');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_credit_application_invoice ON supplier_credit_application(purchase_invoice_id);');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_credit_application_supplier ON supplier_credit_application(supplier_id);');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_supplier_refund_supplier ON supplier_refund(supplier_id);');
}

/// v12: استرجاع الأصناف ورصيد المذخر. يُعاد بناء purchase_invoice_return (قيد
/// CHECK أصبح >= 0 + عمود excess_credit) بنفس المعرّفات والبيانات، ثم المتبقي
/// السالب القديم يصبح رصيداً (نفس ترحيل 0016) — رصيد كل مذخر لا يتغير.
Future<void> _upgradeToSupplierCredit(DatabaseExecutor db) async {
  await _createPurchaseReturnTable(db, 'purchase_invoice_return_v12');
  await db.execute('''
    INSERT INTO purchase_invoice_return_v12
      (id, pharmacy_id, supplier_id, purchase_invoice_id, amount_returned, excess_credit, notes, returned_at)
    SELECT id, pharmacy_id, supplier_id, purchase_invoice_id, amount_returned, 0, notes, returned_at
    FROM purchase_invoice_return
  ''');
  await db.execute('DROP TABLE purchase_invoice_return;');
  await db.execute('ALTER TABLE purchase_invoice_return_v12 RENAME TO purchase_invoice_return;');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_purchase_invoice_return_invoice ON purchase_invoice_return(purchase_invoice_id);');
  await _createSupplierCreditTables(db);
  await _convertLegacyNegativeRemainders(db);
  await db.rawUpdate('UPDATE purchase_invoice SET remaining_debt = MAX(0, ${invoiceRemainingSql('purchase_invoice')})');
}

/// المتبقي السالب القديم ← excess_credit على أحدث استرجاعات الفاتورة، ثم يسدّد
/// فواتير المذخر الأخرى المفتوحة (الأقدم أولاً)، والباقي رصيد لصالح الصيدلية.
Future<void> _convertLegacyNegativeRemainders(DatabaseExecutor db) async {
  final now = DateTime.now().toIso8601String();
  final suppliers = await db.rawQuery('SELECT DISTINCT supplier_id FROM purchase_invoice');
  for (final s in suppliers) {
    final supplierId = s['supplier_id'] as int;
    final invoices =
        await db.query('purchase_invoice', where: 'supplier_id = ?', whereArgs: [supplierId], orderBy: 'created_at, id');
    for (final invoice in invoices) {
      var need = roundMoney(-await _invoiceRemaining(db, invoice['id'] as int));
      if (need <= 0) continue;
      var excess = need;
      final returns = await db.query('purchase_invoice_return',
          where: 'purchase_invoice_id = ?', whereArgs: [invoice['id']], orderBy: 'returned_at DESC, id DESC');
      for (final ret in returns) {
        if (need <= 0) break;
        final current = (ret['excess_credit'] as num).toDouble();
        final room = (ret['amount_returned'] as num).toDouble() - current;
        final take = need < room ? need : room;
        if (take > 0) {
          await db.update('purchase_invoice_return', {'excess_credit': roundMoney(current + take)},
              where: 'id = ?', whereArgs: [ret['id']]);
          need = roundMoney(need - take);
        }
      }
      // need > 0 هنا = متبقٍّ سالب ليس من استرجاع (بيانات شاذة): يُترك كما هو.
      excess = roundMoney(excess - need);
      for (final other in invoices) {
        if (excess <= 0) break;
        if (other['id'] == invoice['id']) continue;
        final open = await _invoiceRemaining(db, other['id'] as int);
        if (open > 0) {
          final amount = roundMoney(excess < open ? excess : open);
          await db.insert('supplier_credit_application', {
            'pharmacy_id': other['pharmacy_id'],
            'supplier_id': supplierId,
            'purchase_invoice_id': other['id'],
            'amount': amount,
            'notes': SupplierCreditNote.legacy,
            'applied_at': now,
          });
          excess = roundMoney(excess - amount);
        }
      }
    }
  }
}

/// v11: قوائم المذاخر من المخزون — أصناف فاتورة الشراء (مع البونص منفصلاً)،
/// وربط كل دفعة بمذخرها وفاتورتها (أو "رصيد افتتاحي"). الدفعات والفواتير
/// القديمة تبقى بلا ربط (NULL / 'manual'). أرقام الفواتير المكررة لنفس المذخر
/// تُعاد تسميتها (-2، -3…) قبل فهرس الفرادة — بلا حذف أي سجل (نفس ترحيل 0013).
Future<void> _upgradeToPurchaseLists(DatabaseExecutor db) async {
  // medicine_batch قد يكون أُنشئ للتو بشكله الكامل (ترقية من < 10).
  await _addColumnIfMissing(db, 'medicine_batch', 'source', 'TEXT');
  await _addColumnIfMissing(
      db, 'medicine_batch', 'supplier_id', 'INTEGER REFERENCES pharmacy_supplier(id) ON DELETE SET NULL');
  await _addColumnIfMissing(
      db, 'medicine_batch', 'purchase_invoice_id', 'INTEGER REFERENCES purchase_invoice(id) ON DELETE SET NULL');
  await _addColumnIfMissing(db, 'medicine_batch', 'supplier_name', 'TEXT');
  await _addColumnIfMissing(db, 'medicine_batch', 'invoice_number', 'TEXT');
  await _addColumnIfMissing(db, 'purchase_invoice', 'invoice_date', 'TEXT');
  await _addColumnIfMissing(db, 'purchase_invoice', 'source', "TEXT NOT NULL DEFAULT 'manual'");
  await _addColumnIfMissing(db, 'purchase_invoice', 'item_count', 'INTEGER NOT NULL DEFAULT 0');
  await _createPurchaseInvoiceItemTable(db);
  await _dedupePurchaseInvoiceNumbers(db);
  await _createPurchaseInvoiceNumberIndex(db);
}

Future<void> _addColumnIfMissing(DatabaseExecutor db, String table, String column, String definition) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  if (columns.any((c) => c['name'] == column)) return;
  await db.execute('ALTER TABLE $table ADD COLUMN $column $definition;');
}

/// سطر من قائمة المذخر. quantity = المدفوع، bonus_quantity = المجاني منفصلاً
/// (سطر مجاني بالكامل: quantity = 0). medicine_id SET NULL + لقطة trade_name:
/// حذف الصنف لا يمس تاريخ الفاتورة (نفس PurchaseInvoiceItem على الخادم).
Future<void> _createPurchaseInvoiceItemTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS purchase_invoice_item(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      purchase_invoice_id INTEGER NOT NULL,
      medicine_id INTEGER,
      trade_name TEXT NOT NULL,
      quantity INTEGER NOT NULL DEFAULT 0 CHECK(quantity >= 0),
      bonus_quantity INTEGER NOT NULL DEFAULT 0 CHECK(bonus_quantity >= 0),
      buy_price REAL NOT NULL DEFAULT 0,
      effective_unit_cost REAL NOT NULL DEFAULT 0,
      sell_price REAL NOT NULL DEFAULT 0,
      expiry_date TEXT,
      line_total REAL NOT NULL DEFAULT 0 CHECK(line_total >= 0),
      CHECK(quantity > 0 OR bonus_quantity > 0),
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(purchase_invoice_id) REFERENCES purchase_invoice(id) ON DELETE CASCADE,
      FOREIGN KEY(medicine_id) REFERENCES medicine(id) ON DELETE SET NULL
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_purchase_invoice_item_invoice ON purchase_invoice_item(purchase_invoice_id);');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_purchase_invoice_item_medicine ON purchase_invoice_item(medicine_id);');
}

/// رقم فاتورة المذخر فريد لنفس المذخر (الفارغ مستثنى) — مقابل قيد
/// unique_purchase_invoice_number_per_supplier على الخادم.
Future<void> _createPurchaseInvoiceNumberIndex(DatabaseExecutor db) async {
  await db.execute('''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_purchase_invoice_number_supplier
    ON purchase_invoice(pharmacy_id, supplier_id, invoice_number)
    WHERE invoice_number IS NOT NULL AND invoice_number != ''
  ''');
}

Future<void> _dedupePurchaseInvoiceNumbers(DatabaseExecutor db) async {
  final groups = await db.rawQuery('''
    SELECT pharmacy_id, supplier_id, invoice_number FROM purchase_invoice
    WHERE invoice_number IS NOT NULL AND invoice_number != ''
    GROUP BY pharmacy_id, supplier_id, invoice_number HAVING COUNT(*) > 1
  ''');
  for (final group in groups) {
    final number = group['invoice_number'] as String;
    final taken = (await db.rawQuery(
      'SELECT invoice_number FROM purchase_invoice WHERE pharmacy_id = ? AND supplier_id = ?',
      [group['pharmacy_id'], group['supplier_id']],
    ))
        .map((r) => r['invoice_number'])
        .toSet();
    final duplicates = await db.rawQuery('''
      SELECT id FROM purchase_invoice
      WHERE pharmacy_id = ? AND supplier_id = ? AND invoice_number = ?
      ORDER BY created_at ASC, id ASC
    ''', [group['pharmacy_id'], group['supplier_id'], number]);
    var suffix = 2;
    for (final row in duplicates.skip(1)) {
      while (taken.contains('$number-$suffix')) {
        suffix++;
      }
      final renamed = '$number-$suffix';
      taken.add(renamed);
      await db.update('purchase_invoice', {'invoice_number': renamed}, where: 'id = ?', whereArgs: [row['id']]);
    }
  }
}

/// v10: تتبّع الربح — avg_cost للدواء، unit_cost لسطر البيع، total_cost
/// للإتلاف، ودفعات صلاحية مخفية (medicine_batch). سعر شراء 0 يعني "غير
/// معروف" فيبقى avg_cost NULL. unit_cost للمبيعات السابقة يبقى NULL (لا تخمين).
Future<void> _upgradeToCostAndBatches(DatabaseExecutor db) async {
  await db.execute('ALTER TABLE medicine ADD COLUMN avg_cost REAL;');
  await db.execute('ALTER TABLE invoice_item ADD COLUMN unit_cost REAL;');
  await db.execute('ALTER TABLE damaged_medicine ADD COLUMN total_cost REAL;');
  await _createMedicineBatchTable(db);
  await db.execute('UPDATE medicine SET avg_cost = buy_price WHERE buy_price > 0;');
  await db.rawInsert('''
    INSERT INTO medicine_batch (medicine_id, quantity, expiry_date, purchase_price, created_at)
    SELECT id, quantity, NULLIF(expiry_date, ''), avg_cost, ? FROM medicine WHERE quantity > 0
  ''', [DateTime.now().toIso8601String()]);
}

/// دفعات الصلاحية المخفية: مجموع quantity = medicine.quantity دائماً.
/// server_id: معرّف الدفعة على الخادم لصفوف كاش الأونلاين (NULL للمحلية).
/// مصدر الدفعة (v11): source = purchase_list / opening_stock (NULL للأقدم)،
/// supplier_id/purchase_invoice_id للدفعات المحلية فقط؛ صفوف كاش الخادم لا
/// تملك مذخراً/فاتورة محليين فتحمل الاسم والرقم نصاً (supplier_name/invoice_number).
Future<void> _createMedicineBatchTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE medicine_batch(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      medicine_id INTEGER NOT NULL,
      quantity INTEGER NOT NULL CHECK(quantity >= 0),
      expiry_date TEXT,
      purchase_price REAL,
      created_at TEXT NOT NULL,
      server_id INTEGER,
      source TEXT,
      supplier_id INTEGER,
      purchase_invoice_id INTEGER,
      supplier_name TEXT,
      invoice_number TEXT,
      FOREIGN KEY(medicine_id) REFERENCES medicine(id) ON DELETE CASCADE,
      FOREIGN KEY(supplier_id) REFERENCES pharmacy_supplier(id) ON DELETE SET NULL,
      FOREIGN KEY(purchase_invoice_id) REFERENCES purchase_invoice(id) ON DELETE SET NULL
    )
  ''');
  await db.execute('CREATE INDEX idx_medicine_batch_medicine ON medicine_batch(medicine_id, expiry_date);');
}

/// v9: فصل نطاق معرّفات الصفوف المحلية عن معرّفات الخادم (راجع localIdBase).
///
/// كل صف محلي (أوفلاين) قائم بمعرّف < localIdBase يُنقل إلى (معرّفه +
/// localIdBase) — تحويل حتمي بلا تصادم لأن المعرّفات الأصلية فريدة — ومعه كل
/// المراجع إليه. "محلي" يُحدَّد هكذا:
///  - warehouses / medicine / invoice / expense: last_synced_at IS NULL
///    (صفوف الكاش يكتبها الخادم دائماً بقيمة غير NULL).
///  - damaged_medicine: لا يملك last_synced_at؛ سجل التالف محلي إن لم يكن
///    دواؤه صف كاش خادم (سجلات كاش الخادم تشير دائماً لأدوية الخادم).
/// قيود FOREIGN KEY معطّلة طوال الترقية (onConfigure)، فترتيب التحديثات لا
/// يهم، والمراجع تبقى صحيحة في النهاية (يتحقق منها الاختبار بـforeign_key_check).
/// ثم يُعاد بناء جدول invoice لإزالة UNIQUE عن invoice_number.
Future<void> _upgradeToSeparateIdRanges(DatabaseExecutor db) async {
  const b = localIdBase;

  // 1) سجلات التالف المحلية (قبل نقل معرّفات الأدوية التي يعتمد عليها التحديد).
  await db.execute('''
    UPDATE damaged_medicine SET id = id + $b
    WHERE id < $b
      AND medicine_id NOT IN (SELECT id FROM medicine WHERE last_synced_at IS NOT NULL)
  ''');

  // 2) المخازن المحلية ومراجعها.
  const localWarehouses = 'SELECT id FROM warehouses WHERE last_synced_at IS NULL AND id < $b';
  await db.execute('UPDATE medicine SET warehouse_id = warehouse_id + $b WHERE warehouse_id IN ($localWarehouses)');
  await db.execute('UPDATE stock_transfers SET from_warehouse_id = from_warehouse_id + $b WHERE from_warehouse_id IN ($localWarehouses)');
  await db.execute('UPDATE stock_transfers SET to_warehouse_id = to_warehouse_id + $b WHERE to_warehouse_id IN ($localWarehouses)');
  await db.execute('UPDATE warehouses SET id = id + $b WHERE last_synced_at IS NULL AND id < $b');

  // 3) الأدوية المحلية ومراجعها (أصناف الفواتير وسجلات التالف).
  const localMedicines = 'SELECT id FROM medicine WHERE last_synced_at IS NULL AND id < $b';
  await db.execute('UPDATE invoice_item SET medicine_id = medicine_id + $b WHERE medicine_id IN ($localMedicines)');
  await db.execute('UPDATE damaged_medicine SET medicine_id = medicine_id + $b WHERE medicine_id IN ($localMedicines)');
  await db.execute('UPDATE medicine SET id = id + $b WHERE last_synced_at IS NULL AND id < $b');

  // 4) الفواتير المحلية وأصنافها.
  const localInvoices = 'SELECT id FROM invoice WHERE last_synced_at IS NULL AND id < $b';
  await db.execute('UPDATE invoice_item SET invoice_id = invoice_id + $b WHERE invoice_id IN ($localInvoices)');
  await db.execute('UPDATE invoice SET id = id + $b WHERE last_synced_at IS NULL AND id < $b');

  // 5) المصروفات المحلية (لا مراجع إليها).
  await db.execute('UPDATE expense SET id = id + $b WHERE last_synced_at IS NULL AND id < $b');

  // 6) إعادة بناء invoice بلا UNIQUE على invoice_number (بنفس المعرّفات).
  await _createInvoiceTable(db, 'invoice_v9');
  await db.execute('''
    INSERT INTO invoice_v9 (
      id, pharmacy_id, invoice_number, cashier_id, cashier_name_synced,
      total_amount, discount, final_amount, created_at, is_refunded, last_synced_at
    )
    SELECT
      id, pharmacy_id, invoice_number, cashier_id, cashier_name_synced,
      total_amount, discount, final_amount, created_at, is_refunded, last_synced_at
    FROM invoice
  ''');
  await db.execute('DROP TABLE invoice;');
  await db.execute('ALTER TABLE invoice_v9 RENAME TO invoice;');
  await _createInvoiceIndexes(db);

  // 7) أي صف محلي جديد من الآن يُعطى معرّفاً في النطاق المحلي.
  await _ensureLocalIdSequences(db);
}

/// جدول سجل عمليات نقل المخزون بين مخازن نفس الصيدلية. لا يُخزَّن
/// medicine_id لأن صف المصدر قد يُحذف بعد النقل الكامل (راجع transferStock).
Future<void> _createStockTransfersTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE stock_transfers(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      from_warehouse_id INTEGER,
      to_warehouse_id INTEGER,
      from_warehouse_name TEXT NOT NULL DEFAULT '',
      to_warehouse_name TEXT NOT NULL DEFAULT '',
      trade_name TEXT NOT NULL,
      barcode TEXT,
      quantity INTEGER NOT NULL CHECK(quantity > 0),
      transferred_at TEXT NOT NULL,
      notes TEXT,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(from_warehouse_id) REFERENCES warehouses(id) ON DELETE SET NULL,
      FOREIGN KEY(to_warehouse_id) REFERENCES warehouses(id) ON DELETE SET NULL
    )
  ''');
  await db.execute('CREATE INDEX idx_stock_transfers_pharmacy ON stock_transfers(pharmacy_id, transferred_at);');
}

  //==========================================
// إغلاق قاعدة البيانات
//==========================================

//==========================================
// حذف جميع البيانات من الجداول
//==========================================

//==========================================
// حذف قاعدة البيانات بالكامل
//==========================================

//==========================================
// إعادة إنشاء قاعدة البيانات
//==========================================

//==========================================
// Pharmacy Branch CRUD
//==========================================

Future<Map<String, dynamic>?> getPharmacy(int id) async {

  final db = await database;

  final result = await db.query(
    'pharmacy_branch',
    where: 'id=?',
    whereArgs: [id],
  );

  if (result.isEmpty) return null;

  return result.first;

}

//====================================================
// Medicine CRUD
//====================================================

// إضافة دواء جديد
// ⚠️ منذ إضافة تعدد المخازن، خريطة medicine يجب أن تحتوي warehouse_id
// (عمود NOT NULL الآن) - مرّر ensureMainWarehouse(pharmacyId) كقيمة
// افتراضية من شاشة الإضافة العادية، أو معرّف المخزن الثاني إن كانت
// الإضافة صراحة لمخزن ثانوي.
//
// avg_cost الأولي = سعر الشراء (إن كان > 0، وإلا يبقى NULL = غير معروف)،
// والكمية الأولية تصبح أول دفعة صلاحية.
Future<int> insertMedicine(Map<String, dynamic> medicine) async {
  final db = await database;
  return db.transaction((txn) async {
    final row = Map<String, dynamic>.from(medicine);
    final expiry = (row['expiry_date'] as String?)?.trim();
    row['expiry_date'] = (expiry == null || expiry.isEmpty) ? null : expiry;
    final buyPrice = (row['buy_price'] as num?)?.toDouble() ?? 0;
    if (row['avg_cost'] == null && buyPrice > 0) row['avg_cost'] = roundCost(buyPrice);
    final id = await txn.insert('medicine', row, conflictAlgorithm: ConflictAlgorithm.abort);
    final quantity = (row['quantity'] as num?)?.toInt() ?? 0;
    if (quantity > 0) {
      await txn.insert('medicine_batch', {
        'medicine_id': id,
        'quantity': quantity,
        'expiry_date': row['expiry_date'],
        'purchase_price': row['avg_cost'],
        'created_at': DateTime.now().toIso8601String(),
      });
    }
    return id;
  });
}

// جميع أدوية الصيدلية. warehouseId اختياري: مرّره لتقييد النتيجة بمخزن
// واحد فقط (مثلاً POS يمرر دائماً المخزن الرئيسي - راجع
// WarehouseRepository.getMainWarehouseId) - بدونه تُعاد أصناف كل مخازن
// الصيدلية معاً (لشاشة الجرد العامة).
//
// كل صف يحمل sellable_quantity: الكمية في الدفعات غير المنتهية (ما يمكن
// بيعه فعلاً؛ البيع يخصم منها بترتيب FEFO).
Future<List<Map<String, dynamic>>> getMedicines(int pharmacyId, {int? warehouseId}) async {
  final db = await database;
  return db.rawQuery('''
    SELECT medicine.*, $sellableQuantitySql
    FROM medicine
    WHERE pharmacy_id = ? ${warehouseId != null ? 'AND warehouse_id = ?' : ''} AND ${originFilter()}
    ORDER BY trade_name COLLATE NOCASE ASC
  ''', [pharmacyId, if (warehouseId != null) warehouseId]);
}

// تعديل دواء
//
// الكمية والصلاحية مشتقتان من الدفعات (تتغيران فقط بالتوريد/البيع/الإتلاف/
// النقل)، وavg_cost يحسبه التوريد — تُتجاهل هنا كما في MedicineSerializer.
Future<int> updateMedicine(int id, Map<String, dynamic> medicine) async {
  final db = await database;
  final values = Map<String, dynamic>.from(medicine)
    ..remove('quantity')
    ..remove('expiry_date')
    ..remove('avg_cost');
  return await db.update(
    'medicine',
    values,
    where: 'id = ?',
    whereArgs: [id],
  );
}

  //====================================================
  // متوسط الكلفة + دفعات الصلاحية المخفية (نفس pharmacy_data/stock.py)
  //
  // medicine.quantity = مجموع medicine_batch.quantity دائماً، وexpiry_date
  // = أقرب انتهاء بين الدفعات المتوفرة. كل تغيير للمخزون يمر من هنا داخل
  // معاملة: البيع FEFO من الدفعات غير المنتهية، والإتلاف/النقل FEFO من كلها.
  //====================================================

  /// الكلفة بـ4 خانات عشرية (كي لا يتراكم خطأ التقريب في كلفة البضاعة المباعة).
  static double? roundCost(num? value) => value == null ? null : (value * 10000).round() / 10000;

  static double roundMoney(num value) => (value * 100).round() / 100;

  /// كلفة سجل إتلاف (dm) بدوائه (m، LEFT JOIN): total_cost المسجّلة، وإلا
  /// الكمية × (avg_cost ثم buy_price). قاعدة واحدة لصافي الربح وتقرير الخسائر.
  static const String damageCostSql =
      'COALESCE(dm.total_cost, dm.quantity_damaged * COALESCE(m.avg_cost, m.buy_price, 0))';

  static double weightedAverageCost({
    required int oldQty,
    required double? oldAvg,
    required int newQty,
    required double newCost,
  }) {
    if (oldQty <= 0 || oldAvg == null) return roundCost(newCost)!;
    return roundCost((oldQty * oldAvg + newQty * newCost) / (oldQty + newQty))!;
  }

  /// avg_cost بعد استرجاع لمذخر: الوحدات المسترجعة تخرج بمبلغ رصيدها
  /// ([costRemoved] = الوحدات المحسوبة × سعر الاسترجاع؛ البونص/المجاني = 0)،
  /// فيبقى على الباقي ما دُفع فعلاً صافياً من الأرصدة. نفس stock.avg_cost_after_return.
  /// - لا يبقى مخزون أو كلفة غير معروفة: avg_cost كما هو.
  /// - نتيجة سالبة: 0.
  static double? avgCostAfterReturn({
    required int oldQty,
    required double? oldAvg,
    required int returnedQty,
    required double costRemoved,
  }) {
    final left = oldQty - returnedQty;
    if (left <= 0 || oldAvg == null) return oldAvg;
    // حساب صحيح بوحدات 0.0001 (avg_cost بأربع منازل والرصيد بمنزلتين) كي يطابق
    // Decimal في الخادم حرفياً (ROUND_HALF_UP) بلا أخطاء الفاصلة العائمة.
    final numerator = oldQty * (oldAvg * 10000).round() - (costRemoved * 10000).round();
    if (numerator <= 0) return 0;
    return ((2 * numerator + left) ~/ (2 * left)) / 10000;
  }

  static const String _sellableBatch =
      "(b.expiry_date IS NULL OR b.expiry_date = '' OR date(b.expiry_date) >= date('now', 'localtime'))";

  /// عمود sellable_quantity لاستعلام على جدول medicine (بلا اسم مستعار). دواء
  /// بلا أي دفعة (كاش من خادم أقدم) يُقيَّم بصلاحيته المجمّعة كما في السابق.
  static const String sellableQuantitySql = '''
    CASE WHEN EXISTS (SELECT 1 FROM medicine_batch b WHERE b.medicine_id = medicine.id)
      THEN (SELECT COALESCE(SUM(b.quantity), 0) FROM medicine_batch b
            WHERE b.medicine_id = medicine.id AND $_sellableBatch)
      ELSE CASE WHEN medicine.expiry_date IS NULL OR medicine.expiry_date = ''
                  OR date(medicine.expiry_date) >= date('now', 'localtime')
             THEN medicine.quantity ELSE 0 END
    END AS sellable_quantity''';

  Future<Map<String, Object?>> _medicineRow(DatabaseExecutor txn, int medicineId) async {
    final rows = await txn.query('medicine', where: 'id = ?', whereArgs: [medicineId], limit: 1);
    if (rows.isEmpty) throw StateError('الصنف غير موجود.');
    return rows.first;
  }

  /// يعيد ضبط quantity وexpiry_date المشتقّين من الدفعات.
  Future<void> _refreshMedicineStock(DatabaseExecutor txn, int medicineId) async {
    final rows = await txn.rawQuery('''
      SELECT COALESCE(SUM(quantity), 0) AS total,
             MIN(NULLIF(expiry_date, '')) AS nearest
      FROM medicine_batch WHERE medicine_id = ? AND quantity > 0
    ''', [medicineId]);
    final total = (rows.first['total'] as num).toInt();
    await txn.update(
      'medicine',
      {'quantity': total, if (total > 0) 'expiry_date': rows.first['nearest']},
      where: 'id = ?',
      whereArgs: [medicineId],
    );
  }

  /// كمية غير مغطاة بدفعات (صف أقدم/معدَّل يدوياً) تُعطى دفعة بالفرق كي لا تُفقد.
  Future<void> _reconcileBatches(DatabaseExecutor txn, Map<String, Object?> medicine) async {
    final medicineId = medicine['id'] as int;
    final covered = Sqflite.firstIntValue(await txn.rawQuery(
          'SELECT COALESCE(SUM(quantity), 0) FROM medicine_batch WHERE medicine_id = ?',
          [medicineId],
        )) ??
        0;
    final quantity = (medicine['quantity'] as num?)?.toInt() ?? 0;
    if (quantity > covered) {
      final expiry = (medicine['expiry_date'] as String?)?.trim();
      await txn.insert('medicine_batch', {
        'medicine_id': medicineId,
        'quantity': quantity - covered,
        'expiry_date': (expiry == null || expiry.isEmpty) ? null : expiry,
        'purchase_price': medicine['avg_cost'],
        'created_at': DateTime.now().toIso8601String(),
      });
    }
  }

  Future<void> _addBatch(
    DatabaseExecutor txn, {
    required int medicineId,
    required int quantity,
    String? expiryDate,
    double? purchasePrice,
    String? source,
    int? supplierId,
    int? purchaseInvoiceId,
  }) async {
    await txn.insert('medicine_batch', {
      'medicine_id': medicineId,
      'quantity': quantity,
      'expiry_date': (expiryDate == null || expiryDate.trim().isEmpty) ? null : expiryDate.trim(),
      'purchase_price': roundCost(purchasePrice),
      'created_at': DateTime.now().toIso8601String(),
      'source': source,
      'supplier_id': supplierId,
      'purchase_invoice_id': purchaseInvoiceId,
    });
    await _refreshMedicineStock(txn, medicineId);
  }

  /// يخصم [quantity] بترتيب FEFO (الأقرب انتهاءً أولاً، بلا تاريخ أخيراً) مع
  /// التقسيم بين الدفعات، ويحذف المستنفدة. [sellableOnly] (البيع) يتجاهل
  /// الدفعات المنتهية. يرجع الأجزاء المأخوذة بمصدرها (لنقلها كما هي بين المخازن).
  Future<List<Map<String, Object?>>> _deductFefo(
    DatabaseExecutor txn,
    int medicineId,
    int quantity, {
    required bool sellableOnly,
    int? preferInvoiceId,
  }) async {
    final medicine = await _medicineRow(txn, medicineId);
    await _reconcileBatches(txn, medicine);
    // استرجاع لمذخر ([preferInvoiceId]): دفعات تلك الفاتورة أولاً ثم FEFO.
    final batches = await txn.rawQuery('''
      SELECT * FROM medicine_batch b
      WHERE b.medicine_id = ? AND b.quantity > 0 ${sellableOnly ? 'AND $_sellableBatch' : ''}
      ORDER BY ${preferInvoiceId != null ? 'CASE WHEN b.purchase_invoice_id = ? THEN 0 ELSE 1 END ASC,' : ''}
               (b.expiry_date IS NULL OR b.expiry_date = '') ASC, b.expiry_date ASC, b.id ASC
    ''', [medicineId, if (preferInvoiceId != null) preferInvoiceId]);

    var remaining = quantity;
    final taken = <Map<String, Object?>>[];
    for (final batch in batches) {
      if (remaining == 0) break;
      final batchQty = batch['quantity'] as int;
      final part = batchQty < remaining ? batchQty : remaining;
      taken.add({
        'quantity': part,
        'expiry_date': batch['expiry_date'],
        'purchase_price': batch['purchase_price'],
        // مصدر الدفعة ينتقل معها (التتبّع للمذخر/الفاتورة يبقى بعد النقل).
        'source': batch['source'],
        'supplier_id': batch['supplier_id'],
        'purchase_invoice_id': batch['purchase_invoice_id'],
        'supplier_name': batch['supplier_name'],
        'invoice_number': batch['invoice_number'],
      });
      remaining -= part;
      if (part == batchQty) {
        await txn.delete('medicine_batch', where: 'id = ?', whereArgs: [batch['id']]);
      } else {
        await txn.update('medicine_batch', {'quantity': batchQty - part}, where: 'id = ?', whereArgs: [batch['id']]);
      }
    }
    if (remaining > 0) {
      throw StateError(sellableOnly
          ? 'الكمية الصالحة (غير المنتهية) من ${medicine['trade_name']} غير كافية.'
          : 'الكمية المتوفرة من ${medicine['trade_name']} غير كافية.');
    }
    await _refreshMedicineStock(txn, medicineId);
    return taken;
  }

  /// إرجاع: الكمية تعود لأبعد دفعة انتهاءً، أو لدفعة جديدة إن لم توجد.
  /// avg_cost لا يتغير.
  Future<void> _restoreToLatestBatch(DatabaseExecutor txn, int medicineId, int quantity) async {
    final medicine = await _medicineRow(txn, medicineId);
    await _reconcileBatches(txn, medicine);
    final latest = await txn.rawQuery('''
      SELECT id, quantity FROM medicine_batch WHERE medicine_id = ?
      ORDER BY (expiry_date IS NULL OR expiry_date = '') ASC, expiry_date DESC, id DESC
      LIMIT 1
    ''', [medicineId]);
    if (latest.isNotEmpty) {
      await txn.update(
        'medicine_batch',
        {'quantity': (latest.first['quantity'] as int) + quantity},
        where: 'id = ?',
        whereArgs: [latest.first['id']],
      );
      await _refreshMedicineStock(txn, medicineId);
    } else {
      await _addBatch(
        txn,
        medicineId: medicineId,
        quantity: quantity,
        expiryDate: medicine['expiry_date'] as String?,
        purchasePrice: (medicine['avg_cost'] as num?)?.toDouble(),
      );
    }
  }

  /// تقرير الربح للفترة [start]..[end] (YYYY-MM-DD)، نفس _profit_summary في الخادم:
  ///   revenue = صافي الفواتير غير المسترجعة.
  ///   cost_of_goods_sold = Σ(unit_cost × الكمية) للأسطر ذات الكلفة المعروفة.
  ///   gross_profit = Σ(إجمالي السطر − كلفته) − حصة تلك الأسطر من خصم فاتورتها.
  ///   net_profit = gross_profit − المصاريف − كلفة الإتلاف (بلا "تصحيح إدخال").
  /// الأسطر بلا unit_cost (مبيعات قديمة) تُستبعد وتُعدّ في items_without_cost.
  Future<Map<String, num>> getProfitSummary(int pharmacyId, {required String start, required String end}) async {
    final db = await database;
    final invoices = await db.rawQuery('''
      SELECT i.id, i.final_amount, i.total_amount, i.discount,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NOT NULL THEN ii.total_price END), 0) AS costed_total,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NOT NULL THEN ii.unit_cost * ii.quantity END), 0) AS cogs,
             COALESCE(SUM(CASE WHEN ii.id IS NOT NULL AND ii.unit_cost IS NULL THEN 1 ELSE 0 END), 0) AS missing
      FROM invoice i
      LEFT JOIN invoice_item ii ON ii.invoice_id = i.id
      WHERE i.pharmacy_id = ? AND ${originFilter('i.')} AND i.is_refunded = 0
        AND date(i.created_at) >= date(?) AND date(i.created_at) <= date(?)
      GROUP BY i.id
    ''', [pharmacyId, start, end]);

    double revenue = 0, cogs = 0, gross = 0;
    int missing = 0;
    for (final row in invoices) {
      final costedTotal = (row['costed_total'] as num).toDouble();
      final total = (row['total_amount'] as num).toDouble();
      final discount = (row['discount'] as num).toDouble();
      revenue += (row['final_amount'] as num).toDouble();
      cogs += (row['cogs'] as num).toDouble();
      missing += (row['missing'] as num).toInt();
      // نفس الخادم: حصة الخصم تُطبَّق متى كان != 0 (حتى خصم سالب قديم).
      gross += costedTotal - (discount != 0 && total > 0 ? discount * costedTotal / total : 0);
    }
    gross -= cogs;

    final expenses = (await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS total FROM expense
      WHERE pharmacy_id = ? AND ${originFilter()} AND date(expense_date) >= date(?) AND date(expense_date) <= date(?)
    ''', [pharmacyId, start, end])).first['total'] as num;
    // كلفة الإتلاف: المسجّلة وقت الإتلاف، وإلا الكمية × (avg_cost ثم buy_price) —
    // نفس damageCostSql وreports.DAMAGE_COST في الخادم.
    final damageCost = (await db.rawQuery('''
      SELECT COALESCE(SUM($damageCostSql), 0) AS total
      FROM damaged_medicine dm LEFT JOIN medicine m ON m.id = dm.medicine_id
      WHERE dm.pharmacy_id = ? AND ${originFilter('dm.')} AND COALESCE(dm.reason, '') != 'correction'
        AND date(dm.damaged_at) >= date(?) AND date(dm.damaged_at) <= date(?)
    ''', [pharmacyId, start, end])).first['total'] as num;

    return {
      'revenue': roundMoney(revenue),
      'cost_of_goods_sold': roundMoney(cogs),
      'gross_profit': roundMoney(gross),
      'damage_cost': roundMoney(damageCost),
      'net_profit': roundMoney(gross - expenses - damageCost),
      'items_without_cost': missing,
    };
  }

  /// دفعات الصنف المتوفرة (الأقرب انتهاءً أولاً) — لعرض تفاصيلها عند النقر،
  /// مع مصدرها: supplier_name/invoice_number من المذخر والفاتورة المحليين، أو
  /// النص المخزّن لصفوف كاش الخادم، وsource ('opening_stock' = رصيد افتتاحي).
  Future<List<Map<String, dynamic>>> getMedicineBatches(int medicineId) async {
    final db = await database;
    return db.rawQuery('''
      SELECT b.id, b.medicine_id, b.quantity, b.expiry_date, b.purchase_price, b.created_at,
             b.server_id, b.source, b.supplier_id, b.purchase_invoice_id,
             COALESCE(s.name, b.supplier_name) AS supplier_name,
             COALESCE(pi.invoice_number, b.invoice_number) AS invoice_number
      FROM medicine_batch b
      LEFT JOIN pharmacy_supplier s ON s.id = b.supplier_id
      LEFT JOIN purchase_invoice pi ON pi.id = b.purchase_invoice_id
      WHERE b.medicine_id = ? AND b.quantity > 0
      ORDER BY (b.expiry_date IS NULL OR b.expiry_date = '') ASC, b.expiry_date ASC, b.id ASC
    ''', [medicineId]);
  }

// حذف دواء
  Future<int> deleteMedicine(int id) async {
    final db = await database;
    return await db.delete(
      'medicine',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  //====================================================
  // Warehouses CRUD (خاصية الباقة الذهبية: تعدد المخازن)
  //
  // دوال الكتابة هنا للوضع الأوفلاين (SQLite محلي هو مصدر الحقيقة). في وضع
  // الأونلاين تمر الشاشات عبر WarehouseRepository التي تكتب على الخادم ثم
  // تحدّث الكاش هنا عبر replaceWarehousesCache/applyServerTransfer.
  //
  // صفوف المخازن نوعان: محلية (معرّف >= localIdBase، أُنشئت أوفلاين) وكاش
  // خادم (last_synced_at غير NULL، معرّفها هو معرّف الخادم). الوضع الأونلاين
  // يقرأ الكاش فقط (syncedOnly: true) حتى لا يظهر مخزن رئيسي محلي قديم
  // بجانب الرئيسي الحقيقي على الخادم.
  //====================================================

  static const String mainWarehouseName = 'المخزن الرئيسي';

  String _warehouseScope(bool syncedOnly) =>
      syncedOnly ? 'id < $localIdBase' : 'id >= $localIdBase';

  /// يعيد المخزن الرئيسي المحلي للصيدلية (ينشئه إن لم يوجد بعد - حالة
  /// صيدلية جديدة كلياً لم يمر عليها أي إدخال دواء/فاتورة سابقاً). للوضع
  /// الأوفلاين فقط؛ الأونلاين يستخدم getMainWarehouseId(syncedOnly: true).
  Future<int> ensureMainWarehouse(int pharmacyId) async {
    final existing = await getMainWarehouseId(pharmacyId, syncedOnly: false);
    if (existing != null) return existing;

    final db = await database;
    return await db.insert('warehouses', {
      'pharmacy_id': pharmacyId,
      'name': mainWarehouseName,
      'is_main': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<int?> getMainWarehouseId(int pharmacyId, {required bool syncedOnly}) async {
    final db = await database;
    final rows = await db.query(
      'warehouses',
      columns: ['id'],
      where: 'pharmacy_id = ? AND is_main = 1 AND ${_warehouseScope(syncedOnly)}',
      whereArgs: [pharmacyId],
      orderBy: 'id ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  /// مخازن الصيدلية (الرئيسي أولاً) مع إجمالي الكمية وعدد الأصناف في كل منها.
  Future<List<Map<String, dynamic>>> getWarehouses(int pharmacyId, {bool syncedOnly = false}) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT w.*,
        COALESCE((SELECT SUM(m.quantity) FROM medicine m WHERE m.warehouse_id = w.id), 0) AS total_quantity,
        (SELECT COUNT(*) FROM medicine m WHERE m.warehouse_id = w.id AND m.quantity > 0) AS item_count
      FROM warehouses w
      WHERE w.pharmacy_id = ? AND w.${_warehouseScope(syncedOnly)}
      ORDER BY w.is_main DESC, w.id ASC
    ''', [pharmacyId]);
  }

  Future<void> _assertUniqueWarehouseName(int pharmacyId, String name, {int? exceptId}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT 1 FROM warehouses
      WHERE pharmacy_id = ? AND id >= $localIdBase
        AND LOWER(TRIM(name)) = LOWER(TRIM(?)) AND id != ?
      LIMIT 1
    ''', [pharmacyId, name, exceptId ?? -1]);
    if (rows.isNotEmpty) {
      throw StateError('يوجد مخزن آخر بنفس الاسم.');
    }
  }

  /// إضافة مخزن إضافي (أوفلاين). [maxWarehouses] هو الحد الكلي شاملاً
  /// الرئيسي (SubscriptionEntitlements.maxWarehouses) — نفس الحد الذي يفرضه
  /// الخادم أونلاين.
  Future<int> addWarehouse({
    required int pharmacyId,
    required String name,
    required int maxWarehouses,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw StateError('اسم المخزن مطلوب.');

    await ensureMainWarehouse(pharmacyId);
    await _assertUniqueWarehouseName(pharmacyId, trimmed);

    final db = await database;
    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM warehouses WHERE pharmacy_id = ? AND id >= $localIdBase',
      [pharmacyId],
    )) ?? 0;

    if (count >= maxWarehouses) {
      throw StateError('وصلت للحد الأقصى لعدد المخازن في باقتك ($maxWarehouses).');
    }

    return await db.insert('warehouses', {
      'pharmacy_id': pharmacyId,
      'name': trimmed,
      'is_main': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> renameWarehouse(int warehouseId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) throw StateError('اسم المخزن مطلوب.');
    final db = await database;
    final rows = await db.query('warehouses', where: 'id = ?', whereArgs: [warehouseId], limit: 1);
    if (rows.isEmpty) throw StateError('المخزن غير موجود.');
    await _assertUniqueWarehouseName(rows.first['pharmacy_id'] as int, trimmed, exceptId: warehouseId);
    await db.update('warehouses', {'name': trimmed}, where: 'id = ?', whereArgs: [warehouseId]);
  }

  /// صف دواء له سجل مبيعات أو تالف لا يُحذف (قيد FOREIGN KEY بلا CASCADE).
  Future<bool> _isMedicineReferenced(DatabaseExecutor txn, int medicineId) async {
    final rows = await txn.rawQuery('''
      SELECT 1 FROM invoice_item WHERE medicine_id = ?
      UNION ALL
      SELECT 1 FROM damaged_medicine WHERE medicine_id = ?
      LIMIT 1
    ''', [medicineId, medicineId]);
    return rows.isNotEmpty;
  }

  /// حذف مخزن إضافي (أوفلاين). لا يحذف الرئيسي أبداً، ويرفض حذف مخزن فيه
  /// كمية مخزون > 0 حتى لا يُفقَد أثر المخزون بصمت. الأصناف ذات الكمية صفر
  /// تُحذف معه إن لم يكن لها سجل مبيعات/تالف (نفس قاعدة الخادم).
  Future<void> deleteWarehouse(int warehouseId) async {
    final db = await database;
    await db.transaction((txn) async {
      final warehouse = await txn.query('warehouses', where: 'id = ?', whereArgs: [warehouseId], limit: 1);
      if (warehouse.isEmpty) return;
      if ((warehouse.first['is_main'] as int) == 1) {
        throw StateError('لا يمكن حذف المخزن الرئيسي.');
      }

      final medicines = await txn.query('medicine', where: 'warehouse_id = ?', whereArgs: [warehouseId]);
      if (medicines.any((m) => ((m['quantity'] as num?) ?? 0) > 0)) {
        throw StateError('لا يمكن حذف مخزن يحتوي على كمية مخزون. انقل الأصناف أولاً.');
      }
      for (final medicine in medicines) {
        if (await _isMedicineReferenced(txn, medicine['id'] as int)) {
          throw StateError(
            'لا يمكن حذف المخزن: الصنف ${medicine['trade_name']} فيه له سجل مبيعات أو إتلاف.',
          );
        }
        await txn.delete('medicine', where: 'id = ?', whereArgs: [medicine['id']]);
      }

      // سجل النقل يبقى (ON DELETE SET NULL + أسماء المخازن محفوظة نصاً).
      await txn.delete('warehouses', where: 'id = ?', whereArgs: [warehouseId]);
    });
  }

  /// ينقل كمية من صنف موجود في مخزن إلى مخزن آخر لنفس الصيدلية (أوفلاين).
  /// يرفض نقل كمية أكبر من الموجودة. إن وُجد بالفعل صنف بنفس الباركود (أو
  /// بنفس الاسم إن كان بلا باركود) في المخزن الهدف يُزاد رصيده، وإلا يُنشأ
  /// صف جديد هناك. صف المصدر يُحذف إن أصبحت كميته صفراً، إلا إن كان له سجل
  /// مبيعات/تالف فيبقى بكمية صفر (حذفه كان يُفشل النقل كله بقيد FOREIGN KEY).
  /// نفس منطق WarehouseViewSet.transfer على الخادم تماماً.
  Future<void> transferStock({
    required int sourceMedicineId,
    required int toWarehouseId,
    required int quantity,
    String? notes,
  }) async {
    if (quantity <= 0) {
      throw StateError('الكمية المنقولة يجب أن تكون أكبر من صفر.');
    }
    final db = await database;

    await db.transaction((txn) async {
      final sourceRows = await txn.query('medicine', where: 'id = ?', whereArgs: [sourceMedicineId], limit: 1);
      if (sourceRows.isEmpty) throw StateError('الصنف غير موجود.');
      final source = sourceRows.first;

      final fromWarehouseId = source['warehouse_id'] as int;
      if (fromWarehouseId == toWarehouseId) {
        throw StateError('المخزن المصدر والهدف متطابقان.');
      }
      final currentQty = source['quantity'] as int;
      if (quantity > currentQty) {
        throw StateError('الكمية المطلوب نقلها أكبر من الكمية المتوفرة.');
      }

      final fromWarehouseRows = await txn.query('warehouses', where: 'id = ?', whereArgs: [fromWarehouseId], limit: 1);
      final toWarehouseRows = await txn.query('warehouses', where: 'id = ?', whereArgs: [toWarehouseId], limit: 1);
      if (toWarehouseRows.isEmpty) throw StateError('المخزن الهدف غير موجود.');
      final sourcePharmacyId = source['pharmacy_id'] as int;
      if (toWarehouseRows.first['pharmacy_id'] as int != sourcePharmacyId) {
        throw StateError('لا يمكن النقل إلا بين مخازن نفس الصيدلية.');
      }

      final barcode = ((source['barcode'] as String?) ?? '').trim();
      List<Map<String, dynamic>> destMatch;
      if (barcode.isNotEmpty) {
        destMatch = await txn.query(
          'medicine',
          where: 'warehouse_id = ? AND barcode = ?',
          whereArgs: [toWarehouseId, barcode],
          limit: 1,
        );
      } else {
        destMatch = await txn.query(
          'medicine',
          where: "warehouse_id = ? AND trade_name = ? AND (barcode IS NULL OR barcode = '')",
          whereArgs: [toWarehouseId, source['trade_name']],
          limit: 1,
        );
      }

      // الدفعات تنتقل كما هي (FEFO من المصدر بصلاحيتها وسعر شرائها)، وavg_cost
      // للهدف يُرجَّح بكلفة المصدر — نفس WarehouseViewSet.transfer.
      final sourceAvg = (source['avg_cost'] as num?)?.toDouble();
      final moved = await _deductFefo(txn, sourceMedicineId, quantity, sellableOnly: false);

      int targetId;
      if (destMatch.isNotEmpty) {
        final target = destMatch.first;
        targetId = target['id'] as int;
        await _reconcileBatches(txn, target);
        if (sourceAvg != null) {
          await txn.update(
            'medicine',
            {
              'avg_cost': weightedAverageCost(
                oldQty: (target['quantity'] as num).toInt(),
                oldAvg: (target['avg_cost'] as num?)?.toDouble(),
                newQty: quantity,
                newCost: sourceAvg,
              ),
            },
            where: 'id = ?',
            whereArgs: [targetId],
          );
        }
      } else {
        targetId = await txn.insert('medicine', {
          'pharmacy_id': sourcePharmacyId,
          'warehouse_id': toWarehouseId,
          'trade_name': source['trade_name'],
          'scientific_name': source['scientific_name'],
          'category': source['category'],
          'quantity': 0,
          'buy_price': source['buy_price'],
          'sell_price': source['sell_price'],
          'avg_cost': sourceAvg,
          'expiry_date': source['expiry_date'],
          'shelf_location': source['shelf_location'],
          'is_damaged': 0,
          'barcode': barcode.isNotEmpty ? barcode : null,
        });
      }
      for (final part in moved) {
        await txn.insert('medicine_batch', {
          ...part,
          'medicine_id': targetId,
          'created_at': DateTime.now().toIso8601String(),
        });
      }
      await _refreshMedicineStock(txn, targetId);

      final sourceAfter = await _medicineRow(txn, sourceMedicineId);
      if ((sourceAfter['quantity'] as int) == 0 && !await _isMedicineReferenced(txn, sourceMedicineId)) {
        await txn.delete('medicine', where: 'id = ?', whereArgs: [sourceMedicineId]);
      }

      await txn.insert('stock_transfers', {
        'pharmacy_id': sourcePharmacyId,
        'from_warehouse_id': fromWarehouseId,
        'to_warehouse_id': toWarehouseId,
        'from_warehouse_name': fromWarehouseRows.isEmpty ? '' : fromWarehouseRows.first['name'],
        'to_warehouse_name': toWarehouseRows.first['name'],
        'trade_name': source['trade_name'],
        'barcode': barcode.isNotEmpty ? barcode : null,
        'quantity': quantity,
        'transferred_at': DateTime.now().toIso8601String(),
        'notes': notes,
      });
    });
  }

  /// سجل عمليات النقل المحلية لصيدلية معيّنة (الأحدث أولاً).
  Future<List<Map<String, dynamic>>> getStockTransfers(int pharmacyId) async {
    final db = await database;
    return await db.query(
      'stock_transfers',
      where: 'pharmacy_id = ?',
      whereArgs: [pharmacyId],
      orderBy: 'transferred_at DESC, id DESC',
    );
  }

  /// يستبدل كاش مخازن الخادم لهذه الصيدلية (أونلاين). مخزن حُذف على الخادم
  /// يُحذف من الكاش إن لم يبقَ فيه أي صف دواء محلي (وإلا يبقى حتى تُزال
  /// أصنافه من الكاش في المزامنة التالية). المخازن المحلية (أوفلاين) لا تُمس.
  Future<void> replaceWarehousesCache({
    required int pharmacyId,
    required List<Map<String, dynamic>> serverItems,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      final serverIds = <int>{};
      for (final item in serverItems) {
        final id = _serverId(item['id']);
        serverIds.add(id);
        final row = <String, dynamic>{
          'id': id,
          'pharmacy_id': pharmacyId,
          'name': (item['name'] as String?) ?? '',
          'is_main': item['is_main'] == true ? 1 : 0,
          'created_at': (item['created_at'] as String?) ?? now,
          'last_synced_at': now,
        };
        await txn.insert('warehouses', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.update('warehouses', row, where: 'id = ?', whereArgs: [id]);
      }

      final cached = await txn.query(
        'warehouses',
        columns: ['id'],
        where: 'pharmacy_id = ? AND id < $localIdBase',
        whereArgs: [pharmacyId],
      );
      for (final row in cached) {
        final id = row['id'] as int;
        if (serverIds.contains(id)) continue;
        final inUse = await txn.rawQuery('SELECT 1 FROM medicine WHERE warehouse_id = ? LIMIT 1', [id]);
        if (inUse.isEmpty) {
          await txn.delete('warehouses', where: 'id = ?', whereArgs: [id]);
        }
      }
    });
  }

  /// يحدّث الكاش المحلي من رد WarehouseViewSet.transfer على الخادم: صف الهدف
  /// (جديد أو مدموج) وصف المصدر (كميته الجديدة، أو إزالته إن حذفه الخادم).
  Future<void> applyServerTransfer({
    required int pharmacyId,
    required Map<String, dynamic> response,
  }) async {
    final destination = response['destination'];
    if (destination is Map<String, dynamic>) {
      await upsertMedicineFromServer(pharmacyId: pharmacyId, serverData: destination);
    }
    final source = response['source'];
    if (source is Map<String, dynamic>) {
      await upsertMedicineFromServer(pharmacyId: pharmacyId, serverData: source);
    } else if (response['source_deleted'] == true && response['source_id'] is num) {
      final db = await database;
      await db.transaction((txn) async {
        await _removeCachedMedicine(txn, _serverId(response['source_id']));
      });
    }
  }

  /// يزيل صف دواء من الكاش؛ إن كانت له فواتير/تالف محلية (لا يُحذف بسبب
  /// قيود FOREIGN KEY) يُصفَّر بدلاً من ذلك كي لا يظهر رصيد وهمي للبيع.
  Future<void> _removeCachedMedicine(DatabaseExecutor txn, int medicineId) async {
    if (await _isMedicineReferenced(txn, medicineId)) {
      await txn.update('medicine', {'quantity': 0}, where: 'id = ?', whereArgs: [medicineId]);
      await txn.delete('medicine_batch', where: 'medicine_id = ?', whereArgs: [medicineId]);
    } else {
      await txn.delete('medicine', where: 'id = ?', whereArgs: [medicineId]);
    }
  }
  //====================================================
  // كاش القراءة فقط لوضع الأونلاين — يُستدعى بعد كل قراءة/كتابة ناجحة
  // من السيرفر فقط (MedicineRepository)، ولا يُستدعى أبداً كإدخال مباشر
  // من واجهة المستخدم أثناء العمل أونلاين، وفق القرار المتفق عليه:
  // "السيرفر مصدر البيانات الوحيد، والكاش المحلي read-only".
  //====================================================

  /// يحفظ/يحدّث دواءً واحداً قادماً من استجابة السيرفر، مفتاحه id (وهو معرّف
  /// السيرفر نفسه هنا، لا معرّف محلي مستقل). يتعمّد استخدام
  /// INSERT OR IGNORE ثم UPDATE بدل REPLACE: REPLACE ينفّذ DELETE+INSERT
  /// داخلياً، وبما أن invoice_item.medicine_id وdamaged_medicine.medicine_id
  /// يشيران لهذا الجدول بقيد FOREIGN KEY بلا ON DELETE CASCADE، فسيفشل أي
  /// REPLACE لدواء له فواتير أو سجلات تلف سابقة.
  ///
  /// ⚠️ يفترض هذا حالياً أن الصيدلية بدأت أونلاين من الصفر (بلا بيانات
  /// أوفلاين قديمة لها معرّفات محلية قد تتصادم مع معرّفات السيرفر). انتقال
  /// صيدلية من أوفلاين لأونلاين لاحقاً يحتاج خطوة توفيق (reconciliation)
  /// منفصلة قبل تفعيل هذا الكاش عليها.
  Future<void> upsertMedicineFromServer({
    required int pharmacyId,
    required Map<String, dynamic> serverData,
  }) async {
    final db = await database;
    final fallbackWarehouseId = await _serverMainWarehouseFallback(pharmacyId);

    final row = _serverMedicineRow(
      pharmacyId: pharmacyId,
      item: serverData,
      fallbackWarehouseId: fallbackWarehouseId,
      syncedAt: DateTime.now().toIso8601String(),
    );

    // ⚠️ warehouse_id عمود NOT NULL منذ v7: كان غائباً هنا فكان
    // INSERT OR IGNORE يتجاهل كل صف بصمت ولا يُحفظ أي دواء أونلاين في الكاش.
    await db.transaction((txn) async {
      await txn.insert('medicine', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.update('medicine', row, where: 'id = ?', whereArgs: [row['id']]);
      await _replaceCachedBatches(txn, row['id'] as int, serverData);
    });
  }

  /// يستبدل كامل كاش المخزون المحلي بقائمة كاملة قادمة من السيرفر (بعد
  /// جلب medicine_api_service.fetchMedicines() لكل الصفحات)، داخل معاملة
  /// واحدة لضمان عدم رؤية الشاشات لحالة كاش منتصفة أثناء التحديث.
  ///
  /// يجب تحديث كاش المخازن (replaceWarehousesCache) قبله، لأن كل صف يشير
  /// لمخزنه بقيد FOREIGN KEY. الصفوف المزامَنة سابقاً التي لم تعد موجودة على
  /// الخادم (حُذفت، أو نُقلت كميتها كاملة لمخزن آخر) تُزال من الكاش؛ أما
  /// الصفوف المحلية الأصلية (معرّف >= localIdBase — بيانات أوفلاين لم
  /// تُرفع بعد) فلا تُمس أبداً، حتى لا تضيع قبل الرفع الأولي.
  Future<void> replaceMedicinesCache({
    required int pharmacyId,
    required List<Map<String, dynamic>> serverItems,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final fallbackWarehouseId = await _serverMainWarehouseFallback(pharmacyId);

    await db.transaction((txn) async {
      final serverIds = <int>{};
      for (final item in serverItems) {
        final row = _serverMedicineRow(
          pharmacyId: pharmacyId,
          item: item,
          fallbackWarehouseId: fallbackWarehouseId,
          syncedAt: now,
        );
        serverIds.add(row['id'] as int);

        await txn.insert('medicine', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.update('medicine', row, where: 'id = ?', whereArgs: [row['id']]);
        await _replaceCachedBatches(txn, row['id'] as int, item);
      }

      final cached = await txn.query(
        'medicine',
        columns: ['id'],
        where: 'pharmacy_id = ? AND id < $localIdBase',
        whereArgs: [pharmacyId],
      );
      for (final row in cached) {
        final id = row['id'] as int;
        if (!serverIds.contains(id)) {
          await _removeCachedMedicine(txn, id);
        }
      }
    });
  }

  /// المخزن الرئيسي في كاش الخادم: احتياط لرد سيرفر أقدم لا يرسل "warehouse".
  Future<int> _serverMainWarehouseFallback(int pharmacyId) async {
    return await getMainWarehouseId(pharmacyId, syncedOnly: true) ??
        await ensureMainWarehouse(pharmacyId);
  }

  Map<String, dynamic> _serverMedicineRow({
    required int pharmacyId,
    required Map<String, dynamic> item,
    required int fallbackWarehouseId,
    required String syncedAt,
  }) {
    return <String, dynamic>{
      'id': _serverId(item['id']),
      'pharmacy_id': pharmacyId,
      'warehouse_id': item['warehouse'] != null ? _serverId(item['warehouse']) : fallbackWarehouseId,
      'trade_name': item['trade_name'] as String,
      'scientific_name': (item['scientific_name'] as String?) ?? '',
      'category': (item['category'] as String?) ?? '',
      'quantity': (item['quantity'] as num?)?.toInt() ?? 0,
      'buy_price': _parseServerDecimal(item['buy_price']),
      'sell_price': _parseServerDecimal(item['sell_price']),
      'expiry_date': item['expiry_date'] as String?,
      'shelf_location': (item['shelf_location'] as String?) ?? '',
      'is_damaged': item['is_damaged'] == true ? 1 : 0,
      'barcode': item['barcode'] as String?,
      'last_synced_at': syncedAt,
      // للمالك فقط (الخادم يحذفه لغير المالك) — غيابه = غير معروف.
      'avg_cost': _parseServerDecimalOrNull(item['avg_cost']),
    };
  }

  /// يستبدل دفعات صف كاش بنسخة الخادم (إن أرسلها؛ خادم أقدم بلا "batches"
  /// لا يمس شيئاً ويعمل الصف بصلاحيته المجمّعة كما في السابق).
  Future<void> _replaceCachedBatches(DatabaseExecutor txn, int medicineId, Map<String, dynamic> item) async {
    final batches = item['batches'];
    if (batches is! List) return;
    await txn.delete('medicine_batch', where: 'medicine_id = ?', whereArgs: [medicineId]);
    for (final raw in batches) {
      if (raw is! Map) continue;
      final quantity = (raw['quantity'] as num?)?.toInt() ?? 0;
      if (quantity <= 0) continue;
      await txn.insert('medicine_batch', {
        'medicine_id': medicineId,
        'quantity': quantity,
        'expiry_date': raw['expiry_date'] as String?,
        'purchase_price': _parseServerDecimalOrNull(raw['purchase_price']),
        'created_at': (raw['created_at'] as String?) ?? DateTime.now().toIso8601String(),
        'server_id': (raw['id'] as num?)?.toInt(),
        // تتبّع المصدر نصاً: supplier_id/purchase_invoice_id المحليان لا
        // يقابلان معرّفات الخادم (والمذاخر غير مخزّنة محلياً أونلاين).
        'source': _nonEmpty(raw['source']),
        'supplier_name': _nonEmpty(raw['supplier_name']),
        'invoice_number': _nonEmpty(raw['purchase_invoice_number']),
      });
    }
  }

  static String? _nonEmpty(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  double? _parseServerDecimalOrNull(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  /// أسعار DRF (DecimalField) تصل كنص "500.00" غالباً، أحياناً كرقم — تُقبل
  /// الحالتان هنا بأمان بدل افتراض نوع واحد فقط.
  double _parseServerDecimal(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  /// يحفظ فاتورة واحدة قادمة من السيرفر (نتيجة checkout أو refund مباشرة)
  /// في الكاش المحلي، بنفس نمط upsertMedicineFromServer تماماً.
  Future<void> upsertInvoiceFromServer({
    required int pharmacyId,
    required Map<String, dynamic> serverData,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await _upsertInvoiceRow(txn, pharmacyId: pharmacyId, serverData: serverData, syncedAt: now);
    });
  }

  /// يستبدل كامل كاش الفواتير المحلي بقائمة كاملة قادمة من السيرفر (بعد
  /// جلب invoice_api_service.fetchInvoices() لكل الصفحات)، بنفس نمط
  /// replaceMedicinesCache تماماً — معاملة واحدة لكل الدفعة.
  Future<void> replaceInvoicesCache({
    required int pharmacyId,
    required List<Map<String, dynamic>> serverItems,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      for (final item in serverItems) {
        await _upsertInvoiceRow(txn, pharmacyId: pharmacyId, serverData: item, syncedAt: now);
      }
    });
  }

  /// المنطق المشترك بين upsertInvoiceFromServer وreplaceInvoicesCache.
  ///
  /// cashier_id يُترك NULL دائماً هنا عمداً: مُعرّف الكاشير القادم من
  /// السيرفر هو user.id في Django (مساحة أرقام مختلفة تماماً عن
  /// user_profile.id المحلي الذي يشير إليه القيد
  /// FOREIGN KEY(cashier_id) REFERENCES user_profile(id))، فتخزينه كما هو
  /// قد يخالف القيد أو يشير خطأً لصف محلي مختلف تماماً. بدلاً من ذلك نخزّن
  /// اسم البائع الجاهز الذي يُرجعه السيرفر (cashier_display_name، يحسبه
  /// InvoiceSerializer.get_cashier_display_name) كنص في cashier_name_synced،
  /// وتعتمد عليه شاشة سجل المبيعات كبديل احتياطي بدل عرض "غير محدد" دائماً.
  Future<void> _upsertInvoiceRow(
    DatabaseExecutor txn, {
    required int pharmacyId,
    required Map<String, dynamic> serverData,
    required String syncedAt,
  }) async {
    final invoiceId = _serverId(serverData['id']);

    final row = <String, dynamic>{
      'id': invoiceId,
      'pharmacy_id': pharmacyId,
      'invoice_number': serverData['invoice_number'] as String,
      'cashier_id': null,
      'cashier_name_synced': serverData['cashier_display_name'] as String?,
      'total_amount': _parseServerDecimal(serverData['total_amount']),
      'discount': _parseServerDecimal(serverData['discount']),
      'final_amount': _parseServerDecimal(serverData['final_amount']),
      'created_at': serverData['created_at'] as String,
      'is_refunded': serverData['is_refunded'] == true ? 1 : 0,
      'last_synced_at': syncedAt,
    };

    await txn.insert('invoice', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    await txn.update('invoice', row, where: 'id = ?', whereArgs: [invoiceId]);

    // نعيد كتابة أصناف هذه الفاتورة بالكامل من نسخة السيرفر في كل مرة —
    // أبسط وأضمن من مطابقة كل صنف على حدة، ولا مشكلة في حذفها وإعادة
    // إدراجها لأنها بيانات قراءة فقط قادمة من السيرفر أصلاً (لا تعديل
    // محلي عليها يُفقَد).
    final items = serverData['items'];
    if (items is List) {
      await txn.delete('invoice_item', where: 'invoice_id = ?', whereArgs: [invoiceId]);
      for (final rawItem in items) {
        if (rawItem is! Map<String, dynamic>) continue;
        await txn.insert('invoice_item', {
          'invoice_id': invoiceId,
          'trade_name': rawItem['trade_name'] as String,
          'medicine_id': _serverId(rawItem['medicine']),
          'quantity': (rawItem['quantity'] as num).toInt(),
          'unit_price': _parseServerDecimal(rawItem['unit_price']),
          'total_price': _parseServerDecimal(rawItem['total_price']),
          'unit_cost': _parseServerDecimalOrNull(rawItem['unit_cost']),
        });
      }
    }
  }

  // البحث بالاسم التجاري أو العلمي أو الباركود
  Future<List<Map<String, dynamic>>> searchMedicines(int pharmacyId, String keyword) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT * 
      FROM medicine 
      WHERE pharmacy_id = ? 
        AND ${originFilter()}
        AND (
          trade_name LIKE ? 
          OR scientific_name LIKE ? 
          OR barcode LIKE ?
        ) 
      ORDER BY trade_name
    ''', [pharmacyId, '%$keyword%', '%$keyword%', '%$keyword%']);
  }

  //====================================================
  // البحث بالباركود
  //====================================================

  /// ⚠️ منذ إضافة تعدد المخازن، الباركود فريد ضمن نفس المخزن فقط، لا على
  /// مستوى الجدول كله. مرّر warehouseId (شاشة البيع تمرر دائماً المخزن
  /// الرئيسي) لضمان مطابقة الصنف الصحيح؛ بدونه تُعاد أول مطابقة فقط بغض
  /// النظر عن المخزن/الصيدلية - غير آمن الآن ولا يُستخدم بلا warehouseId
  /// من أي شاشة جديدة.
  Future<Map<String, dynamic>?> getMedicineByBarcode(String barcode, {int? warehouseId}) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT medicine.*, $sellableQuantitySql FROM medicine
      WHERE barcode = ? ${warehouseId != null ? 'AND warehouse_id = ?' : ''} AND ${originFilter()}
    ''', [barcode, if (warehouseId != null) warehouseId]);
    if (result.isEmpty) return null;
    return result.first;
  }

  //====================================================
  // التحقق من وجود الباركود
  //====================================================

  //====================================================
  // تحديث كمية الدواء
  //====================================================

  //====================================================
  // زيادة كمية المخزن
  //====================================================

  //====================================================
  // خصم كمية من المخزن
  //====================================================

  //====================================================
  // الأدوية منخفضة المخزون
  //====================================================

  Future<List<Map<String, dynamic>>> getLowStockMedicines(int pharmacyId, {int limit = kLowStockThreshold}) async {
    final db = await database;
    return await db.query(
      'medicine',
      where: 'pharmacy_id = ? AND quantity <= ? AND ${originFilter()}',
      whereArgs: [pharmacyId, limit],
      orderBy: 'quantity ASC',
    );
  }

  //====================================================
  // الأدوية المنتهية
  //====================================================

  Future<List<Map<String, dynamic>>> getExpiredMedicines(int pharmacyId, {int daysAhead = 0}) async {
    final db = await database;
    // 🛠️ إصلاح: استخدام رقم اليوم فقط (بدون وقت) + دالة date() في SQLite
    // لتطبيع المقارنة. سابقاً كانت المقارنة نصية مباشرة مع طابع زمني كامل
    // (DateTime.now().toIso8601String())، ما يجعل أي دواء تاريخ صلاحيته
    // "اليوم بالضبط" (بدون وقت) يُعتبر خطأً منتهي الصلاحية فوراً، لأن النص
    // القصير "2026-08-14" يُقارَن كأصغر من النص الطويل "2026-08-14T13:45...".
    //
    // 🆕 daysAhead: لو مُرِّرت قيمة > 0، تُضاف الأدوية "الموشكة على الانتهاء"
    // خلال هذه المدة (وليس فقط المنتهية فعلياً) — بدون تعديل السلوك الافتراضي
    // لأي مكان آخر يستدعي هذه الدالة بدون هذا المعامل (daysAhead = 0 = نفس
    // السلوك القديم تماماً).
    final now = DateTime.now();
    final limitDate = DateTime(now.year, now.month, now.day).add(Duration(days: daysAhead));
    final limitDateOnly = limitDate.toIso8601String().split('T').first;

    // 🆕 لكل دفعة على حدة: صف لكل دفعة منتهية/موشكة بكميتها وتاريخها هي.
    // دواء بلا دفعات (كاش من خادم أقدم) يُقيَّم بصلاحيته المجمّعة كالسابق.
    return await db.rawQuery('''
      SELECT m.id, m.pharmacy_id, m.warehouse_id, m.trade_name, m.scientific_name, m.category,
             b.quantity AS quantity, m.buy_price, m.sell_price, b.expiry_date AS expiry_date,
             m.shelf_location, m.is_damaged, m.barcode
      FROM medicine_batch b
      JOIN medicine m ON m.id = b.medicine_id
      WHERE m.pharmacy_id = ? AND ${originFilter('m.')}
        AND b.quantity > 0
        AND b.expiry_date IS NOT NULL AND b.expiry_date != ''
        AND date(b.expiry_date) < date(?)
      UNION ALL
      SELECT m.id, m.pharmacy_id, m.warehouse_id, m.trade_name, m.scientific_name, m.category,
             m.quantity, m.buy_price, m.sell_price, m.expiry_date,
             m.shelf_location, m.is_damaged, m.barcode
      FROM medicine m
      WHERE m.pharmacy_id = ? AND ${originFilter('m.')}
        AND m.quantity > 0
        AND m.expiry_date IS NOT NULL AND m.expiry_date != ''
        AND date(m.expiry_date) < date(?)
        AND NOT EXISTS (SELECT 1 FROM medicine_batch x WHERE x.medicine_id = m.id)
      ORDER BY expiry_date ASC
    ''', [pharmacyId, limitDateOnly, pharmacyId, limitDateOnly]);
  }

  //====================================================
  // Invoice CRUD
  //====================================================

  /// فواتير مع اسم البائع (محلي، أو cashier_name_synced لفواتير الخادم)،
  /// الأحدث أولاً. [ids] = صفوف صفحة جاءت من الخادم للتو؛ وإلا فلاتر وترقيم
  /// محليان. [start]/[end] = YYYY-MM-DD شاملة بتاريخ الفاتورة المحلي (أول 10
  /// أحرف من created_at، لا DATE() التي تحوّل الإزاحة الزمنية إلى UTC).
  Future<List<Map<String, dynamic>>> queryInvoices(
    int pharmacyId, {
    List<int>? ids,
    String search = '',
    String? start,
    String? end,
    int? limit,
    int offset = 0,
  }) async {
    final db = await database;
    final clauses = <String>['i.pharmacy_id = ?', originFilter('i.')];
    final args = <Object?>[pharmacyId];
    if (ids != null) {
      if (ids.isEmpty) return [];
      clauses.add('i.id IN (${List.filled(ids.length, '?').join(',')})');
      args.addAll(ids);
    }
    if (search.isNotEmpty) {
      clauses.add("(i.invoice_number LIKE ? OR COALESCE(u.full_name, u.username, i.cashier_name_synced, '') LIKE ?)");
      args.addAll(['%$search%', '%$search%']);
    }
    if (start != null) {
      clauses.add('substr(i.created_at, 1, 10) >= ?');
      args.add(start);
    }
    if (end != null) {
      clauses.add('substr(i.created_at, 1, 10) <= ?');
      args.add(end);
    }
    final page = limit != null ? 'LIMIT $limit OFFSET $offset' : '';
    return db.rawQuery('''
      SELECT
        i.*,
        COALESCE(u.full_name, u.username, i.cashier_name_synced, 'غير محدد') AS cashier_name
      FROM invoice i
      LEFT JOIN user_profile up ON i.cashier_id = up.id
      LEFT JOIN users u ON up.user_id = u.id
      WHERE ${clauses.join(' AND ')}
      ORDER BY i.created_at DESC, i.id DESC
      $page
    ''', args);
  }

  // جلب جميع فواتير الصيدلية
  Future<List<Map<String, dynamic>>> getInvoices(int pharmacyId) async {
    final db = await database;
    return await db.query(
      'invoice',
      where: 'pharmacy_id = ? AND ${originFilter()}',
      whereArgs: [pharmacyId],
      orderBy: 'created_at DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getExpenses({
    required int pharmacyId,
    String? startDate,
    String? endDate,
    String? expenseType,
  }) async {
    final db = await database;
    final clauses = <String>['pharmacy_id = ?', originFilter()];
    final args = <Object?>[pharmacyId];
    if (startDate != null) { clauses.add('date(expense_date) >= date(?)'); args.add(startDate); }
    if (endDate != null) { clauses.add('date(expense_date) <= date(?)'); args.add(endDate); }
    if (expenseType != null && expenseType.isNotEmpty) { clauses.add('expense_type = ?'); args.add(expenseType); }
    return db.query('expense', where: clauses.join(' AND '), whereArgs: args, orderBy: 'expense_date DESC, id DESC');
  }

  Future<int> addExpense(Map<String, dynamic> expense) async {
    final amount = (expense['amount'] as num?)?.toDouble() ?? 0;
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر.');
    return (await database).insert('expense', expense, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<void> updateExpense(int id, Map<String, dynamic> expense) async {
    final amount = (expense['amount'] as num?)?.toDouble() ?? 0;
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر.');
    await (await database).update('expense', expense, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteExpense(int id, int pharmacyId) async {
    await (await database).delete('expense', where: 'id = ? AND pharmacy_id = ?', whereArgs: [id, pharmacyId]);
  }

  //====================================================
  // كاش القراءة فقط لوضع الأونلاين — يُستدعى بعد كل قراءة/كتابة ناجحة
  // من السيرفر فقط (ExpenseRepository)، بنفس نمط upsertMedicineFromServer/
  // replaceMedicinesCache تماماً.
  //====================================================

  /// يحفظ/يحدّث مصروفاً واحداً قادماً من استجابة السيرفر، مفتاحه id (معرّف
  /// السيرفر نفسه). INSERT OR IGNORE ثم UPDATE بدل REPLACE، بنفس سبب تفادي
  /// REPLACE المذكور في upsertMedicineFromServer (DELETE+INSERT داخلي قد
  /// يصطدم بقيود FOREIGN KEY لاحقاً لو أُضيفت).
  Future<void> upsertExpenseFromServer({
    required int pharmacyId,
    required Map<String, dynamic> serverData,
  }) async {
    final db = await database;

    final row = <String, dynamic>{
      'id': _serverId(serverData['id']),
      'pharmacy_id': pharmacyId,
      'expense_type': serverData['expense_type'] as String,
      'expense_date': serverData['expense_date'] as String,
      'amount': _parseServerDecimal(serverData['amount']),
      'notes': (serverData['notes'] as String?) ?? '',
      'last_synced_at': DateTime.now().toIso8601String(),
    };

    await db.insert('expense', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update('expense', row, where: 'id = ?', whereArgs: [row['id']]);
  }

  /// يستبدل كامل كاش المصروفات المحلي بقائمة كاملة قادمة من السيرفر (بعد
  /// جلب expense_api_service.fetchExpenses() لكل الصفحات)، بنفس نمط
  /// replaceMedicinesCache تماماً — معاملة واحدة لكل الدفعة.
  Future<void> replaceExpensesCache({
    required int pharmacyId,
    required List<Map<String, dynamic>> serverItems,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      for (final item in serverItems) {
        final row = <String, dynamic>{
          'id': _serverId(item['id']),
          'pharmacy_id': pharmacyId,
          'expense_type': item['expense_type'] as String,
          'expense_date': item['expense_date'] as String,
          'amount': _parseServerDecimal(item['amount']),
          'notes': (item['notes'] as String?) ?? '',
          'last_synced_at': now,
        };

        await txn.insert('expense', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.update('expense', row, where: 'id = ?', whereArgs: [row['id']]);
      }
    });
  }

  //====================================================
  // كاش القراءة فقط لجدول damaged_medicine — نفس نمط upsertExpenseFromServer/
  // replaceExpensesCache تماماً. لا دالة تحديث/حذف هنا لأن الإتلاف عملية
  // نهائية على السيرفر أيضاً (DamagedMedicineViewSet لا تدعم update/destroy).
  //====================================================

  /// يحفظ سجل إتلاف واحد قادماً من استجابة create على السيرفر، مفتاحه id.
  Future<void> upsertDamagedMedicineFromServer({
    required int pharmacyId,
    required Map<String, dynamic> serverData,
  }) async {
    final db = await database;

    final row = <String, dynamic>{
      'id': _serverId(serverData['id']),
      'pharmacy_id': pharmacyId,
      'medicine_id': _serverId(serverData['medicine']),
      'quantity_damaged': serverData['quantity_damaged'] as int,
      'total_cost': _parseServerDecimalOrNull(serverData['total_cost']),
      'reason': (serverData['reason'] as String?) ?? '',
      'notes': (serverData['notes'] as String?) ?? '',
      'damaged_at': serverData['damaged_at'] as String,
    };

    await db.insert('damaged_medicine', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update('damaged_medicine', row, where: 'id = ?', whereArgs: [row['id']]);
  }

  /// يستبدل كامل كاش سجلات الإتلاف المحلي بقائمة كاملة قادمة من السيرفر
  /// (بعد جلب damaged_api_service.fetchDamagedMedicines() لكل الصفحات).
  Future<void> replaceDamagedMedicinesCache({
    required int pharmacyId,
    required List<Map<String, dynamic>> serverItems,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      for (final item in serverItems) {
        final row = <String, dynamic>{
          'id': _serverId(item['id']),
          'pharmacy_id': pharmacyId,
          'medicine_id': _serverId(item['medicine']),
          'quantity_damaged': item['quantity_damaged'] as int,
          'total_cost': _parseServerDecimalOrNull(item['total_cost']),
          'reason': (item['reason'] as String?) ?? '',
          'notes': (item['notes'] as String?) ?? '',
          'damaged_at': item['damaged_at'] as String,
        };

        await txn.insert('damaged_medicine', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.update('damaged_medicine', row, where: 'id = ?', whereArgs: [row['id']]);
      }
    });
  }

  //=========================================
  // INSERT INVOICE ITEM
  //=========================================

  // جلب عناصر الفاتورة مع أسماء الأدوية والباركود باستخدام JOIN
  Future<List<Map<String, dynamic>>> getInvoiceItems(int invoiceId) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT 
        invoice_item.*, 
        medicine.trade_name, 
        medicine.barcode 
      FROM invoice_item 
      INNER JOIN medicine 
        ON invoice_item.medicine_id = medicine.id 
      WHERE invoice_item.invoice_id = ?
    ''', [invoiceId]);
  }

  //====================================================
  // استرجاع فاتورة (Refund) - النسخة المتطورة والآمنة
  //====================================================

  Future<void> refundInvoice(int invoiceId) async {
    final db = await database;

    await db.transaction((txn) async {
      // التحقق من أن الفاتورة غير مسترجعة مسبقاً
      final invoice = await txn.query(
        'invoice',
        where: 'id = ?',
        whereArgs: [invoiceId],
        limit: 1,
      );

      if (invoice.isEmpty) {
        throw Exception('Invoice not found');
      }

      if (invoice.first['is_refunded'] == 1) {
        throw Exception('Invoice already refunded');
      }

      // جلب عناصر الفاتورة
      final invoiceItems = await txn.query(
        'invoice_item',
        where: 'invoice_id = ?',
        whereArgs: [invoiceId],
      );

      // إعادة الكميات إلى أبعد دفعة انتهاءً (avg_cost لا يتغير؛ الفاتورة
      // المسترجعة تُستبعد من تقرير الربح بكلفتها الأصلية).
      for (final item in invoiceItems) {
        await _restoreToLatestBatch(txn, item['medicine_id'] as int, item['quantity'] as int);
      }

      // تحديث حالة الفاتورة
      await txn.update(
        'invoice',
        {'is_refunded': 1},
        where: 'id = ?',
        whereArgs: [invoiceId],
      );
    });
  }



  //====================================================
  // إحصائيات عامة للنظام بالكامل (لكل الفروع)
  //====================================================

  //====================================================
  // إحصائيات ومبيعات خاصة بصيدلية معينة (لفرع محدد)
  //====================================================

  // عدد الأدوية في فرع معين
  Future<int> medicineCountByPharmacy(int pharmacyId) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT COUNT(*) AS total
      FROM medicine
      WHERE pharmacy_id = ? AND ${originFilter()}
    ''', [pharmacyId]);

    return Sqflite.firstIntValue(result) ?? 0;
  }

  //====================================================
  // التقارير ولوحة التحكم (Dashboard & Reports)
  //====================================================

  //====================================================
// عدد فواتير اليوم
//====================================================

Future<int> todayInvoiceCount(int pharmacyId) async {
  final db = await database;

  final today = DateTime.now().toIso8601String().split('T').first;

  final result = await db.rawQuery('''
    SELECT COUNT(*) AS total
    FROM invoice
    WHERE pharmacy_id = ?
      AND ${originFilter()}
      AND is_refunded = 0
      AND DATE(created_at) = ?
  ''', [pharmacyId, today]);

  return Sqflite.firstIntValue(result) ?? 0;
}

//====================================================
// إجمالي مبيعات اليوم
//====================================================

Future<double> totalSalesToday(int pharmacyId) async {
  final db = await database;

  final today = DateTime.now().toIso8601String().split('T').first;

  final result = await db.rawQuery('''
    SELECT SUM(final_amount) AS total
    FROM invoice
    WHERE pharmacy_id = ?
      AND ${originFilter()}
      AND is_refunded = 0
      AND DATE(created_at) = ?
  ''', [pharmacyId, today]);

  if (result.isEmpty || result.first['total'] == null) {
    return 0.0;
  }

  return (result.first['total'] as num).toDouble();
}

  /// رقم فاتورة أوفلاين جديد: أكبر رقم `INV-<n>` بين الفواتير المحلية + 1.
  ///
  /// كان يُشتق من MAX(id)، وهذا لم يعد صالحاً: المعرّفات المحلية تبدأ من
  /// localIdBase (كانت ستنتج INV-1000000000001)، كما أن فواتير كاش الخادم لا
  /// تخص ترقيم هذا الجهاز. نفس منطق _next_invoice_number على الخادم.
  Future<String> generateInvoiceNumber() async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT invoice_number FROM invoice WHERE ${localOnly()} AND invoice_number GLOB 'INV-[0-9]*'",
    );
    var last = 0;
    for (final row in rows) {
      final n = int.tryParse((row['invoice_number'] as String).substring(4));
      if (n != null && n > last) last = n;
    }
    final used = rows.map((r) => r['invoice_number'] as String).toSet();
    var candidate = last + 1;
    while (used.contains('INV-${candidate.toString().padLeft(6, '0')}')) {
      candidate++;
    }
    return 'INV-${candidate.toString().padLeft(6, '0')}';
  }

  //====================================================
  // Invoice Item CRUD (عناصر الفواتير)
  //====================================================

  //====================================================
  // Pharmacy Supplier CRUD (الموردين)
  //====================================================

  // إضافة مورد جديد
  Future<int> insertSupplier(Map<String, dynamic> supplier) async {
    final db = await database;
    final int pharmacyId = supplier['pharmacy_id'];

    await db.insert(
      "pharmacy_branch",
      {
        'id': pharmacyId,
        'name' : 'الفرع الرئيسي', 
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore, 
    );
    return await db.insert('pharmacy_supplier', supplier);
  }

  /// تصحيح اسم المذخر فقط (الهاتف لا يُعرض ولا يُعدَّل). نفس قواعد قائمة
  /// المذخر: الاسم مطلوب بعد التشذيب، ولا يطابق (بلا حساسية لحالة الأحرف)
  /// اسم مذخر آخر في نفس الصيدلية.
  Future<void> updateSupplierName(int id, String name) async {
    final db = await database;
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const PurchaseListException('اسم المذخر مطلوب.');
    final rows = await db.query('pharmacy_supplier', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) throw const PurchaseListException('المذخر غير موجود.');
    final taken = await db.query('pharmacy_supplier',
        where: 'pharmacy_id = ? AND id != ? AND name = ? COLLATE NOCASE',
        whereArgs: [rows.first['pharmacy_id'], id, trimmed],
        limit: 1);
    if (taken.isNotEmpty) throw const PurchaseListException('يوجد مذخر آخر بنفس الاسم.');
    await db.update('pharmacy_supplier', {'name': trimmed}, where: 'id = ?', whereArgs: [id]);
  }

  // حذف مورد
  Future<int> deleteSupplier(int id) async {
    final db = await database;
    return await db.delete(
      "pharmacy_supplier",
      where: "id = ?",
      whereArgs: [id],
    );
  }

  //====================================================
  // Damaged Medicine CRUD (الأدوية التالفة)
  //====================================================

  //====================================================
  // User Profile CRUD (ملفات المستخدمين والصيادلة)
  //====================================================

  //====================================================
  // Complete Sale Transaction (إتمام عملية البيع متكاملة)
  //====================================================

  // حفظ الفاتورة + إضافة العناصر + خصم المخزون في حركة واحدة (Transaction)
  Future<void> completeSale({
    required Map<String, dynamic> invoice,
    required List<Map<String, dynamic>> items,
  }) async {
    // خصم سالب = لا بيع (حماية أخيرة لأي مستدعٍ أوفلاين غير InvoiceRepository).
    if (((invoice['discount'] as num?) ?? 0) < 0) {
      throw StateError('لا يمكن إتمام البيع: قيمة الخصم سالبة.');
    }
    final db = await database;

    await db.transaction((txn) async {
      // 1. إنشاء الفاتورة الأساسية والحصول على الـ ID الخاص بها
      final int pharmacyId = invoice['pharmacy_id'];
      await txn.insert('pharmacy_branch', 
      {'id': pharmacyId,'name': 'الفرع الرئيسي','is_active': 1,'created_at': DateTime.now().toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      if (invoice['cashier_id'] != null) {
        final cashierId = invoice['cashier_id'] as int;

        final cashierProfile = await txn.query(
          'user_profile',
          columns: ['id'],
          where: 'id = ? AND pharmacy_id = ?',
          whereArgs: [cashierId, pharmacyId],
          limit: 1,
        );

        if (cashierProfile.isEmpty) {
          throw StateError(
            'تعذر التحقق من حساب الكاشير. سجّل الخروج ثم سجّل الدخول مجدداً.',
          );
        }
      }

      // 🟢 3. إنشاء الفاتورة الأساسية والحصول على הـ ID الخاص بها
      final invoiceId = await txn.insert(
        "invoice",
        invoice,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

      // 🟢 4. حفظ الأصناف المباعة وخصم كمياتها من الدفعات (FEFO، غير المنتهية فقط).
      // unit_cost لقطة من avg_cost الحالي ولا تتغير بعدها أبداً.
      for (final item in items) {
        final medicineId = item["medicine_id"] as int;
        final medicine = await _medicineRow(txn, medicineId);
        item["invoice_id"] = invoiceId;
        item["unit_cost"] = medicine['avg_cost'];

        await txn.insert("invoice_item", item);
        await _deductFefo(txn, medicineId, item["quantity"] as int, sellableOnly: true);
      }
    });
  }

//====================================================
  // عمليات إضافية خاصة بالمخزن والإتلاف (تكامل الشاشات)
  //====================================================

  /// 1. تزويد شحنة (معاملة واحدة، نفس stock.supply في الخادم):
  /// avg_cost مرجّح، سعر بيع موحّد جديد لكل المخزون، ودفعة صلاحية جديدة.
  /// [purchasePrice] null = يُستخدم avg_cost الحالي (ويُرفض إن كان مجهولاً).
  Future<void> supplyMedicine({
    required int medicineId,
    required int addedQuantity,
    String? newExpiryDate,
    double? purchasePrice,
    required double salePrice,
  }) async {
    if (addedQuantity <= 0) throw StateError('الكمية المضافة يجب أن تكون أكبر من صفر.');
    if (salePrice <= 0) throw StateError('سعر البيع يجب أن يكون أكبر من صفر.');
    if (purchasePrice != null && purchasePrice <= 0) throw StateError('سعر الشراء يجب أن يكون أكبر من صفر.');
    final db = await database;
    await db.transaction((txn) async {
      await _supplyInTxn(
        txn,
        medicineId: medicineId,
        paidQuantity: addedQuantity,
        expiryDate: newExpiryDate,
        purchasePrice: purchasePrice,
        salePrice: salePrice,
      );
    });
  }

  /// توريد شحنة داخل معاملة قائمة (نفس stock.supply في الخادم حرفياً):
  /// متوسط مرجّح + سعر بيع موحّد جديد + دفعة جديدة.
  ///
  /// [paidQuantity] = المدفوع، [bonusQuantity] = المجاني فوقه؛ الدفعة = المجموع
  /// بكلفة effectiveUnitCost. paidQuantity == 0 = سطر مجاني بالكامل: كلفة 0
  /// معروفة تدخل المتوسط، وbuy_price الحالي لا يتغير. [salePrice] null يُبقي
  /// سعر البيع الحالي. [allowUnknownCost] (رصيد افتتاحي بسعر شراء 0): كلفة
  /// مجهولة لا ترفض التوريد، فالدفعة بلا كلفة ولا يتغير avg_cost.
  /// يرجع كلفة وحدة الدفعة (null = غير معروفة).
  Future<double?> _supplyInTxn(
    DatabaseExecutor txn, {
    required int medicineId,
    required int paidQuantity,
    int bonusQuantity = 0,
    String? expiryDate,
    double? purchasePrice,
    double? salePrice,
    bool allowUnknownCost = false,
    String? source,
    int? supplierId,
    int? purchaseInvoiceId,
  }) async {
    final medicine = await _medicineRow(txn, medicineId);
    await _reconcileBatches(txn, medicine);
    final oldAvg = (medicine['avg_cost'] as num?)?.toDouble();
    final total = paidQuantity + bonusQuantity;
    final double? cost = paidQuantity == 0 ? 0 : (purchasePrice ?? oldAvg);
    if (cost == null && !allowUnknownCost) {
      throw StateError('سعر الشراء مطلوب لأن كلفة هذا الصنف غير معروفة بعد.');
    }
    final unitCost = cost == null
        ? null
        : effectiveUnitCost(paidQty: paidQuantity, bonusQty: bonusQuantity, buyPrice: cost);
    final values = <String, Object?>{
      if (unitCost != null)
        'avg_cost': weightedAverageCost(
          oldQty: (medicine['quantity'] as num).toInt(),
          oldAvg: oldAvg,
          newQty: total,
          newCost: unitCost,
        ),
      if (paidQuantity > 0 && cost != null) 'buy_price': roundMoney(cost),
      if (salePrice != null) 'sell_price': roundMoney(salePrice),
    };
    if (values.isNotEmpty) {
      await txn.update('medicine', values, where: 'id = ?', whereArgs: [medicineId]);
    }
    await _addBatch(
      txn,
      medicineId: medicineId,
      quantity: total,
      expiryDate: expiryDate,
      purchasePrice: unitCost,
      source: source,
      supplierId: supplierId,
      purchaseInvoiceId: purchaseInvoiceId,
    );
    return roundCost(unitCost);
  }

  /// 2. عملية إتلاف دواء متكاملة (خصم من المخزن + إضافة سجل في جدول التوالف في حركة واحدة)
  Future<void> processDamageMedicine({
    required int medicineId,
    required int pharmacyId,
    required int quantityToDamage,
    required String reason,
    String? notes,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      // أ) خصم الكمية التالفة من الدفعات بترتيب FEFO (المنتهية أولاً بطبيعتها)
      final avgCost = ((await _medicineRow(txn, medicineId))['avg_cost'] as num?)?.toDouble();
      await _deductFefo(txn, medicineId, quantityToDamage, sellableOnly: false);

      // ب) إضافة السجل في جدول التوالف مع التاريخ الحالي وكلفته وقت الإتلاف
      await txn.insert("damaged_medicine", {
        "pharmacy_id": pharmacyId,
        "medicine_id": medicineId,
        "quantity_damaged": quantityToDamage,
        "total_cost": avgCost == null ? null : roundMoney(quantityToDamage * avgCost),
        "reason": reason,
        "notes": notes ?? '',
        "damaged_at": DateTime.now().toIso8601String().split('T').first,
      });
    });
  }


// 1. دالة قراءة ملف الـ JSON وتعبئة قاعدة البيانات (تُستدعى مرة واحدة فقط تلقائياً)
  Future<void> _seedMasterMedicines(Database db) async {
    try {
      final String response = await rootBundle.loadString('assets/data/iraqi_drugs.json');
      final List<dynamic> data = json.decode(response);

      Batch batch = db.batch();
      for (var item in data) {
        batch.insert('master_medicines', {
          'trade_name': item['trade_name'],
          'scientific_name': item['scientific_name'],
          'category': item['category'],
        });
      }
      await batch.commit(noResult: true);
    } catch (e) {
      debugPrint("خطأ في تحميل قاموس الأدوية: $e");
    }
  }


  //====================================================
// 1️⃣ إدارة قائمة المذاخر وملخص الحسابات المالية
//====================================================

/// متبقي فاتورة شراء كتعبير SQL ([alias] اسم/اسم مستعار جدول purchase_invoice):
/// الإجمالي − المدفوع − (المرتجع − فائضه الذاهب لرصيد المذخر) − الرصيد المستخدم لها.
/// نفس supplier_ledger.remaining_of في الخادم.
static String invoiceRemainingSql(String alias) => '''
  ($alias.total_amount - $alias.paid_amount
    - COALESCE((SELECT SUM(r.amount_returned - r.excess_credit) FROM purchase_invoice_return r
                WHERE r.purchase_invoice_id = $alias.id), 0.0)
    - COALESCE((SELECT SUM(a.amount) FROM supplier_credit_application a
                WHERE a.purchase_invoice_id = $alias.id), 0.0))''';

Future<double> _invoiceRemaining(DatabaseExecutor db, int invoiceId) async {
  final rows = await db.rawQuery(
      'SELECT ${invoiceRemainingSql('pi')} AS remaining FROM purchase_invoice pi WHERE pi.id = ?', [invoiceId]);
  return roundMoney((rows.first['remaining'] as num).toDouble());
}

/// حسابات المذاخر الموحّدة (نفس supplier_ledger.supplier_figures في الخادم):
///   balance = الفواتير − المدفوع − المرتجعات + المستلم من المذخر − دفعات قديمة غير مرتبطة
///     (موجب = دين على الصيدلية، سالب = رصيد لصالحها)
///   رصيد الصيدلية لديه = فائض المرتجعات − الرصيد المستخدم − المستلم
///   available_credit = ما يمكن استخدامه/استلامه منه.
/// مجموع debt_added في كشف الحساب = balance دائماً.
Future<List<Map<String, dynamic>>> _supplierFigures(DatabaseExecutor db, int pharmacyId, {int? supplierId}) async {
  final now = DateTime.now();
  final month = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
  final rows = await db.rawQuery('''
    SELECT s.id, s.pharmacy_id, s.name, s.phone, s.created_at,
      (SELECT COUNT(*) FROM purchase_invoice pi WHERE pi.supplier_id = s.id) AS invoice_count,
      COALESCE((SELECT SUM(pi.total_amount) FROM purchase_invoice pi WHERE pi.supplier_id = s.id), 0.0) AS invoice_total,
      COALESCE((SELECT SUM(pi.paid_amount) FROM purchase_invoice pi WHERE pi.supplier_id = s.id), 0.0) AS paid,
      COALESCE((SELECT SUM(r.amount_returned) FROM purchase_invoice_return r
                JOIN purchase_invoice pi ON pi.id = r.purchase_invoice_id WHERE pi.supplier_id = s.id), 0.0) AS returned,
      COALESCE((SELECT SUM(r.excess_credit) FROM purchase_invoice_return r
                JOIN purchase_invoice pi ON pi.id = r.purchase_invoice_id WHERE pi.supplier_id = s.id), 0.0) AS excess,
      COALESCE((SELECT SUM(a.amount) FROM supplier_credit_application a WHERE a.supplier_id = s.id), 0.0) AS applied,
      COALESCE((SELECT SUM(f.amount) FROM supplier_refund f WHERE f.supplier_id = s.id), 0.0) AS refunds,
      -- دفعات قديمة غير مرتبطة بفاتورة تبقى محسوبة للحفاظ على البيانات السابقة.
      COALESCE((SELECT SUM(sp.amount_paid) FROM supplier_payment sp
                WHERE sp.supplier_id = s.id AND sp.purchase_invoice_id IS NULL), 0.0) AS unlinked_paid,
      -- تاريخ آخر فاتورة ومشتريات الشهر الحالي (تاريخ الفاتورة وإلا تاريخ الإنشاء).
      (SELECT MAX(COALESCE(NULLIF(pi.invoice_date, ''), pi.created_at)) FROM purchase_invoice pi
                WHERE pi.supplier_id = s.id) AS last_invoice_date,
      COALESCE((SELECT SUM(pi.total_amount) FROM purchase_invoice pi WHERE pi.supplier_id = s.id
                AND substr(COALESCE(NULLIF(pi.invoice_date, ''), pi.created_at), 1, 7) = ?), 0.0) AS month_total
    FROM pharmacy_supplier s
    WHERE s.pharmacy_id = ? ${supplierId != null ? 'AND s.id = ?' : ''}
    ORDER BY s.name ASC
  ''', [month, pharmacyId, if (supplierId != null) supplierId]);

  double n(Object? v) => (v as num).toDouble();
  return rows.map((row) {
    final balance = roundMoney(
        n(row['invoice_total']) - n(row['paid']) - n(row['returned']) + n(row['refunds']) - n(row['unlinked_paid']));
    final bucket = roundMoney(n(row['excess']) - n(row['applied']) - n(row['refunds']));
    final credit = balance < 0 ? -balance : 0.0;
    final available = bucket < credit ? bucket : credit;
    return <String, dynamic>{
      'id': row['id'],
      'pharmacy_id': row['pharmacy_id'],
      'name': row['name'],
      'phone': row['phone'],
      'created_at': row['created_at'],
      'invoice_count': row['invoice_count'],
      'total_purchases': roundMoney(n(row['invoice_total']) - n(row['returned'])),
      'remaining_debt': balance > 0 ? balance : 0.0,
      'balance': balance,
      'credit_balance': credit,
      'available_credit': available > 0 ? available : 0.0,
      'total_paid': roundMoney(n(row['paid']) + n(row['unlinked_paid'])),
      'last_invoice_date': row['last_invoice_date'],
      'month_purchases': n(row['month_total']),
    };
  }).toList();
}

/// جلب جميع المذاخر مع إجمالي المشتريات والدين ورصيد الصيدلية لدى كل مذخر.
Future<List<Map<String, dynamic>>> getSuppliersWithFinancials(int pharmacyId) async {
  final db = await database;
  return _supplierFigures(db, pharmacyId);
}

Future<Map<String, dynamic>> _supplierFiguresFor(DatabaseExecutor db, int supplierId) async {
  final supplier = await db.query('pharmacy_supplier', where: 'id = ?', whereArgs: [supplierId], limit: 1);
  if (supplier.isEmpty) throw const PurchaseListException('المذخر غير موجود.');
  return (await _supplierFigures(db, supplier.first['pharmacy_id'] as int, supplierId: supplierId)).single;
}

/// عمود remaining_debt المخزَّن (للتوافق) = المتبقي الموحّد لكل فاتورة.
Future<void> _refreshRemainingDebt(DatabaseExecutor db, int supplierId) async {
  await db.rawUpdate(
    'UPDATE purchase_invoice SET remaining_debt = MAX(0, ${invoiceRemainingSql('purchase_invoice')}) WHERE supplier_id = ?',
    [supplierId],
  );
}

/// يسجّل استخدام رصيد المذخر لتخفيض متبقي فاتورة (حركة غير نقدية).
Future<double> _applySupplierCredit(
  DatabaseExecutor db, {
  required int pharmacyId,
  required int supplierId,
  required int invoiceId,
  required double amount,
  required String notes,
  required String when,
}) async {
  final value = roundMoney(amount);
  if (value <= 0) return 0;
  await db.insert('supplier_credit_application', {
    'pharmacy_id': pharmacyId,
    'supplier_id': supplierId,
    'purchase_invoice_id': invoiceId,
    'amount': value,
    'notes': notes,
    'applied_at': when,
  });
  return value;
}

//====================================================
// 2️⃣ تسجيل فواتير الشراء والتوريد (Purchase Invoices)
//====================================================

/// إدخال قائمة مذخر (أو رصيد افتتاحي) كاملة في معاملة واحدة — نسخة
/// أوفلاين من POST /api/purchase-invoices/from-list/ و /api/medicines/opening-stock/
/// (backend/pharmacy_data/purchase_list.py) بنفس الترتيب والقواعد:
///   1. المذخر (بالمعرّف، أو بنفس الاسم، أو يُنشأ) ← 2. فاتورة الشراء ←
///   3. لكل سطر: توريد لصنف موجود في المخزن (نفس الباركود أو نفس الاسم
///   التجاري) أو إنشاء صنف جديد، بدفعة مرتبطة بالمذخر والفاتورة ←
///   4. الدفعة الأولية الاختيارية.
/// الرصيد الافتتاحي: نفس الأسطر بلا مذخر ولا فاتورة ولا دفعة ولا دين.
/// الكل أو لا شيء: أي خطأ يرمي [PurchaseListException] (line = رقم السطر)
/// ويُلغي المعاملة كاملة. المجاميع تُحسب هنا فقط.
///
/// [items]: مفاتيح الخادم نفسها (medicine_id?, trade_name, scientific_name,
/// category, barcode, shelf_location, quantity, bonus_quantity, is_free,
/// buy_price, sell_price, expiry_date). يرجع purchase_invoice_id (null
/// للرصيد الافتتاحي) وsupplier_id وmedicine_ids.
Future<Map<String, dynamic>> createPurchaseList({
  required int pharmacyId,
  required PurchaseListMode mode,
  required int warehouseId,
  required List<Map<String, dynamic>> items,
  int? supplierId,
  String? supplierName,
  String? supplierPhone,
  String? invoiceNumber,
  String? invoiceDate,
  double paidAmount = 0,
}) async {
  if (items.isEmpty) throw const PurchaseListException('لا يمكن حفظ قائمة بلا أصناف.');
  final isSupplierList = mode == PurchaseListMode.supplierList;
  final db = await database;
  final now = DateTime.now().toIso8601String();

  return db.transaction((txn) async {
    await txn.insert(
      'pharmacy_branch',
      {'id': pharmacyId, 'name': 'الفرع الرئيسي', 'is_active': 1, 'created_at': now},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final warehouse = await txn.query('warehouses',
        where: 'id = ? AND pharmacy_id = ?', whereArgs: [warehouseId, pharmacyId], limit: 1);
    if (warehouse.isEmpty) throw const PurchaseListException('المخزن غير موجود في هذه الصيدلية.');

    int? resolvedSupplierId;
    int? purchaseInvoiceId;
    var availableCredit = 0.0;
    if (isSupplierList) {
      resolvedSupplierId = await _resolveSupplier(txn, pharmacyId, supplierId, supplierName, supplierPhone, now);
      // الرصيد المتاح يُقرأ قبل إنشاء الفاتورة الجديدة (إجماليها يرفع رصيد المذخر).
      availableCredit = ((await _supplierFiguresFor(txn, resolvedSupplierId))['available_credit'] as num).toDouble();
      final number = (invoiceNumber ?? '').trim();
      if (number.isEmpty) throw const PurchaseListException('رقم فاتورة المذخر مطلوب.');
      final duplicate = await txn.query('purchase_invoice',
          where: 'pharmacy_id = ? AND supplier_id = ? AND invoice_number = ?',
          whereArgs: [pharmacyId, resolvedSupplierId, number],
          limit: 1);
      if (duplicate.isNotEmpty) {
        throw PurchaseListException('رقم الفاتورة $number مسجّل مسبقاً لهذا المذخر.');
      }
      purchaseInvoiceId = await txn.insert('purchase_invoice', {
        'pharmacy_id': pharmacyId,
        'supplier_id': resolvedSupplierId,
        'invoice_number': number,
        'invoice_date': invoiceDate,
        'source': PurchaseInvoiceSource.inventoryList,
        'created_at': now,
      });
    }

    final medicineIds = <int>{};
    var total = 0.0;
    for (var index = 0; index < items.length; index++) {
      final line = items[index];
      final medicineId = await _receivePurchaseLine(
        txn,
        index: index,
        line: line,
        mode: mode,
        pharmacyId: pharmacyId,
        warehouseId: warehouseId,
        supplierId: resolvedSupplierId,
        purchaseInvoiceId: purchaseInvoiceId,
        onReceived: (medicine, paidQty, bonusQty, buyPrice, unitCost) async {
          if (purchaseInvoiceId == null) return;
          final amount = purchaseLineTotal(paidQty: paidQty, buyPrice: buyPrice);
          total += amount;
          await txn.insert('purchase_invoice_item', {
            'pharmacy_id': pharmacyId,
            'purchase_invoice_id': purchaseInvoiceId,
            'medicine_id': medicine['id'],
            'trade_name': medicine['trade_name'],
            'quantity': paidQty,
            'bonus_quantity': bonusQty,
            'buy_price': roundMoney(buyPrice),
            'effective_unit_cost': unitCost ?? 0,
            'sell_price': medicine['sell_price'],
            'expiry_date': _blankToNull(line['expiry_date']),
            'line_total': amount,
          });
        },
      );
      medicineIds.add(medicineId);
    }

    if (purchaseInvoiceId != null) {
      total = roundMoney(total);
      // رصيد المذخر لصالح الصيدلية يُخصم أولاً حتى إجمالي الفاتورة، ثم "المدفوع الآن".
      final creditApplied = roundMoney(availableCredit < total ? availableCredit : total);
      final paid = roundMoney(paidAmount);
      if (paid < 0) throw const PurchaseListException('المبلغ المدفوع لا يمكن أن يكون سالباً.');
      if (paid > roundMoney(total - creditApplied)) {
        throw PurchaseListException(creditApplied > 0
            ? 'المبلغ المدفوع أكبر من المتبقي بعد الخصم من رصيد المذخر السابق.'
            : 'المبلغ المدفوع أكبر من إجمالي الفاتورة.');
      }
      await txn.update(
        'purchase_invoice',
        {'total_amount': total, 'paid_amount': paid, 'item_count': items.length},
        where: 'id = ?',
        whereArgs: [purchaseInvoiceId],
      );
      await _applySupplierCredit(txn,
          pharmacyId: pharmacyId,
          supplierId: resolvedSupplierId!,
          invoiceId: purchaseInvoiceId,
          amount: creditApplied,
          notes: SupplierCreditNote.previous,
          when: now);
      if (paid > 0) {
        await txn.insert('supplier_payment', {
          'pharmacy_id': pharmacyId,
          'supplier_id': resolvedSupplierId,
          'purchase_invoice_id': purchaseInvoiceId,
          'amount_paid': paid,
          'notes': 'دفعة عند استلام القائمة',
          'paid_at': now,
        });
      }
      await _refreshRemainingDebt(txn, resolvedSupplierId);
    }

    return {
      'purchase_invoice_id': purchaseInvoiceId,
      'supplier_id': resolvedSupplierId,
      'medicine_ids': medicineIds.toList(),
    };
  });
}

static String? _blankToNull(dynamic value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

/// مذخر موجود بالمعرّف، أو بنفس الاسم (تفادياً للتكرار)، أو يُنشأ جديداً.
Future<int> _resolveSupplier(
  DatabaseExecutor txn,
  int pharmacyId,
  int? supplierId,
  String? name,
  String? phone,
  String now,
) async {
  if (supplierId != null) {
    final rows = await txn.query('pharmacy_supplier',
        where: 'id = ? AND pharmacy_id = ?', whereArgs: [supplierId, pharmacyId], limit: 1);
    if (rows.isEmpty) throw const PurchaseListException('المذخر غير موجود في هذه الصيدلية.');
    return supplierId;
  }
  final trimmed = (name ?? '').trim();
  if (trimmed.isEmpty) throw const PurchaseListException('يرجى اختيار المذخر أو كتابة اسم مذخر جديد.');
  final existing = await txn.query('pharmacy_supplier',
      where: 'pharmacy_id = ? AND name = ? COLLATE NOCASE', whereArgs: [pharmacyId, trimmed], limit: 1);
  if (existing.isNotEmpty) return existing.first['id'] as int;
  return txn.insert('pharmacy_supplier', {
    'pharmacy_id': pharmacyId,
    'name': trimmed,
    'phone': (phone ?? '').trim(),
    'created_at': now,
  });
}

/// الصنف الموجود في نفس المخزن لسطر القائمة: بالمعرّف إن أُرسل، وإلا نفس
/// الباركود، وإلا نفس الاسم التجاري (بلا حساسية لحالة الأحرف). null = صنف جديد.
/// نفس find_existing_medicine في الخادم — تستخدمه النافذة أيضاً لشارة "صنف موجود".
Future<Map<String, Object?>?> findPurchaseListMedicine({
  required int warehouseId,
  int? medicineId,
  String? barcode,
  required String tradeName,
  DatabaseExecutor? executor,
}) async {
  final txn = executor ?? await database;
  if (medicineId != null) {
    final rows =
        await txn.query('medicine', where: 'id = ? AND warehouse_id = ?', whereArgs: [medicineId, warehouseId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }
  final code = (barcode ?? '').trim();
  if (code.isNotEmpty) {
    final rows =
        await txn.query('medicine', where: 'warehouse_id = ? AND barcode = ?', whereArgs: [warehouseId, code], limit: 1);
    if (rows.isNotEmpty) return rows.first;
  }
  final name = tradeName.trim();
  if (name.isEmpty) return null;
  final rows = await txn.query('medicine',
      where: 'warehouse_id = ? AND trade_name = ? COLLATE NOCASE',
      whereArgs: [warehouseId, name],
      orderBy: 'id ASC',
      limit: 1);
  return rows.isEmpty ? null : rows.first;
}

/// يورّد سطراً واحداً (صنف موجود أو جديد) ويرجع معرّف الصنف. [onReceived]
/// يُستدعى بعد التوريد لكتابة سطر الفاتورة.
Future<int> _receivePurchaseLine(
  DatabaseExecutor txn, {
  required int index,
  required Map<String, dynamic> line,
  required PurchaseListMode mode,
  required int pharmacyId,
  required int warehouseId,
  required int? supplierId,
  required int? purchaseInvoiceId,
  required Future<void> Function(Map<String, Object?> medicine, int paidQty, int bonusQty, double buyPrice, double? unitCost)
      onReceived,
}) async {
  final tradeName = (line['trade_name'] ?? '').toString().trim();
  final barcode = _blankToNull(line['barcode']);
  final requestedId = line['medicine_id'] == null ? null : lineInt(line['medicine_id']);
  if (tradeName.isEmpty && requestedId == null) {
    throw PurchaseListException('يرجى إدخال اسم الصنف.', line: index);
  }
  var medicine = await findPurchaseListMedicine(
    warehouseId: warehouseId,
    medicineId: requestedId,
    barcode: barcode,
    tradeName: tradeName,
    executor: txn,
  );
  if (requestedId != null && medicine == null) {
    throw PurchaseListException('الصنف المحدد غير موجود في هذا المخزن.', line: index);
  }
  final isNew = medicine == null;
  final error = validatePurchaseLine(line, mode, isNew: isNew);
  if (error != null) throw PurchaseListException(error, line: index);

  final isSupplierList = mode == PurchaseListMode.supplierList;
  final isFree = isSupplierList && line['is_free'] == true;
  final paidQty = isFree ? 0 : lineInt(line['quantity']);
  final bonusQty = isSupplierList ? lineInt(line['bonus_quantity']) : 0;
  final buyPrice = isFree ? 0.0 : (lineNum(line['buy_price']) ?? 0);
  final sellPrice = lineNum(line['sell_price']);
  // رصيد افتتاحي بسعر شراء 0 = كلفة غير معروفة (نفس قاعدة إضافة الصنف القديمة).
  final unknownCost = !isSupplierList && buyPrice == 0;

  try {
    final medicineId = isNew
        ? await txn.insert('medicine', {
            'pharmacy_id': pharmacyId,
            'warehouse_id': warehouseId,
            'trade_name': tradeName,
            'scientific_name': (line['scientific_name'] ?? '').toString().trim(),
            'category': (line['category'] ?? '').toString().trim(),
            'quantity': 0,
            'buy_price': roundMoney(buyPrice),
            'sell_price': roundMoney(sellPrice!),
            'shelf_location': (line['shelf_location'] ?? '').toString().trim(),
            'is_damaged': 0,
            'barcode': barcode,
          })
        : medicine['id'] as int;
    final unitCost = await _supplyInTxn(
      txn,
      medicineId: medicineId,
      paidQuantity: paidQty,
      bonusQuantity: bonusQty,
      expiryDate: _blankToNull(line['expiry_date']),
      purchasePrice: unknownCost ? null : buyPrice,
      salePrice: sellPrice,
      allowUnknownCost: unknownCost,
      source: isSupplierList ? BatchSource.purchaseList : BatchSource.openingStock,
      supplierId: supplierId,
      purchaseInvoiceId: purchaseInvoiceId,
    );
    medicine = await _medicineRow(txn, medicineId);
    await onReceived(medicine, paidQty, bonusQty, buyPrice, unitCost);
    return medicineId;
  } on StateError catch (e) {
    throw PurchaseListException(e.message, line: index);
  } on DatabaseException catch (e) {
    if (e.isUniqueConstraintError()) {
      throw PurchaseListException('هذا الباركود مستخدم لصنف آخر في نفس المخزن.', line: index);
    }
    rethrow;
  }
}

/// أصناف فاتورة شراء (فارغة للفواتير اليدوية القديمة).
/// مع المسترجع من كل سطر (returned_quantity) ومخزون صنفه الحالي (current_stock،
/// NULL إن حُذف الصنف) — لنافذة الأصناف والاسترجاع.
Future<List<Map<String, dynamic>>> getPurchaseInvoiceItems(int purchaseInvoiceId) async {
  final db = await database;
  return db.rawQuery('''
    SELECT pii.*, pi.invoice_number, pi.invoice_date, pi.created_at AS invoice_created_at,
           COALESCE((SELECT SUM(ri.quantity) FROM purchase_invoice_return_item ri
                     WHERE ri.purchase_invoice_item_id = pii.id), 0) AS returned_quantity,
           m.quantity AS current_stock
    FROM purchase_invoice_item pii
    JOIN purchase_invoice pi ON pi.id = pii.purchase_invoice_id
    LEFT JOIN medicine m ON m.id = pii.medicine_id
    WHERE pii.purchase_invoice_id = ?
    ORDER BY pii.id ASC
  ''', [purchaseInvoiceId]);
}

/// الأصناف المشتراة من مذخر عبر كل فواتيره (أحدث الفواتير أولاً) — لكشف الحساب.
Future<List<Map<String, dynamic>>> getSupplierPurchasedItems(int supplierId) async {
  final db = await database;
  return db.rawQuery('''
    SELECT pii.*, pi.invoice_number, pi.invoice_date, pi.created_at AS invoice_created_at
    FROM purchase_invoice_item pii
    JOIN purchase_invoice pi ON pi.id = pii.purchase_invoice_id
    WHERE pi.supplier_id = ?
    ORDER BY pi.created_at DESC, pii.id ASC
  ''', [supplierId]);
}

/// جلب فواتير الشراء الخاصة بمذخر معين (المتبقي بالصيغة الموحّدة، لا يقل عن 0).
Future<List<Map<String, dynamic>>> getPurchaseInvoicesBySupplier(int supplierId) async {
  final db = await database;
  return await db.rawQuery('''
    SELECT
      pi.*,
      COALESCE((SELECT SUM(pir.amount_returned) FROM purchase_invoice_return pir
                WHERE pir.purchase_invoice_id = pi.id), 0.0) AS returned_amount,
      pi.total_amount - COALESCE((SELECT SUM(pir.amount_returned) FROM purchase_invoice_return pir
                                  WHERE pir.purchase_invoice_id = pi.id), 0.0) AS net_amount,
      COALESCE((SELECT SUM(a.amount) FROM supplier_credit_application a
                WHERE a.purchase_invoice_id = pi.id), 0.0) AS credit_applied,
      MAX(0.0, ${invoiceRemainingSql('pi')}) AS remaining_amount
    FROM purchase_invoice pi
    WHERE pi.supplier_id = ?
    ORDER BY pi.created_at DESC
  ''', [supplierId]);
}


//====================================================
// 3️⃣ تسديد الديون، الاسترجاع، رصيد المذخر، وكشف الحساب
//====================================================

/// إضافة دفعة لفاتورة شراء محددة (لا تتجاوز متبقيها الموحّد).
Future<int> addPurchaseInvoicePayment({
  required int pharmacyId,
  required int supplierId,
  required int purchaseInvoiceId,
  required double amount,
  String? notes,
}) async {
  if (amount <= 0) {
    throw ArgumentError('يجب أن يكون مبلغ الدفعة أكبر من صفر.');
  }

  final db = await database;
  return db.transaction((txn) async {
    final invoices = await txn.query('purchase_invoice',
        where: 'id = ? AND supplier_id = ? AND pharmacy_id = ?', whereArgs: [purchaseInvoiceId, supplierId, pharmacyId]);
    if (invoices.isEmpty) {
      throw StateError('فاتورة الشراء غير موجودة.');
    }
    if (roundMoney(amount) > await _invoiceRemaining(txn, purchaseInvoiceId)) {
      throw ArgumentError('مبلغ الدفعة أكبر من المتبقي لهذه الفاتورة.');
    }

    final paymentId = await txn.insert('supplier_payment', {
      'pharmacy_id': pharmacyId,
      'supplier_id': supplierId,
      'purchase_invoice_id': purchaseInvoiceId,
      'amount_paid': roundMoney(amount),
      'notes': notes?.trim(),
      'paid_at': DateTime.now().toIso8601String(),
    });
    await txn.rawUpdate('UPDATE purchase_invoice SET paid_amount = paid_amount + ? WHERE id = ?',
        [roundMoney(amount), purchaseInvoiceId]);
    await _refreshRemainingDebt(txn, supplierId);
    return paymentId;
  });
}

/// تاريخ الحركة: اليوم (أو null) = الآن، تاريخ سابق = منتصف ذلك اليوم، المستقبل مرفوض.
static String _movementMoment(DateTime? day) {
  final now = DateTime.now();
  if (day == null) return now.toIso8601String();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(day.year, day.month, day.day);
  if (date == today) return now.toIso8601String();
  if (date.isAfter(today)) throw const PurchaseListException('لا يمكن تسجيل حركة بتاريخ مستقبلي.');
  return DateTime(date.year, date.month, date.day, 12).toIso8601String();
}

/// استرجاع أدوية للمذخر من فاتورة شراء (نسخة أوفلاين من
/// POST /api/purchase-invoices/{id}/return-items/، backend/pharmacy_data/purchase_returns.py):
/// لكل سطر: الحد = min(المتبقي من السطر، المخزون الحالي)، الرصيد للوحدات المدفوعة
/// فقط × سعر الاسترجاع (افتراضياً سعر الشراء). المخزون يُخصم من دفعات الفاتورة
/// أولاً ثم FEFO، والوحدات تخرج بمبلغ رصيدها فيُعاد حساب avg_cost
/// ([avgCostAfterReturn]). الرصيد يخفّض متبقي الفاتورة، والفائض يسدّد
/// فواتير المذخر الأخرى (الأقدم أولاً) ثم يبقى رصيداً لصالح الصيدلية.
/// الكل أو لا شيء؛ أخطاء الأسطر ترمي [PurchaseListException] (line = السطر).
///
/// [lines]: [{purchase_invoice_item_id, quantity, unit_price?}].
Future<Map<String, dynamic>> returnPurchaseItems({
  required int pharmacyId,
  required int purchaseInvoiceId,
  required List<Map<String, dynamic>> lines,
  String? notes,
  DateTime? returnDate,
}) async {
  if (lines.isEmpty) throw const PurchaseListException('اختر صنفاً واحداً على الأقل لاسترجاعه.');
  final returnedAt = _movementMoment(returnDate);
  final db = await database;
  return db.transaction((txn) async {
    final invoices = await txn.query('purchase_invoice',
        where: 'id = ? AND pharmacy_id = ?', whereArgs: [purchaseInvoiceId, pharmacyId], limit: 1);
    if (invoices.isEmpty) throw const PurchaseListException('فاتورة الشراء غير موجودة.');
    final invoice = invoices.first;
    final supplierId = invoice['supplier_id'] as int;

    final seen = <int>{};
    final prepared = <Map<String, Object?>>[];
    final medicineIds = <int>{};
    var totalCredit = 0.0;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final itemId = lineInt(line['purchase_invoice_item_id']);
      if (!seen.add(itemId)) throw PurchaseListException('هذا الصنف مكرر في طلب الاسترجاع.', line: index);
      final items = await txn.query('purchase_invoice_item',
          where: 'id = ? AND purchase_invoice_id = ?', whereArgs: [itemId, purchaseInvoiceId], limit: 1);
      if (items.isEmpty) throw PurchaseListException('هذا الصنف ليس من أصناف الفاتورة.', line: index);
      final item = items.first;
      final medicineId = item['medicine_id'] as int?;
      if (medicineId == null) {
        throw PurchaseListException('الصنف ${item['trade_name']} حُذف من المخزون ولا يمكن استرجاعه.', line: index);
      }
      final medicine = await _medicineRow(txn, medicineId);
      final quantity = lineInt(line['quantity']);
      final paidQty = item['quantity'] as int;
      final already = Sqflite.firstIntValue(await txn.rawQuery(
              'SELECT COALESCE(SUM(quantity), 0) FROM purchase_invoice_return_item WHERE purchase_invoice_item_id = ?',
              [itemId])) ??
          0;
      final stock = (medicine['quantity'] as num).toInt();
      final boughtLeft = paidQty + (item['bonus_quantity'] as int) - already;
      final limit = returnableQuantity(
          paidQty: paidQty, bonusQty: item['bonus_quantity'] as int, alreadyReturned: already, currentStock: stock);
      if (quantity < 1) throw PurchaseListException('الكمية المسترجعة يجب أن تكون 1 على الأقل.', line: index);
      if (quantity > limit) {
        throw PurchaseListException(
          'أقصى كمية يمكن استرجاعها من ${item['trade_name']} هي $limit '
          '(المتبقي من الفاتورة ${boughtLeft < 0 ? 0 : boughtLeft}، المتوفر بالمخزون $stock).',
          line: index,
        );
      }
      final price = lineNum(line['unit_price']) ?? (item['buy_price'] as num).toDouble();
      if (price < 0) throw PurchaseListException('سعر الاسترجاع لا يمكن أن يكون سالباً.', line: index);
      final credited = creditedUnits(paidQty: paidQty, alreadyReturned: already, quantity: quantity);
      final credit = roundMoney(credited * price);
      try {
        await _deductFefo(txn, medicineId, quantity, sellableOnly: false, preferInvoiceId: purchaseInvoiceId);
      } on StateError catch (e) {
        throw PurchaseListException(e.message, line: index);
      }
      final oldAvg = (medicine['avg_cost'] as num?)?.toDouble();
      final newAvg = avgCostAfterReturn(oldQty: stock, oldAvg: oldAvg, returnedQty: quantity, costRemoved: credit);
      if (newAvg != oldAvg) {
        await txn.update('medicine', {'avg_cost': newAvg}, where: 'id = ?', whereArgs: [medicineId]);
      }
      medicineIds.add(medicineId);
      totalCredit += credit;
      prepared.add({
        'purchase_invoice_item_id': itemId,
        'medicine_id': medicineId,
        'trade_name': item['trade_name'],
        'quantity': quantity,
        'credited_quantity': credited,
        'unit_return_price': roundMoney(price),
        'credit_amount': credit,
      });
    }

    totalCredit = roundMoney(totalCredit);
    final outstanding = await _invoiceRemaining(txn, purchaseInvoiceId);
    final open = outstanding > 0 ? outstanding : 0.0;
    final excess = totalCredit > open ? roundMoney(totalCredit - open) : 0.0;
    final returnId = await txn.insert('purchase_invoice_return', {
      'pharmacy_id': pharmacyId,
      'supplier_id': supplierId,
      'purchase_invoice_id': purchaseInvoiceId,
      'amount_returned': totalCredit,
      'excess_credit': excess,
      'notes': notes?.trim(),
      'returned_at': returnedAt,
    });
    for (final row in prepared) {
      await txn.insert('purchase_invoice_return_item', {...row, 'pharmacy_id': pharmacyId, 'purchase_return_id': returnId});
    }
    if (excess > 0) {
      await _settleOtherInvoices(txn,
          pharmacyId: pharmacyId, supplierId: supplierId, excludeInvoiceId: purchaseInvoiceId, amount: excess, when: returnedAt);
    }
    await _refreshRemainingDebt(txn, supplierId);
    return {
      'return_id': returnId,
      'amount_returned': totalCredit,
      'excess_credit': excess,
      'medicine_ids': medicineIds.toList(),
    };
  });
}

/// فائض مرتجع يسدّد فواتير المذخر الأخرى المفتوحة (الأقدم أولاً)؛ يرجع الباقي (رصيد).
Future<double> _settleOtherInvoices(
  DatabaseExecutor txn, {
  required int pharmacyId,
  required int supplierId,
  required int excludeInvoiceId,
  required double amount,
  required String when,
}) async {
  var left = amount;
  final others = await txn.query('purchase_invoice',
      where: 'supplier_id = ? AND id != ?', whereArgs: [supplierId, excludeInvoiceId], orderBy: 'created_at, id');
  for (final other in others) {
    if (left <= 0) break;
    final open = await _invoiceRemaining(txn, other['id'] as int);
    if (open <= 0) continue;
    left = roundMoney(left -
        await _applySupplierCredit(txn,
            pharmacyId: pharmacyId,
            supplierId: supplierId,
            invoiceId: other['id'] as int,
            amount: left < open ? left : open,
            notes: SupplierCreditNote.fromReturn,
            when: when));
  }
  return left;
}

/// استلام أموال من المذخر مقابل رصيد الصيدلية لديه (جزئي مسموح، لا يتجاوز الرصيد).
Future<int> receiveSupplierRefund({
  required int pharmacyId,
  required int supplierId,
  required double amount,
  String? notes,
  DateTime? receivedDate,
}) async {
  final when = _movementMoment(receivedDate);
  final value = roundMoney(amount);
  if (value <= 0) throw const PurchaseListException('يجب أن يكون المبلغ المستلم أكبر من صفر.');
  final db = await database;
  return db.transaction((txn) async {
    final supplier = await txn.query('pharmacy_supplier',
        where: 'id = ? AND pharmacy_id = ?', whereArgs: [supplierId, pharmacyId], limit: 1);
    if (supplier.isEmpty) throw const PurchaseListException('المذخر غير موجود.');
    final available = ((await _supplierFiguresFor(txn, supplierId))['available_credit'] as num).toDouble();
    if (value > available) {
      throw PurchaseListException('المبلغ أكبر من رصيدك لدى المذخر (${available.toStringAsFixed(2)}).');
    }
    return txn.insert('supplier_refund', {
      'pharmacy_id': pharmacyId,
      'supplier_id': supplierId,
      'amount': value,
      'notes': notes?.trim(),
      'received_at': when,
    });
  });
}

/// أسطر استرجاع (لكشف الحساب ونافذة الفاتورة). الاسترجاع القديم بالمبلغ: قائمة فارغة.
Future<List<Map<String, dynamic>>> getPurchaseReturnItems(int purchaseReturnId) async {
  final db = await database;
  return db.query('purchase_invoice_return_item',
      where: 'purchase_return_id = ?', whereArgs: [purchaseReturnId], orderBy: 'id');
}

/// كشف حساب تفصيلي للمذخر: الفواتير والدفعات والاسترجاعات (مع أسطرها)
/// واستخدام الرصيد (بلا أثر على الرصيد) والمبالغ المستلمة. مجموع debt_added =
/// رصيد المذخر الموحّد دائماً (نفس SupplierViewSet.statement).
Future<List<Map<String, dynamic>>> getSupplierStatementOfAccount(int supplierId) async {
  final db = await database;
  // لكل حركة: الفاتورة المرتبطة (purchase_invoice_id، invoice_number،
  // invoice_created_at) لكشف الحساب المحاسبي (supplier_statement.dart)؛ وللفاتورة
  // نفسها إجماليها وعدد أصنافها. مجموع debt_added = رصيد المذخر دائماً.
  final rows = await db.rawQuery('''
    SELECT
      pi.id,
      'invoice' AS transaction_type,
      COALESCE(pi.invoice_number, 'فاتورة بدون رقم') AS reference,
      pi.total_amount - COALESCE((
        SELECT SUM(pir.amount_returned)
        FROM purchase_invoice_return pir
        WHERE pir.purchase_invoice_id = pi.id
      ), 0.0) AS amount,
      pi.paid_amount AS cash_paid,
      -- إجمالي الفاتورة ناقص ما دُفع عند إنشائها بلا سطر دفعة (فواتير يدوية
      -- قديمة). الدفعات والاسترجاعات لها أسطرها المنفصلة أدناه.
      pi.total_amount - (pi.paid_amount - COALESCE((
        SELECT SUM(sp.amount_paid)
        FROM supplier_payment sp
        WHERE sp.purchase_invoice_id = pi.id
      ), 0.0)) AS debt_added,
      pi.created_at AS date_time,
      '' AS notes,
      pi.id AS purchase_invoice_id,
      pi.invoice_number AS invoice_number,
      pi.created_at AS invoice_created_at,
      pi.total_amount AS total_amount,
      pi.item_count AS item_count
    FROM purchase_invoice pi
    WHERE pi.supplier_id = ?

    UNION ALL

    SELECT
      sp.id,
      'payment' AS transaction_type,
      'تسديد دفعة' AS reference,
      sp.amount_paid AS amount,
      sp.amount_paid AS cash_paid,
      -sp.amount_paid AS debt_added,
      sp.paid_at AS date_time,
      sp.notes,
      sp.purchase_invoice_id,
      pi.invoice_number,
      pi.created_at AS invoice_created_at,
      NULL AS total_amount,
      NULL AS item_count
    FROM supplier_payment sp
    LEFT JOIN purchase_invoice pi ON pi.id = sp.purchase_invoice_id
    WHERE sp.supplier_id = ?

    UNION ALL

    SELECT
      r.id,
      'return' AS transaction_type,
      'استرجاع من فاتورة #' || COALESCE(NULLIF(pi.invoice_number, ''), pi.id) AS reference,
      r.amount_returned AS amount,
      0.0 AS cash_paid,
      -r.amount_returned AS debt_added,
      r.returned_at AS date_time,
      r.notes,
      r.purchase_invoice_id,
      pi.invoice_number,
      pi.created_at AS invoice_created_at,
      NULL AS total_amount,
      NULL AS item_count
    FROM purchase_invoice_return r
    JOIN purchase_invoice pi ON pi.id = r.purchase_invoice_id
    WHERE r.supplier_id = ?

    UNION ALL

    SELECT
      a.id,
      'credit_applied' AS transaction_type,
      COALESCE(NULLIF(a.notes, ''), '${SupplierCreditNote.previous}') || ' — فاتورة #' ||
        COALESCE(NULLIF(pi.invoice_number, ''), pi.id) AS reference,
      a.amount AS amount,
      0.0 AS cash_paid,
      0.0 AS debt_added,
      a.applied_at AS date_time,
      a.notes,
      a.purchase_invoice_id,
      pi.invoice_number,
      pi.created_at AS invoice_created_at,
      NULL AS total_amount,
      NULL AS item_count
    FROM supplier_credit_application a
    JOIN purchase_invoice pi ON pi.id = a.purchase_invoice_id
    WHERE a.supplier_id = ?

    UNION ALL

    SELECT
      f.id,
      'refund' AS transaction_type,
      'استلام أموال من المذخر' AS reference,
      f.amount AS amount,
      0.0 AS cash_paid,
      f.amount AS debt_added,
      f.received_at AS date_time,
      f.notes,
      NULL AS purchase_invoice_id,
      NULL AS invoice_number,
      NULL AS invoice_created_at,
      NULL AS total_amount,
      NULL AS item_count
    FROM supplier_refund f
    WHERE f.supplier_id = ?

    ORDER BY date_time DESC
  ''', [supplierId, supplierId, supplierId, supplierId, supplierId]);

  final result = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (row['transaction_type'] == 'return') {
      result.add({...row, 'items': await getPurchaseReturnItems(row['id'] as int)});
    } else {
      result.add(Map<String, dynamic>.from(row));
    }
  }
  return result;
}


//====================================================
// 4️⃣ الإحصائيات والتحليلات المالية للمذاخر (Analytics)
//====================================================

/// جلب المذخر الأكبر (صاحب أعلى حجم تعاملات مالية)
Future<Map<String, dynamic>?> getTopSupplier(int pharmacyId) async {
  final db = await database;
  final result = await db.rawQuery('''
    SELECT
      s.id,
      s.name,
      s.phone,
      SUM(pi.total_amount - COALESCE((
        SELECT SUM(pir.amount_returned)
        FROM purchase_invoice_return pir
        WHERE pir.purchase_invoice_id = pi.id
      ), 0.0)) AS total_purchases
    FROM pharmacy_supplier s
    INNER JOIN purchase_invoice pi ON s.id = pi.supplier_id
    WHERE s.pharmacy_id = ?
    GROUP BY s.id
    ORDER BY total_purchases DESC
    LIMIT 1
  ''', [pharmacyId]);

  if (result.isEmpty) return null;
  return result.first;
}

/// مجموع ديون المذاخر لكل مذخر على حدة: رصيد مذخر لصالحنا لا يُطرح من دين مذخر آخر.
Future<double> getTotalSuppliersDebt(int pharmacyId) async {
  final suppliers = await getSuppliersWithFinancials(pharmacyId);
  return roundMoney(suppliers.fold<double>(0, (sum, s) => sum + (s['remaining_debt'] as num).toDouble()));
}

//====================================================
// نقطة 5 (المواصفات الكاملة): تحويل صيدلية أوفلاين إلى أونلاين برفع أولي
// شامل. راجع MigrationViewSet في الباك اند للترتيب الصارم وللتحقق من عدم
// التكرار. ⚠️ لا حذف لأي بيانات محلية بعد النجاح — النسخة المحلية تبقى
// كما هي وتُستخدم كقراءة/كاش لاحقاً مثل باقي الأجهزة، فلا حاجة لأي دالة
// "تفريغ" هنا إطلاقاً (خلافاً لتصميم سابق أُلغي عمداً).
//====================================================

/// هل توجد أي بيانات أوفلاين محلية تستحق الرفع — يُستخدم فقط لتقرير ما إذا
/// كان يستحق عرض اقتراح الرفع أصلاً (صيدلية أونلاين جديدة بلا بيانات سابقة
/// لا تحتاج أي رفع، فلا داعي لإزعاج صاحبها بالسؤال). يشمل كل ما تحمله
/// getOfflineMigrationPayload، لا المخزون/الموردين فقط، وإلا بقيت مثلاً
/// مصروفات صيدلية بلا أدوية مخفية أونلاين بلا أي اقتراح رفع.
Future<bool> hasLocalDataWorthMigrating(int pharmacyId) async {
  final db = await database;
  const checks = [
    'SELECT 1 FROM medicine WHERE pharmacy_id = ? AND id >= $localIdBase LIMIT 1',
    'SELECT 1 FROM invoice WHERE pharmacy_id = ? AND id >= $localIdBase LIMIT 1',
    'SELECT 1 FROM expense WHERE pharmacy_id = ? AND id >= $localIdBase LIMIT 1',
    'SELECT 1 FROM damaged_medicine WHERE pharmacy_id = ? AND id >= $localIdBase LIMIT 1',
    'SELECT 1 FROM pharmacy_supplier WHERE pharmacy_id = ? LIMIT 1',
    'SELECT 1 FROM purchase_invoice WHERE pharmacy_id = ? LIMIT 1',
  ];
  for (final sql in checks) {
    if ((await db.rawQuery(sql, [pharmacyId])).isNotEmpty) return true;
  }
  return false;
}

/// يبني حمولة الرفع الكاملة (النطاق الشامل بلا استثناء) من الجداول
/// المحلية، بنفس مفاتيح MigrationViewSet.upload_offline_data المتوقَّعة
/// تماماً — بما فيها القوائم المتداخلة (payments/returns داخل كل فاتورة
/// شراء، items داخل كل فاتورة بيع) حتى لا يحتاج السيرفر جدول تحويل
/// معرّفات منفصلاً لفواتير الشراء/البيع نفسها.
Future<Map<String, dynamic>> getOfflineMigrationPayload(int pharmacyId) async {
  final db = await database;

  // 1. الموردون
  final suppliers = await db.query('pharmacy_supplier', where: 'pharmacy_id = ?', whereArgs: [pharmacyId]);
  final suppliersPayload = suppliers
      .map((s) => {
            'local_id': s['id'],
            'name': s['name'],
            'phone': s['phone'],
          })
      .toList();

  // 1ب. المخازن المحلية (الرئيسي يُطابَق مع رئيسي الخادم، والباقي تُنشأ
  // كمخازن إضافية). كاش مخازن الخادم مستبعد — هنا وفي كل أقسام الحمولة:
  // تُرفع الصفوف المحلية فقط (معرّف >= localIdBase)، لا صفوف كاش الخادم.
  final warehouses = await db.query(
    'warehouses',
    where: 'pharmacy_id = ? AND ${localOnly()}',
    whereArgs: [pharmacyId],
  );
  final warehousesPayload = warehouses
      .map((w) => {
            'local_id': w['id'],
            'name': w['name'],
            'is_main': (w['is_main'] as int?) == 1,
          })
      .toList();

  // 2. المخزون الكامل (كل صف بمرجع مخزنه المحلي)
  final medicines = await db.query('medicine', where: 'pharmacy_id = ? AND ${localOnly()}', whereArgs: [pharmacyId]);
  final medicinesPayload = <Map<String, dynamic>>[];
  for (final m in medicines) {
    final batches = await getMedicineBatches(m['id'] as int);
    medicinesPayload.add({
            'local_id': m['id'],
            'local_warehouse_id': m['warehouse_id'],
            'trade_name': m['trade_name'],
            'scientific_name': m['scientific_name'],
            'category': m['category'],
            'quantity': m['quantity'],
            'buy_price': m['buy_price'],
            'sell_price': m['sell_price'],
            'expiry_date': m['expiry_date'],
            'shelf_location': m['shelf_location'],
            'is_damaged': (m['is_damaged'] as int?) == 1,
            'barcode': m['barcode'],
            'avg_cost': m['avg_cost'],
            'batches': batches
                .map((b) => {
                      'quantity': b['quantity'],
                      'expiry_date': b['expiry_date'],
                      'purchase_price': b['purchase_price'],
                      'source': b['source'],
                      'local_supplier_id': b['supplier_id'],
                      'local_purchase_invoice_id': b['purchase_invoice_id'],
                    })
                .toList(),
          });
  }

  // 3. فواتير الشراء الكاملة + دفعاتها + مرتجعاتها (متداخلة داخل كل فاتورة)
  final purchaseInvoices = await db.query('purchase_invoice', where: 'pharmacy_id = ?', whereArgs: [pharmacyId]);
  final purchaseInvoicesPayload = <Map<String, dynamic>>[];
  for (final pi in purchaseInvoices) {
    final piId = pi['id'];
    final payments = await db.query('supplier_payment', where: 'purchase_invoice_id = ?', whereArgs: [piId]);
    final returns = await db.query('purchase_invoice_return', where: 'purchase_invoice_id = ?', whereArgs: [piId]);
    final items = await db.query('purchase_invoice_item', where: 'purchase_invoice_id = ?', whereArgs: [piId], orderBy: 'id');
    purchaseInvoicesPayload.add({
      // local_id: لربط الدفعات (batches.local_purchase_invoice_id) بفاتورتها على الخادم.
      'local_id': piId,
      'local_supplier_id': pi['supplier_id'],
      'invoice_number': pi['invoice_number'],
      'invoice_date': pi['invoice_date'],
      'source': pi['source'],
      'item_count': pi['item_count'],
      'total_amount': pi['total_amount'],
      'paid_amount': pi['paid_amount'],
      'created_at': pi['created_at'],
      'items': items
          .map((it) => {
                'local_id': it['id'],
                'local_medicine_id': it['medicine_id'],
                'trade_name': it['trade_name'],
                'quantity': it['quantity'],
                'bonus_quantity': it['bonus_quantity'],
                'buy_price': it['buy_price'],
                'effective_unit_cost': it['effective_unit_cost'],
                'sell_price': it['sell_price'],
                'expiry_date': it['expiry_date'],
                'line_total': it['line_total'],
              })
          .toList(),
      'payments': payments
          .map((p) => {
                'amount_paid': p['amount_paid'],
                'notes': p['notes'],
                'paid_at': p['paid_at'],
              })
          .toList(),
      'returns': [
        for (final r in returns)
          {
            'amount_returned': r['amount_returned'],
            'excess_credit': r['excess_credit'],
            'notes': r['notes'],
            'returned_at': r['returned_at'],
            'items': (await getPurchaseReturnItems(r['id'] as int))
                .map((ri) => {
                      'local_purchase_invoice_item_id': ri['purchase_invoice_item_id'],
                      'local_medicine_id': ri['medicine_id'],
                      'trade_name': ri['trade_name'],
                      'quantity': ri['quantity'],
                      'credited_quantity': ri['credited_quantity'],
                      'unit_return_price': ri['unit_return_price'],
                      'credit_amount': ri['credit_amount'],
                    })
                .toList(),
          },
      ],
      'credit_applications': (await db.query('supplier_credit_application',
              where: 'purchase_invoice_id = ?', whereArgs: [piId], orderBy: 'id'))
          .map((a) => {'amount': a['amount'], 'notes': a['notes'], 'applied_at': a['applied_at']})
          .toList(),
    });
  }

  // 3ب. المبالغ المستلمة من المذاخر مقابل رصيد الصيدلية لديهم.
  final refundsPayload = (await db.query('supplier_refund', where: 'pharmacy_id = ?', whereArgs: [pharmacyId]))
      .map((f) => {
            'local_supplier_id': f['supplier_id'],
            'amount': f['amount'],
            'notes': f['notes'],
            'received_at': f['received_at'],
          })
      .toList();

  // 4. فواتير البيع الكاملة (كل التاريخ) + عناصرها. اسم الكاشير يُجلب من
  // user_profile/users المحليين (نفس JOIN المستخدم في تقرير الشفتات
  // المحلي) لأنه لا حساب Django حقيقي وراء هذه الفواتير التاريخية —
  // ستُحفَظ في Invoice.cashier_name على السيرفر بدل Invoice.cashier.
  final invoices = await db.rawQuery('''
    SELECT i.*, COALESCE(u.full_name, u.username, '') AS cashier_name
    FROM invoice i
    LEFT JOIN user_profile up ON i.cashier_id = up.id
    LEFT JOIN users u ON up.user_id = u.id
    WHERE i.pharmacy_id = ? AND ${localOnly('i.')}
  ''', [pharmacyId]);
  final invoicesPayload = <Map<String, dynamic>>[];
  for (final inv in invoices) {
    final invId = inv['id'];
    final items = await db.query('invoice_item', where: 'invoice_id = ?', whereArgs: [invId]);
    invoicesPayload.add({
      'invoice_number': inv['invoice_number'],
      'cashier_name': inv['cashier_name'],
      'total_amount': inv['total_amount'],
      'discount': inv['discount'],
      'final_amount': inv['final_amount'],
      'created_at': inv['created_at'],
      'is_refunded': (inv['is_refunded'] as int?) == 1,
      'items': items
          .map((it) => {
                'local_medicine_id': it['medicine_id'],
                'trade_name': it['trade_name'],
                'quantity': it['quantity'],
                'unit_price': it['unit_price'],
                'total_price': it['total_price'],
                'unit_cost': it['unit_cost'],
              })
          .toList(),
    });
  }

  // 5. كل سجلات الإتلاف
  final damaged = await db.query('damaged_medicine', where: 'pharmacy_id = ? AND ${localOnly()}', whereArgs: [pharmacyId]);
  final damagedPayload = damaged
      .map((d) => {
            'local_medicine_id': d['medicine_id'],
            'quantity_damaged': d['quantity_damaged'],
            'total_cost': d['total_cost'],
            'reason': d['reason'],
            'notes': d['notes'],
            'damaged_at': d['damaged_at'],
          })
      .toList();

  // 6. كل المصاريف
  final expenses = await db.query('expense', where: 'pharmacy_id = ? AND ${localOnly()}', whereArgs: [pharmacyId]);
  final expensesPayload = expenses
      .map((e) => {
            'expense_type': e['expense_type'],
            'expense_date': e['expense_date'],
            'amount': e['amount'],
            'notes': e['notes'],
          })
      .toList();

  // 7. سجل عمليات النقل (تاريخي فقط؛ الكميات النهائية مرفوعة مع الأدوية).
  final transfers = await db.query('stock_transfers', where: 'pharmacy_id = ?', whereArgs: [pharmacyId]);
  final transfersPayload = transfers
      .map((t) => {
            'local_from_warehouse_id': t['from_warehouse_id'],
            'local_to_warehouse_id': t['to_warehouse_id'],
            'trade_name': t['trade_name'],
            'barcode': t['barcode'],
            'quantity': t['quantity'],
            'notes': t['notes'],
            'transferred_at': t['transferred_at'],
          })
      .toList();

  return {
    'warehouses': warehousesPayload,
    'suppliers': suppliersPayload,
    'medicines': medicinesPayload,
    'purchase_invoices': purchaseInvoicesPayload,
    'invoices': invoicesPayload,
    'damaged_medicines': damagedPayload,
    'expenses': expensesPayload,
    'stock_transfers': transfersPayload,
    'supplier_refunds': refundsPayload,
  };
}

} // <-- هذا القوس يغلق كلاس DatabaseHelper بالكامل