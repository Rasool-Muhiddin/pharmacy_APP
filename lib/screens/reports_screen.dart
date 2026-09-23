import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:pharmacy_app/utils/formatters.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../repository/medicine_repository.dart';
import '../repository/Invoice_repository.dart';
import '../repository/expense_repository.dart';

class ReportsScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOwner;

  /// وضع الأونلاين الحالي للصيدلية. كل استعلامات هذه الشاشة تبقى SQL محلي
  /// مباشر على جداول medicine/invoice/invoice_item/expense — لكن في وضع
  /// الأونلاين نُحدّث هذه الجداول أولاً من السيرفر عبر MedicineRepository/
  /// InvoiceRepository/ExpenseRepository (نفس الكاش الذي تعتمده شاشات
  /// المخزون والمبيعات والمصروفات) قبل تنفيذ أي استعلام تقرير، لتعكس
  /// التقارير بيانات محدّثة بدل الاكتفاء بآخر نسخة محلية قديمة.
  ///
  /// ⚠️ التوالف/المذاخر (جداول damaged_medicine, purchase_invoice) لا تزال
  /// بلا كاش أونلاين حتى الآن — تبقى بيانات هذا الجهاز فقط في كلا الوضعين
  /// حتى تُبنى لها طبقة API/Repository مماثلة ضمن الخطة.
  final bool isOnlineMode;

  const ReportsScreen({
    super.key,
    required this.pharmacyId,
    required this.isOnlineMode,
    this.isOwner = true,
  });

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  bool _isLoading = true;

  // تواريخ الفلترة (الافتراضي: آخر 30 يوم)
  late DateTime _startDate;
  late DateTime _endDate;

  // المؤشرات المالية (KPIs)
  double _totalSales = 0.0;
  int _totalInvoicesCount = 0;
  double _totalDiscountsGiven = 0.0;
  double _totalDamageLosses = 0.0;
  double _totalExpenses = 0.0;
  double _totalSupplierDebt = 0.0;
  int _refundedInvoicesCount = 0;

  // القوائم والجداول
  List<Map<String, dynamic>> _topSellingItems = [];
  List<Map<String, dynamic>> _stagnantMedicines = [];
  List<Map<String, dynamic>> _invoices = [];

  final NumberFormat _currencyFormatter = NumberFormat("#,##0", "en_US");
  final DateFormat _dateFormatter = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _endDate = DateTime.now();
    _startDate = _endDate.subtract(const Duration(days: 30));
    _loadReportData();
  }

  // ==========================================
  // استعلامات واستخراج البيانات من قاعدة البيانات
  // ==========================================
Future<void> _loadReportData() async {
  if (!widget.isOwner) {
    setState(() => _isLoading = false);
    return;
  }

  setState(() => _isLoading = true);

  try {
    // في وضع الأونلاين: نجلب أحدث نسخة من المخزون والفواتير من السيرفر
    // أولاً (نفس مسار medicine/invoice المستخدم في شاشتي المخزون ونقطة
    // البيع)، كي تُبنى استعلامات التقرير أدناه على بيانات مُزامَنة بدل كاش
    // قديم. الدالتان تتعاملان داخلياً مع انعدام الاتصال (تعودان لآخر كاش
    // محلي محفوظ بصمت)، فاستدعاؤهما آمن حتى لو تعذّر الوصول للسيرفر فعلياً
    // الآن — لا حاجة لفحص اتصال منفصل هنا.
    if (widget.isOnlineMode) {
      try {
        await MedicineRepository.instance.getMedicines(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: true,
        );
        await InvoiceRepository.instance.getInvoices(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: true,
        );
        await ExpenseRepository.instance.getExpenses(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: true,
        );
      } catch (_) {
        // فشل التحديث من السيرفر لا يجب أن يمنع عرض التقرير بآخر بيانات
        // متوفرة محلياً — الاستعلامات أدناه تتابع على الكاش كما هو.
      }
    }

    final db = await DatabaseHelper.instance.database;

    // استخراج التاريخ بصيغة YYYY-MM-DD
    final String startStr = DateFormat('yyyy-MM-dd').format(_startDate);
    final String endStr = DateFormat('yyyy-MM-dd').format(_endDate);

    // 1. حساب KPIs المبيعات، الفواتير، والخصومات بالفترة المحددة
    final salesSummary = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(final_amount), 0) AS total_cash_in_drawer,
        COUNT(id) AS total_count,
        COALESCE(SUM(discount), 0) AS total_discounts
      FROM invoice
      WHERE pharmacy_id = ? 
        AND is_refunded = 0 
        AND date(created_at) >= date(?) AND date(created_at) <= date(?)
    ''', [widget.pharmacyId, startStr, endStr]);

    final double cashInDrawer = (salesSummary.first['total_cash_in_drawer'] as num).toDouble();
    final totalInvoicesCount = (salesSummary.first['total_count'] as num).toInt();
    final totalDiscounts = (salesSummary.first['total_discounts'] as num).toDouble();
    final expensesSummary = await db.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS total FROM expense
      WHERE pharmacy_id = ? AND date(expense_date) BETWEEN date(?) AND date(?)
    ''', [widget.pharmacyId, startStr, endStr]);
    final refundedSummary = await db.rawQuery('''
      SELECT COUNT(id) AS total FROM invoice WHERE pharmacy_id = ? AND is_refunded = 1
      AND date(created_at) BETWEEN date(?) AND date(?)
    ''', [widget.pharmacyId, startStr, endStr]);
    final supplierDebtSummary = await db.rawQuery('''
      SELECT COALESCE(SUM(remaining_debt), 0) AS total FROM purchase_invoice WHERE pharmacy_id = ?
    ''', [widget.pharmacyId]);

    // 2. حساب خسائر الأدوية المنتهية بالفترة المحددة
    // 🟢 يُحتسَب الدواء "خسارة" فقط بعد مرور يوم كامل فعلياً على تاريخه
    // (date(expiry_date) < اليوم الحالي فعلياً) — وليس بمجرد وصول تاريخ
    // انتهائه لنفس يوم إنشاء التقرير، حتى تتساوى القيمة مع شاشة التوالف
    // ودالة getExpiredMedicines المستخدمة بالداشبورد (نفس المعيار بالضبط).
    final String todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

    final expiredQuery = await db.rawQuery('''
      SELECT COALESCE(SUM(quantity * buy_price), 0) AS expired_losses
      FROM medicine
      WHERE pharmacy_id = ? 
        AND is_damaged = 0 
        AND quantity > 0 
        AND date(expiry_date) >= date(?) AND date(expiry_date) <= date(?)
        AND date(expiry_date) < date(?)
    ''', [widget.pharmacyId, startStr, endStr, todayStr]);

    // حساب خسائر التوالف المسجلة بالفترة المحددة
    // 🟢 سجلات "تصحيح إدخال" (reason = 'correction') تُستبعد لأنها ليست خسارة
    // فعلية، بل تصحيح لخطأ كتابة كمية أثناء إضافة/تعديل الدواء.
    final damagedQuery = await db.rawQuery('''
      SELECT COALESCE(SUM(dm.quantity_damaged * m.buy_price), 0) AS damaged_losses
      FROM damaged_medicine dm
      JOIN medicine m ON dm.medicine_id = m.id
      WHERE dm.pharmacy_id = ?
        AND dm.reason != 'correction'
        AND date(dm.damaged_at) >= date(?) AND date(dm.damaged_at) <= date(?)
    ''', [widget.pharmacyId, startStr, endStr]);

    final double expiredLosses = (expiredQuery.first['expired_losses'] as num).toDouble();
    final double damagedLosses = (damagedQuery.first['damaged_losses'] as num).toDouble();

    // 3. الأدوية الأكثر مبيعاً (Top 5)
    final topSelling = await db.rawQuery('''
      SELECT 
        m.trade_name,
        m.scientific_name,
        SUM(ii.quantity) AS total_qty,
        SUM(ii.total_price) AS total_revenue
      FROM invoice_item ii
      JOIN invoice i ON ii.invoice_id = i.id
      JOIN medicine m ON ii.medicine_id = m.id
      WHERE i.pharmacy_id = ? 
        AND i.is_refunded = 0
        AND date(i.created_at) >= date(?) AND date(i.created_at) <= date(?)
      GROUP BY ii.medicine_id
      ORDER BY total_qty DESC
      LIMIT 5
    ''', [widget.pharmacyId, startStr, endStr]);

    // 4. الأدوية الراكدة
    final stagnant = await db.rawQuery('''
      SELECT 
        m.id,
        m.trade_name,
        m.scientific_name,
        m.quantity,
        m.category
      FROM medicine m
      WHERE m.pharmacy_id = ? 
        AND m.is_damaged = 0 
        AND m.quantity > 0
        AND m.id NOT IN (
          SELECT DISTINCT ii.medicine_id
          FROM invoice_item ii
          JOIN invoice i ON ii.invoice_id = i.id
          WHERE i.pharmacy_id = ? 
            AND i.is_refunded = 0
            AND date(i.created_at) >= date(?) AND date(i.created_at) <= date(?)
        )
      LIMIT 10
    ''', [widget.pharmacyId, widget.pharmacyId, startStr, endStr]);

    // 5. قائمة الفواتير التفصيلية الصادرة
    final invoicesList = await db.rawQuery('''
      SELECT id, invoice_number, created_at, total_amount, discount, final_amount
      FROM invoice
      WHERE pharmacy_id = ? 
        AND is_refunded = 0 
        AND date(created_at) >= date(?) AND date(created_at) <= date(?)
      ORDER BY created_at DESC
    ''', [widget.pharmacyId, startStr, endStr]);

    if (!mounted) return;

    setState(() {
      _totalSales = cashInDrawer;
      _totalInvoicesCount = totalInvoicesCount;
      _totalDiscountsGiven = totalDiscounts;
      _totalExpenses = (expensesSummary.first['total'] as num).toDouble();
      _totalSupplierDebt = (supplierDebtSummary.first['total'] as num).toDouble();
      _refundedInvoicesCount = (refundedSummary.first['total'] as num).toInt();
      _totalDamageLosses = expiredLosses + damagedLosses; // الخسائر الخاصة بالفترة فقط
      _topSellingItems = topSelling;
      _stagnantMedicines = stagnant;
      _invoices = invoicesList;
      _isLoading = false;
    });
  } catch (e) {
    if (!mounted) return;
    setState(() => _isLoading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("حدث خطأ أثناء تحميل البيانات: $e")),
    );
  }
}
  String _formatDateTime(String rawDate) {
    if (rawDate.isEmpty) return '-';
    try {
      final dateTime = DateTime.parse(rawDate);
      // HH تعني نظام 24 ساعة (مثلاً 14:48 بدلاً من 02:48 PM)
      return DateFormat('yyyy-MM-dd  HH:mm').format(dateTime);
    } catch (_) {
      return rawDate;
    }
  }


  // ==========================================
  // نافذة تقرير شفتات ومبيعات البائعين (حكر للمالك فقط)
  // ==========================================
  Future<void> _openShiftsModal() async {
    if (!widget.isOwner) return;

    final db = await DatabaseHelper.instance.database;

    final String startStr = DateFormat('yyyy-MM-dd').format(_startDate);
    final String endStr = DateFormat('yyyy-MM-dd').format(_endDate);

    final sellersSummary = await db.rawQuery('''
    SELECT 
      COALESCE(u.full_name, u.username, 'بائع غير محدد') AS seller_name,
      COUNT(i.id) AS invoices_count,
      COALESCE(SUM(i.final_amount), 0) AS total_amount
    FROM invoice i
    LEFT JOIN user_profile up ON i.cashier_id = up.id
    LEFT JOIN users u ON up.user_id = u.id
    WHERE i.pharmacy_id = ? 
      AND COALESCE(i.is_refunded, 0) = 0 
      AND date(i.created_at) >= date(?) 
      AND date(i.created_at) <= date(?)
    GROUP BY COALESCE(u.full_name, u.username, 'بائع غير محدد')
    ORDER BY total_amount DESC
  ''', [widget.pharmacyId, startStr, endStr]);
    final allSellersInvoices = await db.rawQuery('''
    SELECT i.id, i.invoice_number, i.created_at, i.total_amount, i.discount, i.final_amount,
           COALESCE(u.full_name, u.username, 'بائع غير محدد') AS seller_name
    FROM invoice i
    LEFT JOIN user_profile up ON i.cashier_id = up.id
    LEFT JOIN users u ON up.user_id = u.id
    WHERE i.pharmacy_id = ? 
      AND COALESCE(i.is_refunded, 0) = 0 
      AND date(i.created_at) >= date(?) 
      AND date(i.created_at) <= date(?)
    ORDER BY i.created_at DESC
  ''', [widget.pharmacyId, startStr, endStr]);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) {
        return Directionality(
          textDirection: ui.TextDirection.rtl,
          child: Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Container(
              width: 750,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1ABC9C).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.badge_outlined, color: Color(0xFF1ABC9C), size: 24),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "تقرير الشفتات وحسابات البائعين",
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50)),
                              ),
                              Text(
                                "الفترة من ${_dateFormatter.format(_startDate)} إلى ${_dateFormatter.format(_endDate)}",
                                style: const TextStyle(fontSize: 12, color: Color(0xFF718096)),
                              ),
                            ],
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Color(0xFFA0AEC0)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(height: 25, color: Color(0xFFEDF2F7)),

                  Expanded(
                    child: sellersSummary.isEmpty
                        ? const Center(
                            child: Text(
                              "لا توجد مبيعات مسجلة للبائعين في هذه الفترة.",
                              style: TextStyle(color: Color(0xFFA0AEC0), fontSize: 15),
                            ),
                          )
                        : ListView.builder(
                            itemCount: sellersSummary.length,
                            itemBuilder: (context, index) {
                              final seller = sellersSummary[index];
                              final String sellerName = seller['seller_name'].toString();
                              final int invCount = (seller['invoices_count'] as num).toInt();
                              final double totalAmount = (seller['total_amount'] as num).toDouble();

                              final sellerInvoices = allSellersInvoices
                                  .where((inv) => inv['seller_name'].toString() == sellerName)
                                  .toList();

                              return Card(
                                margin: const EdgeInsets.only(bottom: 12),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                                ),
                                child: ExpansionTile(
                                  leading: CircleAvatar(
                                    backgroundColor: const Color(0xFF3182CE).withOpacity(0.1),
                                    child: const Icon(Icons.person, color: Color(0xFF3182CE)),
                                  ),
                                  title: Text(
                                    sellerName,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF2D3748)),
                                  ),
                                  subtitle: Text(
                                    "عدد الفواتير المباعة: $invCount فاتورة",
                                    style: const TextStyle(fontSize: 12, color: Color(0xFF718096)),
                                  ),
                                  trailing: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE6FFFA),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: const Color(0xFF319795)),
                                    ),
                                    child: Text(
                                      "${_currencyFormatter.format(totalAmount)} د.ع",
                                      style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF234E52), fontSize: 13),
                                    ),
                                  ),
                                  children: [
                                    Container(
                                      color: const Color(0xFFF7FAFC),
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            "تفاصيل فواتير البائع:",
                                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF4A5568)),
                                          ),
                                          const SizedBox(height: 8),
                                          Table(
                                            columnWidths: const {
                                              0: FlexColumnWidth(1.5),
                                              1: FlexColumnWidth(2),
                                              2: FlexColumnWidth(1.5),
                                              3: FlexColumnWidth(1),
                                            },
                                            children: [
                                              const TableRow(
                                                decoration: BoxDecoration(color: Color(0xFFEDF2F7)),
                                                children: [
                                                  Padding(padding: EdgeInsets.all(8), child: Text("رقم الفاتورة", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                                  Padding(padding: EdgeInsets.all(8), child: Text("التاريخ والوقت", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                                  Padding(padding: EdgeInsets.all(8), child: Text("المبلغ الصافي", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                                  Padding(padding: EdgeInsets.all(8), child: Text("عرض", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                                ],
                                              ),
                                              ...sellerInvoices.map((inv) {
                                                final finalAmt = (inv['final_amount'] as num?)?.toDouble() ?? 0.0;
                                                return TableRow(
                                                  decoration: const BoxDecoration(
                                                    border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
                                                  ),
                                                  children: [
                                                    Padding(padding: const EdgeInsets.all(8), child: Text((inv['invoice_number'] ?? '-').toString(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                                                    Padding(padding: const EdgeInsets.all(8), child: Text( _formatDateTime((inv['created_at'] ?? '').toString()),  style: const TextStyle(fontSize: 11, color: Color(0xFF718096)))),
                                                    Padding(padding: const EdgeInsets.all(8), child: Text("${_currencyFormatter.format(finalAmt)} د.ع", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF38A169)))),
                                                    Padding(
                                                      padding: const EdgeInsets.all(4),
                                                      child: IconButton(
                                                        icon: const Icon(Icons.visibility_outlined, size: 18, color: Color(0xFF3182CE)),
                                                        onPressed: () {
                                                          Navigator.pop(ctx);
                                                          _openInvoiceModal(inv);
                                                        },
                                                      ),
                                                    ),
                                                  ],
                                                );
                                              }),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ==========================================
  // نافذة تفاصيل الفاتورة المنبثقة (Modal Dialog)
  // ==========================================
  Future<void> _openInvoiceModal(Map<String, dynamic> invoice) async {
    final db = await DatabaseHelper.instance.database;

    final items = await db.rawQuery('''
      SELECT 
        m.trade_name,
        ii.quantity,
        ii.unit_price,
        ii.total_price
      FROM invoice_item ii
      JOIN medicine m ON ii.medicine_id = m.id
      WHERE ii.invoice_id = ?
    ''', [invoice['id']]);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        final double subtotal = (invoice['total_amount'] as num?)?.toDouble() ?? 0.0;
        final double discount = (invoice['discount'] as num?)?.toDouble() ?? 0.0;
        final double finalTotal = (invoice['final_amount'] as num?)?.toDouble() ?? 0.0;

        return Directionality(
          textDirection: ui.TextDirection.rtl,
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
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFFA0AEC0)),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const Divider(height: 20, color: Color(0xFFEDF2F7)),

                    Table(
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
                            Padding(padding: EdgeInsets.all(8.0), child: Text("اسم الدواء", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            Padding(padding: EdgeInsets.all(8.0), child: Text("الكمية المباعة", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            Padding(padding: EdgeInsets.all(8.0), child: Text("سعر المفرد", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                            Padding(padding: EdgeInsets.all(8.0), child: Text("المجموع", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
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
                                child: Text((item['trade_name'] ?? "-").toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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
                                child: Text("${_currencyFormatter.format(price)} د.ع", style: const TextStyle(color: Color(0xFF4A5568), fontSize: 12)),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Text("${_currencyFormatter.format(total)} د.ع", style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2D3748), fontSize: 12)),
                              ),
                            ],
                          );
                        }),
                      ],
                    ),
                    const SizedBox(height: 20),

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
                              Text("${_currencyFormatter.format(subtotal)} د.ع", style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2D3748), fontSize: 13)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("الخصم المطبق:", style: TextStyle(color: Color(0xFFE53E3E), fontSize: 13)),
                              Text(
                                discount > 0 ? "-${_currencyFormatter.format(discount)} د.ع" : "0 د.ع",
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFE53E3E), fontSize: 13),
                              ),
                            ],
                          ),
                          const Divider(height: 20, color: Color(0xFFEDF2F7)),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("الصافي النهائي للمدفوع:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF38A169))),
                              Text("${_currencyFormatter.format(finalTotal)} د.ع", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF38A169))),
                            ],
                          ),
                        ],
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

  Future<void> _selectDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2099),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF1ABC9C),
              onPrimary: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      _loadReportData();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOwner) {
      return const Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          body: Center(
            child: Text(
              "عذراً، هذه الصفحة مخصصة للإدارة فقط.",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFC53030), fontFamily: 'Tajawal'),
            ),
          ),
        ),
      );
    }

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF1ABC9C)))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(25.0),
                child: Container(
                  padding: const EdgeInsets.all(25),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.only(bottom: 15),
                        margin: const EdgeInsets.only(bottom: 25),
                        decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: Color(0xFFF1F2F6), width: 2)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.insert_chart_rounded, color: Color(0xFF1ABC9C), size: 28),
                                SizedBox(width: 10),
                                Text(
                                  "تقارير وحركة المبيعات والمخزن ",
                                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50), fontFamily: 'Tajawal'),
                                ),
                              ],
                            ),
                            if (widget.isOwner)
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2C3E50),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                onPressed: _openShiftsModal,
                                icon: const Icon(Icons.badge_outlined, color: Colors.white, size: 18),
                                label: const Text("تقرير شفتات الموظفين", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                              ),
                          ],
                        ),
                      ),

                      Container(
                        padding: const EdgeInsets.all(20),
                        margin: const EdgeInsets.only(bottom: 25),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFEDF2F7)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("من تاريخ:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF4A5568))),
                                  const SizedBox(height: 6),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(color: const Color(0xFFCBD5E0)),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(_dateFormatter.format(_startDate), style: const TextStyle(fontSize: 14, color: Color(0xFF2D3748))),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 15),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("إلى تاريخ:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF4A5568))),
                                  const SizedBox(height: 6),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(color: const Color(0xFFCBD5E0)),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(_dateFormatter.format(_endDate), style: const TextStyle(fontSize: 14, color: Color(0xFF2D3748))),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 15),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1ABC9C),
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                              onPressed: _selectDateRange,
                              icon: const Icon(Icons.flash_on, color: Colors.white, size: 18),
                              label: const Text("تحديث واستخراج التقرير", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                            ),
                          ],
                        ),
                      ),

                      LayoutBuilder(
                        builder: (context, constraints) {
                          double width = (constraints.maxWidth - 45) / 4;
                          if (constraints.maxWidth < 800) width = (constraints.maxWidth - 15) / 2;

                          return Wrap(
                            spacing: 15,
                            runSpacing: 15,
                            children: [
                              _buildKpiCard("الإيراد الكلي", "${_currencyFormatter.format(_totalSales)} د.ع", Icons.payments, const Color(0xFF3182CE), width),
                              _buildKpiCard("إجمالي الخصومات المقدمة", "${_currencyFormatter.format(_totalDiscountsGiven)} د.ع", Icons.local_offer, const Color(0xFFDD6B20), width),
                              _buildKpiCard("عدد الفواتير الصادرة ", "$_totalInvoicesCount فاتورة", Icons.receipt, const Color(0xFF1ABC9C), width),
                              _buildKpiCard("عدد الفواتير الراجعة", "$_refundedInvoicesCount فاتورة", Icons.assignment_return, const Color(0xFFE53E3E), width),
                              _buildKpiCard("إجمالي الخسائر (توالف/منتهي)", "${_currencyFormatter.format(_totalDamageLosses)} د.ع", Icons.delete_forever, const Color(0xFFE53E3E), width),
                              _buildKpiCard("إجمالي المصروفات", "${_currencyFormatter.format(_totalExpenses)} د.ع", Icons.account_balance_wallet, const Color(0xFFE53E3E), width),
                              _buildKpiCard("صافي المبيعات بعد المصروفات", "${_currencyFormatter.format(_totalSales - _totalExpenses)} د.ع", Icons.calculate, const Color(0xFF3182CE), width),
                              _buildKpiCard("إجمالي ديون المذاخر\nالرصيد الحالي", "${_currencyFormatter.format(_totalSupplierDebt)} د.ع", Icons.local_shipping, const Color(0xFFDD6B20), width),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 30),

                      LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth > 900) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 6, child: _buildTopSellingPanel()),
                                const SizedBox(width: 25),
                                Expanded(flex: 5, child: _buildStagnantPanel()),
                              ],
                            );
                          } else {
                            return Column(
                              children: [
                                _buildTopSellingPanel(),
                                const SizedBox(height: 25),
                                _buildStagnantPanel(),
                              ],
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 30),

                      _buildInvoicesTableContainer(),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildKpiCard(String title, String value, IconData icon, Color color, double width) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12, offset: const Offset(0, 4))],
        border: Border(top: BorderSide(color: color, width: 4)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(title, style: const TextStyle(fontSize: 13, color: Color(0xFF718096), fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          Text(value, style: TextStyle(fontSize: 20, color: color == const Color(0xFF1ABC9C) ? const Color(0xFF2D3748) : color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildTopSellingPanel() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12)],
        border: const Border(top: BorderSide(color: Color(0xFF805AD5), width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.local_fire_department, color: Color(0xFFE53E3E), size: 20),
              SizedBox(width: 8),
              Text("الأدوية الأكثر طلباً ومبيعاً (Top 5 )", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2D3748))),
            ],
          ),
          const Divider(height: 24, color: Color(0xFFEDF2F7)),
          _topSellingItems.isEmpty
              ? const Padding(padding: EdgeInsets.all(20), child: Center(child: Text("لا توجد مبيعات مسجلة في هذه الفترة .", style: TextStyle(color: Color(0xFFA0AEC0)))))
              : Table(
                  columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1.2), 2: FlexColumnWidth(1.2)},
                  children: [
                    const TableRow(
                      decoration: BoxDecoration(color: Color(0xFFF7FAFC)),
                      children: [
                        Padding(padding: EdgeInsets.all(10), child: Text("الاسم التجاري (العلمي)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                        Padding(padding: EdgeInsets.all(10), child: Text("الكمية المباعة", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                        Padding(padding: EdgeInsets.all(10), child: Text("العائدات المادية", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                      ],
                    ),
                    ..._topSellingItems.map((item) {
                      final qty = (item['total_qty'] as num?)?.toInt() ?? 0;
                      final revenue = (item['total_revenue'] as num?)?.toDouble() ?? 0.0;

                      return TableRow(
                        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEDF2F7)))),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text((item['trade_name'] ?? "-").toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                Text((item['scientific_name'] ?? "").toString(), style: const TextStyle(fontSize: 11, color: Color(0xFF718096))),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: const Color(0xFFC6F6D5), borderRadius: BorderRadius.circular(50)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.done_all, size: 12, color: Color(0xFF22543D)),
                                  const SizedBox(width: 4),
                                  Text("$qty قطعة", style: const TextStyle(color: Color(0xFF22543D), fontSize: 11, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Text("${_currencyFormatter.format(revenue)} د.ع", style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2D3748), fontSize: 12)),
                          ),
                        ],
                      );
                    }),
                  ],
                ),
        ],
      ),
    );
  }

  Widget _buildStagnantPanel() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 12)],
        border: const Border(top: BorderSide(color: Color(0xFFDD6B20), width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.ac_unit, color: Color(0xFF3182CE), size: 20),
              SizedBox(width: 8),
              Text("أدوية راكدة (لم تبع مطلقاً بالفترة)", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2D3748))),
            ],
          ),
          const Divider(height: 24, color: Color(0xFFEDF2F7)),
          _stagnantMedicines.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle, color: Color(0xFF38A169), size: 18),
                        SizedBox(width: 6),
                        Text("جميع الأدوية نشطة ولها حركة بيع !", style: TextStyle(color: Color(0xFF38A169), fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                )
              : Table(
                  columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1.2), 2: FlexColumnWidth(1)},
                  children: [
                    const TableRow(
                      decoration: BoxDecoration(color: Color(0xFFF7FAFC)),
                      children: [
                        Padding(padding: EdgeInsets.all(10), child: Text("الدواء", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                        Padding(padding: EdgeInsets.all(10), child: Text("المتبقي بالرف الموحد", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                        Padding(padding: EdgeInsets.all(10), child: Text("الشكل الدوائي", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                      ],
                    ),
                    ..._stagnantMedicines.map((med) {
                      final qty = (med['quantity'] as num?)?.toInt() ?? 0;

                      return TableRow(
                        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEDF2F7)))),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text((med['trade_name'] ?? "-").toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                Text((med['scientific_name'] ?? "").toString(), style: const TextStyle(fontSize: 11, color: Color(0xFF718096))),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: const Color(0xFFFEEBC8), borderRadius: BorderRadius.circular(50)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.archive, size: 12, color: Color(0xFFC05621)),
                                  const SizedBox(width: 4),
                                  Text("$qtyقطعة", style: const TextStyle(color: Color(0xFFC05621), fontSize: 11, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Text((med['category'] ?? "-").toString(), style: const TextStyle(color: Color(0xFF4A5568), fontSize: 12)),
                          ),
                        ],
                      );
                    }),
                  ],
                ),
        ],
      ),
    );
  }

  Widget _buildInvoicesTableContainer() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.description, color: Color(0xFF3182CE), size: 20),
              SizedBox(width: 8),
              Text("الفواتير الصادرة بالفترة المحددة", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50))),
            ],
          ),
          const SizedBox(height: 15),
          _invoices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(30),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.description_outlined, size: 40, color: Color(0xFFCBD5E0)),
                        SizedBox(height: 8),
                        Text("لم تصدر أي فاتورة خلال التواريخ المحددة.", style: TextStyle(color: Color(0xFFA0AEC0))),
                      ],
                    ),
                  ),
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(const Color(0xFFF7FAFC)),
                    columns: const [
                      DataColumn(label: Text("رقم الفاتورة", style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text("تاريخ الصدور ", style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text("المجموع الإجمالي", style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text("الخصم ", style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text("الصافي المدفوع ", style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text("إجراءات ", style: TextStyle(fontWeight: FontWeight.bold))),
                    ],
                    rows: _invoices.map((inv) {
                      final subtotal = (inv['total_amount'] as num?)?.toDouble() ?? 0.0;
                      final discount = (inv['discount'] as num?)?.toDouble() ?? 0.0;
                      final finalAmount = (inv['final_amount'] as num?)?.toDouble() ?? 0.0;

                      return DataRow(cells: [
                        DataCell(Text((inv['invoice_number'] ?? "-").toString(), style: const TextStyle(fontWeight: FontWeight.bold))),
                        DataCell(Text(_formatDateTime((inv['created_at'] ?? "-").toString()), style: const TextStyle(color: Color(0xFF4A5568)))),
                        DataCell(Text("${_currencyFormatter.format(subtotal)} د.ع", style: const TextStyle(color: Color(0xFF718096)))),
                        DataCell(Text("${_currencyFormatter.format(discount)} د.ع", style: const TextStyle(color: Color(0xFFE53E3E)))),
                        DataCell(Text("${_currencyFormatter.format(finalAmount)} د.ع", style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF38A169)))),
                        DataCell(
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: const Color(0xFFEDF2F7),
                              side: const BorderSide(color: Color(0xFFCBD5E0)),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            ),
                            onPressed: () => _openInvoiceModal(inv),
                            icon: const Icon(Icons.article_outlined, size: 14, color: Color(0xFF4A5568)),
                            label: const Text("تفاصيل الفاتورة", style: TextStyle(color: Color(0xFF4A5568), fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ]);
                    }).toList(),
                  ),
                ),
        ],
      ),
    );
  }
}