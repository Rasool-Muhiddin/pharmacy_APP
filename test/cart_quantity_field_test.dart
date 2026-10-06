import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/models/medicine_categories.dart';
import 'package:pharmacy_app/widgets/cart_quantity_field.dart';

/// حقل كمية السلة في نقطة البيع: أرقام فقط، الحد الأدنى 1، الأقصى = المخزون، والفارغ يعود.
void main() {
  Future<({List<int> changes, List<int> capped})> pump(WidgetTester tester, {int quantity = 2, int max = 7}) async {
    final changes = <int>[];
    final capped = <int>[];
    var current = quantity;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              CartQuantityField(
                quantity: current,
                maxQuantity: max,
                onChanged: (v) => setState(() {
                  current = v;
                  changes.add(v);
                }),
                onCapped: capped.add,
              ),
              // زر خارجي (مثل +) يغيّر الكمية من خارج الحقل.
              TextButton(onPressed: () => setState(() => current = current + 1), child: const Text('plus')),
              const TextField(key: Key('other')),
            ],
          ),
        ),
      ),
    ));
    return (changes: changes, capped: capped);
  }

  String text(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  testWidgets('typing a valid quantity updates live', (tester) async {
    final r = await pump(tester);
    await tester.enterText(find.byType(TextField).first, '5');
    await tester.pump();
    expect(r.changes, [5]);
    expect(text(tester), '5');
  });

  testWidgets('digits only: minus, decimals and letters are filtered out', (tester) async {
    final r = await pump(tester);
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.inputFormatters!.whereType<FilteringTextInputFormatter>(), isNotEmpty);
    await tester.enterText(find.byType(TextField).first, '-3');
    await tester.pump();
    expect(text(tester), '3');
    await tester.enterText(find.byType(TextField).first, '4.5');
    await tester.pump();
    expect(text(tester).contains('.'), isFalse); // '4.5' → '45' ثم يُقصّ للمخزون 7
    expect(text(tester), '7');
    await tester.enterText(find.byType(TextField).first, 'abc');
    await tester.pump();
    expect(text(tester), '');
    expect(r.changes.every((v) => v >= 1), isTrue);
  });

  testWidgets('above stock is capped to the available quantity with a notice', (tester) async {
    final r = await pump(tester, max: 7);
    await tester.enterText(find.byType(TextField).first, '25');
    await tester.pump();
    expect(text(tester), '7');
    expect(r.changes.last, 7);
    expect(r.capped, [7]);
  });

  testWidgets('empty or 0 reverts to the previous value when leaving the field', (tester) async {
    final r = await pump(tester, quantity: 3);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    expect(r.changes, isEmpty); // لا حذف ولا تغيير أثناء الكتابة
    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();
    expect(text(tester), '3');

    await tester.enterText(find.byType(TextField).first, '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(text(tester), '3');
    expect(r.changes, isEmpty);
  });

  testWidgets('external changes (+ button) are reflected in the field', (tester) async {
    await pump(tester, quantity: 2);
    await tester.tap(find.text('plus'));
    await tester.pump();
    expect(text(tester), '3');
  });

  test('new dosage form options exist and unknown legacy values are shown as-is', () {
    expect(medicineCategories['medical_supplies'], 'مستلزمات طبية / أجهزة');
    expect(medicineCategories['care_cosmetics'], 'مستحضرات عناية / تجميل');
    expect(medicineCategories['other'], 'أخرى');
    expect(medicineCategoryLabel('tablet'), 'حبوب / كبسول');
    expect(medicineCategoryLabel('legacy_value'), 'legacy_value');
    expect(medicineCategoryLabel(null), 'غير محدد');
  });
}
