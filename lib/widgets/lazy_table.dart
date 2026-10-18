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
class LazyTable extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final minWidth = columns.fold<double>(0, (s, c) => s + c.width);
    return LayoutBuilder(builder: (context, constraints) {
      final width = math.max(constraints.maxWidth, minWidth);
      final scale = width / minWidth;

      Widget row(List<Widget> cells) => Row(
            children: [
              for (var i = 0; i < columns.length; i++)
                SizedBox(
                  width: columns[i].width * scale,
                  child: Padding(padding: cellPadding, child: Align(alignment: cellAlignment, child: cells[i])),
                ),
            ],
          );

      final hasFooter = footer != null;
      final body = Column(
        children: [
          Container(
            height: headerHeight,
            color: headerColor,
            child: DefaultTextStyle.merge(
              style: headerStyle,
              child: row([for (final c in columns) Text(c.label, maxLines: 2, overflow: TextOverflow.ellipsis)]),
            ),
          ),
          Expanded(
            child: Scrollbar(
              child: ListView.builder(
                itemCount: itemCount + (hasFooter ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == itemCount) return footer!;
                  return Container(
                    key: rowKey?.call(index),
                    height: rowHeight,
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0), width: 0.8))),
                    child: row(cellsBuilder(context, index)),
                  );
                },
              ),
            ),
          ),
        ],
      );
      if (width <= constraints.maxWidth) return body;
      return Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: width, height: constraints.maxHeight, child: body),
        ),
      );
    });
  }
}
