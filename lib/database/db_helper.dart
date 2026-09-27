import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:convert';
import 'dart:io'; 
import 'package:flutter/services.dart' show rootBundle;

class DatabaseHelper {
  DatabaseHelper._();

  static final DatabaseHelper instance = DatabaseHelper._();

  static Database? _database;
  static const String _dbName = "pharmacy.db";

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();

    return _database!;
  }

Future<Database> _initDatabase() async {
  final directory = await getApplicationSupportDirectory();

  if (!await Directory(directory.path).exists()) {
    await Directory(directory.path).create(recursive: true);
  }

  final path = join(directory.path, _dbName);

  return openDatabase(
    path,
    version: 7,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
    },
    onCreate: _onCreate,
    onUpgrade: _onUpgrade,
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

  // 3ب. جدول المخازن (خاصية الباقة الذهبية: حتى مخزنين لكل صيدلية، الأول
  // هو دائماً is_main = 1 ويُستخدم حصراً في عملية البيع - راجع نقطة 13 أدناه)
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

  // 4. جدول الأدوية
  // ⚠️ barcode لم يعد UNIQUE على مستوى الجدول كله (كان يمنع وجود نفس
  // الصنف بمخزنين منفصلين أو بصيدليتين مرتبطتين). التفرّد الآن ضمن نفس
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
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(warehouse_id) REFERENCES warehouses(id)
    )
  ''');

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
  await db.execute('''
    CREATE TABLE invoice(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      invoice_number TEXT NOT NULL UNIQUE,
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
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(supplier_id) REFERENCES pharmacy_supplier(id) ON DELETE CASCADE
    )
  ''');

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

  // 12. سجل الاسترجاعات الجزئية من فواتير الشراء
  await db.execute('''
    CREATE TABLE purchase_invoice_return (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id INTEGER NOT NULL,
      supplier_id INTEGER NOT NULL,
      purchase_invoice_id INTEGER NOT NULL,
      amount_returned REAL NOT NULL CHECK(amount_returned > 0),
      notes TEXT,
      returned_at TEXT NOT NULL,
      FOREIGN KEY(pharmacy_id) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(supplier_id) REFERENCES pharmacy_supplier(id) ON DELETE CASCADE,
      FOREIGN KEY(purchase_invoice_id) REFERENCES purchase_invoice(id) ON DELETE CASCADE
    )
  ''');

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

  // 13. جدول ربط الصيدليات (خاصية الباقة الذهبية: نقل مخزون فقط، بلا أي
  // مزامنة بيانات أخرى). الربط قرار إداري مركزي يُنشأ من لوحة أدمن Django
  // فقط، لا من التطبيق — هذا الجدول كاش قراءة فقط يُملأ عبر
  // replacePharmacyLinksCache() بعد جلب القائمة من السيرفر. العلاقة غير
  // موجّهة، لكن تُخزَّن دائماً بترتيب ثابت (الأصغر ثم الأكبر) حتى يمنع
  // القيد UNIQUE تكرار نفس الرابط بترتيب معكوس.
  await db.execute('''
    CREATE TABLE pharmacy_links(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pharmacy_id_a INTEGER NOT NULL,
      pharmacy_id_b INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY(pharmacy_id_a) REFERENCES pharmacy_branch(id),
      FOREIGN KEY(pharmacy_id_b) REFERENCES pharmacy_branch(id),
      UNIQUE(pharmacy_id_a, pharmacy_id_b)
    )
  ''');

  // 14. سجل عمليات نقل المخزون (بين مخزنين لنفس الصيدلية، أو بين مخزنين
  // لصيدليتين مرتبطتين). لا يُخزَّن medicine_id مباشرة لأن الصنف قد "ينتقل"
  // كصف مستقل بمعرّف جديد في المخزن الهدف - راجع transferStock() أدناه.
  await db.execute('''
    CREATE TABLE stock_transfers(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_warehouse_id INTEGER NOT NULL,
      to_warehouse_id INTEGER NOT NULL,
      trade_name TEXT NOT NULL,
      barcode TEXT,
      quantity INTEGER NOT NULL CHECK(quantity > 0),
      transferred_at TEXT NOT NULL,
      notes TEXT,
      FOREIGN KEY(from_warehouse_id) REFERENCES warehouses(id),
      FOREIGN KEY(to_warehouse_id) REFERENCES warehouses(id)
    )
  ''');

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
  await db.execute('CREATE INDEX idx_stock_transfers_from ON stock_transfers(from_warehouse_id);');
  await db.execute('CREATE INDEX idx_stock_transfers_to ON stock_transfers(to_warehouse_id);');
  await db.execute('CREATE INDEX idx_trade_name ON medicine(trade_name);');
  await db.execute('CREATE INDEX idx_scientific_name ON medicine(scientific_name);');
  await db.execute('CREATE INDEX idx_invoice_number ON invoice(invoice_number);');
  await db.execute('CREATE INDEX idx_invoice_date ON invoice(created_at);');
  await db.execute('CREATE INDEX idx_purchase_invoice_supplier ON purchase_invoice(supplier_id);');
  await db.execute('CREATE INDEX idx_supplier_payment_supplier ON supplier_payment(supplier_id);');
  await db.execute('CREATE INDEX idx_supplier_payment_invoice ON supplier_payment(purchase_invoice_id);');
  await db.execute('CREATE INDEX idx_purchase_invoice_return_invoice ON purchase_invoice_return(purchase_invoice_id);');
  await db.execute('CREATE INDEX idx_expense_pharmacy_date ON expense(pharmacy_id, expense_date);');

  // 🔴 فهرس لتسريع البحث اللحظي في القاموس أثناء الكتابة
  await db.execute('CREATE INDEX idx_master_trade_name ON master_medicines(trade_name);');

  // 🚀 تعبئة القاموس تلقائياً بالـ 1000 دواء من ملف الـ JSON
  await _seedMasterMedicines(db);
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
    // خاصية الباقة الذهبية: تعدد المخازن + ربط الصيدليات (راجع
    // subscription_plan.dart: AppFeature.multiWarehouse / pharmacyLinking).

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

    // ب) جدول ربط الصيدليات وجدول سجل عمليات النقل.
    await db.execute('''
      CREATE TABLE pharmacy_links(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pharmacy_id_a INTEGER NOT NULL,
        pharmacy_id_b INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(pharmacy_id_a) REFERENCES pharmacy_branch(id),
        FOREIGN KEY(pharmacy_id_b) REFERENCES pharmacy_branch(id),
        UNIQUE(pharmacy_id_a, pharmacy_id_b)
      )
    ''');
    await db.execute('''
      CREATE TABLE stock_transfers(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_warehouse_id INTEGER NOT NULL,
        to_warehouse_id INTEGER NOT NULL,
        trade_name TEXT NOT NULL,
        barcode TEXT,
        quantity INTEGER NOT NULL CHECK(quantity > 0),
        transferred_at TEXT NOT NULL,
        notes TEXT,
        FOREIGN KEY(from_warehouse_id) REFERENCES warehouses(id),
        FOREIGN KEY(to_warehouse_id) REFERENCES warehouses(id)
      )
    ''');
    await db.execute('CREATE INDEX idx_stock_transfers_from ON stock_transfers(from_warehouse_id);');
    await db.execute('CREATE INDEX idx_stock_transfers_to ON stock_transfers(to_warehouse_id);');

    // ج) إعادة بناء جدول medicine بالكامل: إضافة warehouse_id (وربط كل
    // صف حالي بالمخزن الرئيسي لنفس صيدليته)، وإزالة قيد UNIQUE عن barcode
    // على مستوى الجدول كله (كان يمنع تكرار نفس الباركود بين مخزنين أو
    // صيدليتين). SQLite لا يدعم تعديل/حذف قيد عمود مباشرة، فلازم إعادة
    // بناء الجدول. يُعطَّل foreign_keys مؤقتاً لأن invoice_item و
    // damaged_medicine يشيران لـ medicine.id بقيد بلا ON DELETE CASCADE،
    // وسيفشل DROP TABLE أثناء إعادة البناء لو بقي القيد مفعّلاً.
    await db.execute('PRAGMA foreign_keys = OFF;');

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

    await db.execute('PRAGMA foreign_keys = ON;');
  }
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
Future<int> insertMedicine(Map<String, dynamic> medicine) async {
  final db = await database;
  return await db.insert(
    'medicine',
    medicine,
    conflictAlgorithm: ConflictAlgorithm.abort,
  );
}

// جميع أدوية الصيدلية. warehouseId اختياري: مرّره لتقييد النتيجة بمخزن
// واحد فقط (مثلاً POS يمرر دائماً المخزن الرئيسي - راجع getMainWarehouseMedicines
// أدناه) - بدونه تُعاد أصناف كل مخازن الصيدلية معاً (لشاشة الجرد العامة).
Future<List<Map<String, dynamic>>> getMedicines(int pharmacyId, {int? warehouseId}) async {
  final db = await database;
  if (warehouseId != null) {
    return await db.query(
      'medicine',
      where: 'pharmacy_id = ? AND warehouse_id = ?',
      whereArgs: [pharmacyId, warehouseId],
      orderBy: 'trade_name COLLATE NOCASE ASC',
    );
  }
  return await db.query(
    'medicine',
    where: 'pharmacy_id = ?',
    whereArgs: [pharmacyId],
    orderBy: 'trade_name COLLATE NOCASE ASC',
  );
}

/// ⚠️ تُستخدم حصراً من شاشة نقطة البيع (pos_screen.dart): البيع دائماً
/// من المخزن الرئيسي فقط بحسب طلب الباقة الذهبية، بغض النظر عن عدد
/// المخازن الأخرى التي قد تملكها الصيدلية.
Future<List<Map<String, dynamic>>> getMainWarehouseMedicines(int pharmacyId) async {
  final mainWarehouseId = await ensureMainWarehouse(pharmacyId);
  return getMedicines(pharmacyId, warehouseId: mainWarehouseId);
}

// تعديل دواء
Future<int> updateMedicine(int id, Map<String, dynamic> medicine) async {
  final db = await database;
  return await db.update(
    'medicine',
    medicine,
    where: 'id = ?',
    whereArgs: [id],
  );
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
  // Warehouses & Pharmacy Linking CRUD (خاصية الباقة الذهبية)
  //
  // ⚠️ هذه الدوال كلها أوفلاين-فقط (SQLite محلي)، تماماً كباقي db_helper.
  // في وضع الأونلاين هذه الشاشات يجب أن تمر بنفس نمط Repository المتبع
  // لبقية النطاقات (medicine/expense) بدل استدعاء هذه الدوال مباشرة —
  // لم يُبنَ ذلك الجزء بعد (يحتاج نظيره على السيرفر أولاً).
  //====================================================

  static const int maxWarehousesPerPharmacy = 2;

  /// يعيد المخزن الرئيسي للصيدلية (ينشئه إن لم يوجد بعد - حالة صيدلية
  /// جديدة كلياً لم يمر عليها أي إدخال دواء/فاتورة سابقاً).
  Future<int> ensureMainWarehouse(int pharmacyId) async {
    final db = await database;
    final existing = await db.query(
      'warehouses',
      where: 'pharmacy_id = ? AND is_main = 1',
      whereArgs: [pharmacyId],
      limit: 1,
    );
    if (existing.isNotEmpty) return existing.first['id'] as int;

    return await db.insert('warehouses', {
      'pharmacy_id': pharmacyId,
      'name': 'المخزن الرئيسي',
      'is_main': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// كل مخازن الصيدلية (الرئيسي أولاً).
  Future<List<Map<String, dynamic>>> getWarehouses(int pharmacyId) async {
    final db = await database;
    return await db.query(
      'warehouses',
      where: 'pharmacy_id = ?',
      whereArgs: [pharmacyId],
      orderBy: 'is_main DESC, id ASC',
    );
  }

  /// إضافة مخزن ثانٍ (خاصية Gold). يرمي StateError إن كانت الصيدلية
  /// وصلت الحد الأقصى (مخزنين) بالفعل — تحقق من entitlements.allows
  /// (AppFeature.multiWarehouse) في الواجهة *قبل* استدعاء هذه الدالة؛
  /// الفحص هنا طبقة حماية إضافية فقط.
  Future<int> addSecondaryWarehouse({
    required int pharmacyId,
    required String name,
  }) async {
    final db = await database;
    await ensureMainWarehouse(pharmacyId);

    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM warehouses WHERE pharmacy_id = ?',
      [pharmacyId],
    )) ?? 0;

    if (count >= maxWarehousesPerPharmacy) {
      throw StateError('الحد الأقصى لعدد المخازن لكل صيدلية هو $maxWarehousesPerPharmacy.');
    }

    return await db.insert('warehouses', {
      'pharmacy_id': pharmacyId,
      'name': name,
      'is_main': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<int> renameWarehouse(int warehouseId, String newName) async {
    final db = await database;
    return await db.update(
      'warehouses',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [warehouseId],
    );
  }

  /// حذف مخزن ثانوي فارغ (لا يحذف المخزن الرئيسي أبداً، ويرفض حذف مخزن
  /// فيه أصناف كمياتها > 0 حتى لا يُفقَد أثر المخزون بصمت).
  Future<void> deleteSecondaryWarehouse(int warehouseId) async {
    final db = await database;
    final warehouse = await db.query('warehouses', where: 'id = ?', whereArgs: [warehouseId], limit: 1);
    if (warehouse.isEmpty) return;
    if ((warehouse.first['is_main'] as int) == 1) {
      throw StateError('لا يمكن حذف المخزن الرئيسي.');
    }

    final stockCount = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COALESCE(SUM(quantity), 0) FROM medicine WHERE warehouse_id = ?',
      [warehouseId],
    )) ?? 0;
    if (stockCount > 0) {
      throw StateError('لا يمكن حذف مخزن يحتوي على كمية مخزون. انقل الأصناف أولاً.');
    }

    await db.delete('warehouses', where: 'id = ?', whereArgs: [warehouseId]);
  }

  //====================================================
  // Pharmacy Links — كاش قراءة فقط يُزامَن من لوحة تحكم الأدمن (Django)
  //
  // ⚠️ تعديل مهم: الربط بين صيدليتين قرار إداري مركزي فقط (يتم من لوحة
  // الأدمن)، لا يملك صاحب الصيدلية صلاحية إنشائه أو حذفه من داخل التطبيق.
  // لذلك لا توجد هنا أي دالة linkPharmacies/unlinkPharmacies تُستدعى من
  // الواجهة — الجدول المحلي pharmacy_links هو كاش قراءة فقط، تماماً بنفس
  // نمط medicine/expense الأونلاين، يُحدَّث فقط بعد جلب قائمة الروابط من
  // endpoint على السيرفر (لم يُبنَ بعد على الباك اند — راجع الملاحظة في
  // نهاية هذا القسم).
  //====================================================

  /// يستبدل كل روابط هذه الصيدلية بالقائمة القادمة من السيرفر. يُستدعى فقط
  /// من كود مزامنة (مثلاً عند فتح التطبيق أو الشاشة، أونلاين أو أوفلاين
  /// على حد سواء طالما هناك اتصال)، أبداً كنتيجة تفاعل مباشر من المستخدم.
  Future<void> replacePharmacyLinksCache({
    required int pharmacyId,
    required List<int> linkedPharmacyIds,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'pharmacy_links',
        where: 'pharmacy_id_a = ? OR pharmacy_id_b = ?',
        whereArgs: [pharmacyId, pharmacyId],
      );
      final nowIso = DateTime.now().toIso8601String();
      for (final otherId in linkedPharmacyIds) {
        if (otherId == pharmacyId) continue;
        final a = pharmacyId < otherId ? pharmacyId : otherId;
        final b = pharmacyId < otherId ? otherId : pharmacyId;
        await txn.insert(
          'pharmacy_links',
          {'pharmacy_id_a': a, 'pharmacy_id_b': b, 'created_at': nowIso},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  /// معرّفات كل الصيدليات المرتبطة بهذه الصيدلية.
  Future<List<int>> getLinkedPharmacyIds(int pharmacyId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT CASE WHEN pharmacy_id_a = ? THEN pharmacy_id_b ELSE pharmacy_id_a END AS other_id
      FROM pharmacy_links
      WHERE pharmacy_id_a = ? OR pharmacy_id_b = ?
    ''', [pharmacyId, pharmacyId, pharmacyId]);
    return rows.map((r) => r['other_id'] as int).toList();
  }

  Future<bool> arePharmaciesLinked(int pharmacyIdA, int pharmacyIdB) async {
    final linked = await getLinkedPharmacyIds(pharmacyIdA);
    return linked.contains(pharmacyIdB);
  }

  /// ينقل كمية من صنف موجود في مخزن مصدر إلى مخزن هدف (لنفس الصيدلية أو
  /// لصيدلية مرتبطة). يتحقق من الرابط عند اختلاف الصيدلية، ويرفض نقل كمية
  /// أكبر من الموجودة. إن وُجد بالفعل صنف بنفس الباركود (أو بنفس الاسم إن
  /// كان بلا باركود) في المخزن الهدف يُزاد رصيده، وإلا يُنشأ صف جديد هناك.
  /// صف المصدر يُحذف تماماً إن أصبحت كميته صفراً بعد النقل (بدل تركه
  /// بكمية 0 كصف يتيم).
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

      final toWarehouseRows = await txn.query('warehouses', where: 'id = ?', whereArgs: [toWarehouseId], limit: 1);
      if (toWarehouseRows.isEmpty) throw StateError('المخزن الهدف غير موجود.');
      final destPharmacyId = toWarehouseRows.first['pharmacy_id'] as int;
      final sourcePharmacyId = source['pharmacy_id'] as int;

      if (destPharmacyId != sourcePharmacyId) {
        final linkRows = await txn.rawQuery('''
          SELECT 1 FROM pharmacy_links
          WHERE (pharmacy_id_a = ? AND pharmacy_id_b = ?)
             OR (pharmacy_id_a = ? AND pharmacy_id_b = ?)
          LIMIT 1
        ''', [sourcePharmacyId, destPharmacyId, destPharmacyId, sourcePharmacyId]);
        if (linkRows.isEmpty) {
          throw StateError('الصيدليتان غير مرتبطتين ببعض. لا يمكن نقل المخزون بينهما.');
        }
      }

      final barcode = (source['barcode'] as String?) ?? '';
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
          where: 'warehouse_id = ? AND trade_name = ? AND (barcode IS NULL OR barcode = ?)',
          whereArgs: [toWarehouseId, source['trade_name'], ''],
          limit: 1,
        );
      }

      if (destMatch.isNotEmpty) {
        await txn.rawUpdate(
          'UPDATE medicine SET quantity = quantity + ? WHERE id = ?',
          [quantity, destMatch.first['id']],
        );
      } else {
        await txn.insert('medicine', {
          'pharmacy_id': destPharmacyId,
          'warehouse_id': toWarehouseId,
          'trade_name': source['trade_name'],
          'scientific_name': source['scientific_name'],
          'category': source['category'],
          'quantity': quantity,
          'buy_price': source['buy_price'],
          'sell_price': source['sell_price'],
          'expiry_date': source['expiry_date'],
          'shelf_location': source['shelf_location'],
          'is_damaged': 0,
          'barcode': barcode.isNotEmpty ? barcode : null,
        });
      }

      final remaining = currentQty - quantity;
      if (remaining > 0) {
        await txn.update(
          'medicine',
          {'quantity': remaining},
          where: 'id = ?',
          whereArgs: [sourceMedicineId],
        );
      } else {
        await txn.delete('medicine', where: 'id = ?', whereArgs: [sourceMedicineId]);
      }

      await txn.insert('stock_transfers', {
        'from_warehouse_id': fromWarehouseId,
        'to_warehouse_id': toWarehouseId,
        'trade_name': source['trade_name'],
        'barcode': barcode.isNotEmpty ? barcode : null,
        'quantity': quantity,
        'transferred_at': DateTime.now().toIso8601String(),
        'notes': notes,
      });
    });
  }

  /// سجل عمليات النقل لجميع مخازن صيدلية معيّنة (وارد وصادر).
  Future<List<Map<String, dynamic>>> getStockTransfers(int pharmacyId) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT st.*, wf.name AS from_warehouse_name, wt.name AS to_warehouse_name
      FROM stock_transfers st
      JOIN warehouses wf ON wf.id = st.from_warehouse_id
      JOIN warehouses wt ON wt.id = st.to_warehouse_id
      WHERE wf.pharmacy_id = ? OR wt.pharmacy_id = ?
      ORDER BY st.transferred_at DESC
    ''', [pharmacyId, pharmacyId]);
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

    final row = <String, dynamic>{
      'id': serverData['id'] as int,
      'pharmacy_id': pharmacyId,
      'trade_name': serverData['trade_name'] as String,
      'scientific_name': (serverData['scientific_name'] as String?) ?? '',
      'category': (serverData['category'] as String?) ?? '',
      'quantity': (serverData['quantity'] as num?)?.toInt() ?? 0,
      'buy_price': _parseServerDecimal(serverData['buy_price']),
      'sell_price': _parseServerDecimal(serverData['sell_price']),
      'expiry_date': serverData['expiry_date'] as String?,
      'shelf_location': (serverData['shelf_location'] as String?) ?? '',
      'is_damaged': serverData['is_damaged'] == true ? 1 : 0,
      'barcode': serverData['barcode'] as String?,
      'last_synced_at': DateTime.now().toIso8601String(),
    };

    await db.insert('medicine', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update('medicine', row, where: 'id = ?', whereArgs: [row['id']]);
  }

  /// يستبدل كامل كاش المخزون المحلي بقائمة كاملة قادمة من السيرفر (بعد
  /// جلب medicine_api_service.fetchMedicines() لكل الصفحات)، داخل معاملة
  /// واحدة لضمان عدم رؤية الشاشات لحالة كاش منتصفة أثناء التحديث.
  Future<void> replaceMedicinesCache({
    required int pharmacyId,
    required List<Map<String, dynamic>> serverItems,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      for (final item in serverItems) {
        final row = <String, dynamic>{
          'id': item['id'] as int,
          'pharmacy_id': pharmacyId,
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
          'last_synced_at': now,
        };

        await txn.insert('medicine', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.update('medicine', row, where: 'id = ?', whereArgs: [row['id']]);
      }
    });
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
    final invoiceId = serverData['id'] as int;

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
          'medicine_id': rawItem['medicine'] as int,
          'quantity': (rawItem['quantity'] as num).toInt(),
          'unit_price': _parseServerDecimal(rawItem['unit_price']),
          'total_price': _parseServerDecimal(rawItem['total_price']),
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
    final result = await db.query(
      'medicine',
      where: warehouseId != null ? 'barcode = ? AND warehouse_id = ?' : 'barcode = ?',
      whereArgs: warehouseId != null ? [barcode, warehouseId] : [barcode],
    );
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

  Future<List<Map<String, dynamic>>> getLowStockMedicines(int pharmacyId, {int limit = 5}) async {
    final db = await database;
    return await db.query(
      'medicine',
      where: 'pharmacy_id = ? AND quantity <= ?',
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

    return await db.rawQuery('''
      SELECT * FROM medicine
      WHERE pharmacy_id = ?
        AND quantity > 0
        AND expiry_date IS NOT NULL AND expiry_date != ''
        AND date(expiry_date) < date(?)
      ORDER BY expiry_date ASC
    ''', [pharmacyId, limitDateOnly]);
  }

  //====================================================
  // Invoice CRUD
  //====================================================

  // جلب جميع فواتير الصيدلية
  Future<List<Map<String, dynamic>>> getInvoices(int pharmacyId) async {
    final db = await database;
    return await db.query(
      'invoice',
      where: 'pharmacy_id = ?',
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
    final clauses = <String>['pharmacy_id = ?'];
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
      'id': serverData['id'] as int,
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
          'id': item['id'] as int,
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
      'id': serverData['id'] as int,
      'pharmacy_id': pharmacyId,
      'medicine_id': serverData['medicine'] as int,
      'quantity_damaged': serverData['quantity_damaged'] as int,
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
          'id': item['id'] as int,
          'pharmacy_id': pharmacyId,
          'medicine_id': item['medicine'] as int,
          'quantity_damaged': item['quantity_damaged'] as int,
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

      // إعادة الكميات إلى المخزون
      for (final item in invoiceItems) {
        await txn.rawUpdate('''
          UPDATE medicine 
          SET quantity = quantity + ? 
          WHERE id = ?
        ''', [item['quantity'], item['medicine_id']]);
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
      WHERE pharmacy_id = ?
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
      AND is_refunded = 0
      AND DATE(created_at) = ?
  ''', [pharmacyId, today]);

  if (result.isEmpty || result.first['total'] == null) {
    return 0.0;
  }

  return (result.first['total'] as num).toDouble();
}

  // الحصول على آخر ID في جدول الفواتير
  Future<int> getLastInvoiceId() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT MAX(id) AS last_id 
      FROM invoice
    ''');

    if (result.first["last_id"] == null) {
      return 0;
    }
    return result.first["last_id"] as int;
  }

  // توليد رقم فاتورة جديد ومنسق
  Future<String> generateInvoiceNumber() async {
    final lastId = await getLastInvoiceId();
    return "INV-${(lastId + 1).toString().padLeft(6, '0')}";
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

      // 🟢 4. حفظ الأصناف المباعة وخصم كمياتها من المخزن
      for (final item in items) {
        item["invoice_id"] = invoiceId;

        await txn.insert("invoice_item", item);

        await txn.rawUpdate('''
          UPDATE medicine 
          SET quantity = quantity - ? 
          WHERE id = ?
        ''', [item["quantity"], item["medicine_id"]]);
      }
    });
  }

//====================================================
  // عمليات إضافية خاصة بالمخزن والإتلاف (تكامل الشاشات)
  //====================================================

  /// 1. تزويد شحنة لدواء موجود (زيادة الكمية + تحديث الاختياري لتاريخ الصلاحية)
  Future<void> supplyMedicine({
    required int medicineId,
    required int addedQuantity,
    String? newExpiryDate,
  }) async {
    final db = await database;
    if (newExpiryDate != null && newExpiryDate.isNotEmpty) {
      await db.rawUpdate('''
        UPDATE medicine 
        SET quantity = quantity + ?, expiry_date = ? 
        WHERE id = ?
      ''', [addedQuantity, newExpiryDate, medicineId]);
    } else {
      await db.rawUpdate('''
        UPDATE medicine 
        SET quantity = quantity + ? 
        WHERE id = ?
      ''', [addedQuantity, medicineId]);
    }
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
      // أ) خصم الكمية التالفة من المخزن الرئيسي
      await txn.rawUpdate('''
        UPDATE medicine 
        SET quantity = quantity - ? 
        WHERE id = ?
      ''', [quantityToDamage, medicineId]);

      // ب) إضافة السجل في جدول التوالف مع التاريخ الحالي
      await txn.insert("damaged_medicine", {
        "pharmacy_id": pharmacyId,
        "medicine_id": medicineId,
        "quantity_damaged": quantityToDamage,
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
      print("خطأ في تحميل قاموس الأدوية: $e");
    }
  }


  //====================================================
// 1️⃣ إدارة قائمة المذاخر وملخص الحسابات المالية
//====================================================

/// جلب جميع المذاخر مع حساب (إجمالي المشتريات) و(إجمالي الديون الحالية) لكل مذخر تلقائياً
Future<List<Map<String, dynamic>>> getSuppliersWithFinancials(int pharmacyId) async {
  final db = await database;
  return await db.rawQuery('''
    SELECT 
      s.id,
      s.pharmacy_id,
      s.name,
      s.phone,
      s.created_at,
      
      (SELECT COUNT(*) FROM purchase_invoice pi WHERE pi.supplier_id = s.id)
        AS invoice_count,

      -- إجمالي الشراء بعد طرح الاسترجاعات الجزئية
      COALESCE(
        (SELECT SUM(pi.total_amount - COALESCE((
           SELECT SUM(pir.amount_returned)
           FROM purchase_invoice_return pir
           WHERE pir.purchase_invoice_id = pi.id
         ), 0.0))
         FROM purchase_invoice pi
         WHERE pi.supplier_id = s.id),
        0.0
      ) AS total_purchases,

      -- الدفعات المرتبطة بالفاتورة تضاف إلى paid_amount.
      -- الدفعات القديمة غير المرتبطة تبقى محسوبة هنا للحفاظ على البيانات السابقة.
      MAX(0.0,
        COALESCE(
          (SELECT SUM(
            pi.total_amount -
            COALESCE((SELECT SUM(pir.amount_returned)
                      FROM purchase_invoice_return pir
                      WHERE pir.purchase_invoice_id = pi.id), 0.0) -
            pi.paid_amount
          )
           FROM purchase_invoice pi
           WHERE pi.supplier_id = s.id),
          0.0
        ) -
        COALESCE(
          (SELECT SUM(sp.amount_paid) 
           FROM supplier_payment sp
           WHERE sp.supplier_id = s.id
             AND sp.purchase_invoice_id IS NULL),
          0.0
        )
      ) AS remaining_debt

    FROM pharmacy_supplier s
    WHERE s.pharmacy_id = ?
    ORDER BY s.name ASC
  ''', [pharmacyId]);
}

//====================================================
// 2️⃣ تسجيل فواتير الشراء والتوريد (Purchase Invoices)
//====================================================

/// تسجيل فاتورة شراء جديدة من مذخر
Future<int> insertPurchaseInvoice(Map<String, dynamic> data) async {
  final db = await database;
  
  // حساب الدين المتبقي للفاتورة تلقائياً لتجنب الأخطاء البرمجية
  final double totalAmount = (data['total_amount'] as num?)?.toDouble() ?? 0.0;
  final double paidAmount = (data['paid_amount'] as num?)?.toDouble() ?? 0.0;
  
  if (paidAmount > totalAmount) {
    throw ArgumentError('المبلغ المدفوع لا يمكن أن يتجاوز مبلغ الفاتورة.');
  }

  final Map<String, dynamic> invoiceData = Map.from(data);
  invoiceData['remaining_debt'] = totalAmount - paidAmount;
  
  if (!invoiceData.containsKey('created_at') || invoiceData['created_at'] == null) {
    invoiceData['created_at'] = DateTime.now().toIso8601String();
  }

  return await db.insert(
    'purchase_invoice',
    invoiceData,
    conflictAlgorithm: ConflictAlgorithm.abort,
  );
}

/// جلب فواتير الشراء الخاصة بمذخر معين
Future<List<Map<String, dynamic>>> getPurchaseInvoicesBySupplier(int supplierId) async {
  final db = await database;
  return await db.rawQuery('''
    SELECT
      pi.*,
      COALESCE((
        SELECT SUM(pir.amount_returned)
        FROM purchase_invoice_return pir
        WHERE pir.purchase_invoice_id = pi.id
      ), 0.0) AS returned_amount,
      pi.total_amount - COALESCE((
        SELECT SUM(pir.amount_returned)
        FROM purchase_invoice_return pir
        WHERE pir.purchase_invoice_id = pi.id
      ), 0.0) AS net_amount,
      pi.total_amount - COALESCE((
        SELECT SUM(pir.amount_returned)
        FROM purchase_invoice_return pir
        WHERE pir.purchase_invoice_id = pi.id
      ), 0.0) - pi.paid_amount AS remaining_amount
    FROM purchase_invoice pi
    WHERE pi.supplier_id = ?
    ORDER BY pi.created_at DESC
  ''', [supplierId]);
}


//====================================================
// 3️⃣ تسديد الديون وكشف حساب المذخر (Payments & Ledger)
//====================================================

/// إضافة دفعة لفاتورة شراء محددة، مع تحديث المدفوع والمتبقي في نفس العملية.
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
    final invoices = await txn.rawQuery('''
      SELECT
        pi.total_amount,
        pi.paid_amount,
        COALESCE((
          SELECT SUM(pir.amount_returned)
          FROM purchase_invoice_return pir
          WHERE pir.purchase_invoice_id = pi.id
        ), 0.0) AS returned_amount
      FROM purchase_invoice pi
      WHERE pi.id = ? AND pi.supplier_id = ? AND pi.pharmacy_id = ?
    ''', [purchaseInvoiceId, supplierId, pharmacyId]);

    if (invoices.isEmpty) {
      throw StateError('فاتورة الشراء غير موجودة.');
    }

    final invoice = invoices.first;
    final total = (invoice['total_amount'] as num).toDouble();
    final paid = (invoice['paid_amount'] as num).toDouble();
    final returned = (invoice['returned_amount'] as num).toDouble();
    final outstanding = total - returned - paid;

    if (amount > outstanding) {
      throw ArgumentError('مبلغ الدفعة أكبر من المتبقي لهذه الفاتورة.');
    }

    final paymentId = await txn.insert('supplier_payment', {
      'pharmacy_id': pharmacyId,
      'supplier_id': supplierId,
      'purchase_invoice_id': purchaseInvoiceId,
      'amount_paid': amount,
      'notes': notes?.trim(),
      'paid_at': DateTime.now().toIso8601String(),
    });

    final newPaid = paid + amount;
    await txn.update(
      'purchase_invoice',
      {
        'paid_amount': newPaid,
        'remaining_debt': (total - returned - newPaid).clamp(0.0, double.infinity),
      },
      where: 'id = ?',
      whereArgs: [purchaseInvoiceId],
    );
    return paymentId;
  });
}

/// تسجيل استرجاع جزئي من فاتورة شراء بدون حذف أو إلغاء الفاتورة.
Future<int> addPurchaseInvoiceReturn({
  required int pharmacyId,
  required int supplierId,
  required int purchaseInvoiceId,
  required double amount,
  String? notes,
}) async {
  if (amount <= 0) {
    throw ArgumentError('يجب أن يكون مبلغ الاسترجاع أكبر من صفر.');
  }

  final db = await database;
  return db.transaction((txn) async {
    final invoices = await txn.rawQuery('''
      SELECT
        pi.total_amount,
        pi.paid_amount,
        COALESCE((
          SELECT SUM(pir.amount_returned)
          FROM purchase_invoice_return pir
          WHERE pir.purchase_invoice_id = pi.id
        ), 0.0) AS returned_amount
      FROM purchase_invoice pi
      WHERE pi.id = ? AND pi.supplier_id = ? AND pi.pharmacy_id = ?
    ''', [purchaseInvoiceId, supplierId, pharmacyId]);

    if (invoices.isEmpty) {
      throw StateError('فاتورة الشراء غير موجودة.');
    }

    final invoice = invoices.first;
    final total = (invoice['total_amount'] as num).toDouble();
    final paid = (invoice['paid_amount'] as num).toDouble();
    final alreadyReturned = (invoice['returned_amount'] as num).toDouble();

    if (alreadyReturned + amount > total) {
      throw ArgumentError('مجموع الاسترجاعات لا يمكن أن يتجاوز مبلغ الفاتورة الأصلي.');
    }

    final returnId = await txn.insert('purchase_invoice_return', {
      'pharmacy_id': pharmacyId,
      'supplier_id': supplierId,
      'purchase_invoice_id': purchaseInvoiceId,
      'amount_returned': amount,
      'notes': notes?.trim(),
      'returned_at': DateTime.now().toIso8601String(),
    });

    final newNet = total - alreadyReturned - amount;
    await txn.update(
      'purchase_invoice',
      {'remaining_debt': (newNet - paid).clamp(0.0, double.infinity)},
      where: 'id = ?',
      whereArgs: [purchaseInvoiceId],
    );
    return returnId;
  });
}

/// كشف حساب تفصيلي للمذخر (دمج الفواتير والدفعات ترتيباً زمنياً)
Future<List<Map<String, dynamic>>> getSupplierStatementOfAccount(int supplierId) async {
  final db = await database;
  return await db.rawQuery('''
    SELECT 
      id,
      'invoice' AS transaction_type,
      COALESCE(invoice_number, 'فاتورة بدون رقم') AS reference,
      total_amount - COALESCE((
        SELECT SUM(pir.amount_returned)
        FROM purchase_invoice_return pir
        WHERE pir.purchase_invoice_id = purchase_invoice.id
      ), 0.0) AS amount,
      paid_amount AS cash_paid,
      remaining_debt AS debt_added,
      created_at AS date_time,
      '' AS notes
    FROM purchase_invoice
    WHERE supplier_id = ?

    UNION ALL

    SELECT 
      id,
      'payment' AS transaction_type,
      'تسديد دفعة' AS reference,
      amount_paid AS amount,
      amount_paid AS cash_paid,
      -amount_paid AS debt_added,
      paid_at AS date_time,
      notes
    FROM supplier_payment
    WHERE supplier_id = ?

    UNION ALL

    SELECT
      id,
      'return' AS transaction_type,
      'استرجاع من فاتورة شراء' AS reference,
      amount_returned AS amount,
      0.0 AS cash_paid,
      -amount_returned AS debt_added,
      returned_at AS date_time,
      notes
    FROM purchase_invoice_return
    WHERE supplier_id = ?

    ORDER BY date_time DESC
  ''', [supplierId, supplierId, supplierId]);
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

/// حساب مجموع الديون الكلية المستحقة لجميع المذاخر
Future<double> getTotalSuppliersDebt(int pharmacyId) async {
  final db = await database;
  final result = await db.rawQuery('''
    SELECT MAX(0.0,
      COALESCE((
        SELECT SUM(
          pi.total_amount -
          COALESCE((SELECT SUM(pir.amount_returned)
                    FROM purchase_invoice_return pir
                    WHERE pir.purchase_invoice_id = pi.id), 0.0) -
          pi.paid_amount
        )
        FROM purchase_invoice pi
        WHERE pi.pharmacy_id = ?
      ), 0.0) -
      COALESCE((
        SELECT SUM(amount_paid)
        FROM supplier_payment
        WHERE pharmacy_id = ? AND purchase_invoice_id IS NULL
      ), 0.0)
    ) AS total_debt
  ''', [pharmacyId, pharmacyId]);

  if (result.isEmpty || result.first['total_debt'] == null) {
    return 0.0;
  }
  return (result.first['total_debt'] as num).toDouble();
}

Future<void> settlePurchaseInvoiceCredit(int purchaseInvoiceId) async {
  final db = await database;

  await db.rawUpdate('''
    UPDATE purchase_invoice
    SET
      paid_amount = total_amount - COALESCE((
        SELECT SUM(amount_returned)
        FROM purchase_invoice_return
        WHERE purchase_invoice_id = purchase_invoice.id
      ), 0.0),
      remaining_debt = 0
    WHERE id = ?
  ''', [purchaseInvoiceId]);
}

//====================================================
// نقطة 5 (المواصفات الكاملة): تحويل صيدلية أوفلاين إلى أونلاين برفع أولي
// شامل. راجع MigrationViewSet في الباك اند للترتيب الصارم وللتحقق من عدم
// التكرار. ⚠️ لا حذف لأي بيانات محلية بعد النجاح — النسخة المحلية تبقى
// كما هي وتُستخدم كقراءة/كاش لاحقاً مثل باقي الأجهزة، فلا حاجة لأي دالة
// "تفريغ" هنا إطلاقاً (خلافاً لتصميم سابق أُلغي عمداً).
//====================================================

/// عدد صفوف المخزون/الموردين محلياً — يُستخدم فقط لتقرير ما إذا كان يستحق
/// عرض اقتراح الرفع أصلاً (صيدلية أونلاين جديدة بلا بيانات سابقة لا تحتاج
/// أي رفع، فلا داعي لإزعاج صاحبها بالسؤال).
Future<bool> hasLocalDataWorthMigrating(int pharmacyId) async {
  final db = await database;
  final medCount = Sqflite.firstIntValue(await db.rawQuery(
    'SELECT COUNT(*) FROM medicine WHERE pharmacy_id = ?', [pharmacyId],
  )) ?? 0;
  final supCount = Sqflite.firstIntValue(await db.rawQuery(
    'SELECT COUNT(*) FROM pharmacy_supplier WHERE pharmacy_id = ?', [pharmacyId],
  )) ?? 0;
  return medCount > 0 || supCount > 0;
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

  // 2. المخزون الكامل
  final medicines = await db.query('medicine', where: 'pharmacy_id = ?', whereArgs: [pharmacyId]);
  final medicinesPayload = medicines
      .map((m) => {
            'local_id': m['id'],
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
          })
      .toList();

  // 3. فواتير الشراء الكاملة + دفعاتها + مرتجعاتها (متداخلة داخل كل فاتورة)
  final purchaseInvoices = await db.query('purchase_invoice', where: 'pharmacy_id = ?', whereArgs: [pharmacyId]);
  final purchaseInvoicesPayload = <Map<String, dynamic>>[];
  for (final pi in purchaseInvoices) {
    final piId = pi['id'];
    final payments = await db.query('supplier_payment', where: 'purchase_invoice_id = ?', whereArgs: [piId]);
    final returns = await db.query('purchase_invoice_return', where: 'purchase_invoice_id = ?', whereArgs: [piId]);
    purchaseInvoicesPayload.add({
      'local_supplier_id': pi['supplier_id'],
      'invoice_number': pi['invoice_number'],
      'total_amount': pi['total_amount'],
      'paid_amount': pi['paid_amount'],
      'created_at': pi['created_at'],
      'payments': payments
          .map((p) => {
                'amount_paid': p['amount_paid'],
                'notes': p['notes'],
                'paid_at': p['paid_at'],
              })
          .toList(),
      'returns': returns
          .map((r) => {
                'amount_returned': r['amount_returned'],
                'notes': r['notes'],
                'returned_at': r['returned_at'],
              })
          .toList(),
    });
  }

  // 4. فواتير البيع الكاملة (كل التاريخ) + عناصرها. اسم الكاشير يُجلب من
  // user_profile/users المحليين (نفس JOIN المستخدم في تقرير الشفتات
  // المحلي) لأنه لا حساب Django حقيقي وراء هذه الفواتير التاريخية —
  // ستُحفَظ في Invoice.cashier_name على السيرفر بدل Invoice.cashier.
  final invoices = await db.rawQuery('''
    SELECT i.*, COALESCE(u.full_name, u.username, '') AS cashier_name
    FROM invoice i
    LEFT JOIN user_profile up ON i.cashier_id = up.id
    LEFT JOIN users u ON up.user_id = u.id
    WHERE i.pharmacy_id = ?
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
              })
          .toList(),
    });
  }

  // 5. كل سجلات الإتلاف
  final damaged = await db.query('damaged_medicine', where: 'pharmacy_id = ?', whereArgs: [pharmacyId]);
  final damagedPayload = damaged
      .map((d) => {
            'local_medicine_id': d['medicine_id'],
            'quantity_damaged': d['quantity_damaged'],
            'reason': d['reason'],
            'notes': d['notes'],
            'damaged_at': d['damaged_at'],
          })
      .toList();

  // 6. كل المصاريف
  final expenses = await db.query('expense', where: 'pharmacy_id = ?', whereArgs: [pharmacyId]);
  final expensesPayload = expenses
      .map((e) => {
            'expense_type': e['expense_type'],
            'expense_date': e['expense_date'],
            'amount': e['amount'],
            'notes': e['notes'],
          })
      .toList();

  return {
    'suppliers': suppliersPayload,
    'medicines': medicinesPayload,
    'purchase_invoices': purchaseInvoicesPayload,
    'invoices': invoicesPayload,
    'damaged_medicines': damagedPayload,
    'expenses': expensesPayload,
  };
}

} // <-- هذا القوس يغلق كلاس DatabaseHelper بالكامل