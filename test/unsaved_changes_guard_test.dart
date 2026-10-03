import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/widgets/unsaved_changes_guard.dart';

const String message = 'لم يتم حفظ العنصر، هل تريد الخروج بدون حفظ؟';

void main() {
  group('UnsavedChangesGuard on a dialog', () {
    late TextEditingController field;
    late bool saved;

    Future<void> openDialog(WidgetTester tester) async {
      field = TextEditingController();
      saved = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog(
                  context: context,
                  builder: (ctx) => UnsavedChangesGuard(
                    isDirty: () => field.text.isNotEmpty,
                    message: message,
                    leaveLabel: 'خروج بدون حفظ',
                    child: AlertDialog(
                      title: const Text('Add item'),
                      content: TextField(key: const Key('field'), controller: field),
                      actions: [
                        TextButton(onPressed: () => Navigator.maybePop(ctx), child: const Text('إلغاء')),
                        TextButton(
                          onPressed: () {
                            saved = true;
                            Navigator.pop(ctx); // حفظ ناجح: pop مباشر بلا سؤال
                          },
                          child: const Text('حفظ'),
                        ),
                      ],
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> tapOutside(WidgetTester tester) async {
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }

    Future<void> pressEsc(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }

    testWidgets('nothing entered: cancel, Esc and clicking outside close without asking', (tester) async {
      for (final close in <Future<void> Function(WidgetTester)>[
        (t) async {
          await t.tap(find.text('إلغاء'));
          await t.pumpAndSettle();
        },
        pressEsc,
        tapOutside,
      ]) {
        await openDialog(tester);
        await close(tester);
        expect(find.text(message), findsNothing);
        expect(find.text('Add item'), findsNothing);
      }
    });

    testWidgets('data entered: every close path asks; "البقاء" keeps the form and its data', (tester) async {
      for (final close in <Future<void> Function(WidgetTester)>[
        (t) async {
          await t.tap(find.text('إلغاء'));
          await t.pumpAndSettle();
        },
        pressEsc,
        tapOutside,
      ]) {
        await openDialog(tester);
        await tester.enterText(find.byKey(const Key('field')), 'Panadol');
        await close(tester);
        expect(find.text(message), findsOneWidget);

        await tester.tap(find.text('البقاء'));
        await tester.pumpAndSettle();
        expect(find.text(message), findsNothing);
        expect(find.text('Add item'), findsOneWidget);
        expect(field.text, 'Panadol');

        // إغلاق نظيف قبل الجولة التالية.
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('خروج بدون حفظ'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('"خروج بدون حفظ" closes the form; "البقاء" is the default (focused) choice', (tester) async {
      await openDialog(tester);
      await tester.enterText(find.byKey(const Key('field')), 'x');
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();

      final stay = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'البقاء'));
      expect(stay.autofocus, isTrue);

      await tester.tap(find.text('خروج بدون حفظ'));
      await tester.pumpAndSettle();
      expect(find.text('Add item'), findsNothing);
    });

    testWidgets('Esc on the confirmation itself means stay', (tester) async {
      await openDialog(tester);
      await tester.enterText(find.byKey(const Key('field')), 'x');
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      await pressEsc(tester);
      expect(find.text(message), findsNothing);
      expect(find.text('Add item'), findsOneWidget);
    });

    testWidgets('a successful save closes without asking', (tester) async {
      await openDialog(tester);
      await tester.enterText(find.byKey(const Key('field')), 'x');
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      expect(find.text(message), findsNothing);
      expect(find.text('Add item'), findsNothing);
    });
  });

  group('LeaveGuardController with sidebar-style navigation', () {
    // يحاكي MainLayout: صفحتان يبدّل بينهما "الشريط الجانبي" عبر confirmLeave،
    // وصفحة POS وهمية تسجّل فحصها في LeaveGuardScope.
    Future<void> pumpLayout(WidgetTester tester, ValueNotifier<bool> cartHasItems) async {
      await tester.pumpWidget(MaterialApp(home: _FakeLayout(cartHasItems: cartHasItems)));
    }

    testWidgets('empty invoice: navigating away needs no confirmation', (tester) async {
      await pumpLayout(tester, ValueNotifier(false));
      await tester.tap(find.text('go reports'));
      await tester.pumpAndSettle();
      expect(find.text('REPORTS PAGE'), findsOneWidget);
    });

    testWidgets('incomplete invoice: "البقاء" keeps POS, "خروج" navigates and unregisters the guard', (tester) async {
      final cart = ValueNotifier(true);
      await pumpLayout(tester, cart);

      await tester.tap(find.text('go reports'));
      await tester.pumpAndSettle();
      expect(find.text('الفاتورة غير مكتملة، هل تريد فعلاً الخروج؟'), findsOneWidget);
      await tester.tap(find.text('البقاء'));
      await tester.pumpAndSettle();
      expect(find.text('POS PAGE'), findsOneWidget);

      await tester.tap(find.text('go reports'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('خروج'));
      await tester.pumpAndSettle();
      expect(find.text('REPORTS PAGE'), findsOneWidget);

      // العودة لـ POS تسجّل فحص النسخة الجديدة من الشاشة، فيُسأل مجدداً.
      await tester.tap(find.text('go pos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('go reports'));
      await tester.pumpAndSettle();
      expect(find.text('الفاتورة غير مكتملة، هل تريد فعلاً الخروج؟'), findsOneWidget);
    });

    testWidgets('logout-style check reports whether a dialog was shown (null when nothing to protect)', (tester) async {
      final cart = ValueNotifier(false);
      await pumpLayout(tester, cart);
      final state = tester.state<_FakeLayoutState>(find.byType(_FakeLayout));
      expect(await state.guard.confirmLeave(), isNull);

      cart.value = true;
      final pending = state.guard.confirmLeave();
      await tester.pumpAndSettle();
      await tester.tap(find.text('خروج'));
      await tester.pumpAndSettle();
      expect(await pending, isTrue);
    });
  });
}

class _FakeLayout extends StatefulWidget {
  final ValueNotifier<bool> cartHasItems;

  const _FakeLayout({required this.cartHasItems});

  @override
  State<_FakeLayout> createState() => _FakeLayoutState();
}

class _FakeLayoutState extends State<_FakeLayout> {
  final LeaveGuardController guard = LeaveGuardController();
  String page = 'pos';

  Future<void> select(String target) async {
    if (target == page) return;
    final leave = await guard.confirmLeave();
    if (leave == false || !mounted) return;
    setState(() => page = target);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Column(children: [
            TextButton(onPressed: () => select('pos'), child: const Text('go pos')),
            TextButton(onPressed: () => select('reports'), child: const Text('go reports')),
          ]),
          Expanded(
            child: LeaveGuardScope(
              controller: guard,
              child: page == 'pos' ? _FakePos(cartHasItems: widget.cartHasItems) : const Text('REPORTS PAGE'),
            ),
          ),
        ],
      ),
    );
  }
}

class _FakePos extends StatefulWidget {
  final ValueNotifier<bool> cartHasItems;

  const _FakePos({required this.cartHasItems});

  @override
  State<_FakePos> createState() => _FakePosState();
}

class _FakePosState extends State<_FakePos> {
  LeaveGuardController? _guard;

  Future<bool?> _confirmLeave() async {
    if (!widget.cartHasItems.value) return null;
    return confirmDiscardChanges(context, message: 'الفاتورة غير مكتملة، هل تريد فعلاً الخروج؟', leaveLabel: 'خروج');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final guard = LeaveGuardScope.maybeOf(context);
    if (guard != _guard) {
      _guard?.detach(_confirmLeave);
      _guard = guard?..attach(_confirmLeave);
    }
  }

  @override
  void dispose() {
    _guard?.detach(_confirmLeave);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('POS PAGE');
}
