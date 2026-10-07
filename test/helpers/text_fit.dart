import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// شاشات اللابتوب الشائعة + أصغر نافذة للحوار.
const laptopSizes = <String, Size>{
  '1366x768': Size(1366, 768),
  '1920x1080': Size(1920, 1080),
};

/// خط التطبيق الفعلي (Tajawal، نفس GoogleFonts.tajawalTextTheme في main.dart) كي
/// تُقاس النصوص بعرضها الحقيقي لا بخط الاختبار المربّع.
Future<void> loadAppFont() async {
  final loader = FontLoader('Tajawal')
    ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Tajawal-Regular.ttf').readAsBytesSync())))
    ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Tajawal-Bold.ttf').readAsBytesSync())));
  await loader.load();
}

/// ثيم التطبيق مع الخط المحمّل.
ThemeData appTheme() => ThemeData(
      useMaterial3: true,
      fontFamily: 'Tajawal',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff1abc9c),
        primary: const Color(0xff1abc9c),
        secondary: const Color(0xff148f77),
      ),
    );

/// النصوص المقصوصة داخل [within]: كل نص عرضه الكامل في سطر واحد أكبر من
/// المساحة المعطاة له (يُقص بـ"..." أو يُلف لسطر ثانٍ). [multiLine]: نصوص
/// شرح يُسمح لها بالالتفاف (تُطابق ببدايتها).
List<String> cutTexts(WidgetTester tester, Finder within, {List<String> multiLine = const []}) {
  final cut = <String>[];
  // skipOffstage: false — يشمل خيارات القوائم المنسدلة المخفية (تُرسم بعرض الزر).
  final texts = find.descendant(of: within, matching: find.byType(RichText, skipOffstage: false), skipOffstage: false);
  for (final element in texts.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    if (!paragraph.hasSize || paragraph.size.width == 0) continue;
    final text = paragraph.text.toPlainText();
    if (text.trim().isEmpty || multiLine.any(text.startsWith)) continue;
    final full = paragraph.getMaxIntrinsicWidth(double.infinity);
    if (full > paragraph.size.width + 0.5) {
      cut.add('"$text" needs ${full.toStringAsFixed(1)} has ${paragraph.size.width.toStringAsFixed(1)}');
    }
  }
  return cut;
}
