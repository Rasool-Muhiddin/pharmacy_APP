import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../repository/expense_repository.dart';

class ExpensesScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOwner;

  /// وضع الأونلاين الحالي للصيدلية — نفس المعامل المُمرَّر لبقية الشاشات من
  /// MainLayout. عند true تمر كل عمليات القراءة/الإضافة/التعديل/الحذف عبر
  /// ExpenseRepository بدل db_helper مباشرة، فتُطبَّق عليها نفس قواعد "لا
  /// كتابة بلا اتصال فعلي بالسيرفر" المطبَّقة على المخزون والمبيعات.
  final bool isOnlineMode;

  const ExpensesScreen({
    super.key,
    required this.pharmacyId,
    required this.isOnlineMode,
    this.isOwner = true,
  });

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  static const _types = <String>[
    'إيجار',
    'كهرباء',
    'ماء',
    'رواتب',
    'نقل',
    'صيانة',
    'مستلزمات',
    'أخرى',
  ];

  final _dateFormat = DateFormat('yyyy-MM-dd');
  final _moneyFormat = NumberFormat('#,##0.##', 'en_US');
  late DateTime _startDate;
  late DateTime _endDate;
  String? _selectedType;
  bool _loading = true;
  List<Map<String, dynamic>> _expenses = [];

  @override
  void initState() {
    super.initState();
    final today = _dateOnly(DateTime.now());
    _startDate = today;
    _endDate = today;
    _loadExpenses();
  }

  DateTime _dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);

  Future<void> _loadExpenses() async {
    setState(() => _loading = true);
    try {
      final rows = await ExpenseRepository.instance.getExpenses(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        startDate: _dateFormat.format(_startDate),
        endDate: _dateFormat.format(_endDate),
        expenseType: _selectedType,
      );
      if (mounted) setState(() => _expenses = rows);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحميل المصروفات: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  double get _total => _expenses.fold<double>(
      0, (sum, item) => sum + ((item['amount'] as num?)?.toDouble() ?? 0));

  Map<String, double> get _totalsByType {
    final totals = <String, double>{};
    for (final item in _expenses) {
      final type = (item['expense_type'] ?? '').toString();
      totals[type] = (totals[type] ?? 0) + ((item['amount'] as num?)?.toDouble() ?? 0);
    }
    return totals;
  }

  Future<void> _pickRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: Color(0xFF1ABC9C)),
        ),
        child: child!,
      ),
    );
    if (range == null) return;
    setState(() {
      _startDate = _dateOnly(range.start);
      _endDate = _dateOnly(range.end);
    });
    _loadExpenses();
  }

  Future<void> _showExpenseDialog([Map<String, dynamic>? expense]) async {
    final isEditing = expense != null;
    final formKey = GlobalKey<FormState>();
    final amountController = TextEditingController(
        text: isEditing ? (expense['amount'] as num).toString() : '');
    final notesController = TextEditingController(
        text: isEditing ? (expense['notes'] ?? '').toString() : '');
    String selectedType = isEditing ? expense['expense_type'].toString() : _types.first;
    DateTime selectedDate = isEditing
        ? _dateOnly(DateTime.tryParse(expense['expense_date'].toString()) ?? DateTime.now())
        : _dateOnly(DateTime.now());

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => Directionality(
          textDirection: ui.TextDirection.rtl,
          child: AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: Text(isEditing ? 'تعديل مصروف' : 'إضافة مصروف'),
            content: SizedBox(
              width: 420,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      value: selectedType,
                      decoration: const InputDecoration(labelText: 'نوع المصروف'),
                      items: _types.map((type) => DropdownMenuItem(value: type, child: Text(type))).toList(),
                      onChanged: (value) => setDialogState(() => selectedType = value ?? _types.first),
                    ),
                    const SizedBox(height: 14),
                    InkWell(
                      onTap: () async {
                        final date = await showDatePicker(
                          context: context,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                          initialDate: selectedDate,
                        );
                        if (date != null) setDialogState(() => selectedDate = _dateOnly(date));
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: 'التاريخ', suffixIcon: Icon(Icons.calendar_today_outlined)),
                        child: Text(_dateFormat.format(selectedDate)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'المبلغ'),
                      validator: (value) {
                        final amount = double.tryParse((value ?? '').replaceAll(',', ''));
                        return amount == null || amount <= 0 ? 'أدخل مبلغاً صحيحاً أكبر من صفر' : null;
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: notesController,
                      decoration: const InputDecoration(labelText: 'الملاحظات'),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1ABC9C), foregroundColor: Colors.white),
                onPressed: () async {
                  if (!formKey.currentState!.validate()) return;
                  final data = <String, dynamic>{
                    'expense_type': selectedType,
                    'expense_date': _dateFormat.format(selectedDate),
                    'amount': double.parse(amountController.text.replaceAll(',', '')),
                    'notes': notesController.text.trim(),
                  };
                  try {
                    if (isEditing) {
                      await ExpenseRepository.instance.updateExpense(
                        pharmacyId: widget.pharmacyId,
                        isOnlineMode: widget.isOnlineMode,
                        id: expense['id'] as int,
                        data: data,
                      );
                    } else {
                      await ExpenseRepository.instance.addExpense(
                        pharmacyId: widget.pharmacyId,
                        isOnlineMode: widget.isOnlineMode,
                        data: data,
                      );
                    }
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                    await _loadExpenses();
                  } on ExpenseRepositoryException catch (e) {
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text(e.message)),
                      );
                    }
                  } catch (e) {
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text('تعذر حفظ المصروف: $e')),
                      );
                    }
                  }
                },
                child: const Text('حفظ'),
              ),
            ],
          ),
        ),
      ),
    );
    amountController.dispose();
    notesController.dispose();
  }

  Future<void> _deleteExpense(Map<String, dynamic> expense) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف المصروف'),
          content: const Text('هل تريد حذف هذا المصروف؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف', style: TextStyle(color: Colors.red))),
          ],
        ),
      ),
    );
    if (approved != true) return;
    try {
      await ExpenseRepository.instance.deleteExpense(
        isOnlineMode: widget.isOnlineMode,
        id: expense['id'] as int,
        pharmacyId: widget.pharmacyId,
      );
      await _loadExpenses();
    } on ExpenseRepositoryException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حذف المصروف: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOwner) return const Center(child: Text('عذراً، هذه الصفحة مخصصة للإدارة فقط.'));
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF1ABC9C)))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(25),
                child: Container(
                  padding: const EdgeInsets.all(30),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(color: Color(0x12000000), blurRadius: 16),
                    ],
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Row(children: [Icon(Icons.account_balance_wallet_outlined, color: Color(0xFFE53E3E), size: 29), SizedBox(width: 9), Text('المصروفات', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50)))]),
                    ElevatedButton.icon(onPressed: () => _showExpenseDialog(), icon: const Icon(Icons.add_circle_outline, size: 18), label: const Text('إضافة مصروف'), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1ABC9C), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)))),
                  ]),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Divider(color: Color(0xFFEDF2F7))),
                  const SizedBox(height: 22),
                  LayoutBuilder(builder: (context, constraints) {
                    final width = constraints.maxWidth > 700 ? (constraints.maxWidth - 16) / 2 : constraints.maxWidth;
                    return Wrap(spacing: 16, runSpacing: 16, children: [
                      _summaryCard('مصروفات اليوم', '${_moneyFormat.format(_total)} د.ع', Icons.payments_outlined, const Color(0xFFE53E3E), width),
                      _summaryCard('عدد المصروفات', '${_expenses.length} عملية', Icons.receipt_long_outlined, const Color(0xFF1ABC9C), width),
                    ]);
                  }),
                  const SizedBox(height: 22),
                  _filters(),
                  const SizedBox(height: 22),
                  _expensesTable(),
                  const SizedBox(height: 28),
                  _pieChart(),
                ]),
                ),
              ),
      ),
    );
  }

  Widget _summaryCard(String title, String value, IconData icon, Color color, double width) => Container(
    width: width, height: 150, padding: const EdgeInsets.all(25),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border(right: BorderSide(color: color, width: 6)), boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 12)]),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(icon, color: const Color(0xFF718096), size: 18), const SizedBox(width: 6), Text(title, style: const TextStyle(color: Color(0xFF718096), fontWeight: FontWeight.w600, fontSize: 15))]), const Spacer(), Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 25, color: color))]),
  );

  Widget _filters() => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFEDF2F7))),
    child: LayoutBuilder(builder: (context, constraints) {
      final typeSelector = DropdownButtonFormField<String?>(value: _selectedType, decoration: const InputDecoration(labelText: 'نوع المصروف', filled: true, fillColor: Colors.white, border: OutlineInputBorder()), items: [const DropdownMenuItem<String?>(value: null, child: Text('كل الأنواع')), ..._types.map((type) => DropdownMenuItem<String?>(value: type, child: Text(type)))], onChanged: (value) => setState(() => _selectedType = value));
      final searchButton = ElevatedButton.icon(onPressed: _loadExpenses, icon: const Icon(Icons.filter_alt_outlined, size: 18), label: const Text('بحث وتصفية'), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3182CE), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 17), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7))));

      if (constraints.maxWidth >= 850) {
        return Row(children: [
          Expanded(child: _filterDate('من تاريخ', _startDate)),
          const SizedBox(width: 14),
          Expanded(child: _filterDate('إلى تاريخ', _endDate)),
          const SizedBox(width: 14),
          Expanded(child: typeSelector),
          const SizedBox(width: 14),
          searchButton,
        ]);
      }
      return Wrap(spacing: 14, runSpacing: 14, crossAxisAlignment: WrapCrossAlignment.end, children: [
        SizedBox(width: 200, child: _filterDate('من تاريخ', _startDate)),
        SizedBox(width: 200, child: _filterDate('إلى تاريخ', _endDate)),
        SizedBox(width: 200, child: typeSelector),
        searchButton,
      ]);
    }),
  );

  Widget _filterDate(String label, DateTime date) => InkWell(
      onTap: _pickRange,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, filled: true, fillColor: Colors.white, border: const OutlineInputBorder(), suffixIcon: const Icon(Icons.calendar_month_outlined)),
        child: Text(_dateFormat.format(date)),
      ),
  );

  Widget _expensesTable() => Container(
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFEDF2F7))),
    child: _expenses.isEmpty ? const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('لا توجد مصروفات ضمن الفلاتر المحددة.'))) : LayoutBuilder(builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: DataTable(headingRowColor: WidgetStatePropertyAll(Color(0xFF1ABC9C)), headingTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15), columnSpacing: 80, columns: const [DataColumn(label: Text('التاريخ')), DataColumn(label: Text('نوع المصروف')), DataColumn(label: Text('المبلغ')), DataColumn(label: Text('إجراءات'))], rows: _expenses.map((expense) => DataRow(cells: [
        DataCell(Text(expense['expense_date'].toString())),
        DataCell(Text(expense['expense_type'].toString())),
        DataCell(Text('${_moneyFormat.format((expense['amount'] as num).toDouble())} د.ع', style: const TextStyle(color: Color(0xFFE53E3E), fontWeight: FontWeight.bold))),
        DataCell(Row(mainAxisSize: MainAxisSize.min, children: [OutlinedButton.icon(icon: const Icon(Icons.edit_outlined, size: 17), label: const Text('تعديل'), onPressed: () => _showExpenseDialog(expense), style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF3182CE), side: const BorderSide(color: Color(0xFFBFDBFE)))), const SizedBox(width: 8), OutlinedButton.icon(icon: const Icon(Icons.delete_outline, size: 17), label: const Text('حذف'), onPressed: () => _deleteExpense(expense), style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFE53E3E), side: const BorderSide(color: Color(0xFFFECACA))))])),
      ])).toList()),
      ),
    )),
  );

  Widget _pieChart() {
    final totals = _totalsByType;
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFEDF2F7))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('تحليل المصروفات حسب النوع', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        const SizedBox(height: 4), Text('للفترة من ${_dateFormat.format(_startDate)} إلى ${_dateFormat.format(_endDate)}', style: const TextStyle(color: Color(0xFF718096))),
        const SizedBox(height: 16),
        if (totals.isEmpty) const SizedBox(height: 180, child: Center(child: Text('لا توجد بيانات لعرض المخطط.'))) else LayoutBuilder(builder: (context, constraints) => constraints.maxWidth > 600 ? Row(children: [_chart(totals), const SizedBox(width: 30), Expanded(child: _legend(totals))]) : Column(children: [_chart(totals), const SizedBox(height: 16), _legend(totals)])),
      ]),
    );
  }

  Widget _chart(Map<String, double> totals) => SizedBox(width: 220, height: 220, child: CustomPaint(painter: _ExpensePiePainter(totals.values.toList())));

  Widget _legend(Map<String, double> totals) {
    final colors = _ExpensePiePainter.colors;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: totals.entries.toList().asMap().entries.map((entry) { final index = entry.key; final item = entry.value; return Padding(padding: const EdgeInsets.only(bottom: 9), child: Row(children: [Container(width: 12, height: 12, decoration: BoxDecoration(color: colors[index % colors.length], shape: BoxShape.circle)), const SizedBox(width: 8), Expanded(child: Text(item.key)), Text('${_moneyFormat.format(item.value)} د.ع', style: const TextStyle(fontWeight: FontWeight.bold))])); }).toList());
  }
}

class _ExpensePiePainter extends CustomPainter {
  final List<double> values;
  _ExpensePiePainter(this.values);
  static const colors = [Color(0xFF1ABC9C), Color(0xFF3182CE), Color(0xFFDD6B20), Color(0xFF9F7AEA), Color(0xFFE53E3E), Color(0xFF38A169), Color(0xFF4A5568), Color(0xFFF6AD55)];
  @override void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0, (a, b) => a + b); if (total <= 0) return;
    final rect = Offset.zero & size; var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) { final sweep = values[i] / total * 2 * math.pi; canvas.drawArc(rect.deflate(8), start, sweep, true, Paint()..color = colors[i % colors.length]..style = PaintingStyle.fill); start += sweep; }
    canvas.drawCircle(size.center(Offset.zero), size.shortestSide * .22, Paint()..color = Colors.white);
  }
  @override bool shouldRepaint(covariant _ExpensePiePainter old) => old.values != values;
}