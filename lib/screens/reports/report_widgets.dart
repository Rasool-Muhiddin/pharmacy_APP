import 'package:flutter/material.dart';

import '../../utils/formatters.dart';

/// ألوان وعناصر شاشة التقارير المشتركة بين التبويبات.
class RC {
  static const page = Color(0xFFF1F5F9);
  static const card = Colors.white;
  static const border = Color(0xFFE2E8F0);
  static const teal = Color(0xFF1ABC9C);
  static const tealDark = Color(0xFF117A65);
  static const tealLight = Color(0xFFA3E4D7);
  static const text = Color(0xFF1E293B);
  static const muted = Color(0xFF64748B);
  static const faint = Color(0xFFF8FAFC);
  static const green = Color(0xFF15803D);
  static const greenBg = Color(0xFFDCFCE7);
  static const red = Color(0xFFDC2626);
  static const redBg = Color(0xFFFEE2E2);
  static const orange = Color(0xFFC2410C);
  static const orangeBg = Color(0xFFFFEDD5);
  static const blue = Color(0xFF1D4ED8);
  static const blueBg = Color(0xFFDBEAFE);
  static const headerBg = Color(0xFFF7FAFC);
}

/// رقم من JSON (num أو نص عشري من الخادم).
double jn(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

int ji(Object? v) => jn(v).round();

String iqd(Object? v) => AppFormatter.iqdWithCurrency(jn(v));

String pct(double v) => '${v.toStringAsFixed(v.abs() >= 10 ? 0 : 1)}%';

/// تاريخ الفاتورة كما خُزّن (محلي): YYYY-MM-DD HH:MM بلا تحويل منطقة زمنية.
String shortDateTime(Object? raw) {
  final text = raw?.toString() ?? '';
  if (text.length < 16) return text.isEmpty ? '-' : text;
  return '${text.substring(0, 10)}  ${text.substring(11, 16)}';
}

BoxDecoration cardDecoration() => BoxDecoration(
      color: RC.card,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: RC.border),
    );

class ReportCard extends StatelessWidget {
  const ReportCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.subtitle,
    this.trailing,
    this.accent,
    this.padding = const EdgeInsets.all(16),
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final Color? accent;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? RC.tealDark;
    return Container(
      decoration: cardDecoration(),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 8,
            spacing: 12,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[Icon(icon, color: color, size: 20), const SizedBox(width: 8)],
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: RC.text)),
                        if (subtitle != null)
                          Text(subtitle!, style: const TextStyle(fontSize: 12, color: RC.muted)),
                      ],
                    ),
                  ),
                ],
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// شارة صغيرة (مثلاً "الوضع الحالي").
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color = RC.blue, this.background = RC.blueBg, this.icon});

  final String text;
  final Color color;
  final Color background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(50)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}

const currentStateTag = Tag('الوضع الحالي', icon: Icons.schedule);

/// صف من البطاقات يتحول لعمود تحت [breakpoint].
class ResponsiveRow extends StatelessWidget {
  const ResponsiveRow({super.key, required this.children, this.flex, this.breakpoint = 900, this.spacing = 16});

  final List<Widget> children;
  final List<int>? flex;
  final double breakpoint;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < breakpoint) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: spacing), children[i]],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(width: spacing),
            Expanded(flex: flex?[i] ?? 1, child: children[i]),
          ],
        ],
      );
    });
  }
}

/// مربع رقم صغير (قيمة + عنوان) داخل البطاقات.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.color = RC.text, this.hint});

  final String label;
  final String value;
  final Color color;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: RC.faint, borderRadius: BorderRadius.circular(10), border: Border.all(color: RC.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: RC.muted)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: color)),
          ),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(hint!, style: const TextStyle(fontSize: 11, color: RC.muted)),
          ],
        ],
      ),
    );
  }
}

/// شبكة StatTile: 2 أو 3 أو [maxColumns] بالعرض المتاح.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.tiles, this.maxColumns = 4, this.minTileWidth = 170});

  final List<Widget> tiles;
  final int maxColumns;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final columns = (c.maxWidth / minTileWidth).floor().clamp(1, maxColumns);
      final width = (c.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [for (final t in tiles) SizedBox(width: width, child: t)],
      );
    });
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.message, {super.key, this.icon = Icons.inbox_outlined});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(icon, size: 36, color: const Color(0xFFCBD5E1)),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(color: RC.muted, fontSize: 13)),
        ],
      ),
    );
  }
}

/// هيكل رمادي أثناء تحميل قسم.
class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({super.key, this.height = 120, this.lines = 3});

  final double height;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            FractionallySizedBox(
              widthFactor: i.isEven ? 0.9 : 0.6,
              child: Container(
                height: 14,
                decoration: BoxDecoration(color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ],
          const Spacer(),
          const LinearProgressIndicator(minHeight: 2, color: RC.teal, backgroundColor: Color(0xFFE2E8F0)),
        ],
      ),
    );
  }
}

class SectionError extends StatelessWidget {
  const SectionError({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: RC.redBg, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: RC.red, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text('تعذر تحميل هذا القسم: $error',
                style: const TextStyle(color: RC.red, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('إعادة المحاولة'),
            style: TextButton.styleFrom(foregroundColor: RC.red),
          ),
        ],
      ),
    );
  }
}

/// يعرض قسماً من [future]: هيكل أثناء التحميل، خطأ مع إعادة المحاولة، ثم [builder].
class SectionFuture extends StatelessWidget {
  const SectionFuture({
    super.key,
    required this.future,
    required this.builder,
    required this.onRetry,
    this.skeletonHeight = 120,
  });

  final Future<Map<String, dynamic>> future;
  final Widget Function(Map<String, dynamic> data) builder;
  final VoidCallback onRetry;
  final double skeletonHeight;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) return SectionError(error: snap.error!, onRetry: onRetry);
        if (snap.connectionState != ConnectionState.done || !snap.hasData) {
          return SkeletonBlock(height: skeletonHeight);
        }
        return builder(snap.data!);
      },
    );
  }
}

/// عمود جدول تقارير.
class RCol {
  const RCol(this.label, {this.width = 120, this.numeric = false});
  final String label;
  final double width;
  final bool numeric;
}

/// جدول بنفس رأس جداول المخزون/المذاخر، يتمدد بعرض البطاقة ويُمرَّر أفقياً
/// عندما يضيق العرض عن مجموع أعرض أعمدته.
class ReportTable extends StatelessWidget {
  const ReportTable({super.key, required this.columns, required this.rows, this.rowColors});

  final List<RCol> columns;
  final List<List<Widget>> rows;
  final List<Color?>? rowColors;

  @override
  Widget build(BuildContext context) {
    final minWidth = columns.fold<double>(0, (s, c) => s + c.width);
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth > minWidth ? c.maxWidth : minWidth;
      final scale = width / minWidth;
      Widget cell(int i, Widget child) => SizedBox(
            width: columns[i].width * scale,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Align(alignment: AlignmentDirectional.centerStart, child: child),
            ),
          );
      final table = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(color: RC.headerBg, borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              for (var i = 0; i < columns.length; i++)
                cell(
                  i,
                  Text(columns[i].label,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF4A5568))),
                ),
            ]),
          ),
          for (var r = 0; r < rows.length; r++)
            Container(
              decoration: BoxDecoration(
                color: rowColors?[r],
                border: const Border(bottom: BorderSide(color: Color(0xFFEDF2F7))),
              ),
              child: Row(children: [for (var i = 0; i < columns.length; i++) cell(i, rows[r][i])]),
            ),
        ],
      );
      if (width <= c.maxWidth) return table;
      return Scrollbar(
        child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: width, child: table)),
      );
    });
  }
}

Text cellText(String text, {Color color = RC.text, bool bold = false, double size = 12.5}) => Text(
      text,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: size, color: color, fontWeight: bold ? FontWeight.bold : FontWeight.normal),
    );

/// أزرار الصفحة السابقة/التالية.
class Pager extends StatelessWidget {
  const Pager({super.key, required this.page, required this.pageSize, required this.count, required this.onPage});

  final int page;
  final int pageSize;
  final int count;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    final pages = count == 0 ? 1 : ((count + pageSize - 1) ~/ pageSize);
    if (pages <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'السابق',
            onPressed: page > 1 ? () => onPage(page - 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
          Text('صفحة $page من $pages  •  $count سجل', style: const TextStyle(fontSize: 12.5, color: RC.muted)),
          IconButton(
            tooltip: 'التالي',
            onPressed: page < pages ? () => onPage(page + 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
        ],
      ),
    );
  }
}

/// قائمة أشرطة أفقية بحصة كل بند من المجموع.
class ShareBars extends StatelessWidget {
  const ShareBars({super.key, required this.entries, this.color = RC.teal});

  /// (التسمية، القيمة، نص إضافي اختياري)
  final List<(String, double, String?)> entries;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final total = entries.fold<double>(0, (s, e) => s + (e.$2 > 0 ? e.$2 : 0));
    return Column(
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(e.$1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: RC.text)),
                    ),
                    Text(
                      '${iqd(e.$2)}${e.$3 != null ? '  •  ${e.$3}' : ''}  •  ${pct(total > 0 ? e.$2 / total * 100 : 0)}',
                      style: const TextStyle(fontSize: 12, color: RC.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: total > 0 ? (e.$2 / total).clamp(0, 1) : 0,
                    minHeight: 8,
                    color: color,
                    backgroundColor: const Color(0xFFEDF2F7),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// زر بنص ولون غامق على أبيض (تباين كافٍ).
ButtonStyle tealButton() => ElevatedButton.styleFrom(
      backgroundColor: RC.tealDark,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
