// مولّد بيانات سنة كاملة لصيدلية واحدة أوفلاين — حتمي (بذرة ثابتة).
//
// كل عملية تمر عبر منطق التطبيق نفسه الذي تستدعيه الشاشات:
//   SuppliersRepository.createPurchaseList / addPurchaseInvoicePayment /
//   returnPurchaseItems / receiveSupplierRefund، InvoiceRepository.checkout /
//   refund، MedicineRepository.damageMedicine، ExpenseRepository.addExpense.
// فالكلفة المرجّحة، الدفعات (FEFO)، أرصدة المذاخر، لقطات unit_cost والتقارير
// كلها كما يحسبها التطبيق. الاستثناء الوحيد: هذه الدوال تختم بعض الحقول
// بوقت "الآن"، فتُعاد تواريخ الصفوف الجديدة فقط (id > ما قبل العملية) إلى
// التاريخ المحاكى مباشرة بعدها — تواريخ فقط، لا كميات ولا مبالغ.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:pharmacy_app/database/db_helper.dart';
import 'package:pharmacy_app/models/damage_reasons.dart';
import 'package:pharmacy_app/models/purchase_list.dart';
import 'package:pharmacy_app/repository/Invoice_repository.dart';
import 'package:pharmacy_app/repository/expense_repository.dart';
import 'package:pharmacy_app/repository/medicine_repository.dart';
import 'package:pharmacy_app/repository/suppliers_repository.dart';
import 'package:pharmacy_app/repository/warehouse_repository.dart';
import 'package:pharmacy_app/utils/invoice_discount.dart';

import 'load_test_common.dart';

class _Med {
  final String name;
  final String scientific;
  final String category;
  final String? barcode;
  final double baseBuy;
  double sell;
  final double daily; // متوسط القطع المباعة يومياً
  final int supplier;
  final double phase;
  int? id;
  int sellable = 0;

  _Med(this.name, this.scientific, this.category, this.barcode, this.baseBuy, this.sell, this.daily, this.supplier, this.phase);
}

class _Purchase {
  final int id;
  final int supplierId;
  final int day;
  _Purchase(this.id, this.supplierId, this.day);
}

class _Refund {
  final int invoiceId;
  final DateTime at;
  final int userId;
  _Refund(this.invoiceId, this.at, this.userId);
}

class LoadTestGenerator {
  LoadTestGenerator({required this.log});

  final void Function(String) log;
  final DatabaseHelper _db = DatabaseHelper.instance;
  late final Random _rnd = Random(LoadTestConfig.seed);
  final int _pid = LoadTestConfig.pharmacyId;

  late int _ownerId;
  late int _staffId;
  late int _warehouseId;
  late DateTime _start; // اليوم 0 = قبل سنة
  late DateTime _now;
  final List<_Med> _meds = [];
  final List<String> _supplierNames = const [
    'مذخر الرافدين', 'مذخر دجلة الدوائي', 'مذخر الفرات', 'مذخر بابل', 'مذخر النهرين',
    'مذخر الكندي', 'مذخر ابن سينا', 'مذخر الحكمة', 'مذخر الأمل الدوائي', 'مذخر السلام',
  ];
  final Map<int, int> _supplierIds = {}; // فهرس المذخر ← المعرّف بعد أول قائمة
  final Map<int, int> _supplierInvoiceSeq = {};
  final List<_Purchase> _purchases = [];
  final Map<int, List<int>> _paymentsDue = {}; // يوم ← فواتير شراء
  final List<_Refund> _refunds = [];
  late List<double> _cumulativeWeights;
  int _nextInvoiceNumber = 0;
  final Map<String, int> _stats = {};

  void _count(String key, [int by = 1]) => _stats[key] = (_stats[key] ?? 0) + by;

  // ---------------------------------------------------------------------------
  // أدوات
  // ---------------------------------------------------------------------------

  double _roundTo(double v, double step) => (v / step).round() * step;

  int _pick(List<int> weights) {
    final total = weights.fold<int>(0, (a, b) => a + b);
    var r = _rnd.nextInt(total);
    for (var i = 0; i < weights.length; i++) {
      r -= weights[i];
      if (r < 0) return i;
    }
    return weights.length - 1;
  }

  int _between(int min, int max) => min + _rnd.nextInt(max - min + 1);

  DateTime _dayStart(int day) => _start.add(Duration(days: day));

  DateTime _at(int day, int hour, int minute) {
    final d = _dayStart(day);
    return DateTime(d.year, d.month, d.day, hour, minute, _rnd.nextInt(60));
  }

  /// مثل [_at] لحركات غير البيع (توريد، دفعة): في اليوم الأخير لا تتجاوز "الآن".
  DateTime _atPast(int day, int hour, int minute) {
    final t = _at(day, hour, minute);
    return t.isAfter(_now) ? _now.subtract(const Duration(minutes: 1)) : t;
  }

  Future<int> _maxId(String table) async =>
      ((await (await _db.database).rawQuery('SELECT COALESCE(MAX(id), 0) AS m FROM $table')).first['m'] as num).toInt();

  /// يعيد ختم تاريخ الصفوف التي أنشأتها العملية للتو (id > [after]).
  Future<void> _backdate(String table, String column, int after, String value, {String? extraWhere}) async {
    await (await _db.database).rawUpdate(
      'UPDATE $table SET $column = ? WHERE id > ?${extraWhere == null ? '' : ' AND $extraWhere'}',
      [value, after],
    );
  }

  Future<void> _refreshSellable(Iterable<int> medicineIds) async {
    final ids = medicineIds.toSet().toList();
    if (ids.isEmpty) return;
    final rows = await (await _db.database).rawQuery(
      'SELECT id, ${DatabaseHelper.sellableQuantitySql} FROM medicine WHERE id IN (${List.filled(ids.length, '?').join(',')})',
      ids,
    );
    final byId = {for (final m in _meds) if (m.id != null) m.id!: m};
    for (final r in rows) {
      byId[r['id'] as int]?.sellable = (r['sellable_quantity'] as num).toInt();
    }
  }

  // ---------------------------------------------------------------------------
  // التحضير
  // ---------------------------------------------------------------------------

  Future<void> _prepare() async {
    final db = await _db.database;
    final pharmacy = await db.query('pharmacy_branch', where: 'id = ?', whereArgs: [_pid]);
    LoadTestConfig.require(pharmacy.isNotEmpty, 'الصيدلية $_pid غير موجودة في القاعدة.');
    log('Pharmacy: ${pharmacy.first['name']} (id $_pid)');

    Future<int> profile(String username, {required bool owner}) async {
      final rows = await db.rawQuery('''
        SELECT up.id, up.is_owner FROM users u JOIN user_profile up ON up.user_id = u.id
        WHERE u.username = ? AND up.pharmacy_id = ?
      ''', [username, _pid]);
      LoadTestConfig.require(rows.isNotEmpty, 'المستخدم "$username" غير مرتبط بالصيدلية $_pid محلياً.');
      LoadTestConfig.require((rows.first['is_owner'] == 1) == owner,
          'المستخدم "$username" ${owner ? 'ليس مالكاً' : 'مالك (المتوقع موظف)'}.');
      return rows.first['id'] as int;
    }

    _ownerId = await profile(LoadTestConfig.ownerUsername, owner: true);
    _staffId = await profile(LoadTestConfig.staffUsername, owner: false);
    _warehouseId = await WarehouseRepository.instance.getMainWarehouseId(pharmacyId: _pid, isOnlineMode: false);
    final existingSuppliers = {
      for (final r in await db.query('pharmacy_supplier', where: 'pharmacy_id = ?', whereArgs: [_pid])) r['name'] as String,
    };
    for (final name in _supplierNames) {
      LoadTestConfig.require(!existingSuppliers.contains(name), 'المذخر "$name" موجود مسبقاً — نظّف أولاً.');
    }

    final today = DateTime.now();
    _now = today;
    _start = DateTime(today.year, today.month, today.day).subtract(const Duration(days: LoadTestConfig.days));
    final first = await _db.generateInvoiceNumber();
    _nextInvoiceNumber = int.parse(first.substring(4));
    log('Users: owner profile $_ownerId, staff profile $_staffId; main warehouse $_warehouseId');
    log('Period: ${dayKeyOf(_start)} → ${dayKeyOf(today)}; first invoice $first');
  }

  /// 1000 صنف حتمياً من نفس قائمة التطبيق (assets/data/iraqi_drugs.json)،
  /// بلا الأسماء الموجودة مسبقاً في الصيدلية.
  Future<void> _buildCatalog() async {
    final db = await _db.database;
    final existing = {
      for (final r in await db.query('medicine', columns: ['trade_name'], where: 'pharmacy_id = ?', whereArgs: [_pid]))
        (r['trade_name'] as String).trim().toLowerCase(),
    };
    final source = jsonDecode(File('assets/data/iraqi_drugs.json').readAsStringSync()) as List;
    final seen = <String>{};
    final candidates = <Map<String, dynamic>>[];
    for (final raw in source.cast<Map<String, dynamic>>()) {
      final key = (raw['trade_name'] as String).trim().toLowerCase();
      if (existing.contains(key) || !seen.add(key)) continue;
      candidates.add(raw);
    }
    candidates.shuffle(_rnd);
    final chosen = candidates.take(LoadTestConfig.medicines).toList();

    // نطاقات سعر الشراء (د.ع) حسب الشكل الدوائي.
    const ranges = {
      'tablet': [1500, 12000], 'injection': [2000, 25000], 'syrup': [2000, 9000],
      'cream_ointment_gel': [1500, 8000], 'drops_eye_ear': [1500, 7000], 'drops_oral': [1500, 6000],
      'suppository': [1500, 5000], 'powder_sachet': [1000, 6000], 'oral_care': [1500, 6000],
      'drops_nasal': [1500, 6000], 'inhaler_nebulizer': [6000, 30000], 'topical_solution': [1000, 5000],
    };
    // الطلب: توزيع "قلة رائجة وكثرة بطيئة" (Zipf)، مقياسه = ما يبيعه اليوم المتوسط.
    final ranks = List<int>.generate(chosen.length, (i) => i)..shuffle(_rnd);
    final weights = [for (final r in ranks) 1 / pow(r + 4, 0.9)];
    final totalWeight = weights.fold<double>(0, (a, b) => a + b);
    const avgUnitsPerInvoice = 2.3 * 1.35;
    final dailyUnits = LoadTestConfig.invoicesPerDay * avgUnitsPerInvoice;

    for (var i = 0; i < chosen.length; i++) {
      final m = chosen[i];
      final range = ranges[m['category']] ?? const [1500, 8000];
      final buy = _roundTo(range[0] + _rnd.nextDouble() * (range[1] - range[0]), 250);
      final sell = _roundTo(buy * (1.25 + _rnd.nextDouble() * 0.35), 250);
      final barcode = _rnd.nextDouble() < 0.7 ? _ean13('200${_rnd.nextInt(1000000000).toString().padLeft(9, '0')}') : null;
      _meds.add(_Med(
        (m['trade_name'] as String).trim(),
        (m['scientific_name'] ?? '').toString(),
        (m['category'] ?? '').toString(),
        barcode,
        buy,
        sell,
        dailyUnits * weights[i] / totalWeight,
        i % _supplierNames.length,
        _rnd.nextDouble() * 2 * pi,
      ));
    }
    var acc = 0.0;
    _cumulativeWeights = [for (final m in _meds) acc += m.daily];
    log('Catalog: ${_meds.length} medicines (barcodes: ${_meds.where((m) => m.barcode != null).length})');
  }

  /// EAN-13 صالح ببادئة 200 (نطاق الاستخدام الداخلي — ليست باركودات منتجات حقيقية).
  String _ean13(String twelve) {
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      sum += int.parse(twelve[i]) * (i.isEven ? 1 : 3);
    }
    return '$twelve${(10 - sum % 10) % 10}';
  }

  // ---------------------------------------------------------------------------
  // المشتريات
  // ---------------------------------------------------------------------------

  double _buyPriceOn(_Med m, int day) {
    final drift = 0.10 * sin(m.phase + day / 55) + (_rnd.nextDouble() - 0.5) * 0.06;
    return max(250, _roundTo(m.baseBuy * (1 + drift), 50));
  }

  String _expiryFor(int day) {
    final d = _dayStart(day);
    final offset = _rnd.nextDouble() < 0.07 ? _between(45, 150) : _between(300, 1095);
    return dayKeyOf(d.add(Duration(days: offset)));
  }

  Future<void> _purchaseList(int day, int supplier, List<MapEntry<_Med, int>> lines) async {
    if (lines.isEmpty) return;
    final items = <Map<String, dynamic>>[];
    for (final line in lines) {
      final m = line.key;
      final roll = _rnd.nextDouble();
      // صنف مجاني بالكامل (لصنف موجود فقط) ~1%، بونص ~15%.
      final isFree = m.id != null && roll < 0.01;
      final bonus = isFree ? _between(2, 6) : (roll < 0.16 ? max(1, line.value ~/ 10) : 0);
      if (_rnd.nextDouble() < 0.04 && m.id != null) {
        m.sell = _roundTo(m.sell * (1.05 + _rnd.nextDouble() * 0.05), 250); // سعر بيع جديد يحل محل القديم
        _count('sell_price_changes');
      }
      items.add({
        if (m.id != null) 'medicine_id': m.id,
        'trade_name': m.name,
        'scientific_name': m.scientific,
        'category': m.category,
        'barcode': m.barcode,
        'quantity': isFree ? 0 : line.value,
        'bonus_quantity': bonus,
        'is_free': isFree,
        'buy_price': isFree ? 0 : _buyPriceOn(m, day),
        'sell_price': m.sell,
        'expiry_date': _expiryFor(day),
      });
      if (bonus > 0) _count(isFree ? 'free_lines' : 'bonus_lines');
    }

    final supplierId = _supplierIds[supplier];
    final total = PurchaseListTotals.of(items).invoiceTotal;
    var credit = 0.0;
    if (supplierId != null) {
      final figures = await _db.getSuppliersWithFinancials(_pid);
      final row = figures.firstWhere((f) => f['id'] == supplierId);
      credit = min((row['available_credit'] as num).toDouble(), total);
    }
    final payable = total - credit;
    final mode = _pick(const [40, 30, 30]); // مدفوعة / جزئية / آجلة
    final paid = switch (mode) {
      0 => payable,
      1 => _roundTo(payable * (0.3 + _rnd.nextDouble() * 0.4), 1000).clamp(0, payable).toDouble(),
      _ => 0.0,
    };
    final seq = (_supplierInvoiceSeq[supplier] = (_supplierInvoiceSeq[supplier] ?? 1000) + _between(1, 7));
    final when = _atPast(day, _between(9, 11), _between(0, 59));

    final before = {for (final t in ['purchase_invoice', 'medicine_batch', 'supplier_payment', 'supplier_credit_application', 'pharmacy_supplier', 'medicine']) t: await _maxId(t)};
    await SuppliersRepository.instance.createPurchaseList(
      pharmacyId: _pid,
      isOnlineMode: false,
      warehouseId: _warehouseId,
      invoiceNumber: '${String.fromCharCode(65 + supplier)}-$seq',
      invoiceDate: dayKeyOf(when),
      items: items,
      supplierId: supplierId,
      supplierName: supplierId == null ? _supplierNames[supplier] : null,
      paidAmount: DatabaseHelper.roundMoney(paid),
    );
    final iso = when.toIso8601String();
    await _backdate('purchase_invoice', 'created_at', before['purchase_invoice']!, iso);
    await _backdate('medicine_batch', 'created_at', before['medicine_batch']!, iso);
    await _backdate('supplier_payment', 'paid_at', before['supplier_payment']!, iso);
    await _backdate('supplier_credit_application', 'applied_at', before['supplier_credit_application']!, iso);
    await _backdate('pharmacy_supplier', 'created_at', before['pharmacy_supplier']!, iso);

    final db = await _db.database;
    final invoice = (await db.query('purchase_invoice', where: 'id > ?', whereArgs: [before['purchase_invoice']], orderBy: 'id DESC', limit: 1)).single;
    final invoiceId = invoice['id'] as int;
    _supplierIds[supplier] ??= invoice['supplier_id'] as int;
    if (before['medicine']! < await _maxId('medicine')) {
      final created = await db.query('medicine', columns: ['id', 'trade_name'], where: 'id > ? AND pharmacy_id = ?', whereArgs: [before['medicine'], _pid]);
      final byName = {for (final m in _meds) m.name.toLowerCase(): m};
      for (final r in created) {
        byName[(r['trade_name'] as String).toLowerCase()]?.id = r['id'] as int;
      }
    }
    await _refreshSellable(lines.map((l) => l.key.id!));
    _purchases.add(_Purchase(invoiceId, _supplierIds[supplier]!, day));
    if (mode != 0) {
      final dueDay = day + _between(15, 60);
      if (dueDay <= LoadTestConfig.days) (_paymentsDue[dueDay] ??= []).add(invoiceId);
    }
    _count('purchase_lists');
    _count('purchase_mode_${['paid', 'partial', 'credit'][mode]}');
  }

  /// الموجة الأولى (أول أسبوع): كل مذخر يورّد كل أصنافه بكمية ~45 يوماً.
  Future<void> _initialStock(int day) async {
    for (var s = 0; s < _supplierNames.length; s++) {
      if (s % 7 != day) continue;
      final lines = [
        for (final m in _meds.where((m) => m.supplier == s))
          MapEntry(m, max(10, _roundTo(m.daily * _between(35, 55), 5).toInt())),
      ];
      // قائمة كبيرة تُقسم على فاتورتين كما يحدث فعلاً (حتى ~60 سطراً للفاتورة).
      for (var i = 0; i < lines.length; i += 60) {
        await _purchaseList(day, s, lines.sublist(i, min(i + 60, lines.length)));
      }
    }
  }

  /// إعادة التموين: كل مذخر يزور الصيدلية يوماً ثابتاً في الأسبوع ويورّد ما نقص.
  Future<void> _restock(int day) async {
    for (var s = 0; s < _supplierNames.length; s++) {
      if (_supplierIds[s] == null || (day + s) % 7 != 0) continue;
      final low = <MapEntry<_Med, int>>[];
      for (final m in _meds.where((m) => m.supplier == s && m.id != null)) {
        final reorderPoint = max(3, (m.daily * 10).ceil());
        if (m.sellable <= reorderPoint) {
          low.add(MapEntry(m, max(10, _roundTo(m.daily * _between(35, 60), 5).toInt())));
        }
      }
      if (low.length >= 4 || low.any((e) => e.key.sellable == 0)) {
        for (var i = 0; i < low.length; i += 60) {
          await _purchaseList(day, s, low.sublist(i, min(i + 60, low.length)));
        }
      }
    }
  }

  Future<void> _laterPayments(int day) async {
    for (final invoiceId in _paymentsDue.remove(day) ?? const <int>[]) {
      final purchase = _purchases.firstWhere((p) => p.id == invoiceId);
      final rows = await _db.getPurchaseInvoicesBySupplier(purchase.supplierId);
      final remaining = ((rows.firstWhere((r) => r['id'] == invoiceId)['remaining_amount']) as num).toDouble();
      if (remaining <= 0) continue;
      final amount = _rnd.nextDouble() < 0.7 ? remaining : max(1000.0, _roundTo(remaining * 0.5, 1000)).clamp(0, remaining).toDouble();
      final before = await _maxId('supplier_payment');
      await SuppliersRepository.instance.addPurchaseInvoicePayment(
        pharmacyId: _pid,
        isOnlineMode: false,
        supplierId: purchase.supplierId,
        purchaseInvoiceId: invoiceId,
        amount: DatabaseHelper.roundMoney(amount),
        notes: 'دفعة لاحقة',
      );
      await _backdate('supplier_payment', 'paid_at', before, _atPast(day, _between(10, 15), _between(0, 59)).toIso8601String());
      _count('later_payments');
      // ما تبقى بعد دفعة جزئية يُدفع لاحقاً.
      if (amount < remaining) {
        final next = day + _between(20, 45);
        if (next <= LoadTestConfig.days) (_paymentsDue[next] ??= []).add(invoiceId);
      }
    }
  }

  Future<void> _supplierReturn(int day) async {
    final candidates = _purchases.where((p) => day - p.day >= 5 && day - p.day <= 45).toList();
    if (candidates.isEmpty) return;
    final db = await _db.database;
    for (var attempt = 0; attempt < 10; attempt++) {
      final purchase = candidates[_rnd.nextInt(candidates.length)];
      final items = await db.query('purchase_invoice_item', where: 'purchase_invoice_id = ? AND quantity > 0', whereArgs: [purchase.id]);
      final byId = {for (final m in _meds) if (m.id != null) m.id!: m};
      final eligible = items.where((it) => (byId[it['medicine_id']]?.sellable ?? 0) > 8).toList()..shuffle(_rnd);
      if (eligible.isEmpty) continue;
      final lines = [
        for (final it in eligible.take(_between(1, 2)))
          {'purchase_invoice_item_id': it['id'], 'quantity': _between(1, min(4, (it['quantity'] as int)))},
      ];
      await SuppliersRepository.instance.returnPurchaseItems(
        pharmacyId: _pid,
        isOnlineMode: false,
        purchaseInvoiceId: purchase.id,
        lines: lines,
        notes: 'استرجاع (تجريبي)',
        returnDate: _dayStart(day),
      );
      await _refreshSellable(eligible.take(lines.length).map((it) => it['medicine_id'] as int));
      _count('supplier_returns');
      // أحياناً يعيد المذخر رصيدنا نقداً.
      final figures = await _db.getSuppliersWithFinancials(_pid);
      final credit = ((figures.firstWhere((f) => f['id'] == purchase.supplierId))['available_credit'] as num).toDouble();
      if (credit > 0 && _rnd.nextDouble() < 0.5) {
        await SuppliersRepository.instance.receiveSupplierRefund(
          pharmacyId: _pid,
          isOnlineMode: false,
          supplierId: purchase.supplierId,
          amount: credit,
          notes: 'استلام رصيد المرتجع',
          receivedDate: _dayStart(day),
        );
        _count('supplier_refunds_received');
      }
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // المبيعات والإرجاع
  // ---------------------------------------------------------------------------

  int _invoicesFor(int day) {
    final d = _dayStart(day);
    final weekday = switch (d.weekday) {
      DateTime.friday => 0.5,
      DateTime.thursday => 1.25,
      DateTime.saturday || DateTime.sunday => 1.1,
      _ => 1.0,
    };
    final season = 1 + 0.15 * cos((d.month - 1) / 12 * 2 * pi); // الشتاء أكثر (نزلات البرد)
    final ramp = day < 3 ? 0.0 : 1.0; // أول المخزون يصل في الأيام الأولى
    return (LoadTestConfig.invoicesPerDay * weekday * season * (0.8 + _rnd.nextDouble() * 0.4) * ramp).round();
  }

  int _saleHour(DateTime day) {
    // ذروة الضحى والمساء، قليل بعد العاشرة ليلاً، والجمعة تبدأ بعد الظهر.
    const hours = [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23];
    final weights = day.weekday == DateTime.friday
        ? const [0, 0, 0, 0, 0, 2, 4, 6, 8, 10, 12, 12, 10, 8, 3, 1]
        : const [3, 6, 9, 10, 8, 6, 5, 5, 6, 8, 10, 11, 9, 6, 2, 1];
    return hours[_pick(weights)];
  }

  _Med? _sampleMedicine(Set<int> exclude) {
    final total = _cumulativeWeights.last;
    for (var attempt = 0; attempt < 25; attempt++) {
      final r = _rnd.nextDouble() * total;
      var lo = 0, hi = _cumulativeWeights.length - 1;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (_cumulativeWeights[mid] < r) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      final m = _meds[lo];
      if (m.id != null && m.sellable > 0 && !exclude.contains(m.id)) return m;
    }
    return null;
  }

  Future<void> _sale(DateTime when) async {
    final lineCount = 1 + _pick(const [35, 28, 18, 10, 6, 3]);
    final used = <int>{};
    final items = <Map<String, dynamic>>[];
    for (var i = 0; i < lineCount; i++) {
      final m = _sampleMedicine(used);
      if (m == null) break;
      final qty = min(m.sellable, 1 + _pick(const [75, 18, 5, 1, 1]));
      used.add(m.id!);
      items.add({
        'trade_name': m.name,
        'medicine_id': m.id,
        'quantity': qty,
        'unit_price': m.sell,
        'total_price': DatabaseHelper.roundMoney(qty * m.sell),
      });
    }
    if (items.isEmpty) {
      _count('sales_skipped_no_stock');
      return;
    }
    final subtotal = DatabaseHelper.roundMoney(items.fold<double>(0, (s, it) => s + (it['total_price'] as double)));
    var discount = 0.0;
    if (_rnd.nextDouble() < 0.12) {
      final percent = _rnd.nextBool();
      final input = percent ? '${const [5, 10, 15][_rnd.nextInt(3)]}' : '${max(250, _roundTo(subtotal * (0.03 + _rnd.nextDouble() * 0.07), 250).toInt())}';
      discount = InvoiceDiscount.compute(subtotal: subtotal, type: percent ? InvoiceDiscount.percent : InvoiceDiscount.amount, input: input);
      _count('discounted_sales');
    }
    final cashier = _rnd.nextDouble() < 0.45 ? _ownerId : _staffId;
    final number = 'INV-${(_nextInvoiceNumber++).toString().padLeft(6, '0')}';
    await InvoiceRepository.instance.checkout(
      pharmacyId: _pid,
      isOnlineMode: false,
      invoice: {
        'pharmacy_id': _pid,
        'invoice_number': number,
        'cashier_id': cashier,
        'total_amount': subtotal,
        'discount': discount,
        'final_amount': DatabaseHelper.roundMoney(subtotal - discount),
        'created_at': when.toIso8601String(),
        'is_refunded': 0,
      },
      items: items,
    );
    for (final it in items) {
      final m = _meds.firstWhere((m) => m.id == it['medicine_id']);
      m.sellable -= it['quantity'] as int;
    }
    _count('sales');

    if (_rnd.nextDouble() < 0.04) {
      final roll = _rnd.nextDouble();
      final delay = roll < 0.6
          ? Duration(minutes: _between(5, 180))
          : roll < 0.9
              ? Duration(hours: _between(3, 24))
              : Duration(hours: _between(24, 72));
      final at = when.add(delay);
      if (at.isBefore(_now)) {
        final invoiceId = await _maxId('invoice');
        _refunds.add(_Refund(invoiceId, at, _rnd.nextBool() ? _ownerId : _staffId));
      }
    }
  }

  Future<void> _dueRefunds(DateTime until) async {
    _refunds.sort((a, b) => a.at.compareTo(b.at));
    while (_refunds.isNotEmpty && _refunds.first.at.isBefore(until)) {
      final r = _refunds.removeAt(0);
      final batchesBefore = await _maxId('medicine_batch');
      await InvoiceRepository.instance.refund(pharmacyId: _pid, isOnlineMode: false, invoiceId: r.invoiceId, userId: r.userId);
      await (await _db.database).update('invoice', {'refunded_at': r.at.toIso8601String()}, where: 'id = ?', whereArgs: [r.invoiceId]);
      // صنف نفدت دفعاته: الإرجاع ينشئ دفعة جديدة مختومة بـ"الآن".
      await _backdate('medicine_batch', 'created_at', batchesBefore, r.at.toIso8601String());
      final items = await (await _db.database).query('invoice_item', columns: ['medicine_id'], where: 'invoice_id = ?', whereArgs: [r.invoiceId]);
      await _refreshSellable(items.map((i) => i['medicine_id'] as int));
      _count(r.userId == _ownerId ? 'refunds_by_owner' : 'refunds_by_staff');
    }
  }

  // ---------------------------------------------------------------------------
  // التالف والمصروفات
  // ---------------------------------------------------------------------------

  Future<void> _damage(int day) async {
    final inStock = _meds.where((m) => m.id != null && m.sellable > 0).toList();
    if (inStock.isEmpty) return;
    final m = inStock[_rnd.nextInt(inStock.length)];
    final reasons = damageReasons.keys.toList(); // broken, spoiled, withdrawn, expired, correction, other
    const weights = {'broken': 30, 'spoiled': 15, 'withdrawn': 5, 'expired': 25, 'correction': 10, 'other': 15};
    final reason = reasons[_pick([for (final r in reasons) weights[r] ?? 5])];
    final qty = min(m.sellable, reason == 'correction' ? _between(1, 5) : _between(1, 3));
    final before = await _maxId('damaged_medicine');
    await MedicineRepository.instance.damageMedicine(
      pharmacyId: _pid,
      isOnlineMode: false,
      medicineId: m.id!,
      quantityToDamage: qty,
      reason: reason,
      notes: const ['', '', 'وُجد أثناء الجرد', 'تلف في التخزين', 'ملاحظة الصيدلي'][_rnd.nextInt(5)],
    );
    await _backdate('damaged_medicine', 'damaged_at', before, dayKeyOf(_dayStart(day)));
    await _refreshSellable([m.id!]);
    _count('damaged');
  }

  Future<void> _expense(String type, DateTime date, double amount, String notes) async {
    await ExpenseRepository.instance.addExpense(
      pharmacyId: _pid,
      isOnlineMode: false,
      data: {'expense_type': type, 'expense_date': dayKeyOf(date), 'amount': amount, 'notes': notes},
    );
    _count('expenses');
  }

  Future<void> _expenses(int day) async {
    final d = _dayStart(day);
    final summer = d.month >= 6 && d.month <= 9;
    final winter = d.month == 12 || d.month <= 2;
    if (d.day == 1) await _expense('إيجار', d, 1500000, 'إيجار الصيدلية الشهري');
    if (d.day == 3) {
      await _expense('رواتب', d, 900000, 'راتب ${LoadTestConfig.staffUsername}');
      await _expense('رواتب', d, 300000, 'راتب عامل التنظيف');
    }
    if (d.day == 5) {
      await _expense('كهرباء', d, _roundTo((summer ? 180000 : winter ? 140000 : 90000) * (0.85 + _rnd.nextDouble() * 0.3), 1000), 'الكهرباء الوطنية');
      await _expense('كهرباء', d, _roundTo((summer ? 380000 : winter ? 260000 : 180000) * (0.9 + _rnd.nextDouble() * 0.2), 1000), 'اشتراك المولدة الأهلية');
    }
    if (_rnd.nextDouble() < 0.33) {
      const options = [
        ['ماء', 15000, 40000, 'ماء شرب وتعبئة'],
        ['نقل', 5000, 25000, 'أجور نقل بضاعة'],
        ['صيانة', 25000, 150000, 'صيانة'],
        ['مستلزمات', 10000, 60000, 'أكياس وقرطاسية'],
        ['أخرى', 5000, 50000, 'مصاريف متفرقة'],
      ];
      final o = options[_pick(const [20, 25, 10, 30, 15])];
      await _expense(o[0] as String, d, _roundTo(_between(o[1] as int, o[2] as int).toDouble(), 500), o[3] as String);
    }
  }

  // ---------------------------------------------------------------------------
  // التشغيل
  // ---------------------------------------------------------------------------

  Future<Map<String, int>> run() async {
    await _prepare();
    await _buildCatalog();
    final watch = Stopwatch()..start();
    final returnDays = {for (var i = 1; i <= 10; i++) 25 + i * 33};

    // اليوم 0 = قبل سنة، والأخير = اليوم (مبيعاته حتى الساعة الحالية فقط).
    for (var day = 0; day <= LoadTestConfig.days; day++) {
      final date = _dayStart(day);
      if (day < 7) await _initialStock(day);
      await _restock(day);
      await _laterPayments(day);
      if (returnDays.contains(day)) await _supplierReturn(day);
      await _expenses(day);

      final count = _invoicesFor(day);
      final times = [
        for (var i = 0; i < count; i++) _at(day, _saleHour(date), _rnd.nextInt(60)),
      ]..sort();
      final damageAt = _rnd.nextDouble() < 0.41 ? _between(0, max(0, count - 1)) : -1;
      for (var i = 0; i < times.length; i++) {
        if (times[i].isAfter(_now)) break;
        await _dueRefunds(times[i]);
        await _sale(times[i]);
        if (i == damageAt) await _damage(day);
      }
      if (count == 0 && damageAt == 0) await _damage(day);
      await _dueRefunds(DateTime(date.year, date.month, date.day).add(const Duration(days: 1)));

      if (day % 30 == 0 || day == LoadTestConfig.days) {
        log('day $day/${LoadTestConfig.days} (${dayKeyOf(date)}): sales ${_stats['sales'] ?? 0}, '
            'purchase lists ${_stats['purchase_lists'] ?? 0}, elapsed ${watch.elapsed.inSeconds}s');
      }
    }
    await _dueRefunds(_now);
    log('Generation stats: ${const JsonEncoder.withIndent('  ').convert(_stats)}');
    return _stats;
  }
}
