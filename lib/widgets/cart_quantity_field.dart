import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// حقل كمية سطر في سلة البيع، قابل للكتابة مباشرة:
///  - أرقام فقط (بلا سالب ولا كسور)؛
///  - الحد الأدنى 1، والأقصى [maxQuantity] (المخزون المتاح): الأكبر يُقصّ إليه
///    ويُبلَّغ عبر [onCapped]؛
///  - فارغ أو 0 عند مغادرة الحقل يعود للقيمة السابقة (الحذف بزر الحذف فقط).
/// كل قيمة صحيحة تُرسل فوراً عبر [onChanged] فيتحدث إجمالي السطر والفاتورة حياً.
class CartQuantityField extends StatefulWidget {
  final int quantity;
  final int maxQuantity;
  final ValueChanged<int> onChanged;
  final ValueChanged<int>? onCapped;

  /// بعد Enter (مثلاً لإعادة التركيز لحقل الباركود).
  final VoidCallback? onSubmitted;

  const CartQuantityField({
    super.key,
    required this.quantity,
    required this.maxQuantity,
    required this.onChanged,
    this.onCapped,
    this.onSubmitted,
  });

  @override
  State<CartQuantityField> createState() => _CartQuantityFieldState();
}

class _CartQuantityFieldState extends State<CartQuantityField> {
  late final TextEditingController _controller = TextEditingController(text: '${widget.quantity}');
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _revertIfEmpty();
    });
  }

  @override
  void didUpdateWidget(CartQuantityField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // تغيّر من خارج الحقل (+/−، مسح نفس الصنف مرة أخرى): يُعرض الجديد.
    if (widget.quantity != oldWidget.quantity && int.tryParse(_controller.text) != widget.quantity) {
      _setText('${widget.quantity}');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _setText(String text) {
    _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  void _onChanged(String text) {
    final value = int.tryParse(text);
    if (value == null || value < 1) return; // فارغ/0: يُحسم عند المغادرة
    var accepted = value;
    if (value > widget.maxQuantity) {
      accepted = widget.maxQuantity;
      _setText('$accepted');
      widget.onCapped?.call(accepted);
    }
    if (accepted != widget.quantity) widget.onChanged(accepted);
  }

  void _revertIfEmpty() {
    final value = int.tryParse(_controller.text);
    if (value == null || value < 1) _setText('${widget.quantity}');
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        onChanged: _onChanged,
        onSubmitted: (_) {
          _revertIfEmpty();
          widget.onSubmitted?.call();
        },
        onTap: () => _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF1ABC9C), width: 1.5),
          ),
        ),
      ),
    );
  }
}
