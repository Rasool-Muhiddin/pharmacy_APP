import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../repository/medicine_repository.dart';
import 'add_damage_dialog.dart';
import '../widgets/filter_dropdown.dart';
import '../widgets/stat_card.dart';

class DamagedScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOwner; // التأكد من صلاحية المالك

  /// وضع الأونلاين الحالي للصيدلية — يُمرَّر من نفس المكان الذي يحدّد به بقية
  /// التطبيق (inventory_screen، pos_screen...) الوضع الحالي، وليس افتراضاً
  /// محلياً هنا. عند true تمر كل عمليات الإتلاف عبر MedicineRepository بدل
  /// الكتابة المباشرة في db_helper، فتُطبَّق عليها نفس قواعد "لا كتابة بلا
  /// اتصال فعلي بالسيرفر" المطبَّقة على المخزون والمبيعات.
  final bool isOnlineMode;

  const DamagedScreen({
    super.key,
    required this.pharmacyId,
    required this.isOnlineMode,
    this.isOwner = true,
  });

  @override
  State<DamagedScreen> createState() => _DamagedScreenState();
}

class _DamagedScreenState extends State<DamagedScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _damagedList = [];
  double _totalLosses = 0.0;

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  // يتجاهل نتائج تحميل أقدم إن تغيّر البحث أثناء انتظارها.
  int _loadSeq = 0;

  final NumberFormat _currencyFormatter = NumberFormat("#,##0", "en_US");

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ==========================================
  // جلب بيانات التوالف والأدوية وتأطير الإحصائيات
  // ==========================================
  /// [sync] = true (فتح الشاشة وبعد أي إتلاف): مزامنة السجل وقائمة الأدوية من
  /// الخادم أونلاين. false (البحث الحي): فلترة آخر مزامنة محلياً فقط.
  Future<void> _loadData({bool sync = true}) async {
    _searchDebounce?.cancel();
    final seq = ++_loadSeq;
    if (sync) setState(() => _isLoading = true);
    try {
      final list = await MedicineRepository.instance.getDamagedMedicines(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        syncFromServer: sync,
        search: _searchController.text,
      );

      // إجمالي الخسائر للنتائج المعروضة: مجموع `loss` (الكلفة المسجّلة وقت
      // الإتلاف بالمتوسط المرجّح) — نفس رقم تقرير الخسائر والربح.
      // 🟢 سجلات "تصحيح إدخال" لا تُعتبر خسارة فعلية (الكمية لم تُفقد، فقط خطأ كتابة
      // أثناء إضافة الدواء أو تعديله)، لذلك تُستبعد من إجمالي الخسائر كالتقارير.
      double lossesSum = 0.0;
      for (var item in list) {
        if (item['reason'] == 'correction') continue;
        lossesSum += (item['loss'] as num?)?.toDouble() ?? 0.0;
      }
      lossesSum = DatabaseHelper.roundMoney(lossesSum);

      if (!mounted) return;
      if (seq != _loadSeq) {
        // مزامنة انتهت بعد بحث أحدث: النتيجة الأحدث قرأت الكاش قبل تحديثه.
        if (sync) unawaited(_loadData(sync: false));
        return;
      }
      setState(() {
        _damagedList = list;
        _totalLosses = lossesSum;
      });
    } catch (e) {
      if (mounted && seq == _loadSeq) {
        _showSnackBar("حدث خطأ أثناء تحميل البيانات: $e", isError: true);
      }
    } finally {
      if (mounted && seq == _loadSeq) setState(() => _isLoading = false);
    }
  }

  /// بحث حي: يُعاد التحميل بعد توقف الكتابة 300ms، لا مع كل حرف.
  void _onSearchChanged(String _) {
    setState(() {}); // زر المسح يظهر/يختفي مع النص.
    _searchDebounce?.cancel();
    _searchDebounce =
        Timer(const Duration(milliseconds: 300), () => _loadData(sync: false));
  }

  void _clearSearch() {
    _searchController.clear();
    _loadData(sync: false);
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        backgroundColor:
            isError ? const Color(0xFFC53030) : const Color(0xFF22543D),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  // ==========================================
  // نافذة إضافة دواء للتوالف
  // ==========================================
  Future<void> _showAddDamageDialog() async {
    if (!widget.isOwner) {
      _showSnackBar("عذراً، لا تمتلك الصلاحية لنقل الأدوية للتوالف.", isError: true);
      return;
    }
    final message = await showAddDamageDialog(
      context,
      pharmacyId: widget.pharmacyId,
      isOnlineMode: widget.isOnlineMode,
    );
    if (message == null || !mounted) return;
    _loadData();
    _showSnackBar(message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FAFC),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.report_problem,
                          color: Color(0xFFE53E3E), size: 28),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          "سجل الأدوية التالفة وإدارة الخسائر",
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2C3E50),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53E3E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: _showAddDamageDialog,
                  icon: const Icon(Icons.add),
                  label: const Text(
                    "تسجيل توالف جديدة",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            StatCardRow(
              cards: [
                StatCard(
                  title: "إجمالي الخسائر المالية (بالكلفة)",
                  value: "${_currencyFormatter.format(_totalLosses)} د.ع",
                  icon: Icons.trending_down,
                  accentColor: const Color(0xFFE53E3E),
                ),
                StatCard(
                  title: "عدد العمليات المسجلة",
                  value: "${_damagedList.length} عملية إتلاف",
                  icon: Icons.inventory_2_outlined,
                  accentColor: const Color(0xFF3182CE),
                  valueColor: const Color(0xFF2D3748),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.list_alt, color: Color(0xFF1ABC9C)),
                        SizedBox(width: 8),
                        Text(
                          "الأدوية التالفة المسجلة بالنظام",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2C3E50),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 15),
                    _buildSearchBar(),
                    const SizedBox(height: 15),
                    Expanded(
                      child: _isLoading
                          ? const Center(child: CircularProgressIndicator())
                          : _damagedList.isEmpty
                              ? _buildEmptyState()
                              : _buildDataTable(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// بحث حي باسم الدواء (التجاري/العلمي) أو سبب الإتلاف أو الملاحظات.
  Widget _buildSearchBar() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _loadData(sync: false),
            decoration: InputDecoration(
              hintText: '🔍 ابحث باسم الدواء أو سبب الإتلاف أو الملاحظات...',
              fillColor: Colors.white,
              filled: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: Color(0xFF1ABC9C), width: 1.5),
              ),
            ),
          ),
        ),
        if (_searchController.text.trim().isNotEmpty) ...[
          const SizedBox(width: 6),
          ClearFiltersButton(onPressed: _clearSearch),
        ],
      ],
    );
  }

  Widget _buildDataTable() {
    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                headingRowColor:
                    WidgetStateProperty.all(const Color(0xFF1ABC9C)),
                headingTextStyle: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                dataTextStyle: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF2D3748),
                ),
                columns: const [
                  DataColumn(label: Text("اسم الدواء العلمي والتجاري")),
                  DataColumn(label: Text("الكمية التالفة")),
                  DataColumn(label: Text("كلفة الوحدة")),
                  DataColumn(label: Text("خسارة العملية الإجمالية")),
                  DataColumn(label: Text("سبب الإتلاف")),
                  DataColumn(label: Text("تاريخ ووقت الإتلاف")),
                  DataColumn(label: Text("ملاحظات وتفاصيل")),
                ],
                rows: _damagedList.map((item) {
                  final qty = (item['quantity_damaged'] as num?)?.toInt() ?? 0;
                  // كلفة العملية كما في التقارير؛ كلفة الوحدة مشتقة منها.
                  final totalLoss = (item['loss'] as num?)?.toDouble() ?? 0.0;
                  final unitCost = qty > 0 ? totalLoss / qty : 0.0;
                  // 🟢 سجلات تصحيح الإدخال لا تُحتسب كخسارة، فتُعرض بلون محايد
                  // بدل الأحمر مع توضيح نصي بدل الرقم لتفادي أي التباس بصري.
                  final isCorrection = item['reason'] == 'correction';

                  return DataRow(
                    cells: [
                      DataCell(
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['trade_name'] ?? "دواء محذوف",
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              item['scientific_name'] ?? "-",
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xFF718096)),
                            ),
                          ],
                        ),
                      ),
                      DataCell(
                        Text(
                          "$qty قطعة",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFE53E3E),
                          ),
                        ),
                      ),
                      DataCell(
                          Text("${_currencyFormatter.format(unitCost)} د.ع")),
                      DataCell(
                        Text(
                          isCorrection
                              ? "لا تُحتسب"
                              : "${_currencyFormatter.format(totalLoss)} د.ع",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isCorrection
                                ? const Color(0xFF718096)
                                : const Color(0xFFE53E3E),
                            fontStyle: isCorrection
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ),
                      DataCell(_buildReasonBadge(item['reason'])),
                      DataCell(
                        Text(
                          item['damaged_at'] ?? "-",
                          style: const TextStyle(color: Color(0xFF4A5568)),
                        ),
                      ),
                      DataCell(
                        SizedBox(
                          width: 180,
                          child: Text(
                            (item['notes'] != null &&
                                    item['notes'].toString().isNotEmpty)
                                ? item['notes']
                                : "لا توجد ملاحظات",
                            style: TextStyle(
                              color: (item['notes'] != null &&
                                      item['notes'].toString().isNotEmpty)
                                  ? const Color(0xFF718096)
                                  : const Color(0xFFCBD5E0),
                              fontStyle: (item['notes'] == null ||
                                      item['notes'].toString().isEmpty)
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReasonBadge(String? reason) {
    String text = "أسباب أخرى";
    Color bgColor = const Color(0xFFEBF8FF);
    Color textColor = const Color(0xFF2B6CB0);
    IconData icon = Icons.inventory_2_outlined;

    final normalized = reason?.trim();

    if (normalized == 'broken' ||
        normalized == 'كسر وضرر' ||
        normalized == 'تالف / مكسور') {
      text = "كسر وضرر";
      bgColor = const Color(0xFFFAF5FF);
      textColor = const Color(0xFF6B46C1);
      icon = Icons.heart_broken_outlined;
    } else if (normalized == 'spoiled' || normalized == 'سوء خزن') {
      text = "سوء خزن";
      bgColor = const Color(0xFFFFF5F5);
      textColor = const Color(0xFFC53030);
      icon = Icons.wb_sunny_outlined;
    } else if (normalized == 'withdrawn' ||
        normalized == 'سحب وزاري' ||
        normalized == 'مسحوب من الشركة') {
      text = "سحب وزاري";
      bgColor = const Color(0xFFEDF2F7);
      textColor = const Color(0xFF4A5568);
      icon = Icons.block_outlined;
    } else if (normalized == 'expired') {
      text = "انتهاء الصلاحية";
      bgColor = const Color(0xFFFFFAF0);
      textColor = const Color(0xFFC05621);
      icon = Icons.event_busy_outlined;
    } else if (normalized == 'correction') {
      // 🟢 لا يُعتبر خسارة فعلية — لون محايد (رمادي مزرق) بدل درجات الأحمر/البنفسجي
      // المستخدمة لأسباب التلف الحقيقية، لتمييزه بصريًا في الجدول فورًا.
      text = "تصحيح إدخال";
      bgColor = const Color(0xFFF7FAFC);
      textColor = const Color(0xFF718096);
      icon = Icons.edit_note_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(50),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: textColor),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.folder_off_outlined,
              size: 60, color: Color(0xFFCBD5E0)),
          const SizedBox(height: 10),
          Text(
            _searchController.text.trim().isNotEmpty
                ? "لا توجد سجلات إتلاف مطابقة للبحث."
                : "لا توجد أدوية تالفة مسجلة في النظام حتى الآن.",
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFFA0AEC0),
            ),
          ),
        ],
      ),
    );
  }
}
