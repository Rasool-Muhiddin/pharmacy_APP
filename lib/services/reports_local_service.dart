import '../database/db_helper.dart';
import '../models/report_period.dart';

/// تقارير الوضع الأوفلاين على SQLite المحلي — قسم لكل دالة، بنفس أسماء الحقول
/// وصيغ pharmacy_data/reports.py حرفياً (الخادم في الأونلاين)، ويتحقق من
/// تطابقهما test/fixtures/reports_parity.json. كل التجميع في SQL.
///
/// قواعد مشتركة (راجع reports.py للتفصيل):
///   - الفترة أيام كاملة شاملة: created_at >= أول يوم AND < اليوم التالي لآخر يوم.
///   - صافي السطر = إجمالي السطر − (خصم الفاتورة × إجمالي السطر ÷ إجمالي الفاتورة).
///   - الربح الإجمالي من الأسطر ذات unit_cost فقط.
///   - قيمة الدفعة = الكمية × (كلفة الدفعة ثم avg_cost ثم buy_price).
///   - صافي الربح يطرح الخسائر المسجّلة فقط (مصاريف + إتلاف بلا 'correction').
class ReportsLocalService {
  ReportsLocalService({DatabaseHelper? db, DateTime Function()? clock})
      : _helper = db ?? DatabaseHelper.instance,
        _clock = clock ?? DateTime.now;

  final DatabaseHelper _helper;
  final DateTime Function() _clock;

  static const int expiryAlertDays = 30;
  static const int topItemsLimit = 20;
  static const int topDebtorsLimit = 10;
  static const int defaultPageSize = 50;
  static const int maxPageSize = 200;
  static const String unknownSeller = 'بائع غير محدد';

  static const String _lineDiscount =
      '(CASE WHEN i.total_amount > 0 THEN i.discount * ii.total_price * 1.0 / i.total_amount ELSE 0 END)';
  static const String _lineNet = '(ii.total_price - $_lineDiscount)';
  static const String _lineCost = '(ii.unit_cost * ii.quantity)';
  static const String _batchValue = '(b.quantity * COALESCE(b.purchase_price, m.avg_cost, m.buy_price, 0))';
  static const String _medicineCost = 'COALESCE(m.avg_cost, m.buy_price, 0)';
  static const String _sellerName =
      "COALESCE(NULLIF(TRIM(u.full_name), ''), NULLIF(TRIM(u.username), ''), NULLIF(TRIM(i.cashier_name_synced), ''), '$unknownSeller')";

  double _r(Object? v) => DatabaseHelper.roundMoney((v as num?) ?? 0);
  int _i(Object? v) => (v as num?)?.toInt() ?? 0;

  String get _today => dayKey(_clock());

  /// [أول يوم, اليوم التالي لآخر يوم) كنصوص قابلة للمقارنة مع created_at.
  List<String> _range(DateTime start, DateTime end) => [dayKey(start), dayKey(addDays(end, 1))];

  String _origin(String alias) => _helper.originFilter(alias);

  Future<List<Map<String, Object?>>> _q(String sql, [List<Object?> args = const []]) async {
    final db = await _helper.database;
    return db.rawQuery(sql, args);
  }

  /// أسطر الفواتير غير المسترجعة في الفترة (ii, i, m).
  String _itemsFrom() => '''
    FROM invoice_item ii
    JOIN invoice i ON i.id = ii.invoice_id
    LEFT JOIN medicine m ON m.id = ii.medicine_id
    WHERE i.pharmacy_id = ? AND ${_origin('i.')} AND i.is_refunded = 0
      AND i.created_at >= ? AND i.created_at < ?''';

  // ---------------------------------------------------------------------------
  // المؤشرات
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> periodFigures(int pharmacyId, DateTime start, DateTime end) async {
    final range = _range(start, end);
    final sales = (await _q('''
      SELECT COALESCE(SUM(total_amount), 0) AS gross_sales, COALESCE(SUM(discount), 0) AS discounts,
             COALESCE(SUM(final_amount), 0) AS net_sales, COUNT(id) AS invoices_count,
             COALESCE(SUM(CASE WHEN discount > 0 THEN 1 ELSE 0 END), 0) AS discounted
      FROM invoice i
      WHERE i.pharmacy_id = ? AND ${_origin('i.')} AND i.is_refunded = 0 AND i.created_at >= ? AND i.created_at < ?
    ''', [pharmacyId, ...range])).first;
    final refunded = (await _q('''
      SELECT COUNT(id) AS c, COALESCE(SUM(final_amount), 0) AS v FROM invoice i
      WHERE i.pharmacy_id = ? AND ${_origin('i.')} AND i.is_refunded = 1 AND i.created_at >= ? AND i.created_at < ?
    ''', [pharmacyId, ...range])).first;
    final lines = (await _q('''
      SELECT COALESCE(SUM(CASE WHEN ii.unit_cost IS NOT NULL THEN $_lineNet END), 0) AS costed_net,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NULL THEN $_lineNet END), 0) AS uncosted_net,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NOT NULL THEN $_lineCost END), 0) AS cogs,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NULL THEN 1 ELSE 0 END), 0) AS missing
      ${_itemsFrom()}
    ''', [pharmacyId, ...range])).first;
    final expenses = _r((await _q('''
      SELECT COALESCE(SUM(amount), 0) AS t FROM expense e
      WHERE e.pharmacy_id = ? AND ${_origin('e.')} AND e.expense_date >= ? AND e.expense_date < ?
    ''', [pharmacyId, ...range])).first['t']);
    final damage = _r((await _q('''
      SELECT COALESCE(SUM(${DatabaseHelper.damageCostSql}), 0) AS t
      FROM damaged_medicine dm LEFT JOIN medicine m ON m.id = dm.medicine_id
      WHERE dm.pharmacy_id = ? AND ${_origin('dm.')} AND COALESCE(dm.reason, '') != 'correction'
        AND dm.damaged_at >= ? AND dm.damaged_at < ?
    ''', [pharmacyId, ...range])).first['t']);

    final cogs = (lines['cogs'] as num).toDouble();
    final gross = _r((lines['costed_net'] as num).toDouble() - cogs);
    return {
      'gross_sales': _r(sales['gross_sales']),
      'discounts': _r(sales['discounts']),
      'net_sales': _r(sales['net_sales']),
      'invoices_count': _i(sales['invoices_count']),
      'discounted_invoices_count': _i(sales['discounted']),
      'refunded_count': _i(refunded['c']),
      'refunded_value': _r(refunded['v']),
      'cost_of_goods_sold': _r(cogs),
      'gross_profit': gross,
      'uncosted_revenue': _r(lines['uncosted_net']),
      'items_without_cost': _i(lines['missing']),
      'expenses': expenses,
      'damage_cost': damage,
      'net_profit': _r(gross - expenses - damage),
    };
  }

  /// دفعات المخزون الحالي (b, m[, s]).
  String _stockBatches({bool withSupplier = false}) => '''
    FROM medicine_batch b JOIN medicine m ON m.id = b.medicine_id
    ${withSupplier ? 'LEFT JOIN pharmacy_supplier s ON s.id = b.supplier_id' : ''}
    WHERE m.pharmacy_id = ? AND ${_origin('m.')} AND m.is_damaged = 0 AND b.quantity > 0''';

  static const String _hasExpiry = "b.expiry_date IS NOT NULL AND b.expiry_date != ''";

  Future<Map<String, Object?>> _expiryFigures(int pharmacyId, String condition, List<Object?> args) async {
    return (await _q('''
      SELECT COUNT(DISTINCT b.medicine_id) AS c, COALESCE(SUM($_batchValue), 0) AS v
      ${_stockBatches()} AND $_hasExpiry AND $condition
    ''', [pharmacyId, ...args])).first;
  }

  String _belowCostWhere() => '''
    FROM medicine m
    WHERE m.pharmacy_id = ? AND ${_origin('m.')} AND m.is_damaged = 0 AND m.quantity > 0
      AND $_medicineCost > 0 AND m.sell_price < $_medicineCost''';

  Future<Map<String, dynamic>> alerts(int pharmacyId) async {
    final today = _today;
    final limit = dayKey(addDays(_clock(), expiryAlertDays));
    final expiring = await _expiryFigures(pharmacyId, 'substr(b.expiry_date, 1, 10) >= ? AND substr(b.expiry_date, 1, 10) <= ?', [today, limit]);
    final expired = await _expiryFigures(pharmacyId, 'substr(b.expiry_date, 1, 10) < ?', [today]);
    final belowCost = (await _q('SELECT COUNT(*) AS c ${_belowCostWhere()}', [pharmacyId])).first['c'];
    final stock = (await _q('''
      SELECT COALESCE(SUM(CASE WHEN m.quantity <= ? THEN 1 ELSE 0 END), 0) AS low,
             COALESCE(SUM(CASE WHEN m.quantity <= 0 THEN 1 ELSE 0 END), 0) AS out_of_stock
      FROM medicine m WHERE m.pharmacy_id = ? AND ${_origin('m.')} AND m.is_damaged = 0
    ''', [kLowStockThreshold, pharmacyId])).first;
    return {
      'below_cost_count': _i(belowCost),
      'expiring_days': expiryAlertDays,
      'expiring_count': _i(expiring['c']),
      'expiring_value': _r(expiring['v']),
      'expired_count': _i(expired['c']),
      'expired_value': _r(expired['v']),
      'low_stock_count': _i(stock['low']),
      'out_of_stock_count': _i(stock['out_of_stock']),
    };
  }

  Future<Map<String, dynamic>> kpis(int pharmacyId, ReportPeriod period) async {
    final previous = period.previous;
    return {
      'start': period.startKey,
      'end': period.endKey,
      'previous_start': previous.startKey,
      'previous_end': previous.endKey,
      'current': await periodFigures(pharmacyId, period.start, period.end),
      'previous': await periodFigures(pharmacyId, previous.start, previous.end),
      'alerts': await alerts(pharmacyId),
    };
  }

  // ---------------------------------------------------------------------------
  // نظرة عامة
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> trend(int pharmacyId, ReportPeriod period) async {
    final range = _range(period.start, period.end);
    final points = {for (final k in period.bucketKeys()) k: <String, double>{'net_sales': 0, 'gross_profit': 0}};
    String keyOf(Object? day) => dayKey(period.bucketStart(DateTime.parse(day as String)));

    final sales = await _q('''
      SELECT substr(i.created_at, 1, 10) AS day, COALESCE(SUM(i.final_amount), 0) AS net
      FROM invoice i
      WHERE i.pharmacy_id = ? AND ${_origin('i.')} AND i.is_refunded = 0 AND i.created_at >= ? AND i.created_at < ?
      GROUP BY day
    ''', [pharmacyId, ...range]);
    for (final row in sales) {
      points[keyOf(row['day'])]!['net_sales'] = points[keyOf(row['day'])]!['net_sales']! + (row['net'] as num).toDouble();
    }
    final lines = await _q('''
      SELECT substr(i.created_at, 1, 10) AS day,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NOT NULL THEN $_lineNet - $_lineCost END), 0) AS gross
      ${_itemsFrom()}
      GROUP BY day
    ''', [pharmacyId, ...range]);
    for (final row in lines) {
      points[keyOf(row['day'])]!['gross_profit'] =
          points[keyOf(row['day'])]!['gross_profit']! + (row['gross'] as num).toDouble();
    }
    return {
      'bucket': period.bucket.name,
      'points': [
        for (final e in points.entries)
          {'key': e.key, 'net_sales': _r(e.value['net_sales']), 'gross_profit': _r(e.value['gross_profit'])},
      ],
    };
  }

  Future<Map<String, dynamic>> categories(int pharmacyId, ReportPeriod period) async {
    final rows = await _q('''
      SELECT TRIM(COALESCE(m.category, '')) AS category, COALESCE(SUM($_lineNet), 0) AS net, COALESCE(SUM(ii.quantity), 0) AS qty
      ${_itemsFrom()}
      GROUP BY TRIM(COALESCE(m.category, ''))
    ''', [pharmacyId, ..._range(period.start, period.end)]);
    final result = [
      for (final r in rows) {'category': r['category'] as String, 'net_sales': _r(r['net']), 'quantity': _i(r['qty'])},
    ];
    result.sort((a, b) {
      final byNet = (b['net_sales'] as double).compareTo(a['net_sales'] as double);
      return byNet != 0 ? byNet : (a['category'] as String).compareTo(b['category'] as String);
    });
    return {'categories': result};
  }

  Future<Map<String, dynamic>> hours(int pharmacyId, ReportPeriod period) async {
    final rows = await _q('''
      SELECT CAST(substr(i.created_at, 12, 2) AS INTEGER) AS hour, COUNT(i.id) AS c, COALESCE(SUM(i.final_amount), 0) AS net
      FROM invoice i
      WHERE i.pharmacy_id = ? AND ${_origin('i.')} AND i.is_refunded = 0 AND i.created_at >= ? AND i.created_at < ?
      GROUP BY hour
    ''', [pharmacyId, ..._range(period.start, period.end)]);
    final byHour = {for (final r in rows) _i(r['hour']): r};
    return {
      'hours': [
        for (var h = 0; h < 24; h++)
          {'hour': h, 'invoices_count': _i(byHour[h]?['c']), 'net_sales': _r(byHour[h]?['net'])},
      ],
    };
  }

  // ---------------------------------------------------------------------------
  // الأصناف
  // ---------------------------------------------------------------------------

  static const Map<String, String> _itemSorts = {'qty': 'qty', 'revenue': 'revenue', 'profit': 'profit'};

  Future<Map<String, dynamic>> items(int pharmacyId, ReportPeriod period, {String sort = 'qty'}) async {
    final key = _itemSorts.containsKey(sort) ? sort : 'qty';
    // LEFT JOIN: صنف حُذف لاحقاً يبقى ظاهراً باسمه المحفوظ في سطر الفاتورة.
    final rows = await _q('''
      SELECT ii.medicine_id AS medicine_id,
             COALESCE(MAX(m.trade_name), MAX(ii.trade_name)) AS name,
             SUM(ii.quantity) AS qty,
             COALESCE(SUM($_lineNet), 0) AS revenue,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NOT NULL THEN $_lineNet END), 0) AS costed_revenue,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NOT NULL THEN $_lineCost END), 0) AS line_cost,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NULL THEN ii.quantity END), 0) AS uncosted_qty,
             COALESCE(SUM(CASE WHEN ii.unit_cost IS NOT NULL THEN $_lineNet - $_lineCost END), 0) AS profit
      ${_itemsFrom()}
      GROUP BY ii.medicine_id
      ORDER BY ${_itemSorts[key]} DESC, name ASC, medicine_id ASC
      LIMIT $topItemsLimit
    ''', [pharmacyId, ..._range(period.start, period.end)]);
    final below = await _q('''
      SELECT m.id, m.trade_name, m.quantity, $_medicineCost AS cost, m.sell_price
      ${_belowCostWhere()}
      ORDER BY ($_medicineCost - m.sell_price) DESC, m.trade_name ASC, m.id ASC
    ''', [pharmacyId]);
    return {
      'sort': key,
      'items': [
        for (final r in rows)
          {
            'medicine_id': r['medicine_id'],
            'trade_name': r['name'],
            'quantity': _i(r['qty']),
            'revenue': _r(r['revenue']),
            'costed_revenue': _r(r['costed_revenue']),
            'cost': _r(r['line_cost']),
            'profit': _r(r['profit']),
            'uncosted_quantity': _i(r['uncosted_qty']),
          },
      ],
      'below_cost': [
        for (final r in below)
          {
            'medicine_id': r['id'],
            'trade_name': r['trade_name'],
            'quantity': _i(r['quantity']),
            'cost': _r(r['cost']),
            'sell_price': _r(r['sell_price']),
            'loss_per_unit': _r((r['cost'] as num) - (r['sell_price'] as num)),
          },
      ],
    };
  }

  ({int page, int pageSize}) _page(int page, int pageSize) =>
      (page: page < 1 ? 1 : page, pageSize: pageSize.clamp(1, maxPageSize));

  Future<Map<String, dynamic>> stagnant(int pharmacyId, ReportPeriod period,
      {int page = 1, int pageSize = defaultPageSize}) async {
    final p = _page(page, pageSize);
    final range = _range(period.start, period.end);
    final where = '''
      FROM medicine m
      WHERE m.pharmacy_id = ? AND ${_origin('m.')} AND m.is_damaged = 0 AND m.quantity > 0
        AND m.id NOT IN (SELECT ii.medicine_id ${_itemsFrom()})''';
    final args = [pharmacyId, pharmacyId, ...range];
    final totals = (await _q('''
      SELECT COUNT(*) AS c,
             COALESCE(SUM((SELECT SUM($_batchValue) FROM medicine_batch b WHERE b.medicine_id = m.id AND b.quantity > 0)), 0) AS v
      $where
    ''', args)).first;
    final rows = await _q('''
      SELECT m.id, m.trade_name, COALESCE(m.category, '') AS category, m.quantity,
             COALESCE((SELECT SUM($_batchValue) FROM medicine_batch b WHERE b.medicine_id = m.id AND b.quantity > 0), 0) AS stock_value,
             (SELECT MAX(substr(si.created_at, 1, 10)) FROM invoice_item sii JOIN invoice si ON si.id = sii.invoice_id
               WHERE sii.medicine_id = m.id AND si.is_refunded = 0) AS last_sale
      $where
      ORDER BY stock_value DESC, m.trade_name ASC, m.id ASC
      LIMIT ? OFFSET ?
    ''', [...args, p.pageSize, (p.page - 1) * p.pageSize]);
    return {
      'count': _i(totals['c']),
      'page': p.page,
      'page_size': p.pageSize,
      'total_value': _r(totals['v']),
      'results': [
        for (final r in rows)
          {
            'medicine_id': r['id'],
            'trade_name': r['trade_name'],
            'category': (r['category'] as String).trim(),
            'quantity': _i(r['quantity']),
            'stock_value': _r(r['stock_value']),
            'last_sale': r['last_sale'],
          },
      ],
    };
  }

  // ---------------------------------------------------------------------------
  // المخزون (الوضع الحالي)
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> _batchRows(int pharmacyId, String condition, List<Object?> args) async {
    final rows = await _q('''
      SELECT b.id AS batch_id, b.medicine_id, m.trade_name, substr(b.expiry_date, 1, 10) AS expiry_date, b.quantity,
             $_batchValue AS value, COALESCE(s.name, b.supplier_name, '') AS supplier_name
      ${_stockBatches(withSupplier: true)} AND $_hasExpiry AND $condition
      ORDER BY expiry_date ASC, m.trade_name ASC, b.id ASC
    ''', [pharmacyId, ...args]);
    return [
      for (final r in rows)
        {
          'medicine_id': r['medicine_id'],
          'batch_id': r['batch_id'],
          'trade_name': r['trade_name'],
          'expiry_date': r['expiry_date'],
          'quantity': _i(r['quantity']),
          'value': _r(r['value']),
          'supplier_name': r['supplier_name'],
        },
    ];
  }

  Future<Map<String, dynamic>> inventory(int pharmacyId, {int days = expiryAlertDays}) async {
    final today = _today;
    final limit = dayKey(addDays(_clock(), days));
    final cost = (await _q('SELECT COALESCE(SUM($_batchValue), 0) AS v ${_stockBatches()}', [pharmacyId])).first['v'];
    final sell = (await _q('''
      SELECT COALESCE(SUM(m.quantity * m.sell_price), 0) AS v FROM medicine m
      WHERE m.pharmacy_id = ? AND ${_origin('m.')} AND m.is_damaged = 0 AND m.quantity > 0
    ''', [pharmacyId])).first['v'];
    final expiring = await _batchRows(
        pharmacyId, 'substr(b.expiry_date, 1, 10) >= ? AND substr(b.expiry_date, 1, 10) <= ?', [today, limit]);
    final expired = await _batchRows(pharmacyId, 'substr(b.expiry_date, 1, 10) < ?', [today]);
    final low = await _q('''
      SELECT m.id, m.trade_name, m.quantity, COALESCE(m.category, '') AS category, m.sell_price FROM medicine m
      WHERE m.pharmacy_id = ? AND ${_origin('m.')} AND m.is_damaged = 0 AND m.quantity <= ?
      ORDER BY m.quantity ASC, m.trade_name ASC, m.id ASC
    ''', [pharmacyId, kLowStockThreshold]);
    final costValue = _r(cost), sellValue = _r(sell);
    double sumOf(List<Map<String, dynamic>> rows) => _r(rows.fold<double>(0, (s, r) => s + (r['value'] as double)));
    return {
      'today': today,
      'days': days,
      'stock_cost_value': costValue,
      'stock_sell_value': sellValue,
      'expected_profit': _r(sellValue - costValue),
      'expiring': expiring,
      'expiring_value': sumOf(expiring),
      'expired': expired,
      'expired_value': sumOf(expired),
      'low_stock_threshold': kLowStockThreshold,
      'low_stock': [
        for (final r in low)
          {
            'medicine_id': r['id'],
            'trade_name': r['trade_name'],
            'quantity': _i(r['quantity']),
            'category': (r['category'] as String).trim(),
            'sell_price': _r(r['sell_price']),
          },
      ],
    };
  }

  // ---------------------------------------------------------------------------
  // المشتريات والمذاخر
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> purchases(int pharmacyId, ReportPeriod period) async {
    final range = _range(period.start, period.end);
    final totals = (await _q('''
      SELECT COALESCE(SUM(total_amount), 0) AS t, COUNT(id) AS c FROM purchase_invoice
      WHERE pharmacy_id = ? AND created_at >= ? AND created_at < ?
    ''', [pharmacyId, ...range])).first;
    final bySupplier = <int, Map<String, dynamic>>{};
    for (final r in await _q('''
      SELECT pi.supplier_id, s.name, COUNT(pi.id) AS c, COALESCE(SUM(pi.total_amount), 0) AS t
      FROM purchase_invoice pi JOIN pharmacy_supplier s ON s.id = pi.supplier_id
      WHERE pi.pharmacy_id = ? AND pi.created_at >= ? AND pi.created_at < ?
      GROUP BY pi.supplier_id
    ''', [pharmacyId, ...range])) {
      bySupplier[r['supplier_id'] as int] = {
        'supplier_id': r['supplier_id'], 'name': r['name'], 'invoices_count': _i(r['c']), 'total': _r(r['t']), 'returns': 0.0,
      };
    }
    for (final r in await _q('''
      SELECT r.supplier_id, s.name, COALESCE(SUM(r.amount_returned), 0) AS t
      FROM purchase_invoice_return r JOIN pharmacy_supplier s ON s.id = r.supplier_id
      WHERE r.pharmacy_id = ? AND r.returned_at >= ? AND r.returned_at < ?
      GROUP BY r.supplier_id
    ''', [pharmacyId, ...range])) {
      bySupplier.putIfAbsent(r['supplier_id'] as int, () => {
            'supplier_id': r['supplier_id'], 'name': r['name'], 'invoices_count': 0, 'total': 0.0, 'returns': 0.0,
          })['returns'] = _r(r['t']);
    }
    Future<double> sumIn(String table, String column, String dateColumn) async => _r((await _q('''
      SELECT COALESCE(SUM($column), 0) AS t FROM $table WHERE pharmacy_id = ? AND $dateColumn >= ? AND $dateColumn < ?
    ''', [pharmacyId, ...range])).first['t']);

    final figures = await _helper.getSuppliersWithFinancials(pharmacyId);
    final debtors = [
      for (final f in figures)
        if ((f['remaining_debt'] as num) > 0) {'supplier_id': f['id'], 'name': f['name'], 'debt': _r(f['remaining_debt'])},
    ]..sort((a, b) {
        final byDebt = (b['debt'] as double).compareTo(a['debt'] as double);
        if (byDebt != 0) return byDebt;
        final byName = (a['name'] as String).compareTo(b['name'] as String);
        return byName != 0 ? byName : (a['supplier_id'] as int).compareTo(b['supplier_id'] as int);
      });
    final suppliers = bySupplier.values.toList()
      ..sort((a, b) {
        final byTotal = (b['total'] as double).compareTo(a['total'] as double);
        if (byTotal != 0) return byTotal;
        final byName = (a['name'] as String).compareTo(b['name'] as String);
        return byName != 0 ? byName : (a['supplier_id'] as int).compareTo(b['supplier_id'] as int);
      });
    return {
      'purchases_total': _r(totals['t']),
      'invoices_count': _i(totals['c']),
      'returns_total': await sumIn('purchase_invoice_return', 'amount_returned', 'returned_at'),
      'payments_total': await sumIn('supplier_payment', 'amount_paid', 'paid_at'),
      'refunds_received': await sumIn('supplier_refund', 'amount', 'received_at'),
      'by_supplier': suppliers,
      'total_debt': _r(figures.fold<double>(0, (s, f) => s + (f['remaining_debt'] as num).toDouble())),
      'total_credit': _r(figures.fold<double>(0, (s, f) => s + (f['credit_balance'] as num).toDouble())),
      'top_debtors': debtors.take(topDebtorsLimit).toList(),
    };
  }

  // ---------------------------------------------------------------------------
  // المصاريف والخسائر
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> losses(int pharmacyId, ReportPeriod period) async {
    final range = _range(period.start, period.end);
    final expenses = await _q('''
      SELECT e.expense_type AS type, COALESCE(SUM(e.amount), 0) AS t, COUNT(e.id) AS c FROM expense e
      WHERE e.pharmacy_id = ? AND ${_origin('e.')} AND e.expense_date >= ? AND e.expense_date < ?
      GROUP BY e.expense_type
      ORDER BY t DESC, type ASC
    ''', [pharmacyId, ...range]);
    final damage = await _q('''
      SELECT COALESCE(dm.reason, '') AS reason, COALESCE(SUM(${DatabaseHelper.damageCostSql}), 0) AS t,
             COALESCE(SUM(dm.quantity_damaged), 0) AS q, COUNT(dm.id) AS c
      FROM damaged_medicine dm LEFT JOIN medicine m ON m.id = dm.medicine_id
      WHERE dm.pharmacy_id = ? AND ${_origin('dm.')} AND COALESCE(dm.reason, '') != 'correction'
        AND dm.damaged_at >= ? AND dm.damaged_at < ?
      GROUP BY COALESCE(dm.reason, '')
    ''', [pharmacyId, ...range]);
    final byType = [for (final r in expenses) {'type': r['type'], 'total': _r(r['t']), 'count': _i(r['c'])}];
    final byReason = [
      for (final r in damage) {'reason': r['reason'], 'total': _r(r['t']), 'quantity': _i(r['q']), 'count': _i(r['c'])},
    ]..sort((a, b) {
        final byTotal = (b['total'] as double).compareTo(a['total'] as double);
        return byTotal != 0 ? byTotal : (a['reason'] as String).compareTo(b['reason'] as String);
      });
    double sumOf(Iterable<Map<String, dynamic>> rows) => _r(rows.fold<double>(0, (s, r) => s + (r['total'] as double)));
    final expired = await _expiryFigures(pharmacyId, 'substr(b.expiry_date, 1, 10) < ?', [_today]);
    return {
      'expenses_total': sumOf(byType),
      'expenses_by_type': byType,
      'damage_total': sumOf(byReason),
      'damage_by_reason': byReason,
      'expired_recorded': sumOf(byReason.where((r) => r['reason'] == 'expired')),
      'expired_not_disposed_value': _r(expired['v']),
    };
  }

  // ---------------------------------------------------------------------------
  // المبيعات والموظفين
  // ---------------------------------------------------------------------------

  String _invoicesFrom() => '''
    FROM invoice i
    LEFT JOIN user_profile up ON up.id = i.cashier_id
    LEFT JOIN users u ON u.id = up.user_id
    WHERE i.pharmacy_id = ? AND ${_origin('i.')} AND i.created_at >= ? AND i.created_at < ?''';

  Future<Map<String, dynamic>> invoices(
    int pharmacyId,
    ReportPeriod period, {
    int page = 1,
    int pageSize = defaultPageSize,
    String query = '',
    String seller = '',
    bool refunded = false,
  }) async {
    final p = _page(page, pageSize);
    final filters = StringBuffer(' AND i.is_refunded = ${refunded ? 1 : 0}');
    final args = <Object?>[pharmacyId, ..._range(period.start, period.end)];
    if (query.trim().isNotEmpty) {
      filters.write(' AND i.invoice_number LIKE ?');
      args.add('%${query.trim()}%');
    }
    if (seller.trim().isNotEmpty) {
      filters.write(' AND $_sellerName = ?');
      args.add(seller.trim());
    }
    final totals = (await _q('SELECT COUNT(i.id) AS c, COALESCE(SUM(i.final_amount), 0) AS t ${_invoicesFrom()}$filters', args)).first;
    final rows = await _q('''
      SELECT i.id, i.invoice_number, i.created_at, i.total_amount, i.discount, i.final_amount, i.is_refunded,
             $_sellerName AS seller_name
      ${_invoicesFrom()}$filters
      ORDER BY i.created_at DESC, i.id DESC
      LIMIT ? OFFSET ?
    ''', [...args, p.pageSize, (p.page - 1) * p.pageSize]);
    return {
      'count': _i(totals['c']),
      'page': p.page,
      'page_size': p.pageSize,
      'total_amount': _r(totals['t']),
      'results': [
        for (final r in rows)
          {
            'id': r['id'],
            'invoice_number': r['invoice_number'],
            'created_at': r['created_at'],
            'total_amount': _r(r['total_amount']),
            'discount': _r(r['discount']),
            'final_amount': _r(r['final_amount']),
            'seller_name': r['seller_name'],
            'is_refunded': _i(r['is_refunded']) == 1,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> sellers(int pharmacyId, ReportPeriod period) async {
    final rows = await _q('''
      SELECT $_sellerName AS seller_name, COUNT(i.id) AS c, COALESCE(SUM(i.final_amount), 0) AS t
      ${_invoicesFrom()} AND i.is_refunded = 0
      GROUP BY seller_name
    ''', [pharmacyId, ..._range(period.start, period.end)]);
    final result = [
      for (final r in rows) {'seller_name': r['seller_name'], 'invoices_count': _i(r['c']), 'net_sales': _r(r['t'])},
    ]..sort((a, b) {
        final byNet = (b['net_sales'] as double).compareTo(a['net_sales'] as double);
        return byNet != 0 ? byNet : (a['seller_name'] as String).compareTo(b['seller_name'] as String);
      });
    return {'sellers': result};
  }

  /// أسطر فاتورة لنافذة التفاصيل — LEFT JOIN مع الاسم المحفوظ وقت البيع.
  Future<List<Map<String, dynamic>>> invoiceItems(int invoiceId) async {
    final rows = await _q('''
      SELECT COALESCE(ii.trade_name, m.trade_name, '-') AS trade_name, ii.quantity, ii.unit_price, ii.total_price
      FROM invoice_item ii LEFT JOIN medicine m ON m.id = ii.medicine_id
      WHERE ii.invoice_id = ?
      ORDER BY ii.id
    ''', [invoiceId]);
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}
