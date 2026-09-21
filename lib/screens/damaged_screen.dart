import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';

class DamagedScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOwner; // التأكد من صلاحية المالك

  const DamagedScreen({
    Key? key,
    required this.pharmacyId,
    this.isOwner = true,
  }) : super(key: key);

  @override
  State<DamagedScreen> createState() => _DamagedScreenState();
}

class _DamagedScreenState extends State<DamagedScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _damagedList = [];
  List<Map<String, dynamic>> _medicinesList = [];
  double _totalLosses = 0.0;

  final NumberFormat _currencyFormatter = NumberFormat("#,##0", "en_US");

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  // ==========================================
  // جلب بيانات التوالف والأدوية وتأطير الإحصائيات
  // ==========================================
  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final db = await DatabaseHelper.instance.database;

      // جلب سجلات التوالف مع أسماء واسعار الأدوية عبر JOIN
      final list = await db.rawQuery('''
        SELECT 
          dm.*, 
          m.trade_name, 
          m.scientific_name, 
          m.buy_price 
        FROM damaged_medicine dm
        LEFT JOIN medicine m ON dm.medicine_id = m.id
        WHERE dm.pharmacy_id = ?
        ORDER BY dm.id DESC
      ''', [widget.pharmacyId]);

      // جلب قائمة الأدوية المتاحة لإسقاطها في نافذة الإضافة
      final medicines =
          await DatabaseHelper.instance.getMedicines(widget.pharmacyId);

      // حساب إجمالي الخسائر المادية بسعر الشراء
      // 🟢 سجلات "تصحيح إدخال" لا تُعتبر خسارة فعلية (الكمية لم تُفقد، فقط خطأ كتابة
      // أثناء إضافة الدواء أو تعديله)، لذلك تُستبعد من إجمالي الخسائر.
      double lossesSum = 0.0;
      for (var item in list) {
        if (item['reason'] == 'correction') continue;
        final qty = (item['quantity_damaged'] as num?)?.toInt() ?? 0;
        final buyPrice = (item['buy_price'] as num?)?.toDouble() ?? 0.0;
        lossesSum += (qty * buyPrice);
      }

      setState(() {
        _damagedList = list;
        _medicinesList = medicines;
        _totalLosses = lossesSum;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar("حدث خطأ أثناء تحميل البيانات: $e", isError: true);
    }
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
                  fontFamily: 'Tajawal',
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: isError ? const Color(0xFFC53030) : const Color(0xFF22543D),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  // ==========================================
  // نافذة إضافة دواء للتوالف
  // ==========================================
  void _showAddDamageDialog() {
    if (!widget.isOwner) {
      _showSnackBar("عذراً، لا تمتلك الصلاحية لنقل الأدوية للتوالف.", isError: true);
      return;
    }

    final formKey = GlobalKey<FormState>();
    int? selectedMedicineId;
    final qtyController = TextEditingController();
    final notesController = TextEditingController();
    
    // تغيير الخيار الافتراضي إلى kser وضرر
    String selectedReason = 'broken';

    // تم حذف خيار 'expired' لأن الصلاحية تُعالج تلقائياً
    // 🟢 'correction': لتصحيح خطأ إدخال كمية أكبر من المطلوب عند إضافة/تعديل
    // الدواء — لا يُحتسب كخسارة فعلية لأن الكمية لم تُفقد أو تُتلف حقيقةً.
    final Map<String, String> reasons = {
      'broken': 'كسر وضرر',
      'spoiled': 'سوء خزن',
      'withdrawn': 'سحب وزاري',
      'correction': 'تصحيح إدخال (خطأ كمية)',
      'other': 'أسباب أخرى',
    };

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Map<String, dynamic>? selectedMedicine;
            if (selectedMedicineId != null) {
              final found = _medicinesList.where((m) => m['id'] == selectedMedicineId);
              if (found.isNotEmpty) {
                selectedMedicine = found.first;
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              title: Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFE53E3E)),
                  SizedBox(width: 8),
                  Text(
                    "نقل دواء إلى التوالف",
                    style: TextStyle(
                      fontFamily: 'Tajawal',
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 450,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButtonFormField<int>(
                          value: selectedMedicineId,
                          decoration: const InputDecoration(
                            labelText: "اختر الدواء *",
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.medication),
                          ),
                          items: _medicinesList.map((med) {
                            return DropdownMenuItem<int>(
                              value: med['id'] as int,
                              child: Text(
                                "${med['trade_name']} (المتوفر: ${med['quantity']})",
                                style: const TextStyle(fontFamily: 'Tajawal'),
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            setDialogState(() {
                              selectedMedicineId = val;
                            });
                          },
                          validator: (val) => val == null ? "الرجاء اختيار دواء" : null,
                        ),
                        const SizedBox(height: 15),

                        TextFormField(
                          controller: qtyController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: "الكمية التالفة *",
                            hintText: selectedMedicine != null
                                ? "أقصى كمية: ${selectedMedicine['quantity']}"
                                : "",
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.format_list_numbered),
                          ),
                          validator: (val) {
                            if (val == null || val.trim().isEmpty) {
                              return "الرجاء إدخال الكمية الصحيحة.";
                            }
                            final qty = int.tryParse(val);
                            if (qty == null) {
                              return "الرجاء إدخال رقم صحيح.";
                            }
                            if (qty <= 0) {
                              return "يجب أن تكون الكمية التالفة أكبر من الصفر.";
                            }
                            if (selectedMedicine != null &&
                                qty > (selectedMedicine['quantity'] as int)) {
                              return "الكمية المدخلة ($qty) أكبر من المتوفر في المخزن (${selectedMedicine['quantity']})!";
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 15),

                        DropdownButtonFormField<String>(
                          value: selectedReason,
                          decoration: const InputDecoration(
                            labelText: "سبب الإتلاف *",
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.category),
                          ),
                          items: reasons.entries.map((e) {
                            return DropdownMenuItem<String>(
                              value: e.key,
                              child: Text(
                                e.value,
                                style: const TextStyle(fontFamily: 'Tajawal'),
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) setDialogState(() => selectedReason = val);
                          },
                        ),
                        const SizedBox(height: 15),

                        TextFormField(
                          controller: notesController,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: "ملاحظات وتفاصيل (اختياري)",
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.note_alt_outlined),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("إلغاء", style: TextStyle(fontFamily: 'Tajawal')),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53E3E),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.check),
                  label: const Text(
                    "تأكيد الإتلاف",
                    style: TextStyle(fontFamily: 'Tajawal', fontWeight: FontWeight.bold),
                  ),
                  onPressed: () async {
                    if (formKey.currentState!.validate() && selectedMedicine != null) {
                      final qty = int.parse(qtyController.text.trim());
                      final medId = selectedMedicine['id'] as int;
                      final medName = selectedMedicine['trade_name'];

                      try {
                        await DatabaseHelper.instance.processDamageMedicine(
                          medicineId: medId,
                          pharmacyId: widget.pharmacyId,
                          quantityToDamage: qty,
                          reason: selectedReason,
                          notes: notesController.text.trim(),
                        );

                        if (!context.mounted) return;
                        Navigator.pop(context);
                        _loadData();
                        _showSnackBar(
                            "تم نقل ($qty قطعة) من دواء ($medName) إلى التوالف بنجاح.");
                      } catch (e) {
                        _showSnackBar("حدث خطأ أثناء معالجة الطلب: $e", isError: true);
                      }
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
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
                Row(
                  children: const [
                    Icon(Icons.report_problem, color: Color(0xFFE53E3E), size: 28),
                    SizedBox(width: 10),
                    Text(
                      "سجل الأدوية التالفة وإدارة الخسائر",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2C3E50),
                        fontFamily: 'Tajawal',
                      ),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53E3E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: _showAddDamageDialog,
                  icon: const Icon(Icons.add),
                  label: const Text(
                    "تسجيل توالف جديدة",
                    style: TextStyle(
                      fontFamily: 'Tajawal',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            LayoutBuilder(
              builder: (context, constraints) {
                return Row(
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        title: "إجمالي الخسائر المالية (بسعر الشراء)",
                        value: "${_currencyFormatter.format(_totalLosses)} د.ع",
                        icon: Icons.trending_down,
                        accentColor: const Color(0xFFE53E3E),
                        valueColor: const Color(0xFFE53E3E),
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: _buildStatCard(
                        title: "عدد العمليات المسجلة",
                        value: "${_damagedList.length} عملية إتلاف",
                        icon: Icons.inventory_2_outlined,
                        accentColor: const Color(0xFF3182CE),
                        valueColor: const Color(0xFF2D3748),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 25),

            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
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
                            fontFamily: 'Tajawal',
                          ),
                        ),
                      ],
                    ),
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

  Widget _buildStatCard({
    required String title,
    required String value,
    required IconData icon,
    required Color accentColor,
    required Color valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border(
          right: BorderSide(color: accentColor, width: 5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: accentColor),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF718096),
                  fontFamily: 'Tajawal',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: valueColor,
              fontFamily: 'Tajawal',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDataTable() {
    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(const Color(0xFF1ABC9C)),
            headingTextStyle: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontFamily: 'Tajawal',
            ),
            dataTextStyle: const TextStyle(
              fontFamily: 'Tajawal',
              fontSize: 13,
              color: Color(0xFF2D3748),
            ),
            columns: const [
              DataColumn(label: Text("اسم الدواء العلمي والتجاري")),
              DataColumn(label: Text("الكمية التالفة")),
              DataColumn(label: Text("سعر الشراء الفردي")),
              DataColumn(label: Text("خسارة العملية الإجمالية")),
              DataColumn(label: Text("سبب الإتلاف")),
              DataColumn(label: Text("تاريخ ووقت الإتلاف")),
              DataColumn(label: Text("ملاحظات وتفاصيل")),
            ],
            rows: _damagedList.map((item) {
              final qty = (item['quantity_damaged'] as num?)?.toInt() ?? 0;
              final buyPrice = (item['buy_price'] as num?)?.toDouble() ?? 0.0;
              final totalLoss = qty * buyPrice;
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
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          item['scientific_name'] ?? "-",
                          style: const TextStyle(fontSize: 11, color: Color(0xFF718096)),
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
                  DataCell(Text("${_currencyFormatter.format(buyPrice)} د.ع")),
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
                        fontStyle:
                            isCorrection ? FontStyle.italic : FontStyle.normal,
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
                        (item['notes'] != null && item['notes'].toString().isNotEmpty)
                            ? item['notes']
                            : "لا توجد ملاحظات",
                        style: TextStyle(
                          color: (item['notes'] != null && item['notes'].toString().isNotEmpty)
                              ? const Color(0xFF718096)
                              : const Color(0xFFCBD5E0),
                          fontStyle: (item['notes'] == null || item['notes'].toString().isEmpty)
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
    );
  }

  Widget _buildReasonBadge(String? reason) {
    String text = "أسباب أخرى";
    Color bgColor = const Color(0xFFEBF8FF);
    Color textColor = const Color(0xFF2B6CB0);
    IconData icon = Icons.inventory_2_outlined;

    final normalized = reason?.trim();

    if (normalized == 'broken' || normalized == 'كسر وضرر' || normalized == 'تالف / مكسور') {
      text = "كسر وضرر";
      bgColor = const Color(0xFFFAF5FF);
      textColor = const Color(0xFF6B46C1);
      icon = Icons.heart_broken_outlined;
    } else if (normalized == 'spoiled' || normalized == 'سوء خزن') {
      text = "سوء خزن";
      bgColor = const Color(0xFFFFF5F5);
      textColor = const Color(0xFFC53030);
      icon = Icons.wb_sunny_outlined;
    } else if (normalized == 'withdrawn' || normalized == 'سحب وزاري' || normalized == 'مسحوب من الشركة') {
      text = "سحب وزاري";
      bgColor = const Color(0xFFEDF2F7);
      textColor = const Color(0xFF4A5568);
      icon = Icons.block_outlined;
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
              fontFamily: 'Tajawal',
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
        children: const [
          Icon(Icons.folder_off_outlined, size: 60, color: Color(0xFFCBD5E0)),
          SizedBox(height: 10),
          Text(
            "لا توجد أدوية تالفة مسجلة في النظام حتى الآن.",
            style: TextStyle(
              fontSize: 14,
              color: Color(0xFFA0AEC0),
              fontFamily: 'Tajawal',
            ),
          ),
        ],
      ),
    );
  }
}