import 'package:flutter/material.dart';

/// قائمة فلتر منسدلة بجانب حقل البحث (شاشتا المخزون وسجل المبيعات): الخيار
/// الأول [allLabel] = بلا فلتر (null)، والإطار يتلوّن عند تفعيل الفلتر.
class FilterDropdown<T> extends StatelessWidget {
  final T? value;

  /// القيم بالترتيب مع نص كل منها.
  final Map<T, String> options;
  final String allLabel;
  final IconData icon;
  final double width;
  final double height;
  final ValueChanged<T?> onChanged;

  const FilterDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.allLabel,
    required this.icon,
    required this.onChanged,
    this.width = 170,
    this.height = 48,
  });

  static const Color _accent = Color(0xFF1ABC9C);

  @override
  Widget build(BuildContext context) {
    final active = value != null;
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsetsDirectional.only(start: 12, end: 6),
      decoration: BoxDecoration(
        color: active ? _accent.withValues(alpha: 0.06) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: active ? _accent : Colors.grey.shade300, width: active ? 1.5 : 1),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T?>(
          value: value,
          isExpanded: true,
          // أيقونة الفلتر في البداية وسهم القائمة في النهاية (بدل أن تحل الأيقونة محل السهم).
          icon: Icon(Icons.keyboard_arrow_down_rounded, color: active ? _accent : Colors.grey.shade600),
          // style يستبدل نمط الثيم كاملاً، فندمجه معه كي يبقى خط Tajawal كحقل البحث.
          style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
              .copyWith(fontSize: 13.5, color: const Color(0xFF1E293B)),
          alignment: AlignmentDirectional.centerStart,
          borderRadius: BorderRadius.circular(10),
          dropdownColor: Colors.white,
          menuMaxHeight: 360,
          selectedItemBuilder: (context) => [
            _selected(allLabel, active: false),
            for (final label in options.values) _selected(label, active: true),
          ],
          items: [
            DropdownMenuItem<T?>(value: null, child: Text(allLabel, overflow: TextOverflow.ellipsis)),
            for (final entry in options.entries)
              DropdownMenuItem<T?>(
                value: entry.key,
                child: Text(entry.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  /// النص الظاهر في الحقل المغلق: أيقونة الفلتر + الاختيار، بمحاذاة البداية (يمين في RTL).
  Widget _selected(String label, {required bool active}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: active ? _accent : Colors.grey.shade500),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: active ? FontWeight.bold : FontWeight.normal),
          ),
        ),
      ],
    );
  }
}

/// زر "مسح الفلاتر" الموحَّد (يظهر فقط عند وجود بحث أو فلتر مفعّل).
class ClearFiltersButton extends StatelessWidget {
  final VoidCallback onPressed;

  const ClearFiltersButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xFF64748B),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
      ),
      onPressed: onPressed,
      icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
      label: const Text('مسح الفلاتر'),
    );
  }
}
