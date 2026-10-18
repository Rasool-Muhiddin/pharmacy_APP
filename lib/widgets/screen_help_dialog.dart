import 'package:flutter/material.dart';

import '../help/screen_help_content.dart';

const Color _accent = Color(0xFF1ABC9C);
const Color _textMain = Color(0xFF2C3E50);
const Color _textBody = Color(0xFF334155);

/// نافذة "معلومات الشاشة": ملخص، نقاط سريعة، وأقسام قابلة للطي (RTL، قابلة للتمرير).
Future<void> showScreenHelpDialog(BuildContext context, ScreenHelp help) {
  return showDialog<void>(
    context: context,
    builder: (_) => ScreenHelpDialog(help: help),
  );
}

class ScreenHelpDialog extends StatelessWidget {
  final ScreenHelp help;

  const ScreenHelpDialog({super.key, required this.help});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final body = Theme.of(context)
            .textTheme
            .bodyLarge
            ?.copyWith(fontSize: 15, height: 1.7, color: _textBody) ??
        const TextStyle(fontSize: 15, height: 1.7, color: _textBody);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: 760, maxHeight: size.height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 20, 8),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: _accent, size: 26),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        help.title,
                        key: const Key('screen-help-title'),
                        style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                            color: _textMain),
                      ),
                    ),
                    IconButton(
                      tooltip: 'إغلاق',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(help.summary,
                          style: body.copyWith(
                              fontWeight: FontWeight.w600, color: _textMain)),
                      if (help.points.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _Points(help.points, style: body),
                      ],
                      if (help.sections.isNotEmpty) const SizedBox(height: 12),
                      for (final section in help.sections)
                        _SectionTile(section, style: body, depth: 0),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: ElevatedButton(
                    key: const Key('screen-help-close'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('إغلاق'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  final HelpSection section;
  final TextStyle style;
  final int depth;

  const _SectionTile(this.section, {required this.style, required this.depth});

  @override
  Widget build(BuildContext context) {
    final top = depth == 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      // Material (لا Container ملوّن): ExpansionTile يرسم خلفيته وتأثير الضغط عليه.
      child: Material(
        color: top ? const Color(0xFFF8FAFC) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          // بلا خطوط ExpansionTile الافتراضية فوق/تحت القسم المفتوح.
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            iconColor: _accent,
            title: Text(
              section.title,
              style: TextStyle(
                  fontSize: top ? 16 : 15,
                  fontWeight: FontWeight.bold,
                  color: _textMain),
            ),
            children: [
              if (section.intro != null) ...[
                Text(section.intro!, style: style),
                const SizedBox(height: 6),
              ],
              if (section.points.isNotEmpty)
                _Points(section.points, style: style),
              if (section.children.isNotEmpty) const SizedBox(height: 8),
              for (final child in section.children)
                _SectionTile(child, style: style, depth: depth + 1),
            ],
          ),
        ),
      ),
    );
  }
}

class _Points extends StatelessWidget {
  final List<String> points;
  final TextStyle style;

  const _Points(this.points, {required this.style});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final point in points)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: 10, end: 8),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                        color: _accent, shape: BoxShape.circle),
                  ),
                ),
                Expanded(child: Text(point, style: style)),
              ],
            ),
          ),
      ],
    );
  }
}
