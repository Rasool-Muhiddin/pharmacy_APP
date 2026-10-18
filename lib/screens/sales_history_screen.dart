import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pharmacy_app/utils/formatters.dart';
import '../database/db_helper.dart';
import '../repository/invoice_repository.dart';
import '../widgets/filter_dropdown.dart';
import '../widgets/lazy_table.dart';

class SalesHistoryScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOwner;
  final bool isOnlineMode; // من license.mode القادم من التفعيل/تسجيل الدخول

  /// المستخدم الحالي (user_profile.id أوفلاين) — يُسجَّل كمنفّذ الإرجاع.
  final int? userId;

  const SalesHistoryScreen({
    super.key,
    required this.pharmacyId,
    this.isOwner = true,
    this.isOnlineMode = false, // قيمة افتراضية آمنة (أوفلاين)
    this.userId,
  });

  /// من أرجع الفاتورة ومتى. فواتير أُرجعت قبل تسجيل ذلك لا تحمل الاسم ولا الوقت.
  static String refundInfoText(Map<String, dynamic> invoice) {
    final by = (invoice['refunded_by_display'] ?? '').toString().trim();
    final rawAt = (invoice['refunded_at'] ?? '').toString().trim();
    final at = DateTime.tryParse(rawAt)?.toLocal();
    final when = at == null
        ? ''
        : '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} '
            '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    if (by.isEmpty && when.isEmpty) return 'تم الإرجاع (قبل تسجيل المنفّذ)';
    return [
      'تم الإرجاع بواسطة: ${by.isEmpty ? 'غير معروف' : by}',
      if (when.isNotEmpty) 'بتاريخ: $when',
    ].join('  •  ');
  }

  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  static const int _pageSize = 50;

  List<Map<String, dynamic>> _invoices = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  bool _fromCache = false;
  int _page = 1;
  DateTime? _startDate;
  DateTime? _endDate;
  Timer? _searchDebounce;
  // يتجاهل ردود طلبات أقدم إن تغيّر البحث/الفلاتر أثناء انتظارها.
  int _requestSeq = 0;
  final TextEditingController _searchCtrl = TextEditingController();

  // الفلاتر (null = الكل). البائع = اسمه كما يُعرض (DatabaseHelper.sellerNameSql
  // محلياً، cashier_display_name على الخادم). الحالة: الفواتير إما مكتملة أو
  // مسترجعة بالكامل (is_refunded) — لا حالات أخرى في النظام.
  String? _seller;
  bool? _refunded;
  bool? _hasDiscount;
  List<String> _sellers = [];

  @override
  void initState() {
    super.initState();
    _loadInvoices();
    _loadSellers();
  }

  Future<void> _loadSellers() async {
    try {
      final sellers = await InvoiceRepository.instance.getSellers(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
      );
      if (mounted) setState(() => _sellers = sellers);
    } catch (_) {
      // فلتر البائع اختياري: بلا قائمة يبقى "كل البائعين" فقط.
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// الصفحة الأولى بالبحث والفترة الحاليين. الترقيم والفلترة على الخادم
  /// أونلاين (لا يُنزَّل السجل كاملاً)، وعلى الجدول المحلي أوفلاين.
  Future<void> _loadInvoices() async {
    _searchDebounce?.cancel();
    final seq = ++_requestSeq;
    setState(() => _isLoading = true);

    try {
      final page = await _fetchPage(1);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _invoices = page.rows;
        _page = 1;
        _hasMore = page.hasMore;
        _fromCache = page.fromCache;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() => _isLoading = false);
      _showSnackBar('خطأ أثناء تحميل سجل المبيعات: $e', Colors.red);
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    final seq = _requestSeq;
    setState(() => _isLoadingMore = true);
    try {
      final page = await _fetchPage(_page + 1);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        final seen = {for (final inv in _invoices) inv['id']};
        _invoices = [
          ..._invoices,
          ...page.rows.where((inv) => !seen.contains(inv['id']))
        ];
        _page += 1;
        _hasMore = page.hasMore;
      });
    } catch (e) {
      _showSnackBar('خطأ أثناء تحميل المزيد: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  Future<InvoicePage> _fetchPage(int page) {
    return InvoiceRepository.instance.getInvoicesPage(
      pharmacyId: widget.pharmacyId,
      isOnlineMode: widget.isOnlineMode,
      page: page,
      pageSize: _pageSize,
      search: _searchCtrl.text,
      start: _startDate,
      end: _endDate,
      seller: _seller,
      refunded: _refunded,
      hasDiscount: _hasDiscount,
    );
  }

  /// بحث حي: يُعاد التحميل بعد توقف الكتابة 300ms، لا مع كل حرف.
  /// لا setState هنا: زر المسح يتابع النص وحده (ValueListenableBuilder).
  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), _loadInvoices);
  }

  bool get _hasActiveFilters =>
      _searchCtrl.text.trim().isNotEmpty ||
      _startDate != null ||
      _seller != null ||
      _refunded != null ||
      _hasDiscount != null;

  void _clearFilters() {
    _searchCtrl.clear();
    setState(() {
      _startDate = null;
      _endDate = null;
      _seller = null;
      _refunded = null;
      _hasDiscount = null;
    });
    _loadInvoices();
  }

  static String _sellerLabel(String name) => name == DatabaseHelper.unknownSeller ? 'غير محدد' : name;

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _startDate != null && _endDate != null
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
    );
    if (picked == null) return;
    setState(() {
      _startDate = picked.start;
      _endDate = picked.end;
    });
    _loadInvoices();
  }

  String _formatDay(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // تنفيذ عملية الاسترجاع
  Future<void> _handleRefund(int invoiceId, String invoiceNumber) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأكيد استرجاع الفاتورة'),
          content: Text('هل أنت تأكد من استرجاع الفاتورة رقم ($invoiceNumber)؟\nسيتم إرجاع كافة الكميات المباعة إلى المخزن.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('استرجاع', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    try {
      await InvoiceRepository.instance.refund(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        invoiceId: invoiceId,
        userId: widget.userId,
      );
      _showSnackBar('تم استرجاع الفاتورة بنجاح وإعادة الكميات للمخزن', Colors.green);
      _loadInvoices();
    } catch (e) {
      _showSnackBar('حدث خطأ أثناء الاسترجاع: $e', Colors.red);
    }
  }

  // عرض تفاصيل الفاتورة وعناصرها
  void _showInvoiceDetails(Map<String, dynamic> invoice) {
    final bool isRefunded = invoice['is_refunded'] == 1;

    showDialog(
      context: context,
      builder: (context) {
        final double subtotal = (invoice['total_amount'] as num?)?.toDouble() ??
            (invoice['subtotal'] as num?)?.toDouble() ??
            0.0;
        final double discount = (invoice['discount'] as num?)?.toDouble() ?? 0.0;
        final double finalTotal = (invoice['final_amount'] as num?)?.toDouble() ?? (subtotal - discount);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Container(
              width: 600,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: const Border(top: BorderSide(color: Color(0xFF1ABC9C), width: 6)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // الشريط العلوي (العنوان + الحالة + زر الإغلاق)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              const Icon(Icons.receipt_long, color: Color(0xFF1ABC9C), size: 22),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  "تفاصيل الفاتورة: ${(invoice['invoice_number'] ?? '').toString()}",
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF2C3E50),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              _buildStatusChip(isRefunded),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFFA0AEC0)),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const Divider(height: 20, color: Color(0xFFEDF2F7)),

                    // معلومات ترويسة الفاتورة
                    _buildInvoiceHeaderInfo(invoice),
                    if (isRefunded) ...[
                      const SizedBox(height: 8),
                      _buildRefundInfo(invoice),
                    ],
                    const SizedBox(height: 12),

                    // جدول أصناف الفاتورة
                    FutureBuilder<List<Map<String, dynamic>>>(
                      future: DatabaseHelper.instance.getInvoiceItems(invoice['id']),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const SizedBox(
                            height: 150,
                            child: Center(child: CircularProgressIndicator(color: Color(0xFF1ABC9C))),
                          );
                        }

                        if (snapshot.hasError || !snapshot.hasData || snapshot.data!.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20.0),
                            child: Center(
                              child: Text(
                                'لا توجد عناصر لعرضها في هذه الفاتورة.',
                                style: TextStyle(color: Color(0xFF718096), fontSize: 13),
                              ),
                            ),
                          );
                        }

                        final items = snapshot.data!;

                        return Table(
                          columnWidths: const {
                            0: FlexColumnWidth(2),
                            1: FlexColumnWidth(1.2),
                            2: FlexColumnWidth(1),
                            3: FlexColumnWidth(1),
                          },
                          children: [
                            const TableRow(
                              decoration: BoxDecoration(color: Color(0xFFF7FAFC)),
                              children: [
                                Padding(padding: EdgeInsets.all(8.0), child: Text("اسم الدواء", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF2D3748)))),
                                Padding(padding: EdgeInsets.all(8.0), child: Text("الكمية المباعة", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF2D3748)))),
                                Padding(padding: EdgeInsets.all(8.0), child: Text("سعر المفرد", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF2D3748)))),
                                Padding(padding: EdgeInsets.all(8.0), child: Text("المجموع", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF2D3748)))),
                              ],
                            ),
                            ...items.map((item) {
                              final qty = (item['quantity'] as num?)?.toInt() ?? 0;
                              final price = (item['unit_price'] as num?)?.toDouble() ?? 0.0;
                              final total = (item['total_price'] as num?)?.toDouble() ?? 0.0;

                              return TableRow(
                                decoration: const BoxDecoration(
                                  border: Border(bottom: BorderSide(color: Color(0xFFEDF2F7))),
                                ),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Text(
                                      (item['trade_name'] ?? "-").toString(),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF2D3748)),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEBF8FF),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        "$qty قطعة",
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(color: Color(0xFF2B6CB0), fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Text(AppFormatter.iqdWithCurrency(price), style: const TextStyle(color: Color(0xFF4A5568), fontSize: 12)),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Text(AppFormatter.iqdWithCurrency(total), style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2D3748), fontSize: 12)),
                                  ),
                                ],
                              );
                            }),
                          ],
                        );
                      },
                    ),

                    const SizedBox(height: 20),

                    // قسم ملخص الحسابات والإجماليات
                    Container(
                      padding: const EdgeInsets.only(top: 15),
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: Color(0xFFEDF2F7), width: 2)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("المجموع الإجمالي:", style: TextStyle(color: Color(0xFF718096), fontSize: 13)),
                              Text(AppFormatter.iqdWithCurrency(subtotal), style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2D3748), fontSize: 13)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("الخصم المطبق:", style: TextStyle(color: Color(0xFFE53E3E), fontSize: 13)),
                              Text(
                                discount > 0 ? "-${AppFormatter.iqdWithCurrency(discount)}" : AppFormatter.iqdWithCurrency(0),
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFE53E3E), fontSize: 13),
                              ),
                            ],
                          ),
                          const Divider(height: 20, color: Color(0xFFEDF2F7)),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("الصافي النهائي للمدفوع:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF38A169))),
                              Text(AppFormatter.iqdWithCurrency(finalTotal), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF38A169))),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // زر استرجاع الفاتورة
                    if (!isRefunded) ...[
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE53E3E),
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            ),
                            icon: const Icon(Icons.undo, color: Colors.white, size: 18),
                            label: const Text('استرجاع الفاتورة', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            onPressed: () {
                              Navigator.pop(context);
                              _handleRefund(invoice['id'], invoice['invoice_number']);
                            },
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  // استخراج تاريخ ووقت منفصلين للكبسولات
  Map<String, String> _parseDateTime(String? rawDate) {
    if (rawDate == null || rawDate.isEmpty) return {'date': '-', 'time': '-'};
    try {
      final dt = DateTime.parse(rawDate);
      final dateStr = "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";
      final timeStr = "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
      return {'date': dateStr, 'time': timeStr};
    } catch (_) {
      return {'date': rawDate, 'time': '-'};
    }
  }

  @override
  Widget build(BuildContext context) {
    const primaryTeal = Color(0xFF00A884);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F5F9),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(8),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. العنوان العلوي (يمين إلى يسار)
                Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: const [
                    Icon(Icons.description_rounded, color: primaryTeal, size: 28),
                    SizedBox(width: 8),
                    Text(
                      'سجل الفواتير والمبيعات',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // 2. شريط البحث والفلاتر (صف واحد؛ صفّان على الشاشات الضيقة)
                _buildFilterBar(primaryTeal),
                if (_fromCache)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'لا يوجد اتصال بالخادم — تُعرض آخر نسخة محفوظة على هذا الجهاز.',
                      style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600),
                    ),
                  ),
                const SizedBox(height: 20),

                // 3. جدول البيانات
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _invoices.isEmpty
                          ? Center(
                              child: Text(
                                _hasActiveFilters ? 'لا توجد فواتير مطابقة للبحث والفلاتر' : 'لا توجد فواتير بعد',
                                style: const TextStyle(color: Colors.grey, fontSize: 16),
                              ),
                            )
                          : Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.grey.shade200),
                              ),
                              clipBehavior: Clip.antiAlias,
                              // صفوف تُبنى عند ظهورها فقط: "تحميل المزيد" لا يبطئ الشاشة مهما كثرت الصفحات.
                              child: LazyTable(
                                columns: const [
                                  LazyColumn('رقم الفاتورة', 130),
                                  LazyColumn('البائع', 130),
                                  LazyColumn('تاريخ ووقت البيع', 190),
                                  LazyColumn('حالة الفاتورة', 130),
                                  LazyColumn('الإجمالي (قبل الخصم)', 150),
                                  LazyColumn('الخصم', 130),
                                  LazyColumn('الصافي المدفوع', 150),
                                  LazyColumn('الإجراءات', 150),
                                ],
                                itemCount: _invoices.length,
                                rowHeight: 56,
                                headerHeight: 56,
                                headerColor: primaryTeal,
                                headerStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                cellAlignment: Alignment.center,
                                cellPadding: const EdgeInsets.symmetric(horizontal: 6),
                                cellsBuilder: (context, index) => _invoiceCells(_invoices[index], primaryTeal),
                                footer: _hasMore
                                    ? Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: _isLoadingMore
                                            ? const Center(child: CircularProgressIndicator())
                                            : Center(
                                                child: OutlinedButton.icon(
                                                  onPressed: _loadMore,
                                                  icon: const Icon(Icons.expand_more),
                                                  label: const Text('تحميل المزيد'),
                                                ),
                                              ),
                                      )
                                    : null,
                              ),
                            ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterBar(Color primaryTeal) {
    final search = SizedBox(
      height: 48,
      child: TextField(
        controller: _searchCtrl,
        onChanged: _onSearchChanged,
        onSubmitted: (_) => _loadInvoices(),
        decoration: InputDecoration(
          hintText: '🔍 ابحث برقم الفاتورة أو اسم الدواء...',
          hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: primaryTeal, width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: primaryTeal, width: 2),
          ),
        ),
      ),
    );

    final seller = _seller;
    final filters = <Widget>[
      FilterDropdown<String>(
        value: seller,
        allLabel: 'كل البائعين',
        icon: Icons.person_outline,
        width: 165,
        options: {
          for (final name in _sellers) name: _sellerLabel(name),
          if (seller != null && !_sellers.contains(seller)) seller: _sellerLabel(seller),
        },
        onChanged: (value) {
          setState(() => _seller = value);
          _loadInvoices();
        },
      ),
      const SizedBox(width: 8),
      FilterDropdown<bool>(
        value: _refunded,
        allLabel: 'كل الحالات',
        icon: Icons.fact_check_outlined,
        width: 135,
        options: const {false: 'مكتملة', true: 'مسترجعة'},
        onChanged: (value) {
          setState(() => _refunded = value);
          _loadInvoices();
        },
      ),
      const SizedBox(width: 8),
      FilterDropdown<bool>(
        value: _hasDiscount,
        allLabel: 'الخصم: الكل',
        icon: Icons.percent,
        width: 135,
        options: const {true: 'بخصم', false: 'بدون خصم'},
        onChanged: (value) {
          setState(() => _hasDiscount = value);
          _loadInvoices();
        },
      ),
      const SizedBox(width: 8),
      SizedBox(
        height: 48,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: primaryTeal,
            backgroundColor: _startDate != null ? primaryTeal.withValues(alpha: 0.06) : null,
            side: BorderSide(color: primaryTeal, width: 1.5),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _pickDateRange,
          icon: const Icon(Icons.date_range, size: 18),
          label: Text(
            _startDate == null ? 'كل الفترات' : '${_formatDay(_startDate!)} ← ${_formatDay(_endDate!)}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchCtrl,
        builder: (context, value, _) => _hasActiveFilters
            ? Padding(
                padding: const EdgeInsetsDirectional.only(start: 4),
                child: ClearFiltersButton(onPressed: _clearFilters),
              )
            : const SizedBox.shrink(),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // الفلاتر حتى ~850px (مع فترة ومسح)؛ البحث يحتاج ~250px بجانبها، وإلا ينزل فوقها.
        if (constraints.maxWidth >= 1100) {
          return Row(children: [Expanded(child: search), const SizedBox(width: 10), ...filters]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            search,
            const SizedBox(height: 10),
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: filters)),
          ],
        );
      },
    );
  }

  List<Widget> _invoiceCells(Map<String, dynamic> inv, Color primaryTeal) {
    final bool isRefunded = inv['is_refunded'] == 1;
    final discount = (inv['discount'] as num?)?.toDouble() ?? 0.0;
    final finalAmount = (inv['final_amount'] as num?)?.toDouble() ?? 0.0;
    final totalAmount = (inv['total_amount'] as num?)?.toDouble() ?? (finalAmount + discount);
    final dtParts = _parseDateTime(inv['created_at']);
    final cashierName = _sellerLabel((inv['cashier_name'] ?? DatabaseHelper.unknownSeller) as String);
    Widget pill(String text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(12)),
          child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        );
    return [
      Text(inv['invoice_number'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
      Text(cashierName, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(mainAxisSize: MainAxisSize.min, children: [pill(dtParts['time']!), const SizedBox(width: 4), pill(dtParts['date']!)]),
      ),
      _buildStatusChip(isRefunded),
      Text(AppFormatter.iqdWithCurrency(totalAmount), style: TextStyle(color: Colors.grey.shade700)),
      Text(
        discount > 0 ? '-${AppFormatter.iqdWithCurrency(discount)}' : AppFormatter.iqdWithCurrency(0),
        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
      ),
      Text(AppFormatter.iqdWithCurrency(finalAmount), style: TextStyle(fontWeight: FontWeight.bold, color: primaryTeal)),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.grey.shade300),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
        icon: const Icon(Icons.search, size: 14, color: Colors.black87),
        label: const Text('تفاصيل الفاتورة', style: TextStyle(color: Colors.black87, fontSize: 11)),
        onPressed: () => _showInvoiceDetails(inv),
      ),
    ];
  }

  Widget _buildStatusChip(bool isRefunded) {
    if (isRefunded) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFEE2E2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(radius: 3, backgroundColor: Color(0xFFDC2626)),
            SizedBox(width: 5),
            Flexible(child: Text('مسترجعة', overflow: TextOverflow.ellipsis, style: TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.bold, fontSize: 12))),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFDCFCE7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(radius: 3, backgroundColor: Color(0xFF16A34A)),
          SizedBox(width: 5),
          Flexible(child: Text('مكتملة', overflow: TextOverflow.ellipsis, style: TextStyle(color: Color(0xFF15803D), fontWeight: FontWeight.bold, fontSize: 12))),
        ],
      ),
    );
  }

  Widget _buildRefundInfo(Map<String, dynamic> invoice) {
    return Container(
      key: const Key('invoice-refund-info'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.undo, size: 18, color: Color(0xFFB91C1C)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              SalesHistoryScreen.refundInfoText(invoice),
              style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInvoiceHeaderInfo(Map<String, dynamic> invoice) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('الإجمالي: ${AppFormatter.iqdWithCurrency(invoice['total_amount'] ?? invoice['final_amount'])}'),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Text('الخصم المطبق: ${AppFormatter.iqdWithCurrency(invoice['discount'] ?? 0)}')),
              const SizedBox(width: 12),
              Flexible(
                child: Text('المبلغ النهائي: ${AppFormatter.iqdWithCurrency(invoice['final_amount'])}',
                    textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}