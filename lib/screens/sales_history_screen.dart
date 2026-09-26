import 'package:flutter/material.dart';
import 'package:pharmacy_app/utils/formatters.dart';
import '../database/db_helper.dart';
import '../repository/invoice_repository.dart';

class SalesHistoryScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOwner;
  final bool isOnlineMode; // من license.mode القادم من التفعيل/تسجيل الدخول

  const SalesHistoryScreen({
    super.key,
    required this.pharmacyId,
    this.isOwner = true,
    this.isOnlineMode = false, // قيمة افتراضية آمنة (أوفلاين)
  });

  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  List<Map<String, dynamic>> _invoices = [];
  List<Map<String, dynamic>> _filteredInvoices = [];
  bool _isLoading = true;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadInvoices();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // جلب الفواتير مع اسم الكاشير مباشرة من قاعدة البيانات بداخل هذه الصفحة
  Future<void> _loadInvoices() async {
    setState(() => _isLoading = true);

    try {
      // أونلاين: نُحدّث الكاش المحلي من السيرفر أولاً (قراءة فقط)، ثم
      // نعرضه بنفس استعلام JOIN المحلي أدناه دون أي تغيير عليه. فواتير
      // أونلاين مُخزَّنة عبر cashier_id = NULL دائماً (انظر
      // db_helper._upsertInvoiceRow)، لكن اسم البائع الجاهز القادم من
      // السيرفر محفوظ في invoice.cashier_name_synced ويُستخدم كبديل هنا.
      if (widget.isOnlineMode) {
        await InvoiceRepository.instance.getInvoices(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: true,
        );
      }

      // الحصول على كائن قاعدة البيانات بدون التعديل على ملف db_helper.dart
      final db = await DatabaseHelper.instance.database;

      // الاستعلام المباشر لربط الفاتورة بجدول المستخدِمين
      final data = await db.rawQuery('''
        SELECT 
          i.*,
          COALESCE(u.full_name, u.username, i.cashier_name_synced, 'غير محدد') AS cashier_name
        FROM invoice i
        LEFT JOIN user_profile up ON i.cashier_id = up.id
        LEFT JOIN users u ON up.user_id = u.id
        WHERE i.pharmacy_id = ?
        ORDER BY i.created_at DESC
      ''', [widget.pharmacyId]);

      setState(() {
        _invoices = data;
        _filteredInvoices = data;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar('خطأ أثناء تحميل سجل المبيعات: $e', Colors.red);
    }
  }

  // فلترة الفواتير حسب البحث
  void _filterInvoices(String query) {
    if (query.trim().isEmpty) {
      setState(() => _filteredInvoices = _invoices);
      return;
    }

    final lower = query.trim().toLowerCase();
    setState(() {
      _filteredInvoices = _invoices.where((inv) {
        final invNum = (inv['invoice_number'] ?? '').toString().toLowerCase();
        final cashier = (inv['cashier_name'] ?? '').toString().toLowerCase();
        return invNum.contains(lower) || cashier.contains(lower);
      }).toList();
    });
  }

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
                        Row(
                          children: [
                            const Icon(Icons.receipt_long, color: Color(0xFF1ABC9C), size: 22),
                            const SizedBox(width: 8),
                            Text(
                              "تفاصيل الفاتورة: ${(invoice['invoice_number'] ?? '').toString()}",
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF2C3E50),
                                fontFamily: 'Tajawal',
                              ),
                            ),
                            const SizedBox(width: 10),
                            _buildStatusChip(isRefunded),
                          ],
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
                    if (!isRefunded && widget.isOwner) ...[
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

                // 2. شريط البحث بدون زر شفتات اليوم
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: TextField(
                          controller: _searchCtrl,
                          onChanged: _filterInvoices,
                          decoration: InputDecoration(
                            hintText: '🔍 ابحث برقم الفاتورة أو اسم البائع...',
                            hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: primaryTeal, width: 1.5),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: primaryTeal, width: 2),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryTeal,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
                      ),
                      onPressed: () => _filterInvoices(_searchCtrl.text),
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('ابحث الآن', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // 3. جدول البيانات
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _filteredInvoices.isEmpty
                          ? const Center(child: Text('لا توجد فواتير مطابقة للبحث', style: TextStyle(color: Colors.grey, fontSize: 16)))
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SingleChildScrollView(
                                child: Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.grey.shade200),
                                  ),
                                  child: DataTable(
                                    headingRowColor: WidgetStateProperty.all(primaryTeal),
                                    headingTextStyle: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                    dataRowMinHeight: 52,
                                    dataRowMaxHeight: 56,
                                    horizontalMargin: 16,
                                    columnSpacing: 15,
                                    columns: const [
                                      DataColumn(label: Expanded(child: Text('رقم الفاتورة', textAlign: TextAlign.center))),
                                      DataColumn(label: Expanded(child: Text('البائع', textAlign: TextAlign.center))),
                                      DataColumn(label: Expanded(child: Text('تاريخ ووقت البيع', textAlign: TextAlign.center))),
                                      DataColumn(label: Expanded(child: Text('حالة الفاتورة', textAlign: TextAlign.center))),
                                      DataColumn(label: Expanded(child: Text('الإجمالي (قبل الخصم)', textAlign: TextAlign.center))),
                                      DataColumn(label: Expanded(child: Text('الخصم', textAlign: TextAlign.center))),
                                      DataColumn(label: Expanded(child: Text('الصافي المدفوع', textAlign: TextAlign.center))),
                                      DataColumn(label: Expanded(child: Text('الإجراءات', textAlign: TextAlign.center))),
                                    ],
                                    rows: _filteredInvoices.map((inv) {
                                      final bool isRefunded = inv['is_refunded'] == 1;
                                      final discount = (inv['discount'] as num?)?.toDouble() ?? 0.0;
                                      final finalAmount = (inv['final_amount'] as num?)?.toDouble() ?? 0.0;
                                      final totalAmount = (inv['total_amount'] as num?)?.toDouble() ?? (finalAmount + discount);
                                      final dtParts = _parseDateTime(inv['created_at']);
                                      final cashierName = inv['cashier_name'] ?? 'غير محدد';

                                      return DataRow(
                                        cells: [
                                          DataCell(Center(
                                            child: Text(inv['invoice_number'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold)),
                                          )),
                                          DataCell(Center(
                                            child: Text(cashierName, style: const TextStyle(fontWeight: FontWeight.w600)),
                                          )),
                                          DataCell(Center(
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFFE2E8F0),
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  child: Text(dtParts['time']!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                                                ),
                                                const SizedBox(width: 4),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFFE2E8F0),
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  child: Text(dtParts['date']!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                                                ),
                                              ],
                                            ),
                                          )),
                                          DataCell(Center(child: _buildStatusChip(isRefunded))),
                                          DataCell(Center(
                                            child: Text(AppFormatter.iqdWithCurrency(totalAmount), style: TextStyle(color: Colors.grey.shade700)),
                                          )),
                                          DataCell(Center(
                                            child: Text(
                                              discount > 0 ? '-${AppFormatter.iqdWithCurrency(discount)}' : AppFormatter.iqdWithCurrency(0),
                                              style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                                            ),
                                          )),
                                          DataCell(Center(
                                            child: Text(
                                              AppFormatter.iqdWithCurrency(finalAmount),
                                              style: const TextStyle(fontWeight: FontWeight.bold, color: primaryTeal),
                                            ),
                                          )),
                                          DataCell(Center(
                                            child: OutlinedButton.icon(
                                              style: OutlinedButton.styleFrom(
                                                side: BorderSide(color: Colors.grey.shade300),
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                              ),
                                              icon: const Icon(Icons.search, size: 14, color: Colors.black87),
                                              label: const Text('تفاصيل الفاتورة', style: TextStyle(color: Colors.black87, fontSize: 11)),
                                              onPressed: () => _showInvoiceDetails(inv),
                                            ),
                                          )),
                                        ],
                                      );
                                    }).toList(),
                                  ),
                                ),
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
            Text('مسترجعة', style: TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.bold, fontSize: 12)),
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
          Text('مكتملة', style: TextStyle(color: Color(0xFF15803D), fontWeight: FontWeight.bold, fontSize: 12)),
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
              Text('الخصم المطبق: ${AppFormatter.iqdWithCurrency(invoice['discount'] ?? 0)}'),
              Text('المبلغ النهائي: ${AppFormatter.iqdWithCurrency(invoice['final_amount'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }
}