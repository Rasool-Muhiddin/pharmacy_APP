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
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? _accent.withValues(alpha: 0.06) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: active ? _accent : Colors.grey.shade300, width: active ? 1.5 : 1),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T?>(
          value: value,
          isExpanded: true,
          icon: Icon(icon, size: 18, color: _accent),
          style: const TextStyle(fontSize: 13, color: Color(0xFF1E293B)),
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
