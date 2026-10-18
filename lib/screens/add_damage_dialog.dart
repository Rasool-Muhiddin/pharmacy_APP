import 'dart:async';

import 'package:flutter/material.dart';

import '../models/damage_reasons.dart';
import '../repository/medicine_repository.dart';

/// نافذة "نقل دواء إلى التوالف" (شاشة الأدوية التالفة): الدواء يُختار بالبحث
/// بالاسم التجاري/العلمي أو الباركود (لا تُحمَّل كل الأصناف)، والسبب من نفس
/// قائمة زر "إتلاف" في المخزن ([damageReasons]). ترجع رسالة النجاح أو null.
Future<String?> showAddDamageDialog(
  BuildContext context, {
  required int pharmacyId,
  required bool isOnlineMode,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => AddDamageDialog(pharmacyId: pharmacyId, isOnlineMode: isOnlineMode),
  );
}

class AddDamageDialog extends StatefulWidget {
  final int pharmacyId;
  final bool isOnlineMode;

  const AddDamageDialog({super.key, required this.pharmacyId, required this.isOnlineMode});

  @override
  State<AddDamageDialog> createState() => _AddDamageDialogState();
}

class _AddDamageDialogState extends State<AddDamageDialog> {
  final _formKey = GlobalKey<FormState>();
  final _searchController = TextEditingController();
  final _qtyController = TextEditingController();
  final _notesController = TextEditingController();
  Timer? _debounce;
  // يتجاهل نتيجة بحث أقدم إن وصل نص أحدث أثناء انتظارها.
  int _searchSeq = 0;
  bool _searching = false;
  List<Map<String, dynamic>> _results = [];
  Map<String, dynamic>? _selected;
  String _reason = 'broken';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _qtyController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  int get _available => (_selected?['quantity'] as num?)?.toInt() ?? 0;

  /// بحث بعد توقف الكتابة 300ms، لا مع كل حرف.
  void _onQueryChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      _searchSeq++;
      setState(() {
        _results = [];
        _searching = false;
      });
      return;
    }
    setState(() {}); // يُخفي "لا توجد نتائج" القديمة حتى يصل البحث الجديد.
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  Future<void> _search(String text) async {
    final seq = ++_searchSeq;
    setState(() => _searching = true);
    try {
      final rows = await MedicineRepository.instance.searchMedicinesForPicker(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        query: text,
      );
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = rows;
        _searching = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searching = false;
        _error = 'تعذر البحث: $e';
      });
    }
  }

  void _select(Map<String, dynamic> med) {
    _debounce?.cancel();
    _searchSeq++;
    setState(() {
      _selected = med;
      _results = [];
      _searching = false;
      _error = null;
    });
  }

  void _clearSelection() {
    _searchController.clear();
    setState(() => _selected = null);
  }

  Future<void> _save() async {
    if (_selected == null) {
      setState(() => _error = 'الرجاء اختيار الدواء من نتائج البحث.');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final qty = int.parse(_qtyController.text.trim());
    final med = _selected!;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await MedicineRepository.instance.damageMedicine(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        medicineId: med['id'] as int,
        quantityToDamage: qty,
        reason: _reason,
        notes: _notesController.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, 'تم نقل ($qty قطعة) من دواء (${med['trade_name']}) إلى التوالف بنجاح.');
    } on MedicineRepositoryException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'حدث خطأ أثناء معالجة الطلب: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _subtitle(Map<String, dynamic> med) {
    String text(Object? v) => (v ?? '').toString().trim();
    return [
      text(med['scientific_name']),
      text(med['barcode']),
      if (text(med['warehouse_name']).isNotEmpty) 'المخزن: ${text(med['warehouse_name'])}',
    ].where((t) => t.isNotEmpty).join('  •  ');
  }

  Widget _searchField() {
    return TextField(
      key: const Key('damage-medicine-search'),
      controller: _searchController,
      autofocus: true,
      onChanged: _onQueryChanged,
      decoration: InputDecoration(
        labelText: 'ابحث عن الدواء *',
        hintText: 'الاسم التجاري أو العلمي أو الباركود',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searching
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : null,
      ),
    );
  }

  Widget _resultsList() {
    if (_results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('لا توجد أصناف متوفرة مطابقة.', style: TextStyle(color: Color(0xFF718096))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.white,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _results.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final med = _results[i];
                final subtitle = _subtitle(med);
                return ListTile(
                  key: Key('damage-result-${med['id']}'),
                  dense: true,
                  title: Text('${med['trade_name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: subtitle.isEmpty ? null : Text(subtitle),
                  trailing: Text('المتوفر: ${med['quantity']}'),
                  onTap: () => _select(med),
                );
              },
            ),
          ),
        ),
        if (_results.length >= MedicineRepository.pickerLimit)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'تُعرض أول ${MedicineRepository.pickerLimit} نتيجة؛ اكتب المزيد لتضييق البحث.',
              style: TextStyle(fontSize: 12, color: Color(0xFF718096)),
            ),
          ),
      ],
    );
  }

  Widget _selectedCard(Map<String, dynamic> med) {
    return Container(
      key: const Key('damage-selected-medicine'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF86EFAC)),
      ),
      child: Row(
        children: [
          const Icon(Icons.medication, color: Color(0xFF16A34A)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${med['trade_name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('المتوفر: $_available', style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          TextButton(onPressed: _clearSelection, child: const Text('تغيير')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final showResults = selected == null && _searchController.text.trim().isNotEmpty && !_searching && _debounce?.isActive != true;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Color(0xFFE53E3E)),
          SizedBox(width: 8),
          Text('نقل دواء إلى التوالف', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (selected == null) _searchField() else _selectedCard(selected),
                if (showResults) ...[const SizedBox(height: 6), _resultsList()],
                const SizedBox(height: 15),
                TextFormField(
                  key: const Key('damage-quantity'),
                  controller: _qtyController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'الكمية التالفة *',
                    hintText: selected != null ? 'أقصى كمية: $_available' : '',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.format_list_numbered),
                  ),
                  validator: (val) {
                    final qty = int.tryParse((val ?? '').trim());
                    if (qty == null) return 'الرجاء إدخال رقم صحيح.';
                    if (qty <= 0) return 'يجب أن تكون الكمية التالفة أكبر من الصفر.';
                    if (qty > _available) return 'الكمية المدخلة ($qty) أكبر من المتوفر في المخزن ($_available)!';
                    return null;
                  },
                ),
                const SizedBox(height: 15),
                DropdownButtonFormField<String>(
                  key: const Key('damage-reason'),
                  initialValue: _reason,
                  decoration: const InputDecoration(
                    labelText: 'سبب الإتلاف *',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.category),
                  ),
                  items: [
                    for (final e in damageReasons.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _reason = val);
                  },
                ),
                const SizedBox(height: 15),
                TextFormField(
                  controller: _notesController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظات وتفاصيل (اختياري)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.note_alt_outlined),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: Color(0xFFC53030), fontWeight: FontWeight.bold)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton.icon(
          key: const Key('damage-confirm'),
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE53E3E), foregroundColor: Colors.white),
          icon: const Icon(Icons.check),
          label: const Text('تأكيد الإتلاف', style: TextStyle(fontWeight: FontWeight.bold)),
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
