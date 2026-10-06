import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/purchase_list.dart';
import '../models/purchase_return.dart';
import '../repository/suppliers_repository.dart';
import '../utils/formatters.dart';
import '../widgets/unsaved_changes_guard.dart';

/// نافذة "إضافة استرجاع": أدوية فقط من أصناف الفاتورة. لكل سطر يُعرض المشترى
/// (مدفوع + بونص)، المسترجع سابقاً، والمخزون الحالي؛ الحد الأقصى = min(المتبقي
/// من السطر، المخزون)، والرصيد للوحدات المدفوعة فقط × سعر الاسترجاع. ترجع true
/// بعد الحفظ.
Future<bool> showPurchaseReturnDialog(
  BuildContext context, {
  required int pharmacyId,
  required bool isOnlineMode,
  required Map<String, dynamic> invoice,
  required List<Map<String, dynamic>> items,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => PurchaseReturnDialog(
      pharmacyId: pharmacyId,
      isOnlineMode: isOnlineMode,
      invoice: invoice,
      items: items,
    ),
  );
  return saved == true;
}

const _primary = Color(0xFF1ABC9C);
const _primaryDark = Color(0xFF16A085);
const _textMain = Color(0xFF2C3E50);
const _textSecondary = Color(0xFF7F8C8D);
const _border = Color(0xFFE2E8F0);
const _danger = Color(0xFFDC2626);
const _free = Color(0xFF2ECC71);
const _returnColor = Color(0xFF2980B9);

class PurchaseReturnDialog extends StatefulWidget {
  final int pharmacyId;
  final bool isOnlineMode;
  final Map<String, dynamic> invoice;
  final List<Map<String, dynamic>> items;

  const PurchaseReturnDialog({
    super.key,
    required this.pharmacyId,
    required this.isOnlineMode,
    required this.invoice,
    required this.items,
  });

  @override
  State<PurchaseReturnDialog> createState() => _PurchaseReturnDialogState();
}

class _ReturnLine {
  final Map<String, dynamic> item;
  final quantity = TextEditingController();
  final price = TextEditingController();
  bool selected = false;
  String? error;

  _ReturnLine(this.item) {
    final buy = _num(item['buy_price']);
    price.text = buy == buy.roundToDouble() ? buy.toStringAsFixed(0) : buy.toStringAsFixed(2);
  }

  int get paid => _num(item['quantity']).toInt();
  int get bonus => _num(item['bonus_quantity']).toInt();
  int get alreadyReturned => _num(item['returned_quantity']).toInt();
  bool get isFree => paid == 0;

  /// null = الصنف حُذف من المخزون (لا يمكن استرجاعه).
  int? get stock => item['current_stock'] == null ? null : _num(item['current_stock']).toInt();

  int get limit => stock == null
      ? 0
      : returnableQuantity(paidQty: paid, bonusQty: bonus, alreadyReturned: alreadyReturned, currentStock: stock!);

  int get enteredQuantity => int.tryParse(quantity.text.trim()) ?? 0;

  double? get enteredPrice => double.tryParse(price.text.trim().replaceAll(',', ''));

  double get credit => selected
      ? returnLineCredit(
          paidQty: paid,
          alreadyReturned: alreadyReturned,
          quantity: enteredQuantity.clamp(0, limit),
          unitPrice: isFree ? 0 : (enteredPrice ?? 0),
        )
      : 0;

  void dispose() {
    quantity.dispose();
    price.dispose();
  }
}

double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;

class _PurchaseReturnDialogState extends State<PurchaseReturnDialog> {
  late final List<_ReturnLine> _lines = widget.items.map(_ReturnLine.new).toList();
  final _notes = TextEditingController();
  DateTime _date = DateTime.now();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  bool _isDirty() => _lines.any((l) => l.selected) || _notes.text.trim().isNotEmpty;

  double get _totalCredit => _lines.fold(0.0, (s, l) => s + l.credit);

  String? _validate(_ReturnLine line) {
    final qty = line.enteredQuantity;
    if (qty < 1) return 'أدخل الكمية المسترجعة (1 على الأقل).';
    if (qty > line.limit) return 'أقصى كمية يمكن استرجاعها ${line.limit}.';
    if (!line.isFree && (line.enteredPrice == null || line.enteredPrice! < 0)) return 'سعر الاسترجاع غير صحيح.';
    return null;
  }

  Future<void> _save() async {
    final selected = _lines.where((l) => l.selected).toList();
    setState(() {
      _error = null;
      for (final line in _lines) {
        line.error = line.selected ? _validate(line) : null;
      }
    });
    if (selected.isEmpty) {
      setState(() => _error = 'اختر صنفاً واحداً على الأقل لاسترجاعه.');
      return;
    }
    if (selected.any((l) => l.error != null)) return;

    setState(() => _saving = true);
    try {
      await SuppliersRepository.instance.returnPurchaseItems(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        purchaseInvoiceId: widget.invoice['id'] as int,
        lines: [
          for (final line in selected)
            {
              'purchase_invoice_item_id': line.item['id'],
              'quantity': line.enteredQuantity,
              'unit_price': line.isFree ? 0 : line.enteredPrice,
            },
        ],
        notes: _notes.text.trim(),
        returnDate: _date,
      );
      if (mounted) Navigator.of(context).pop(true); // pop (لا maybePop) بعد الحفظ
    } on PurchaseListException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        final index = e.line;
        if (index != null && index >= 0 && index < selected.length) {
          selected[index].error = e.message;
        } else {
          _error = e.message;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final number = widget.invoice['invoice_number']?.toString().trim() ?? '';
    return UnsavedChangesGuard(
      isDirty: _isDirty,
      message: 'لم يتم حفظ الاسترجاع، هل تريد الخروج بدون حفظ؟',
      leaveLabel: 'خروج بدون حفظ',
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Dialog(
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (size.width * 0.85).clamp(640.0, 1200.0).clamp(0.0, size.width - 32),
              maxHeight: size.height * 0.9,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: Color(0xFFE8F1FA),
                        child: Icon(Icons.keyboard_return_rounded, color: _returnColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'إضافة استرجاع — فاتورة ${number.isEmpty ? '#${widget.invoice['id']}' : '#$number'}',
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: _textMain),
                        ),
                      ),
                      IconButton(
                        tooltip: 'إغلاق',
                        onPressed: () => Navigator.maybePop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'حدد الأدوية المسترجعة. يُحسب الرصيد للوحدات المدفوعة فقط؛ البونص والأصناف المجانية بلا رصيد.',
                    style: TextStyle(color: _textSecondary, fontSize: 12.5),
                  ),
                ),
                const Divider(height: 20),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _lines.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _buildLine(_lines[i]),
                  ),
                ),
                _buildFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLine(_ReturnLine line) {
    final deleted = line.stock == null;
    final canReturn = line.limit > 0;
    final hasError = line.error != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: line.selected ? const Color(0xFFF4FAFE) : Colors.white,
        border: Border.all(color: hasError ? _danger : (line.selected ? _returnColor : _border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Checkbox(
                value: line.selected,
                activeColor: _returnColor,
                onChanged: !canReturn || _saving
                    ? null
                    : (v) => setState(() {
                          line.selected = v ?? false;
                          line.error = null;
                          if (line.selected && line.quantity.text.isEmpty) line.quantity.text = '${line.limit}';
                        }),
              ),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(line.item['trade_name']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                    if (line.isFree) _badge('مجاني', _free),
                    if (deleted) _badge('حُذف من المخزون', _danger),
                  ],
                ),
              ),
              Text(
                line.isFree
                    ? 'مشترى: مجاني ${line.bonus}'
                    : 'مشترى: ${line.paid}${line.bonus > 0 ? ' + بونص ${line.bonus}' : ''}',
                style: const TextStyle(color: _textSecondary, fontSize: 12.5),
              ),
              const SizedBox(width: 14),
              Text('مسترجع سابقاً: ${line.alreadyReturned}', style: const TextStyle(color: _textSecondary, fontSize: 12.5)),
              const SizedBox(width: 14),
              Text('بالمخزون: ${line.stock ?? '-'}', style: const TextStyle(color: _textSecondary, fontSize: 12.5)),
            ],
          ),
          if (line.selected)
            Padding(
              padding: const EdgeInsets.only(right: 48, top: 6),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 150,
                    child: TextField(
                      controller: line.quantity,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => setState(() => line.error = null),
                      decoration: _decoration('الكمية المسترجعة', helper: 'الحد الأقصى: ${line.limit}'),
                    ),
                  ),
                  if (!line.isFree)
                    SizedBox(
                      width: 170,
                      child: TextField(
                        controller: line.price,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                        onChanged: (_) => setState(() => line.error = null),
                        decoration: _decoration('سعر الاسترجاع للوحدة',
                            helper: 'سعر الشراء: ${AppFormatter.iqd(_num(line.item['buy_price']))}'),
                      ),
                    ),
                  Text(
                    'الرصيد: ${AppFormatter.iqd(line.credit)}',
                    style: const TextStyle(fontWeight: FontWeight.w800, color: _primaryDark),
                  ),
                  if (!line.isFree && line.enteredQuantity > 0)
                    Text(
                      _creditNote(line),
                      style: const TextStyle(fontSize: 12, color: _textSecondary),
                    ),
                ],
              ),
            ),
          if (hasError)
            Padding(
              padding: const EdgeInsets.only(right: 48, top: 6),
              child: Text(line.error!, style: const TextStyle(color: _danger, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  String _creditNote(_ReturnLine line) {
    final qty = line.enteredQuantity.clamp(0, line.limit);
    final credited = creditedUnits(paidQty: line.paid, alreadyReturned: line.alreadyReturned, quantity: qty);
    final noCredit = qty - credited;
    return noCredit > 0 ? '$credited وحدة مدفوعة + $noCredit بونص بلا رصيد' : '$credited وحدة مدفوعة';
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      margin: const EdgeInsets.only(top: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF1F8F8),
        border: Border(top: BorderSide(color: _border)),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: _danger, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _notes,
                  onChanged: (_) => setState(() {}),
                  decoration: _decoration('ملاحظات (اختياري)'),
                ),
              ),
              SizedBox(
                width: 170,
                child: InkWell(
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: _decoration('تاريخ الاسترجاع'),
                    child: Text(_fmtDate(_date)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('إجمالي رصيد الاسترجاع: ', style: TextStyle(color: Colors.grey.shade700)),
              Text(
                AppFormatter.iqdWithCurrency(_totalCredit),
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _primaryDark),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: _saving ? null : () => Navigator.maybePop(context),
                child: const Text('إلغاء', style: TextStyle(color: Colors.black87)),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(backgroundColor: _returnColor, elevation: 0),
                icon: _saving
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save_outlined, color: Colors.white),
                label: const Text('حفظ الاسترجاع', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: .13), borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
      );

  InputDecoration _decoration(String label, {String? helper}) => InputDecoration(
        labelText: label,
        helperText: helper,
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _primary, width: 1.5),
        ),
      );

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
    );
    if (picked != null) setState(() => _date = picked);
  }
}
