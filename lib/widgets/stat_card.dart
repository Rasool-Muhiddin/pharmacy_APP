import 'package:flutter/material.dart';

/// بطاقة إحصائية مختصرة (شاشتا التوالف والمصروفات): عنوان صغير بأيقونة،
/// قيمة بارزة، وشريط لوني على جهة البداية (اليمين في RTL).
class StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color accentColor;

  /// لون القيمة (الافتراضي [accentColor]).
  final Color? valueColor;

  const StatCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    required this.accentColor,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border(right: BorderSide(color: accentColor, width: 5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: accentColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF718096)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              value,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: valueColor ?? accentColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// صف بطاقات متساوية العرض؛ على العرض الضيق (< [stackBelow]) تُرصّ عمودياً.
class StatCardRow extends StatelessWidget {
  final List<StatCard> cards;
  final double spacing;
  final double stackBelow;

  const StatCardRow(
      {super.key,
      required this.cards,
      this.spacing = 16,
      this.stackBelow = 560});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < stackBelow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) SizedBox(height: spacing),
                cards[i],
              ],
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) SizedBox(width: spacing),
                Expanded(child: cards[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}
