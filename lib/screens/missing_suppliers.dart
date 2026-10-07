import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/purchase_list.dart';
import '../repository/suppliers_repository.dart';
import 'purchase_return_dialog.dart';
import 'reports/report_widgets.dart';

/// فلاتر قائمة المذاخر.
enum _SupplierFilter { all, debt, credit }

/// ترتيب قائمة المذاخر.
enum _SupplierSort { debt, name, lastInvoice }

/// تبويبات تفاصيل المذخر.
enum _DetailsTab { invoices, statement, items }

const _filterLabels = {
  _SupplierFilter.all: 'الكل',
  _SupplierFilter.debt: 'عليها دين',
  _SupplierFilter.credit: 'لصالحنا رصيد',
};

const _sortLabels = {
  _SupplierSort.debt: 'الدين',
  _SupplierSort.name: 'الاسم',
  _SupplierSort.lastInvoice: 'آخر فاتورة',
};

const _tabLabels = {
  _DetailsTab.invoices: 'الفواتير',
  _DetailsTab.statement: 'كشف الحساب',
  _DetailsTab.items: 'الأصناف المشتراة',
};

/// شاشة "المذاخر والمشتريات". المذاخر تُنشأ حصراً من قائمة المذخر في شاشة
/// المخزن؛ هنا العرض، تصحيح الاسم، الدفعات، الاسترجاع، واستلام الأموال.
class MissingSuppliersScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOnlineMode; // من license.mode القادم من main_layout.dart

  const MissingSuppliersScreen({
    super.key,
    this.pharmacyId = 1, // معرف الفرع الافتراضي
    this.isOnlineMode = false, // قيمة افتراضية آمنة (أوفلاين)
  });

  @override
  State<MissingSuppliersScreen> createState() => _MissingSuppliersScreenState();
}

class _MissingSuppliersScreenState extends State<MissingSuppliersScreen> {
  late Future<List<Map<String, dynamic>>> _suppliersFuture;
  final SuppliersRepository _repository = SuppliersRepository.instance;

  String _searchQuery = '';
  _SupplierFilter _filter = _SupplierFilter.all;
  _SupplierSort _sort = _SupplierSort.debt;
  int _page = 1;
  static const int _pageSize = 25;

  int? _selectedId;
  _DetailsTab _tab = _DetailsTab.invoices;

  /// بيانات تبويبات المذخر المفتوح، تُحمَّل عند أول فتح لكل تبويب.
  final Map<_DetailsTab, Future<List<Map<String, dynamic>>>> _detailFutures = {};

  /// استرجاعات مفتوحة في كشف الحساب لعرض أدويتها (المفتاح = معرّف الاسترجاع).
  final Set<Object?> _expandedReturns = <Object?>{};

  // نفس ألوان شاشتي التقارير والبيع.
  static const Color primary = RC.teal;
  static const Color primaryDark = RC.tealDark;
  static const Color bgCanvas = RC.page;
  static const Color cardBg = RC.card;
  static const Color borderCol = RC.border;
  static const Color textMain = RC.text;
  static const Color textSecondary = RC.muted;
  static const Color success = RC.green;
  static const Color danger = RC.red;
  static const Color warning = RC.orange;
  static const Color tealBg = Color(0xFFE8F8F5);

  /// عرض النافذة الذي تظهر فوقه التفاصيل كلوحة جانبية بدل صفحة كاملة.
  static const double _sidePanelBreakpoint = 1100;

  @override
  void initState() {
    super.initState();
    _refreshData();
  }

  void _refreshData() {
    setState(() {
      _suppliersFuture = _repository.getSuppliersWithFinancials(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
      );
      _detailFutures.clear();
    });
  }

  void _openSupplier(int id) {
    setState(() {
      if (_selectedId != id) {
        _tab = _DetailsTab.invoices;
        _expandedReturns.clear();
      }
      _selectedId = id;
      _detailFutures.clear();
    });
  }

  void _closeSupplier() => setState(() {
        _selectedId = null;
        _detailFutures.clear();
      });

  Future<List<Map<String, dynamic>>> _detailFuture(_DetailsTab tab, int supplierId) {
    return _detailFutures.putIfAbsent(tab, () {
      switch (tab) {
        case _DetailsTab.invoices:
          return _repository.getPurchaseInvoicesBySupplier(supplierId: supplierId, isOnlineMode: widget.isOnlineMode);
        case _DetailsTab.statement:
          return _repository.getSupplierStatementOfAccount(supplierId: supplierId, isOnlineMode: widget.isOnlineMode);
        case _DetailsTab.items:
          return _repository.getSupplierPurchasedItems(supplierId: supplierId, isOnlineMode: widget.isOnlineMode);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: bgCanvas,
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _suppliersFuture,
          builder: (context, snapshot) {
            final suppliers = snapshot.data;
            final selected = _selectedId == null || suppliers == null
                ? null
                : suppliers.where((s) => s['id'] == _selectedId).firstOrNull;
            return LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= _sidePanelBreakpoint;
                if (selected != null && !wide) {
                  return _buildDetails(selected, suppliers!, fullPage: true);
                }
                final main = _buildMain(snapshot, compact: selected != null);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(),
                    Expanded(
                      child: selected == null
                          ? main
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: main),
                                SizedBox(
                                  width: (constraints.maxWidth * 0.5).clamp(560.0, 820.0),
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: cardBg,
                                      border: BorderDirectional(start: BorderSide(color: borderCol)),
                                    ),
                                    child: _buildDetails(selected, suppliers!, fullPage: false),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  // ==========================================
  // الرأس: العنوان، البحث، الفلاتر، الترتيب
  // ==========================================
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      decoration: const BoxDecoration(
        color: cardBg,
        border: Border(bottom: BorderSide(color: borderCol)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_shipping_rounded, color: primary, size: 26),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'المذاخر والمشتريات',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50)),
                ),
              ),
              IconButton(
                key: const Key('suppliers-refresh'),
                tooltip: 'تحديث البيانات',
                onPressed: _refreshData,
                icon: const Icon(Icons.refresh, color: primaryDark),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              LayoutBuilder(
                builder: (context, c) => SizedBox(
                  width: c.maxWidth < 320 ? c.maxWidth : 300,
                  child: TextField(
                    key: const Key('supplier-search'),
                    textAlign: TextAlign.right,
                    onChanged: (value) => setState(() {
                      _searchQuery = value.trim();
                      _page = 1;
                    }),
                    style: const TextStyle(fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: 'بحث باسم المذخر...',
                      hintStyle: const TextStyle(fontSize: 13, color: textSecondary),
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      isDense: true,
                      filled: true,
                      fillColor: RC.faint,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: borderCol),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: primaryDark, width: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
              for (final filter in _SupplierFilter.values)
                ChoiceChip(
                  key: Key('supplier-filter-${filter.name}'),
                  label: Text(_filterLabels[filter]!),
                  selected: _filter == filter,
                  showCheckmark: false,
                  labelStyle: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _filter == filter ? Colors.white : textMain,
                  ),
                  selectedColor: primaryDark,
                  backgroundColor: RC.faint,
                  side: const BorderSide(color: borderCol),
                  onSelected: (_) => setState(() {
                    _filter = filter;
                    _page = 1;
                  }),
                ),
              PopupMenuButton<_SupplierSort>(
                key: const Key('supplier-sort'),
                tooltip: 'ترتيب القائمة',
                initialValue: _sort,
                onSelected: (sort) => setState(() {
                  _sort = sort;
                  _page = 1;
                }),
                itemBuilder: (_) => [
                  for (final sort in _SupplierSort.values)
                    PopupMenuItem(value: sort, child: Text('ترتيب حسب ${_sortLabels[sort]}')),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: tealBg,
                    borderRadius: BorderRadius.circular(50),
                    border: Border.all(color: RC.tealLight),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sort_rounded, size: 18, color: primaryDark),
                      const SizedBox(width: 6),
                      Text(
                        'الترتيب: ${_sortLabels[_sort]}',
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: primaryDark),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================
  // المحتوى الرئيسي: بطاقات الملخص + جدول المذاخر
  // ==========================================
  Widget _buildMain(AsyncSnapshot<List<Map<String, dynamic>>> snapshot, {required bool compact}) {
    final suppliers = snapshot.data;
    final Widget body;
    if (suppliers == null && snapshot.hasError) {
      body = Container(
        decoration: cardDecoration(),
        padding: const EdgeInsets.all(16),
        child: SectionError(error: snapshot.error!, onRetry: _refreshData),
      );
    } else if (suppliers == null) {
      body = Container(
        decoration: cardDecoration(),
        padding: const EdgeInsets.all(16),
        child: const SkeletonBlock(height: 220, lines: 6),
      );
    } else if (suppliers.isEmpty) {
      body = _noSuppliersYet();
    } else {
      body = _buildSuppliersCard(suppliers, compact: compact);
    }

    return RefreshIndicator(
      color: primary,
      onRefresh: () async => _refreshData(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSummaryCards(suppliers),
            const SizedBox(height: 16),
            body,
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCards(List<Map<String, dynamic>>? suppliers) {
    double sum(String key) => suppliers?.fold<double>(0, (s, row) => s + _number(row[key])) ?? 0;
    final monthKnown = suppliers?.any((s) => s['month_purchases'] != null) ?? false;
    final cards = [
      _SummaryCard(
        key: const Key('summary-debt'),
        title: 'إجمالي الديون',
        icon: Icons.account_balance_wallet_outlined,
        value: suppliers == null ? null : iqd(sum('remaining_debt')),
        valueColor: sum('remaining_debt') > 0.001 ? danger : null,
        hint: 'مجموع ديون كل مذخر',
      ),
      _SummaryCard(
        key: const Key('summary-credit'),
        title: 'رصيد لصالحنا',
        icon: Icons.savings_outlined,
        value: suppliers == null ? null : iqd(sum('credit_balance')),
        valueColor: sum('credit_balance') > 0.001 ? success : null,
        hint: 'لدى المذاخر من المرتجعات',
      ),
      _SummaryCard(
        key: const Key('summary-month'),
        title: 'مشتريات هذا الشهر',
        icon: Icons.shopping_cart_outlined,
        value: suppliers == null ? null : (monthKnown ? iqd(sum('month_purchases')) : '—'),
        hint: monthKnown || suppliers == null ? 'حسب تاريخ الفاتورة' : 'يتطلب تحديث الخادم',
      ),
      _SummaryCard(
        key: const Key('summary-count'),
        title: 'عدد المذاخر',
        icon: Icons.storefront_outlined,
        value: suppliers == null ? null : '${suppliers.length}',
        hint: 'المسجلة في الصيدلية',
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('ملخص المذاخر', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textMain)),
            currentStateTag,
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, constraints) {
          final perRow = constraints.maxWidth >= 900 ? 4 : (constraints.maxWidth >= 440 ? 2 : 1);
          final width = (constraints.maxWidth - (perRow - 1) * 14) / perRow;
          return Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [for (final card in cards) SizedBox(width: width, child: card)],
          );
        }),
      ],
    );
  }

  Widget _noSuppliersYet() {
    return Container(
      decoration: cardDecoration(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: const Column(
        children: [
          Icon(Icons.storefront_outlined, size: 48, color: Color(0xFFCBD5E1)),
          SizedBox(height: 12),
          Text(
            'لا توجد مذاخر بعد',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textMain),
          ),
          SizedBox(height: 6),
          Text(
            'تُضاف المذاخر تلقائياً عند إدخال قائمة مذخر من شاشة المخزن',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: textSecondary),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _visibleSuppliers(List<Map<String, dynamic>> all) {
    final query = _searchQuery.toLowerCase();
    final rows = all.where((s) {
      if (query.isNotEmpty && !(s['name']?.toString().toLowerCase().contains(query) ?? false)) return false;
      switch (_filter) {
        case _SupplierFilter.all:
          return true;
        case _SupplierFilter.debt:
          return _number(s['remaining_debt']) > 0.001;
        case _SupplierFilter.credit:
          return _number(s['credit_balance']) > 0.001;
      }
    }).toList();

    int byName(Map<String, dynamic> a, Map<String, dynamic> b) =>
        (a['name']?.toString() ?? '').toLowerCase().compareTo((b['name']?.toString() ?? '').toLowerCase());
    rows.sort((a, b) {
      switch (_sort) {
        case _SupplierSort.debt:
          final cmp = _number(b['balance']).compareTo(_number(a['balance']));
          return cmp != 0 ? cmp : byName(a, b);
        case _SupplierSort.name:
          return byName(a, b);
        case _SupplierSort.lastInvoice:
          final da = DateTime.tryParse(a['last_invoice_date']?.toString() ?? '');
          final db = DateTime.tryParse(b['last_invoice_date']?.toString() ?? '');
          if (da == null && db == null) return byName(a, b);
          if (da == null) return 1;
          if (db == null) return -1;
          final cmp = db.compareTo(da);
          return cmp != 0 ? cmp : byName(a, b);
      }
    });
    return rows;
  }

  Widget _buildSuppliersCard(List<Map<String, dynamic>> all, {required bool compact}) {
    final rows = _visibleSuppliers(all);
    final pages = rows.isEmpty ? 1 : (rows.length + _pageSize - 1) ~/ _pageSize;
    final page = _page.clamp(1, pages);
    final pageRows = rows.skip((page - 1) * _pageSize).take(_pageSize).toList();

    final columns = compact
        ? const [RCol('المذخر', width: 170), RCol('الرصيد', width: 170), RCol('آخر فاتورة', width: 100)]
        : const [
            RCol('المذخر', width: 190),
            RCol('الفواتير', width: 80),
            RCol('إجمالي المشتريات', width: 130),
            RCol('إجمالي المدفوع', width: 130),
            RCol('الرصيد', width: 180),
            RCol('آخر فاتورة', width: 110),
          ];

    return ReportCard(
      title: 'المذاخر',
      subtitle: '${rows.length} مذخر${rows.length != all.length ? ' من ${all.length}' : ''}',
      icon: Icons.storefront_outlined,
      child: rows.isEmpty
          ? const EmptyState('لا توجد مذاخر مطابقة.', icon: Icons.search_off_rounded)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Grid(
                  columns: columns,
                  selectedIndex: pageRows.indexWhere((s) => s['id'] == _selectedId),
                  onTap: (i) => _openSupplier(pageRows[i]['id'] as int),
                  rows: [
                    for (final s in pageRows)
                      compact
                          ? [
                              _cell(s['name']?.toString() ?? 'بدون اسم', bold: true, color: primaryDark),
                              _balanceBadge(s),
                              _cell(_formatDate(s['last_invoice_date']?.toString())),
                            ]
                          : [
                              _cell(s['name']?.toString() ?? 'بدون اسم', bold: true, color: primaryDark),
                              _cell('${(s['invoice_count'] as num?)?.toInt() ?? 0}'),
                              _cell(iqd(s['total_purchases'])),
                              _cell(s['total_paid'] == null ? '-' : iqd(s['total_paid'])),
                              _balanceBadge(s),
                              _cell(_formatDate(s['last_invoice_date']?.toString())),
                            ],
                  ],
                ),
                Pager(
                  page: page,
                  pageSize: _pageSize,
                  count: rows.length,
                  onPage: (p) => setState(() => _page = p),
                ),
              ],
            ),
    );
  }

  /// شارة الرصيد: دين (أحمر) / رصيد لصالح الصيدلية (أخضر) / مسدد (رمادي).
  Widget _balanceBadge(Map<String, dynamic> supplier) {
    final debt = _number(supplier['remaining_debt']);
    final credit = _number(supplier['credit_balance']);
    if (debt > 0.001) return _Badge('دين ${_formatAmount(debt)}', color: danger, background: RC.redBg);
    if (credit > 0.001) return _Badge('رصيد لصالحك ${_formatAmount(credit)}', color: success, background: RC.greenBg);
    return const _Badge('مسدد', color: textSecondary, background: Color(0xFFF1F5F9));
  }

  Widget _cell(String text, {Color color = textMain, bool bold = false, double size = 12.5}) => Text(
        text,
        softWrap: true,
        style: TextStyle(fontSize: size, color: color, fontWeight: bold ? FontWeight.bold : FontWeight.normal),
      );

  // ==========================================
  // تفاصيل المذخر (لوحة جانبية أو صفحة كاملة)
  // ==========================================
  Widget _buildDetails(Map<String, dynamic> supplier, List<Map<String, dynamic>> all, {required bool fullPage}) {
    final supplierId = supplier['id'] as int;
    final supplierName = supplier['name']?.toString() ?? 'بدون اسم';
    final availableCredit = _number(supplier['available_credit']);
    final count = (supplier['invoice_count'] as num?)?.toInt() ?? 0;

    final header = Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: const BoxDecoration(
        color: cardBg,
        border: Border(bottom: BorderSide(color: borderCol)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (fullPage) ...[
                IconButton(
                  key: const Key('supplier-details-back'),
                  tooltip: 'رجوع إلى المذاخر',
                  onPressed: _closeSupplier,
                  icon: const Icon(Icons.arrow_forward_rounded, color: primaryDark),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      supplierName,
                      key: const Key('supplier-details-name'),
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: textMain),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _balanceBadge(supplier),
                        Text('$count فاتورة', style: const TextStyle(fontSize: 12, color: textSecondary)),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'المزيد',
                icon: const Icon(Icons.more_vert_rounded, color: textSecondary),
                onSelected: (value) {
                  if (value == 'delete') _confirmDeleteSupplier(supplierId, supplierName);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('حذف المذخر', style: TextStyle(color: danger))),
                ],
              ),
              if (!fullPage)
                IconButton(
                  key: const Key('supplier-details-close'),
                  tooltip: 'إغلاق التفاصيل',
                  onPressed: _closeSupplier,
                  icon: const Icon(Icons.close_rounded, color: textSecondary),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('supplier-edit'),
                onPressed: () => _showEditNameDialog(supplierId, supplierName, all),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('تعديل'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: primaryDark,
                  side: const BorderSide(color: RC.tealLight),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              if (availableCredit > 0)
                FilledButton.icon(
                  onPressed: () => _showReceiveRefundDialog(context, supplierId, supplierName, availableCredit),
                  icon: const Icon(Icons.savings_outlined, size: 16),
                  label: const Text('استلام أموال من المذخر'),
                  style: FilledButton.styleFrom(
                    backgroundColor: success,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          StatGrid(
            maxColumns: 3,
            minTileWidth: 150,
            tiles: [
              StatTile(label: 'إجمالي المشتريات', value: iqd(supplier['total_purchases'])),
              StatTile(
                label: 'إجمالي المدفوع',
                value: supplier['total_paid'] == null ? '-' : iqd(supplier['total_paid']),
              ),
              StatTile(
                label: 'آخر فاتورة',
                value: _formatDate(supplier['last_invoice_date']?.toString()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [for (final tab in _DetailsTab.values) _tabButton(tab)],
          ),
        ],
      ),
    );

    final Widget content;
    switch (_tab) {
      case _DetailsTab.invoices:
        content = _invoicesTab(supplierId, supplierName);
      case _DetailsTab.statement:
        content = _statementTab(supplierId);
      case _DetailsTab.items:
        content = _purchasedItemsTab(supplierId);
    }

    final page = SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Padding(padding: const EdgeInsets.all(16), child: content),
        ],
      ),
    );
    if (!fullPage) return page;
    return ColoredBox(color: cardBg, child: page);
  }

  Widget _tabButton(_DetailsTab tab) {
    final selected = _tab == tab;
    return InkWell(
      key: Key('supplier-tab-${tab.name}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _tab = tab),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? tealBg : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? RC.tealLight : Colors.transparent),
        ),
        child: Text(
          _tabLabels[tab]!,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.bold : FontWeight.w600,
            color: selected ? primaryDark : textSecondary,
          ),
        ),
      ),
    );
  }

  /// قسم تبويب: هيكل أثناء التحميل، خطأ مع إعادة المحاولة، فارغ، ثم [builder].
  Widget _tabSection(
    _DetailsTab tab,
    int supplierId, {
    required String emptyText,
    required Widget Function(List<Map<String, dynamic>> rows) builder,
  }) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _detailFuture(tab, supplierId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SectionError(
            error: snapshot.error!,
            onRetry: () => setState(() => _detailFutures.remove(tab)),
          );
        }
        if (snapshot.connectionState != ConnectionState.done || !snapshot.hasData) {
          return const SkeletonBlock(height: 160, lines: 4);
        }
        final rows = snapshot.data!;
        if (rows.isEmpty) return EmptyState(emptyText);
        return builder(rows);
      },
    );
  }

  // --- تبويب الفواتير ---
  Widget _invoicesTab(int supplierId, String supplierName) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // الفواتير تُنشأ حصراً من شاشة المخزون (قائمة مذخر)؛ هنا الدفعات والاسترجاعات فقط.
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 15, color: textSecondary),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                'افتح الفاتورة لعرض أصنافها وإضافة دفعة أو استرجاع.',
                style: TextStyle(color: textSecondary, fontSize: 12.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _tabSection(
          _DetailsTab.invoices,
          supplierId,
          emptyText: 'لا توجد فواتير لهذا المذخر.',
          builder: (invoices) => _Grid(
            columns: const [
              RCol('رقم الفاتورة', width: 100),
              RCol('التاريخ', width: 92),
              RCol('الأصناف', width: 60),
              RCol('الإجمالي', width: 105),
              RCol('المدفوع', width: 100),
              RCol('المتبقي', width: 100),
              RCol('الحالة', width: 96),
            ],
            // النقر على الفاتورة يفتح أصنافها، ومنها الدفع والاسترجاع.
            onTap: (i) => _showInvoiceItemsDialog(context, invoices[i], supplierId, supplierName),
            rows: [
              for (final invoice in invoices) _invoiceRow(invoice),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _invoiceRow(Map<String, dynamic> invoice) {
    final id = invoice['id'];
    final total = _number(invoice['total_amount']);
    final returned = _number(invoice['returned_amount']);
    final paid = _number(invoice['paid_amount']);
    // المتبقي لا يقل عن 0: فائض الاسترجاع يذهب لرصيد المذخر.
    final remaining = _number(invoice['remaining_amount']);
    final invNum = invoice['invoice_number']?.toString().trim();
    final displayNum = (invNum != null && invNum.isNotEmpty) ? '#$invNum' : '#$id';
    // فواتير القوائم تحمل أصنافها؛ اليدوية القديمة بلا أصناف.
    final itemCount = _number(invoice['item_count']).toInt();
    final fromList = invoice['source'] == 'inventory_list';
    final invoiceDate = (invoice['invoice_date']?.toString().isNotEmpty ?? false)
        ? invoice['invoice_date'].toString()
        : invoice['created_at']?.toString();

    final _Badge status;
    if (remaining <= 0.001) {
      status = const _Badge('مسددة', color: success, background: RC.greenBg);
    } else if (paid > 0.001 || returned > 0.001 || _number(invoice['credit_applied']) > 0.001) {
      status = const _Badge('جزئية', color: warning, background: RC.orangeBg);
    } else {
      status = const _Badge('غير مسددة', color: danger, background: RC.redBg);
    }

    return [
      Text(
        displayNum,
        style: const TextStyle(
          color: primaryDark,
          fontWeight: FontWeight.bold,
          fontSize: 12.5,
          decoration: TextDecoration.underline,
        ),
      ),
      _cell(_formatDate(invoiceDate)),
      _cell(fromList ? '$itemCount' : '-'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _cell(_formatAmount(total)),
          if (returned > 0.001)
            Text('استرجاع ${_formatAmount(returned)}', style: const TextStyle(fontSize: 11, color: RC.blue)),
        ],
      ),
      _cell(_formatAmount(paid)),
      _cell(_formatAmount(remaining), color: remaining > 0.001 ? danger : textMain, bold: remaining > 0.001),
      status,
    ];
  }

  // --- تبويب كشف الحساب ---
  Widget _statementTab(int supplierId) {
    return _tabSection(
      _DetailsTab.statement,
      supplierId,
      emptyText: 'لا توجد تعاملات مسجلة لهذا المذخر.',
      builder: (rows) {
        final statement = _computeRunningBalance(rows);
        double totalInvoice = 0;
        double totalPayment = 0;
        double totalReturn = 0;
        for (final row in statement) {
          final type = row['transaction_type']?.toString();
          final amount = _number(row['amount']);
          // المبلغ المستلم من المذخر يُعرض في عمود المدين (يرفع الرصيد).
          if (type == 'invoice' || type == 'refund') totalInvoice += amount;
          if (type == 'payment') totalPayment += amount;
          if (type == 'return') totalReturn += amount;
        }
        final finalBalance = _number(statement.last['balance']);

        // Table يحسب عرض الأعمدة تلقائياً؛ تحت 620px يُمرَّر أفقياً بعرض ثابت.
        final table = Table(
          columnWidths: const {
            0: FixedColumnWidth(84),
            1: FlexColumnWidth(2.5),
            2: FlexColumnWidth(1),
            3: FlexColumnWidth(1),
            4: FlexColumnWidth(1),
            5: FlexColumnWidth(1.25),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            _statementHeaderRow(),
            for (final row in statement) ...[
              _statementRow(
                row,
                expanded: _expandedReturns.contains(row['id']),
                onToggle: () => setState(() {
                  _expandedReturns.contains(row['id'])
                      ? _expandedReturns.remove(row['id'])
                      : _expandedReturns.add(row['id']);
                }),
              ),
              if (row['transaction_type'] == 'return' && _expandedReturns.contains(row['id']))
                _statementReturnItemsRow(row),
            ],
            _statementTotalsRow(totalInvoice, totalPayment, totalReturn, finalBalance),
          ],
        );
        return LayoutBuilder(builder: (context, c) {
          if (c.maxWidth >= 620) return table;
          return _HorizontalScroll(child: SizedBox(width: 620, child: table));
        });
      },
    );
  }

  // --- تبويب الأصناف المشتراة ---
  Widget _purchasedItemsTab(int supplierId) {
    return _tabSection(
      _DetailsTab.items,
      supplierId,
      emptyText: 'لا توجد أصناف مشتراة مسجلة من هذا المذخر بعد.',
      builder: (items) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _purchaseItemsGrid(items, true),
          const SizedBox(height: 12),
          _purchaseItemsTotals(items),
        ],
      ),
    );
  }

  double _number(dynamic value) => (value as num?)?.toDouble() ?? 0.0;

  /// يرتّب الحركات زمنياً (الأقدم فالأحدث) ويحسب الرصيد التراكمي بعد كل
  /// حركة، تماماً كما يُعرض كشف الحساب الورقي/المطبوع (الأقدم في الأعلى).
  /// كما يضيف فرزاً ثانوياً بالمعرّف عند تساوي التاريخ للحفاظ على ترتيب
  /// الإدخال الفعلي (مثال: فاتورة ثم دفعاتها بنفس اليوم).
  List<Map<String, dynamic>> _computeRunningBalance(
    List<Map<String, dynamic>> rows,
  ) {
    final chronological = List<Map<String, dynamic>>.from(rows)
      ..sort((a, b) {
        final dateA = DateTime.tryParse(a['date_time']?.toString() ?? '') ?? DateTime(1970);
        final dateB = DateTime.tryParse(b['date_time']?.toString() ?? '') ?? DateTime(1970);
        final cmp = dateA.compareTo(dateB);
        if (cmp != 0) return cmp;
        final idA = int.tryParse(a['id']?.toString() ?? '') ?? 0;
        final idB = int.tryParse(b['id']?.toString() ?? '') ?? 0;
        return idA.compareTo(idB);
      });

    double runningBalance = 0;
    final withBalance = <Map<String, dynamic>>[];

    for (final row in chronological) {
      runningBalance += _number(row['debt_added']);
      withBalance.add({...row, 'balance': runningBalance});
    }

    return withBalance;
  }

  /// نص عمود "البيان" لكل حركة. الملاحظات أُزيلت من الواجهة (تبقى في القاعدة/API
  /// فقط)، فالبيان من نوع الحركة ومرجعها.
  String _statementDescription(Map<String, dynamic> row) {
    final type = row['transaction_type']?.toString() ?? '';
    final reference = row['reference']?.toString().trim() ?? '';

    switch (type) {
      case 'invoice':
        if (reference.isEmpty || reference.contains('بدون رقم')) {
          return 'فاتورة شراء #${row['id'] ?? ''}';
        }
        return 'فاتورة رقم $reference';
      case 'payment':
        return 'دفعة نقدية للمذخر';
      case 'return':
        final items = row['items'] is List ? (row['items'] as List).length : 0;
        final base = reference.isNotEmpty ? reference : 'استرجاع بضاعة للمذخر';
        final withItems = items > 0 ? '$base ($items صنف)' : base;
        return withItems;
      case 'credit_applied':
        return '$reference: ${_formatAmount(_number(row['amount']))} د.ع';
      case 'refund':
        return 'استلام أموال من المذخر';
      default:
        return reference.isEmpty ? '-' : reference;
    }
  }

  String _formatAmount(double amount) {
    final raw = amount.toStringAsFixed(0);
    return raw.replaceAllMapped(RegExp(r'(?<!^)(?=(\d{3})+$)'), (_) => ',');
  }

  String _formatDate(String? value) {
    final date = DateTime.tryParse(value ?? '');
    if (date == null) return '-';
    return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
  }

  // ==========================================
  // عناصر الحوارات المشتركة
  // ==========================================
  static final ShapeBorder _dialogShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));

  Widget _dialogTitle(IconData icon, String text, {Color color = primaryDark, Color background = tealBg}) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textMain)),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: textSecondary),
        filled: true,
        fillColor: RC.faint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: borderCol),
          borderRadius: BorderRadius.circular(10),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: primaryDark, width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
      );

  ButtonStyle _primaryButton([Color color = primaryDark]) => ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );

  Widget _cancelButton(BuildContext ctx) => TextButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('إلغاء', style: TextStyle(color: textSecondary)),
      );

  // ==========================================
  // ✏️ تصحيح اسم المذخر (الاسم فقط)
  // ==========================================
  Future<void> _showEditNameDialog(int supplierId, String currentName, List<Map<String, dynamic>> all) async {
    final nameController = TextEditingController(text: currentName);
    String? error;
    var saving = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> save() async {
            final name = nameController.text.trim();
            if (name.isEmpty) {
              setDialogState(() => error = 'اسم المذخر مطلوب.');
              return;
            }
            if (name == currentName) {
              Navigator.pop(ctx);
              return;
            }
            // نفس قاعدة قائمة المذخر: الاسم يطابق المذخر بلا حساسية لحالة الأحرف.
            final taken = all.any((s) =>
                s['id'] != supplierId && (s['name']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase());
            if (taken) {
              setDialogState(() => error = 'يوجد مذخر آخر بنفس الاسم.');
              return;
            }
            setDialogState(() {
              saving = true;
              error = null;
            });
            try {
              await _repository.renameSupplier(isOnlineMode: widget.isOnlineMode, id: supplierId, name: name);
              if (ctx.mounted) Navigator.pop(ctx);
              _refreshData();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تم تعديل اسم المذخر.'), backgroundColor: success),
                );
              }
            } catch (e) {
              setDialogState(() {
                saving = false;
                error = e is PurchaseListException ? e.message : e.toString();
              });
            }
          }

          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              shape: _dialogShape,
              backgroundColor: cardBg,
              title: _dialogTitle(Icons.edit_outlined, 'تعديل اسم المذخر'),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('supplier-name-field'),
                      controller: nameController,
                      autofocus: true,
                      decoration: _inputDecoration('اسم المذخر'),
                      onSubmitted: (_) => saving ? null : save(),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      Text(error!, style: const TextStyle(color: danger, fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
              actions: [
                _cancelButton(ctx),
                ElevatedButton(
                  style: _primaryButton(),
                  onPressed: saving ? null : save,
                  child: const Text('حفظ'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ==========================================
  // 🧾 أصناف فاتورة الشراء
  // ==========================================
  /// أصناف الفاتورة (مع المسترجع من كل سطر) وفي أسفلها "إضافة دفعة" و"إضافة
  /// استرجاع". الفواتير اليدوية القديمة بلا أصناف: الدفع فقط.
  Future<void> _showInvoiceItemsDialog(
    BuildContext context,
    Map<String, dynamic> invoice,
    int supplierId,
    String supplierName,
  ) async {
    var current = invoice;
    late Future<List<Map<String, dynamic>>> itemsFuture;
    void load() => itemsFuture = _repository.getPurchaseInvoiceItems(
          purchaseInvoiceId: invoice['id'] as int,
          isOnlineMode: widget.isOnlineMode,
        );
    load();

    Future<void> reloadInvoice(StateSetter setDialogState) async {
      final rows = await _repository.getPurchaseInvoicesBySupplier(
        supplierId: supplierId,
        isOnlineMode: widget.isOnlineMode,
      );
      final fresh = rows.where((r) => r['id'] == invoice['id']);
      setDialogState(() {
        if (fresh.isNotEmpty) current = fresh.first;
        load();
      });
      _refreshData();
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final number = current['invoice_number']?.toString().trim() ?? '';
            final remaining = _number(current['remaining_amount']);
            return Directionality(
              textDirection: TextDirection.rtl,
              child: Dialog(
                shape: _dialogShape,
                backgroundColor: cardBg,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: (size.width * 0.85).clamp(360.0, 1100.0),
                    maxHeight: size.height * 0.85,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: FutureBuilder<List<Map<String, dynamic>>>(
                      future: itemsFuture,
                      builder: (context, snapshot) {
                        final items = snapshot.data ?? const <Map<String, dynamic>>[];
                        final loading = snapshot.connectionState == ConnectionState.waiting;
                        final canReturn = items.any((i) => i['current_stock'] != null);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: _dialogTitle(
                                    Icons.receipt_long_rounded,
                                    'أصناف الفاتورة ${number.isEmpty ? '#${current['id']}' : '#$number'} — $supplierName',
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'إغلاق',
                                  onPressed: () => Navigator.pop(ctx),
                                  icon: const Icon(Icons.close_rounded, color: textSecondary),
                                ),
                              ],
                            ),
                            const Divider(height: 24, color: borderCol),
                            Flexible(
                              child: loading
                                  ? const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: SkeletonBlock(height: 120, lines: 3),
                                    )
                                  : snapshot.hasError
                                      ? SectionError(error: snapshot.error!, onRetry: () => setDialogState(load))
                                      : items.isEmpty
                                          ? const EmptyState('لا توجد أصناف (فاتورة قديمة أُدخلت يدوياً).')
                                          : SingleChildScrollView(child: _purchaseItemsGrid(items, false, showReturned: true)),
                            ),
                            if (items.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              _purchaseItemsTotals(items),
                            ],
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                _StatChip('الإجمالي', '${_formatAmount(_number(current['total_amount']))} د.ع'),
                                _StatChip('المدفوع', '${_formatAmount(_number(current['paid_amount']))} د.ع'),
                                _StatChip('الاسترجاع', '${_formatAmount(_number(current['returned_amount']))} د.ع'),
                                if (_number(current['credit_applied']) > 0)
                                  _StatChip('خصم من رصيد سابق', '${_formatAmount(_number(current['credit_applied']))} د.ع'),
                                Text(
                                  'المتبقي: ${_formatAmount(remaining)} د.ع',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: remaining > 0 ? danger : success,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed: remaining <= 0
                                      ? null
                                      : () async {
                                          final saved = await _showPaymentDialog(ctx, supplierId, supplierName, current);
                                          if (saved) await reloadInvoice(setDialogState);
                                        },
                                  icon: const Icon(Icons.payments_rounded, size: 18),
                                  label: const Text('إضافة دفعة'),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: primaryDark,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                                if (items.isNotEmpty)
                                  FilledButton.icon(
                                    onPressed: loading || !canReturn
                                        ? null
                                        : () async {
                                            final saved = await showPurchaseReturnDialog(
                                              ctx,
                                              pharmacyId: widget.pharmacyId,
                                              isOnlineMode: widget.isOnlineMode,
                                              invoice: current,
                                              items: items,
                                            );
                                            if (saved) {
                                              await reloadInvoice(setDialogState);
                                              if (mounted) {
                                                ScaffoldMessenger.of(this.context).showSnackBar(
                                                  const SnackBar(
                                                    content: Text('تم تسجيل الاسترجاع وتحديث المخزون والرصيد.'),
                                                    backgroundColor: success,
                                                  ),
                                                );
                                              }
                                            }
                                          },
                                    icon: const Icon(Icons.keyboard_return_rounded, size: 18),
                                    label: const Text('إضافة استرجاع'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: RC.blue,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _purchaseItemsGrid(List<Map<String, dynamic>> items, bool showInvoiceColumns, {bool showReturned = false}) {
    return _Grid(
      columns: [
        if (showInvoiceColumns) const RCol('رقم الفاتورة', width: 100),
        if (showInvoiceColumns) const RCol('التاريخ', width: 92),
        const RCol('الصنف', width: 170),
        const RCol('الكمية المدفوعة', width: 90),
        const RCol('البونص / المجاني', width: 90),
        const RCol('سعر الشراء', width: 95),
        const RCol('الصلاحية', width: 92),
        const RCol('إجمالي السطر', width: 105),
        if (showReturned) const RCol('المسترجع', width: 80),
      ],
      rows: [
        for (final item in items) _purchaseItemRow(item, showInvoiceColumns, showReturned),
      ],
    );
  }

  List<Widget> _purchaseItemRow(Map<String, dynamic> item, bool showInvoiceColumns, bool showReturned) {
    final isFree = item['is_free'] == true;
    final invoiceDate = (item['invoice_date']?.toString().isNotEmpty ?? false)
        ? item['invoice_date'].toString()
        : item['invoice_created_at']?.toString();
    final returned = _number(item['returned_quantity']);
    return [
      if (showInvoiceColumns) _cell('#${item['invoice_number'] ?? ''}'),
      if (showInvoiceColumns) _cell(_formatDate(invoiceDate)),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _cell(item['trade_name']?.toString() ?? '', bold: true),
          if (isFree) const _Badge('مجاني', color: success, background: RC.greenBg),
        ],
      ),
      _cell(isFree ? '-' : '${_number(item['quantity']).toInt()}'),
      _cell('${_number(item['bonus_quantity']).toInt()}'),
      _cell(isFree ? '-' : _formatAmount(_number(item['buy_price']))),
      _cell(_formatDate(item['expiry_date']?.toString())),
      _cell(_formatAmount(_number(item['line_total']))),
      if (showReturned)
        _cell(returned > 0 ? '${returned.toInt()}' : '-', color: returned > 0 ? RC.blue : textSecondary, bold: true),
    ];
  }

  Widget _purchaseItemsTotals(List<Map<String, dynamic>> items) {
    var paidTotal = 0, bonusTotal = 0, freeCount = 0;
    var amountTotal = 0.0;
    for (final item in items) {
      paidTotal += _number(item['quantity']).toInt();
      bonusTotal += _number(item['bonus_quantity']).toInt();
      if (item['is_free'] == true) freeCount++;
      amountTotal += _number(item['line_total']);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: RC.faint,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderCol),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 8,
        children: [
          Text('عدد الأصناف: ${items.length}', style: const TextStyle(fontWeight: FontWeight.w700, color: textMain)),
          Text('الكمية المدفوعة: $paidTotal', style: const TextStyle(color: textMain)),
          Text('البونص / المجاني: $bonusTotal', style: const TextStyle(color: textMain)),
          if (freeCount > 0) Text('أصناف مجانية: $freeCount', style: const TextStyle(color: textMain)),
          Text(
            'الإجمالي: ${_formatAmount(amountTotal)} د.ع',
            style: const TextStyle(fontWeight: FontWeight.w800, color: primaryDark),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // 💵 حوار تسديد دفعة لفاتورة محددة
  // ==========================================
  Future<bool> _showPaymentDialog(
    BuildContext context,
    int supplierId,
    String supplierName,
    Map<String, dynamic> invoice,
  ) async {
    final amountController = TextEditingController();
    final invoiceId = invoice['id'] as int;
    final remaining = _number(invoice['remaining_amount']);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape: _dialogShape,
          backgroundColor: cardBg,
          title: _dialogTitle(Icons.payments_rounded, 'إضافة دفعة لفاتورة $supplierName'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('المتبقي: ${_formatAmount(remaining)} د.ع', style: const TextStyle(color: textSecondary)),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  decoration: _inputDecoration('المبلغ المسدد'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              ],
            ),
          ),
          actions: [
            _cancelButton(ctx),
            ElevatedButton(
              style: _primaryButton(),
              onPressed: () async {
                final double amount = double.tryParse(amountController.text) ?? 0.0;
                if (amount > 0) {
                  try {
                    await _repository.addPurchaseInvoicePayment(
                      pharmacyId: widget.pharmacyId,
                      isOnlineMode: widget.isOnlineMode,
                      supplierId: supplierId,
                      purchaseInvoiceId: invoiceId,
                      amount: amount,
                    );

                    if (ctx.mounted) Navigator.pop(ctx, true);
                    _refreshData();

                    if (mounted) {
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        const SnackBar(content: Text('تم تسجيل الدفعة بنجاح!'), backgroundColor: success),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(content: Text('خطأ أثناء تسجيل الدفعة: $e'), backgroundColor: danger),
                      );
                    }
                  }
                }
              },
              child: const Text('تأكيد التسديد'),
            ),
          ],
        ),
      ),
    );
    return saved == true;
  }

  // ==========================================
  // 📖 كشف الحساب — صفوف الجدول
  // ==========================================
  /// خلية جدول عامة تُستخدم داخل TableRow — بلا عرض ثابت، لأن عرض كل عمود
  /// يُحسب تلقائياً بواسطة Table نفسه عبر columnWidths.
  Widget _statementCell(
    Widget child, {
    AlignmentGeometry alignment = AlignmentDirectional.centerStart,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
  }) {
    return Padding(
      padding: padding,
      child: Align(alignment: alignment, child: child),
    );
  }

  // --- صف عناوين الأعمدة ---
  TableRow _statementHeaderRow() {
    Widget label(String text) => _statementCell(
          Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF4A5568)),
          ),
        );

    return TableRow(
      decoration: BoxDecoration(color: RC.headerBg, borderRadius: BorderRadius.circular(8)),
      children: [
        label('التاريخ'),
        label('البيان'),
        label('مدين (فاتورة / استلام)'),
        label('دائن - دفعة'),
        label('دائن - استرجاع'),
        label('الرصيد بعد الحركة'),
      ],
    );
  }

  // --- صف بيانات لحركة واحدة (فاتورة / دفعة / استرجاع) ---
  TableRow _statementRow(Map<String, dynamic> row, {bool expanded = false, VoidCallback? onToggle}) {
    final type = row['transaction_type']?.toString() ?? '';
    final isInvoice = type == 'invoice';
    final isPayment = type == 'payment';
    final isReturn = type == 'return';
    final isRefund = type == 'refund';
    final isCreditApplied = type == 'credit_applied';
    final returnItems = isReturn && row['items'] is List ? row['items'] as List : const [];

    final amount = _number(row['amount']);
    final balance = _number(row['balance']);

    final _Badge badge;
    if (isInvoice) {
      badge = const _Badge('فاتورة', color: Color(0xFF9A6B00), background: Color(0xFFFEF3C7));
    } else if (isPayment) {
      badge = const _Badge('دفعة', color: success, background: RC.greenBg);
    } else if (isRefund) {
      badge = const _Badge('استلام', color: Color(0xFF6D28D9), background: Color(0xFFEDE9FE));
    } else if (isCreditApplied) {
      badge = const _Badge('خصم رصيد', color: RC.blue, background: RC.blueBg);
    } else {
      badge = const _Badge('استرجاع', color: warning, background: RC.orangeBg);
    }

    Widget amountText(double v, Color color) {
      return Text(
        v == 0 ? '—' : _formatAmount(v),
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: v == 0 ? textSecondary : color),
      );
    }

    return TableRow(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEDF2F7)))),
      children: [
        _statementCell(
          Text(_formatDate(row['date_time']?.toString()), style: const TextStyle(fontSize: 12, color: textSecondary)),
        ),
        _statementCell(
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              badge,
              if (returnItems.isNotEmpty)
                InkWell(
                  onTap: onToggle,
                  child: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      size: 18, color: primaryDark),
                ),
              Text(
                _statementDescription(row),
                style: const TextStyle(fontSize: 12.5, color: textMain, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        _statementCell(amountText(isInvoice || isRefund ? amount : 0, textMain)),
        _statementCell(amountText(isPayment ? amount : 0, success)),
        _statementCell(amountText(isReturn ? amount : 0, warning)),
        _statementCell(
          Text(
            _balanceText(balance),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: _balanceColor(balance)),
          ),
        ),
      ],
    );
  }

  /// أدوية استرجاع (يظهر تحت سطره في كشف الحساب عند فتحه).
  TableRow _statementReturnItemsRow(Map<String, dynamic> row) {
    final items = (row['items'] as List).whereType<Map>().toList();
    return TableRow(
      decoration: const BoxDecoration(
        color: RC.faint,
        border: Border(bottom: BorderSide(color: Color(0xFFEDF2F7))),
      ),
      children: [
        const SizedBox(),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(24, 6, 6, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '• ${item['trade_name']} × ${_number(item['quantity']).toInt()}'
                    '${_number(item['credited_quantity']) < _number(item['quantity']) ? ' (${(_number(item['quantity']) - _number(item['credited_quantity'])).toInt()} بلا رصيد)' : ''}'
                    ' — ${_formatAmount(_number(item['credit_amount']))} د.ع',
                    style: const TextStyle(fontSize: 12, color: textMain),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(),
        const SizedBox(),
        const SizedBox(),
        const SizedBox(),
      ],
    );
  }

  /// الرصيد السالب = المذخر مدين للصيدلية: "لصالحك" بلون مختلف بدل رقم سالب.
  String _balanceText(double balance) =>
      balance < -0.001 ? 'لصالحك ${_formatAmount(-balance)}' : _formatAmount(balance);

  Color _balanceColor(double balance) => balance > 0.001 ? danger : (balance < -0.001 ? success : textSecondary);

  // --- صف الإجمالي أسفل الجدول ---
  TableRow _statementTotalsRow(
    double totalInvoice,
    double totalPayment,
    double totalReturn,
    double finalBalance,
  ) {
    Widget total(double v, {Color? color}) => Text(
          _formatAmount(v),
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: color ?? textMain),
        );

    return TableRow(
      decoration: BoxDecoration(color: RC.headerBg, borderRadius: BorderRadius.circular(8)),
      children: [
        _statementCell(const SizedBox()),
        _statementCell(
          const Text('الإجمالي', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: textMain)),
        ),
        _statementCell(total(totalInvoice)),
        _statementCell(total(totalPayment, color: success)),
        _statementCell(total(totalReturn, color: warning)),
        _statementCell(
          Text(
            finalBalance < -0.001 ? 'رصيد لصالحك: ${_formatAmount(-finalBalance)}' : _formatAmount(finalBalance),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _balanceColor(finalBalance)),
          ),
        ),
      ],
    );
  }

  // ==========================================
  // 💰 استلام أموال من المذخر
  // ==========================================
  /// "استلام أموال من المذخر": المبلغ افتراضياً كامل الرصيد، والجزئي مسموح،
  /// ولا يتجاوز الرصيد المتاح أبداً (يُتحقق منه أيضاً عند الحفظ).
  Future<void> _showReceiveRefundDialog(
    BuildContext context,
    int supplierId,
    String supplierName,
    double availableCredit,
  ) async {
    final amountController = TextEditingController(text: availableCredit.toStringAsFixed(availableCredit % 1 == 0 ? 0 : 2));
    var date = DateTime.now();
    String? error;
    var saving = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            shape: _dialogShape,
            backgroundColor: cardBg,
            title: _dialogTitle(Icons.savings_outlined, 'استلام أموال من $supplierName',
                color: success, background: RC.greenBg),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('رصيدك لدى المذخر: ${_formatAmount(availableCredit)} د.ع',
                      style: const TextStyle(color: success, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: _inputDecoration('المبلغ المستلم'),
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: date,
                        firstDate: DateTime(DateTime.now().year - 3),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) setDialogState(() => date = picked);
                    },
                    child: InputDecorator(
                      decoration: _inputDecoration('التاريخ'),
                      child: Text(_formatDate(date.toIso8601String())),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(error!, style: const TextStyle(color: danger, fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            ),
            actions: [
              _cancelButton(ctx),
              ElevatedButton(
                style: _primaryButton(success),
                onPressed: saving
                    ? null
                    : () async {
                        final amount = double.tryParse(amountController.text.trim()) ?? 0;
                        if (amount <= 0) {
                          setDialogState(() => error = 'أدخل مبلغاً أكبر من صفر.');
                          return;
                        }
                        if (amount > availableCredit + 0.001) {
                          setDialogState(() => error = 'المبلغ أكبر من رصيدك لدى المذخر.');
                          return;
                        }
                        setDialogState(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          await _repository.receiveSupplierRefund(
                            pharmacyId: widget.pharmacyId,
                            isOnlineMode: widget.isOnlineMode,
                            supplierId: supplierId,
                            amount: amount,
                            receivedDate: date,
                          );
                          if (ctx.mounted) Navigator.pop(ctx);
                          _refreshData();
                          if (mounted) {
                            ScaffoldMessenger.of(this.context).showSnackBar(
                              const SnackBar(content: Text('تم تسجيل المبلغ المستلم من المذخر.'), backgroundColor: success),
                            );
                          }
                        } catch (e) {
                          setDialogState(() {
                            saving = false;
                            error = e is PurchaseListException ? e.message : e.toString();
                          });
                        }
                      },
                child: const Text('تأكيد الاستلام'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================
  // 🗑️ تأكيد حذف المذخر
  // ==========================================
  void _confirmDeleteSupplier(int id, String name) {
    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape: _dialogShape,
          backgroundColor: cardBg,
          title: _dialogTitle(Icons.delete_outline_rounded, 'تأكيد الحذف', color: danger, background: RC.redBg),
          content: Text(
            'هل أنت متأكد من حذف المذخر "$name"؟ سيتم حذف جميع الفواتير والسجلات المرتبطة به.',
            style: const TextStyle(color: textSecondary),
          ),
          actions: [
            _cancelButton(ctx),
            ElevatedButton(
              style: _primaryButton(danger),
              onPressed: () async {
                try {
                  await _repository.deleteSupplier(isOnlineMode: widget.isOnlineMode, id: id);
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (_selectedId == id) _selectedId = null;
                  _refreshData();

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('تم حذف المذخر "$name" بنجاح.'), backgroundColor: warning),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('خطأ أثناء الحذف: $e'), backgroundColor: danger),
                    );
                  }
                }
              },
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة رقم في ملخص المذاخر (نفس شكل KpiCard في التقارير).
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({super.key, required this.title, required this.icon, required this.value, this.hint, this.valueColor});

  final String title;
  final IconData icon;

  /// null أثناء التحميل.
  final String? value;
  final String? hint;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 118),
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(color: const Color(0xFFE8F8F5), borderRadius: BorderRadius.circular(9)),
                child: Icon(icon, color: RC.tealDark, size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title, style: const TextStyle(fontSize: 13, color: RC.muted, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (value == null)
            const SkeletonBlock(height: 44, lines: 2)
          else ...[
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                value!,
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold, color: valueColor ?? RC.text),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint!, style: const TextStyle(fontSize: 11.5, color: RC.muted)),
            ],
          ],
        ],
      ),
    );
  }
}

/// شارة ملوّنة (رصيد/حالة/نوع حركة). بخلاف Tag في التقارير، النص يلتف داخل
/// خلايا الجداول الضيقة بدل أن يتجاوزها.
class _Badge extends StatelessWidget {
  const _Badge(this.text, {required this.color, required this.background});

  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(50)),
      child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: color)),
    );
  }
}

/// رقم صغير بعنوان داخل حوار الفاتورة.
class _StatChip extends StatelessWidget {
  const _StatChip(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text('$label: $value', style: const TextStyle(color: RC.text, fontSize: 13));
  }
}

/// تمرير أفقي بشريط ظاهر (السحب بالفأرة غير مفعّل على سطح المكتب).
class _HorizontalScroll extends StatefulWidget {
  const _HorizontalScroll({required this.child});

  final Widget child;

  @override
  State<_HorizontalScroll> createState() => _HorizontalScrollState();
}

class _HorizontalScrollState extends State<_HorizontalScroll> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 10),
        child: widget.child,
      ),
    );
  }
}

/// جدول بنفس رأس جداول التقارير، بصفوف قابلة للنقر. النصوص تلتف داخل
/// الخلايا (بلا "...")، ويُمرَّر أفقياً عندما يضيق العرض عن مجموع الأعمدة.
class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.rows, this.onTap, this.selectedIndex});

  final List<RCol> columns;
  final List<List<Widget>> rows;
  final void Function(int index)? onTap;
  final int? selectedIndex;

  @override
  Widget build(BuildContext context) {
    final minWidth = columns.fold<double>(0, (s, c) => s + c.width);
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth > minWidth ? c.maxWidth : minWidth;
      final scale = width / minWidth;
      Widget cell(int i, Widget child) => SizedBox(
            width: columns[i].width * scale,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              child: Align(alignment: AlignmentDirectional.centerStart, child: child),
            ),
          );
      final table = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(color: RC.headerBg, borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              for (var i = 0; i < columns.length; i++)
                cell(
                  i,
                  Text(
                    columns[i].label,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF4A5568)),
                  ),
                ),
            ]),
          ),
          for (var r = 0; r < rows.length; r++)
            Material(
              color: r == selectedIndex ? const Color(0xFFE8F8F5) : Colors.transparent,
              child: InkWell(
                onTap: onTap == null ? null : () => onTap!(r),
                child: Container(
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEDF2F7)))),
                  child: Row(children: [for (var i = 0; i < columns.length; i++) cell(i, rows[r][i])]),
                ),
              ),
            ),
        ],
      );
      if (width <= c.maxWidth) return table;
      return _HorizontalScroll(child: SizedBox(width: width, child: table));
    });
  }
}
