import 'dart:math' as math;

import 'package:flutter/material.dart';

/// عمود في [LazyTable]: عنوانه وعرضه الأدنى (يتمدد العمود بنسبة عرضه إذا اتسعت المساحة).
class LazyColumn {
  final String label;
  final double width;

  const LazyColumn(this.label, this.width);
}

/// جدول بصف عناوين ثابت وصفوف تُبنى عند ظهورها فقط (ListView.builder)، بدل
/// DataTable داخل SingleChildScrollView الذي يبني كل الصفوف دفعة واحدة — فيبقى
/// فتح شاشة بآلاف الصفوف بنفس سرعة فتحها بعشرات. يحتاج ارتفاعاً محدوداً
/// (داخل Expanded). يُمرَّر أفقياً إذا ضاق العرض عن مجموع الأعمدة.
class LazyTable extends StatefulWidget {
  final List<LazyColumn> columns;
  final int itemCount;

  /// خلايا الصف [index] بترتيب [columns].
  final List<Widget> Function(BuildContext context, int index) cellsBuilder;
  final double rowHeight;
  final double headerHeight;
  final Color headerColor;
  final TextStyle headerStyle;
  final AlignmentGeometry cellAlignment;
  final EdgeInsetsGeometry cellPadding;

  /// عنصر أخير بعد الصفوف (مثلاً زر "تحميل المزيد").
  final Widget? footer;

  /// مفتاح كل صف (للاختبارات)، اختياري.
  final Key Function(int index)? rowKey;

  const LazyTable({
    super.key,
    required this.columns,
    required this.itemCount,
    required this.cellsBuilder,
    required this.rowHeight,
    required this.headerColor,
    required this.headerStyle,
    this.headerHeight = 50,
    this.cellAlignment = AlignmentDirectional.centerStart,
    this.cellPadding = const EdgeInsets.symmetric(horizontal: 12),
    this.footer,
    this.rowKey,
  });

  @override
  State<LazyTable> createState() => _LazyTableState();
}

class _LazyTableState extends State<LazyTable> {
  // متحكمات صريحة يتشاركها كل Scrollbar مع قائمته: بدونها لا يرتبط شريط التمرير
  // بالقائمة على سطح المكتب فلا يمكن سحبه بالفأرة.
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final columns = widget.columns;
    final minWidth = columns.fold<double>(0, (s, c) => s + c.width);
    // نرسم أشرطتنا بأنفسنا، فنُلغي الأشرطة التلقائية لسطح المكتب كي لا تتكرر.
    final behavior = ScrollConfiguration.of(context).copyWith(scrollbars: false);
    return LayoutBuilder(builder: (context, constraints) {
      final width = math.max(constraints.maxWidth, minWidth);
      final scale = width / minWidth;
      final overflowsX = width > constraints.maxWidth;

      Widget row(List<Widget> cells) => Row(
            children: [
              for (var i = 0; i < columns.length; i++)
                SizedBox(
                  width: columns[i].width * scale,
                  child: Padding(padding: widget.cellPadding, child: Align(alignment: widget.cellAlignment, child: cells[i])),
                ),
            ],
          );

      final hasFooter = widget.footer != null;
      final list = ListView.builder(
        controller: _vertical,
        itemCount: widget.itemCount + (hasFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == widget.itemCount) return widget.footer!;
          return Container(
            key: widget.rowKey?.call(index),
            height: widget.rowHeight,
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0), width: 0.8))),
            child: row(widget.cellsBuilder(context, index)),
          );
        },
      );

      Widget verticalBar(Widget child, {int depth = 0}) => Scrollbar(
            controller: _vertical,
            thumbVisibility: true,
            interactive: true,
            notificationPredicate: (n) => n.depth == depth && n.metrics.axis == Axis.vertical,
            child: child,
          );

      final body = Column(
        children: [
          Container(
            height: widget.headerHeight,
            color: widget.headerColor,
            child: DefaultTextStyle.merge(
              style: widget.headerStyle,
              child: row([for (final c in columns) Text(c.label, maxLines: 2, overflow: TextOverflow.ellipsis)]),
            ),
          ),
          // بلا تمرير أفقي: الشريط العمودي بجانب القائمة مباشرة.
          Expanded(child: overflowsX ? list : verticalBar(list)),
        ],
      );
      if (!overflowsX) return ScrollConfiguration(behavior: behavior, child: body);

      // مع التمرير الأفقي يبقى الشريط العمودي على حافة الشاشة الظاهرة (لا في آخر
      // المحتوى العريض خارج الشاشة)، والأفقي في الأسفل؛ عجلة الفأرة تمرر القائمة عمودياً.
      return ScrollConfiguration(
        behavior: behavior,
        child: verticalBar(
          depth: 1,
          Scrollbar(
            controller: _horizontal,
            thumbVisibility: true,
            interactive: true,
            notificationPredicate: (n) => n.depth == 0 && n.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: width, height: constraints.maxHeight, child: body),
            ),
          ),
        ),
      );
    });
  }
}
