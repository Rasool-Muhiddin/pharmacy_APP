import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/purchase_list.dart';
import '../repository/suppliers_repository.dart';
import 'purchase_return_dialog.dart';

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
  late Future<double> _totalDebtFuture;
  late Future<Map<String, dynamic>?> _topSupplierFuture;
  final Set<int> _expandedSupplierIds = <int>{};
  String _searchQuery = '';
  final SuppliersRepository _repository = SuppliersRepository.instance;

  // الهوية البصرية وتناسق الألوان
  static const Color primary = Color(0xFF1ABC9C);
  static const Color primaryDark = Color(0xFF16A085);
  static const Color bgCanvas = Color(0xFFF4F7F6);
  static const Color cardBg = Colors.white;
  static const Color borderCol = Color(0xFFE2E8F0);
  static const Color textMain = Color(0xFF2C3E50);
  static const Color textSecondary = Color(0xFF7F8C8D);
  static const Color success = Color(0xFF2ECC71);
  static const Color danger = Color(0xFFE74C3C);
  static const Color warning = Color(0xFFF39C12);

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
      _totalDebtFuture = _repository.getTotalSuppliersDebt(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
      );
      _topSupplierFuture = _repository.getTopSupplier(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: bgCanvas,
        appBar: AppBar(
          backgroundColor: cardBg,
          foregroundColor: textMain,
          elevation: 0,
          title: const Text(
            'إدارة المذاخر والمشتريات',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          actions: [
            IconButton(
              tooltip: 'تحديث البيانات',
              onPressed: _refreshData,
              icon: const Icon(Icons.refresh_rounded, color: primaryDark),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: RefreshIndicator(
          color: primary,
          onRefresh: () async => _refreshData(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                _buildAnalyticsCards(),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        textAlign: TextAlign.right,
                        onChanged: (value) =>
                            setState(() => _searchQuery = value.trim()),
                        decoration: InputDecoration(
                          hintText: 'بحث باسم المذخر...',
                          prefixIcon: const Icon(Icons.search_rounded),
                          filled: true,
                          fillColor: cardBg,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: borderCol),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: borderCol),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: () => _showAddSupplierDialog(context),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('إضافة مذخر جديد'),
                      style: FilledButton.styleFrom(
                        backgroundColor: primary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSuppliersList(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAnalyticsCards() {
    final debtCard = FutureBuilder<double>(
      future: _totalDebtFuture,
      builder: (_, snapshot) => _analyticsCard(
        title: 'إجمالي الديون للمذاخر',
        value: '${_formatAmount(snapshot.data ?? 0.0)} د.ع',
        icon: Icons.attach_money_rounded,
        accent: danger,
      ),
    );
    final topCard = FutureBuilder<Map<String, dynamic>?>(
      future: _topSupplierFuture,
      builder: (_, snapshot) => _analyticsCard(
        title: 'أكثر مذخر تم الشراء منه',
        value: snapshot.data?['name']?.toString() ?? 'لا يوجد',
        icon: Icons.apartment_rounded,
        accent: primary,
      ),
    );
    return LayoutBuilder(builder: (_, constraints) {
      if (constraints.maxWidth < 620) {
        return Column(children: [debtCard, const SizedBox(height: 12), topCard]);
      }
      return Row(children: [Expanded(child: debtCard), const SizedBox(width: 16), Expanded(child: topCard)]);
    });
  }

  Widget _analyticsCard({required String title, required String value, required IconData icon, required Color accent}) {
    return Container(
      height: 122,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: BorderDirectional(end: BorderSide(color: accent, width: 5)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .04), blurRadius: 12, offset: const Offset(0, 3))],
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: accent.withValues(alpha: .14), shape: BoxShape.circle),
          child: Icon(icon, color: accent, size: 27),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: const TextStyle(color: textSecondary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 7),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: textMain, fontSize: 20, fontWeight: FontWeight.w800)),
          ],
        )),
      ]),
    );
  }

  Widget _buildSuppliersList() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _suppliersFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator(color: primary)));
        }
        final suppliers = (snapshot.data ?? []).where((supplier) {
          return supplier['name'].toString().toLowerCase().contains(_searchQuery.toLowerCase());
        }).toList();
        if (suppliers.isEmpty) {
          return Container(
            width: double.infinity, padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(16), border: Border.all(color: borderCol)),
            child: const Column(children: [
              Icon(Icons.storefront_outlined, size: 48, color: textSecondary),
              SizedBox(height: 12), Text('لا يوجد مذاخر مطابقة.', style: TextStyle(color: textSecondary)),
            ]),
          );
        }
        return ListView.separated(
          shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          itemCount: suppliers.length, separatorBuilder: (_, __) => const SizedBox(height: 16),
          itemBuilder: (_, index) => _buildSupplierCard(suppliers[index]),
        );
      },
    );
  }

  Widget _buildSupplierCard(Map<String, dynamic> supplier) {
    final supplierId = supplier['id'] as int;
    final supplierName = supplier['name']?.toString() ?? 'بدون اسم';
    final debt = _number(supplier['remaining_debt']);
    // رصيد سالب = المذخر مدين للصيدلية: يُعرض "رصيد لصالحك" بدل الدين.
    final credit = _number(supplier['credit_balance']);
    final availableCredit = _number(supplier['available_credit']);
    final purchases = _number(supplier['total_purchases']);
    final count = (supplier['invoice_count'] as num?)?.toInt() ?? 0;
    final expanded = _expandedSupplierIds.contains(supplierId);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC9E7E7)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            color: const Color(0xFFD6EAF5),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          supplierName,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: textMain,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${supplier['phone'] ?? 'غير محدد'}  ☎',
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: textSecondary),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert_rounded,
                      color: primaryDark,
                    ),
                    onSelected: (value) {
                      if (value == 'statement') {
                        _showStyledStatementOfAccount(
                          context,
                          supplierId,
                          supplierName,
                        );
                      }

                      if (value == 'purchased_items') {
                        _showSupplierPurchasedItemsDialog(
                          context,
                          supplierId,
                          supplierName,
                        );
                      }

                      if (value == 'receive_refund') {
                        _showReceiveRefundDialog(context, supplierId, supplierName, availableCredit);
                      }

                      if (value == 'delete') {
                        _confirmDeleteSupplier(supplierId, supplierName);
                      }
                    },
                    itemBuilder: (_) => [
                      if (availableCredit > 0)
                        const PopupMenuItem(
                          value: 'receive_refund',
                          child: Text('استلام أموال من المذخر'),
                        ),
                      const PopupMenuItem(
                        value: 'statement',
                        child: Text('كشف حساب'),
                      ),
                      const PopupMenuItem(
                        value: 'purchased_items',
                        child: Text('الأصناف المشتراة'),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('حذف المذخر'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: LayoutBuilder(
              builder: (_, constraints) {
                final stats = [
                  _statCard('عدد الفواتير', '$count', textMain),
                  _statCard(
                    'إجمالي المشتريات',
                    _formatAmount(purchases),
                    textMain,
                  ),
                  credit > 0
                      ? _statCard('رصيد لصالحك', _formatAmount(credit), success)
                      : _statCard(
                          'المتبقي',
                          _formatAmount(debt),
                          debt > 0 ? danger : success,
                        ),
                ];

                if (constraints.maxWidth < 560) {
                  return Column(
                    children: [
                      stats[0],
                      const SizedBox(height: 10),
                      stats[1],
                      const SizedBox(height: 10),
                      stats[2],
                    ],
                  );
                }

                return Row(
                  children: [
                    Expanded(child: stats[0]),
                    const SizedBox(width: 12),
                    Expanded(child: stats[1]),
                    const SizedBox(width: 12),
                    Expanded(child: stats[2]),
                  ],
                );
              },
            ),
          ),
          Container(
            width: double.infinity,
            color: const Color(0xFFF1F8F8),
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 12,
            ),
            alignment: AlignmentDirectional.centerEnd,
            child: OutlinedButton(
              onPressed: () => setState(() {
                expanded
                    ? _expandedSupplierIds.remove(supplierId)
                    : _expandedSupplierIds.add(supplierId);
              }),
              style: OutlinedButton.styleFrom(
                foregroundColor: primaryDark,
                side: const BorderSide(color: primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              child: Text(
                expanded ? 'إخفاء التفاصيل' : 'عرض التفاصيل والفواتير',
              ),
            ),
          ),
          if (expanded) _buildInvoicesSection(supplierId, supplierName, availableCredit),
        ],
      ),
    );
  }
  Widget _statCard(String label, String value, Color valueColor) {
    return Container(
      width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 12),
      decoration: BoxDecoration(color: const Color(0xFFF0F4F5), borderRadius: BorderRadius.circular(9)),
      child: Column(children: [
        Text(label, style: const TextStyle(color: textSecondary, fontSize: 13)), const SizedBox(height: 8),
        Text(value, style: TextStyle(color: valueColor, fontWeight: FontWeight.w800, fontSize: 17)),
      ]),
    );
  }

Widget _buildInvoicesSection(int supplierId, String supplierName, double availableCredit) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: _repository.getPurchaseInvoicesBySupplier(
        supplierId: supplierId,
        isOnlineMode: widget.isOnlineMode,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(color: primary)),
          );
        }

        final invoices = snapshot.data ?? [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'فواتير $supplierName',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: textMain,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (availableCredit > 0) ...[
                  FilledButton.icon(
                    onPressed: () => _showReceiveRefundDialog(context, supplierId, supplierName, availableCredit),
                    icon: const Icon(Icons.savings_outlined, size: 16),
                    label: const Text('استلام أموال من المذخر'),
                    style: FilledButton.styleFrom(
                      backgroundColor: success,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                OutlinedButton.icon(
                  onPressed: () => _showSupplierPurchasedItemsDialog(
                    context,
                    supplierId,
                    supplierName,
                  ),
                  icon: const Icon(Icons.medication_outlined, size: 16),
                  label: const Text('الأصناف المشتراة'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primaryDark,
                    side: const BorderSide(color: primary),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // الفواتير تُنشأ حصراً من شاشة المخزون (قائمة مذخر)؛ هنا الدفعات والاسترجاعات فقط.
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 15, color: textSecondary),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'تُضاف فواتير الشراء من شاشة المخزون عبر "إضافة قائمة مذخر". افتح الفاتورة لعرض أصنافها وإضافة دفعة أو استرجاع.',
                    style: TextStyle(color: textSecondary, fontSize: 12.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (invoices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'لا توجد فواتير لهذا المذخر.',
                    style: TextStyle(color: textSecondary),
                  ),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  showCheckboxColumn: false,
                  headingRowColor: WidgetStateProperty.all(
                    const Color(0xFFF0F4F5),
                  ),
                  columns: const [
                    DataColumn(label: Text('رقم الفاتورة')),
                    DataColumn(label: Text('التاريخ')),
                    DataColumn(label: Text('الأصناف')),
                    DataColumn(label: Text('المبلغ الأصلي')),
                    DataColumn(label: Text('الاسترجاع')),
                    DataColumn(label: Text('الصافي')),
                    DataColumn(label: Text('المدفوع')),
                    DataColumn(label: Text('المتبقي')),
                    DataColumn(label: Text('الحالة')),
                  ],
                  rows: invoices.map((invoice) {
                    final id = invoice['id'] as int;
                    final original = _number(invoice['total_amount']);
                    final returned = _number(invoice['returned_amount']);
                    final net = _number(invoice['net_amount']);
                    final paid = _number(invoice['paid_amount']);
                    // المتبقي لا يقل عن 0: فائض الاسترجاع يذهب لرصيد المذخر.
                    final remaining = _number(invoice['remaining_amount']);
                    final settled = remaining <= 0.001;
                    final statusColor = settled ? success : warning;
                    final statusText = settled ? 'مؤداة' : 'مؤجلة';

                    final invNum = invoice['invoice_number']?.toString().trim();
                    final displayNum = (invNum != null && invNum.isNotEmpty) ? '#$invNum' : '#$id';
                    // فواتير القوائم تحمل أصنافها؛ اليدوية القديمة بلا أصناف.
                    final itemCount = _number(invoice['item_count']).toInt();
                    final fromList = invoice['source'] == 'inventory_list';
                    final invoiceDate = (invoice['invoice_date']?.toString().isNotEmpty ?? false)
                        ? invoice['invoice_date'].toString()
                        : invoice['created_at']?.toString();

                    return DataRow(
                      // النقر على الفاتورة يفتح أصنافها، ومنها الدفع والاسترجاع.
                      onSelectChanged: (_) => _showInvoiceItemsDialog(context, invoice, supplierId, supplierName),
                      cells: [
                        DataCell(
                          Text(
                            displayNum,
                            style: const TextStyle(
                              color: primaryDark,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                        DataCell(Text(_formatDate(invoiceDate))),
                        DataCell(Text(fromList ? '$itemCount' : '-')),
                        DataCell(Text(_formatAmount(original))),
                        DataCell(Text(_formatAmount(returned))),
                        DataCell(Text(_formatAmount(net))),
                        DataCell(Text(_formatAmount(paid))),
                        DataCell(Text(_formatAmount(remaining))),
                        DataCell(
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: .14),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              statusText,
                              style: TextStyle(color: statusColor, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
          ],
        );
      },
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
        final dateA = DateTime.tryParse(a['date_time']?.toString() ?? '') ??
            DateTime(1970);
        final dateB = DateTime.tryParse(b['date_time']?.toString() ?? '') ??
            DateTime(1970);
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
  // ➕ 1. حوار إضافة مذخر جديد
  // ==========================================
  void _showAddSupplierDialog(BuildContext context) {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: cardBg,
        title: const Text('إضافة مذخر جديد', style: TextStyle(color: textMain, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'اسم المذخر',
                labelStyle: const TextStyle(color: textSecondary),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: primary, width: 2),
                  borderRadius: BorderRadius.circular(10),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: borderCol),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phoneController,
              decoration: InputDecoration(
                labelText: 'رقم الهاتف',
                labelStyle: const TextStyle(color: textSecondary),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: primary, width: 2),
                  borderRadius: BorderRadius.circular(10),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: borderCol),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              keyboardType: TextInputType.phone,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(color: textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final name = nameController.text.trim();

              if (name.isEmpty) return;

              try {
                final supplierId = await _repository.insertSupplier(
                  pharmacyId: widget.pharmacyId,
                  isOnlineMode: widget.isOnlineMode,
                  data: {
                    'name': name,
                    'phone': phoneController.text.trim(),
                    'created_at': DateTime.now().toIso8601String(),
                  },
                );

                debugPrint(
                  'تمت إضافة المذخر: id=$supplierId, '
                  'pharmacyId=${widget.pharmacyId}',
                );

                if (ctx.mounted) Navigator.pop(ctx);

                _refreshData();

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('تمت إضافة المذخر "$name" بنجاح!'),
                      backgroundColor: success,
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              } catch (e, stackTrace) {
                debugPrint('خطأ أثناء إضافة المذخر: $e');
                debugPrintStack(stackTrace: stackTrace);

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('حدث خطأ أثناء الإضافة: $e'),
                      backgroundColor: danger,
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
              }
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // 🧾 2. أصناف فاتورة الشراء / الأصناف المشتراة من المذخر
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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                                const CircleAvatar(
                                  backgroundColor: Color(0xFFE6F7F5),
                                  child: Icon(Icons.receipt_long_rounded, color: primary),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'أصناف الفاتورة ${number.isEmpty ? '#${current['id']}' : '#$number'} — $supplierName',
                                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: textMain),
                                  ),
                                ),
                                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close_rounded)),
                              ],
                            ),
                            const Divider(height: 24),
                            Flexible(
                              child: loading
                                  ? const Padding(
                                      padding: EdgeInsets.all(32),
                                      child: Center(child: CircularProgressIndicator(color: primary)),
                                    )
                                  : snapshot.hasError
                                      ? Text(snapshot.error.toString(), style: const TextStyle(color: danger))
                                      : items.isEmpty
                                          ? const Padding(
                                              padding: EdgeInsets.all(32),
                                              child: Text(
                                                'لا توجد أصناف (فاتورة قديمة أُدخلت يدوياً).',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(color: textSecondary),
                                              ),
                                            )
                                          : _buildPurchaseItemsTable(items, false, showReturned: true),
                            ),
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 20,
                              runSpacing: 6,
                              children: [
                                Text('الإجمالي: ${_formatAmount(_number(current['total_amount']))} د.ع'),
                                Text('المدفوع: ${_formatAmount(_number(current['paid_amount']))} د.ع'),
                                Text('الاسترجاع: ${_formatAmount(_number(current['returned_amount']))} د.ع'),
                                if (_number(current['credit_applied']) > 0)
                                  Text('خصم من رصيد سابق: ${_formatAmount(_number(current['credit_applied']))} د.ع'),
                                Text(
                                  'المتبقي: ${_formatAmount(remaining)} د.ع',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: remaining > 0 ? danger : success,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
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
                                  style: FilledButton.styleFrom(backgroundColor: success),
                                ),
                                const SizedBox(width: 10),
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
                                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2980B9)),
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

  void _showSupplierPurchasedItemsDialog(
    BuildContext context,
    int supplierId,
    String supplierName,
  ) {
    _showPurchaseItemsDialog(
      context,
      title: 'الأصناف المشتراة من $supplierName',
      future: _repository.getSupplierPurchasedItems(
        supplierId: supplierId,
        isOnlineMode: widget.isOnlineMode,
      ),
      showInvoiceColumns: true,
      emptyText: 'لا توجد أصناف مشتراة مسجلة من هذا المذخر بعد.',
    );
  }

  void _showPurchaseItemsDialog(
    BuildContext context, {
    required String title,
    required Future<List<Map<String, dynamic>>> future,
    required bool showInvoiceColumns,
    required String emptyText,
  }) {
    showDialog(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (size.width * 0.85).clamp(360.0, 1100.0),
                maxHeight: size.height * 0.85,
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const CircleAvatar(
                          backgroundColor: Color(0xFFE6F7F5),
                          child: Icon(Icons.receipt_long_rounded, color: primary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: textMain,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    Flexible(
                      child: FutureBuilder<List<Map<String, dynamic>>>(
                        future: future,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(child: CircularProgressIndicator(color: primary)),
                            );
                          }
                          if (snapshot.hasError) {
                            return Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                snapshot.error.toString(),
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: danger),
                              ),
                            );
                          }
                          final items = snapshot.data ?? [];
                          if (items.isEmpty) {
                            return Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                emptyText,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: textSecondary),
                              ),
                            );
                          }
                          return _buildPurchaseItemsTable(items, showInvoiceColumns);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPurchaseItemsTable(List<Map<String, dynamic>> items, bool showInvoiceColumns, {bool showReturned = false}) {
    var paidTotal = 0, bonusTotal = 0, freeCount = 0;
    var amountTotal = 0.0;
    for (final item in items) {
      paidTotal += _number(item['quantity']).toInt();
      bonusTotal += _number(item['bonus_quantity']).toInt();
      if (item['is_free'] == true) freeCount++;
      amountTotal += _number(item['line_total']);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(const Color(0xFFF0F4F5)),
                columns: [
                  if (showInvoiceColumns) const DataColumn(label: Text('رقم الفاتورة')),
                  if (showInvoiceColumns) const DataColumn(label: Text('التاريخ')),
                  const DataColumn(label: Text('الصنف')),
                  const DataColumn(label: Text('الكمية المدفوعة'), numeric: true),
                  const DataColumn(label: Text('البونص / المجاني'), numeric: true),
                  const DataColumn(label: Text('سعر الشراء'), numeric: true),
                  const DataColumn(label: Text('الصلاحية')),
                  const DataColumn(label: Text('إجمالي السطر'), numeric: true),
                  if (showReturned) const DataColumn(label: Text('المسترجع'), numeric: true),
                ],
                rows: items.map((item) {
                  final isFree = item['is_free'] == true;
                  final invoiceDate = (item['invoice_date']?.toString().isNotEmpty ?? false)
                      ? item['invoice_date'].toString()
                      : item['invoice_created_at']?.toString();
                  return DataRow(
                    cells: [
                      if (showInvoiceColumns) DataCell(Text('#${item['invoice_number'] ?? ''}')),
                      if (showInvoiceColumns) DataCell(Text(_formatDate(invoiceDate))),
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item['trade_name']?.toString() ?? '',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            if (isFree) ...[
                              const SizedBox(width: 8),
                              _freeBadge(),
                            ],
                          ],
                        ),
                      ),
                      DataCell(Text(isFree ? '-' : '${_number(item['quantity']).toInt()}')),
                      DataCell(Text('${_number(item['bonus_quantity']).toInt()}')),
                      DataCell(Text(isFree ? '-' : _formatAmount(_number(item['buy_price'])))),
                      DataCell(Text(_formatDate(item['expiry_date']?.toString()))),
                      DataCell(Text(_formatAmount(_number(item['line_total'])))),
                      if (showReturned)
                        DataCell(Text(
                          _number(item['returned_quantity']) > 0 ? '${_number(item['returned_quantity']).toInt()}' : '-',
                          style: TextStyle(
                            color: _number(item['returned_quantity']) > 0 ? const Color(0xFF2980B9) : textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        )),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F8F8),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              Text('عدد الأصناف: ${items.length}', style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('الكمية المدفوعة: $paidTotal'),
              Text('البونص / المجاني: $bonusTotal'),
              if (freeCount > 0) Text('أصناف مجانية: $freeCount'),
              Text(
                'الإجمالي: ${_formatAmount(amountTotal)} د.ع',
                style: const TextStyle(fontWeight: FontWeight.w800, color: primaryDark),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _freeBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: success.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        'مجاني',
        style: TextStyle(color: success, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }

  // ==========================================
  // 💵 3. حوار تسديد دفعة لفاتورة محددة
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
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: cardBg,
        title: Text('إضافة دفعة لفاتورة $supplierName', style: const TextStyle(color: textMain, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text('المتبقي: ${_formatAmount(remaining)} د.ع', style: const TextStyle(color: textSecondary)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountController,
              decoration: InputDecoration(
                labelText: 'المبلغ المسدد',
                labelStyle: const TextStyle(color: textSecondary),
                enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: borderCol), borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: primary, width: 2), borderRadius: BorderRadius.circular(10)),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء', style: TextStyle(color: textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: success,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
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
                      const SnackBar(
                        content: Text('تم تسجيل الدفعة بنجاح!'),
                        backgroundColor: success,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
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
    );
    return saved == true;
  }

  // ==========================================
  // 📖 كشف حساب المذخر — نافذة منتصف الشاشة (Dialog) بدل الـ Bottom Sheet
  // ==========================================
  // ملاحظة: التطبيق هنا واجهة ويب/سطح مكتب (Desktop/Web layout)، لذلك تم
  // استبدال showModalBottomSheet + DraggableScrollableSheet — المصمم أصلاً
  // لتطبيقات الموبايل ويعتمد على أبعاد الشاشة الكاملة من الأسفل — بنافذة
  // showDialog عادية تظهر في المنتصف وبأبعاد ثابتة، وهذا يحل المشاكل الثلاث
  // معاً: (1) الظهور من الأسفل بدل المنتصف، (2) عدم استقرار القياسات داخل
  // تخطيط الشريط الجانبي مما كان يُفرغ المحتوى، (3) زر الإغلاق X الذي كان
  // يستخدم الـ context الخاص بالشاشة الأصلية بدل الـ context الحقيقي
  // لنافذة الحوار نفسها.
  void _showStyledStatementOfAccount(
    BuildContext context,
    int supplierId,
    String supplierName,
  ) {
    // استرجاعات مفتوحة لعرض أدويتها (المفتاح = معرّف الاسترجاع).
    final expandedReturns = <Object?>{};
    final statementFuture = _repository.getSupplierStatementOfAccount(
      supplierId: supplierId,
      isOnlineMode: widget.isOnlineMode,
    );
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        final screenSize = MediaQuery.of(dialogContext).size;
        final dialogWidth =
            screenSize.width < 880 ? screenSize.width * 0.94 : 860.0;
        final dialogMaxHeight = screenSize.height * 0.85;

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: dialogWidth,
                maxHeight: dialogMaxHeight,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Material(
                  color: cardBg,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _statementTopBar(dialogContext, supplierName),
                      Flexible(
                        child: StatefulBuilder(
                          builder: (_, setStatementState) => FutureBuilder<List<Map<String, dynamic>>>(
                          future: statementFuture,
                          builder: (futureCtx, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const SizedBox(
                                height: 200,
                                child: Center(
                                  child: CircularProgressIndicator(
                                      color: primary),
                                ),
                              );
                            }
                            if (snapshot.hasError) {
                              return SizedBox(
                                height: 200,
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Text(
                                      'حدث خطأ أثناء تحميل كشف الحساب:\n${snapshot.error}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: danger),
                                    ),
                                  ),
                                ),
                              );
                            }

                            final statement =
                                _computeRunningBalance(snapshot.data ?? []);

                            if (statement.isEmpty) {
                              return const SizedBox(
                                height: 200,
                                child: Center(
                                  child: Text(
                                    'لا توجد تعاملات مسجلة لهذا المذخر.',
                                    style: TextStyle(color: textSecondary),
                                  ),
                                ),
                              );
                            }

                            double totalInvoice = 0;
                            double totalPayment = 0;
                            double totalReturn = 0;
                            for (final row in statement) {
                              final type =
                                  row['transaction_type']?.toString();
                              final amount = _number(row['amount']);
                              // المبلغ المستلم من المذخر يُعرض في عمود المدين (يرفع الرصيد).
                              if (type == 'invoice' || type == 'refund') totalInvoice += amount;
                              if (type == 'payment') totalPayment += amount;
                              if (type == 'return') totalReturn += amount;
                            }
                            final finalBalance =
                                _number(statement.last['balance']);

                            // ملاحظة مهمّة: تم استبدال أسلوب "أعمدة بعرض ثابت
                            // داخل Row + تمرير أفقي (SingleChildScrollView
                            // متداخل عمودي/أفقي)" بأسلوب Table القياسي في
                            // Flutter. التمرير الأفقي المتداخل مع Flexible
                            // وmainAxisSize.min كان هو سبب أخطاء
                            // "RenderBox was not laid out" التي ظهرت في الـ
                            // terminal — لأن حساب القيود بين الطبقات
                            // المتعامدة يصبح غير محدد في حالات معينة. الجدول
                            // (Table) يحسب عرض كل عمود تلقائياً بشكل مضمون
                            // وبدون أي أبعاد غير محدودة، وبالتالي لا حاجة
                            // للتمرير الأفقي إطلاقاً هنا.
                            return SingleChildScrollView(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 6, 12, 14),
                              child: Table(
                                columnWidths: const {
                                  0: FixedColumnWidth(82),
                                  1: FlexColumnWidth(2.5),
                                  2: FlexColumnWidth(1),
                                  3: FlexColumnWidth(1),
                                  4: FlexColumnWidth(1),
                                  5: FlexColumnWidth(1.2),
                                },
                                defaultVerticalAlignment:
                                    TableCellVerticalAlignment.middle,
                                children: [
                                  _statementHeaderRow(),
                                  for (final row in statement) ...[
                                    _statementRow(
                                      row,
                                      expanded: expandedReturns.contains(row['id']),
                                      onToggle: () => setStatementState(() {
                                        expandedReturns.contains(row['id'])
                                            ? expandedReturns.remove(row['id'])
                                            : expandedReturns.add(row['id']);
                                      }),
                                    ),
                                    if (row['transaction_type'] == 'return' && expandedReturns.contains(row['id']))
                                      _statementReturnItemsRow(row),
                                  ],
                                  _statementTotalsRow(
                                    totalInvoice,
                                    totalPayment,
                                    totalReturn,
                                    finalBalance,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        ),
                      ),
                      _statementCloseButton(dialogContext),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- الشريط العلوي: عنوان كشف الحساب + زر إغلاق ---
  // يستقبل dialogContext (وليس context الشاشة الأصلية) حتى يكون
  // Navigator.pop مضموناً ويغلق نافذة الحوار نفسها دائماً.
  Widget _statementTopBar(BuildContext dialogContext, String supplierName) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 16, 14),
      decoration: const BoxDecoration(
        color: primary,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => Navigator.of(dialogContext).pop(),
              child: const Padding(
                padding: EdgeInsets.all(6),
                child:
                    Icon(Icons.close_rounded, color: Colors.white, size: 22),
              ),
            ),
          ),
          Expanded(
            child: Text(
              'كشف حساب: $supplierName',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// خلية جدول عامة تُستخدم داخل TableRow — بلا عرض ثابت، لأن عرض كل عمود
  /// يُحسب تلقائياً بواسطة Table نفسه عبر columnWidths.
  Widget _statementCell(
    Widget child, {
    Alignment alignment = Alignment.center,
    EdgeInsetsGeometry padding =
        const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
  }) {
    return Padding(
      padding: padding,
      child: Align(alignment: alignment, child: child),
    );
  }

  // --- صف عناوين الأعمدة ---
  TableRow _statementHeaderRow() {
    Widget label(String text, {IconData? icon}) {
      return _statementCell(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: textSecondary),
              const SizedBox(height: 3),
            ],
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: textMain,
              ),
            ),
          ],
        ),
      );
    }

    return TableRow(
      decoration: const BoxDecoration(
        color: bgCanvas,
        border: Border(bottom: BorderSide(color: borderCol, width: 1)),
      ),
      children: [
        label('التاريخ'),
        label('البيان'),
        label('مدين\n(فاتورة / استلام)'),
        label('دائن - دفعة', icon: Icons.payments_outlined),
        label('دائن - استرجاع', icon: Icons.undo_rounded),
        label('الرصيد بعد\nالحركة'),
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

    late final Color badgeBg;
    late final Color badgeFg;
    late final String badgeText;
    if (isInvoice) {
      badgeBg = const Color(0xFFFCE8B2);
      badgeFg = const Color(0xFF9A6B00);
      badgeText = 'فاتورة';
    } else if (isPayment) {
      badgeBg = success.withValues(alpha: 0.16);
      badgeFg = const Color(0xFF1E8449);
      badgeText = 'دفعة';
    } else if (isRefund) {
      badgeBg = const Color(0xFFE8DAEF);
      badgeFg = const Color(0xFF6C3483);
      badgeText = 'استلام';
    } else if (isCreditApplied) {
      badgeBg = const Color(0xFFD6EAF8);
      badgeFg = const Color(0xFF1F618D);
      badgeText = 'خصم رصيد';
    } else {
      badgeBg = warning.withValues(alpha: 0.18);
      badgeFg = const Color(0xFF9C5B00);
      badgeText = 'استرجاع';
    }

    Widget amountText(double v, Color color) {
      return Text(
        v == 0 ? '—' : _formatAmount(v),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
          color: v == 0 ? textSecondary : color,
        ),
      );
    }

    return TableRow(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: borderCol, width: 1)),
      ),
      children: [
        _statementCell(
          Text(
            _formatDate(row['date_time']?.toString()),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: textSecondary),
          ),
        ),
        _statementCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: badgeFg,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (returnItems.isNotEmpty)
                InkWell(
                  onTap: onToggle,
                  child: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      size: 18, color: primaryDark),
                ),
              Flexible(
                child: Text(
                  _statementDescription(row),
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: textMain,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          alignment: Alignment.centerRight,
        ),
        _statementCell(
          amountText(isInvoice || isRefund ? amount : 0, const Color(0xFF2C3E50)),
        ),
        _statementCell(
          amountText(isPayment ? amount : 0, success),
        ),
        _statementCell(
          amountText(isReturn ? amount : 0, warning),
        ),
        _statementCell(
          Text(
            _balanceText(balance),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
              color: _balanceColor(balance),
            ),
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
        color: Color(0xFFF4FAFE),
        border: Border(bottom: BorderSide(color: borderCol, width: 1)),
      ),
      children: [
        const SizedBox(),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 24, 8),
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
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13,
            color: color ?? textMain,
          ),
        );

    return TableRow(
      decoration: const BoxDecoration(color: bgCanvas),
      children: [
        _statementCell(const SizedBox()),
        _statementCell(
          const Text(
            'الإجمالي',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: textMain,
            ),
          ),
          alignment: Alignment.centerRight,
        ),
        _statementCell(total(totalInvoice)),
        _statementCell(total(totalPayment, color: success)),
        _statementCell(total(totalReturn, color: warning)),
        _statementCell(
          Text(
            finalBalance < -0.001 ? 'رصيد لصالحك: ${_formatAmount(-finalBalance)}' : _formatAmount(finalBalance),
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _balanceColor(finalBalance)),
          ),
        ),
      ],
    );
  }

  // --- زر إغلاق أسفل النافذة ---
  // يستقبل dialogContext لضمان إغلاق نافذة الحوار الصحيحة دائماً.
  Widget _statementCloseButton(BuildContext dialogContext) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          style: OutlinedButton.styleFrom(
            foregroundColor: textSecondary,
            side: const BorderSide(color: borderCol),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child:
              const Text('إغلاق', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  // ==========================================
  // 🗑️ 5. تأكيد حذف المذخر
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('استلام أموال من $supplierName', style: const TextStyle(color: textMain, fontWeight: FontWeight.bold)),
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
                    decoration: const InputDecoration(labelText: 'المبلغ المستلم', border: OutlineInputBorder()),
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
                      decoration: const InputDecoration(labelText: 'التاريخ', border: OutlineInputBorder()),
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
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء', style: TextStyle(color: textSecondary))),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: success, foregroundColor: Colors.white, elevation: 0),
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

  void _confirmDeleteSupplier(int id, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: cardBg,
        title: const Text('تأكيد الحذف', style: TextStyle(color: textMain, fontWeight: FontWeight.bold)),
        content: Text('هل أنت متأكد من حذف المذخر "$name"؟ سيتم حذف جميع الفواتير والسجلات المرتبطة به.', style: const TextStyle(color: textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء', style: TextStyle(color: textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              try {
                await _repository.deleteSupplier(
                  isOnlineMode: widget.isOnlineMode,
                  id: id,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                _refreshData();

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('تم حذف المذخر "$name" بنجاح.'),
                      backgroundColor: warning,
                    ),
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
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}