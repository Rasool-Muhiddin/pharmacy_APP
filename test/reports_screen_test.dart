import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/models/report_period.dart';
import 'package:pharmacy_app/repository/reports_repository.dart';
import 'package:pharmacy_app/screens/reports_screen.dart';

/// مصدر بيانات وهمي يسجّل كل طلب (القسم + الفترة).
class FakeReports implements ReportsDataSource {
  FakeReports({this.empty = false, this.failKpis = false});

  final bool empty;
  bool failKpis;
  final List<String> calls = [];
  final List<ReportPeriod> kpiPeriods = [];

  Map<String, dynamic> figures(double scale) => {
        'gross_sales': 4500 * scale, 'discounts': 100 * scale, 'net_sales': 4400 * scale, 'invoices_count': 2,
        'discounted_invoices_count': 1, 'refunded_count': 1, 'refunded_value': 1000, 'cost_of_goods_sold': 1500,
        'gross_profit': 2400 * scale, 'uncosted_revenue': 500, 'items_without_cost': 1, 'expenses': 350,
        'damage_cost': 700, 'net_profit': 1350 * scale,
      };

  Map<String, dynamic> zeros() => {for (final k in figures(1).keys) k: 0};

  @override
  Future<Map<String, dynamic>> kpis(ReportPeriod period) async {
    calls.add('kpis');
    kpiPeriods.add(period);
    if (failKpis) throw Exception('تعذر الاتصال بالخادم');
    return {
      'current': empty ? zeros() : figures(1),
      'previous': empty ? zeros() : figures(0.5),
      'alerts': {
        'below_cost_count': empty ? 0 : 1, 'expiring_days': 30, 'expiring_count': empty ? 0 : 1,
        'expiring_value': 1200, 'expired_count': empty ? 0 : 1, 'expired_value': empty ? 0 : 300,
        'low_stock_count': empty ? 0 : 3, 'out_of_stock_count': 1,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> trend(ReportPeriod period) async {
    calls.add('trend');
    return {
      'bucket': period.bucket.name,
      'points': [
        for (final (i, k) in period.bucketKeys().indexed)
          {'key': k, 'net_sales': empty ? 0 : 1000.0 + i * 100, 'gross_profit': empty ? 0 : 400.0 + i * 10},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> categories(ReportPeriod period) async {
    calls.add('categories');
    return {
      'categories': empty
          ? []
          : [
              {'category': 'tablet', 'net_sales': 2933.33, 'quantity': 3},
              {'category': '', 'net_sales': 500, 'quantity': 1},
            ],
    };
  }

  @override
  Future<Map<String, dynamic>> hours(ReportPeriod period) async {
    calls.add('hours');
    return {
      'hours': [
        for (var h = 0; h < 24; h++) {'hour': h, 'invoices_count': empty || h != 10 ? 0 : 3, 'net_sales': h == 10 ? 2900 : 0},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> items(ReportPeriod period, {String sort = 'qty'}) async {
    calls.add('items:$sort');
    return {
      'sort': sort,
      'items': empty
          ? []
          : [
              {'medicine_id': 1, 'trade_name': 'Panadol Extra Long Name 500mg', 'quantity': 3, 'revenue': 2933.33,
                'costed_revenue': 2933.33, 'cost': 1200, 'profit': 1733.33, 'uncosted_quantity': 0},
              {'medicine_id': 2, 'trade_name': 'B', 'quantity': 1, 'revenue': 200, 'costed_revenue': 200, 'cost': 300,
                'profit': -100, 'uncosted_quantity': 0},
            ],
      'below_cost': empty
          ? []
          : [
              {'medicine_id': 2, 'trade_name': 'B', 'quantity': 4, 'cost': 300, 'sell_price': 250, 'loss_per_unit': 50},
            ],
    };
  }

  @override
  Future<Map<String, dynamic>> stagnant(ReportPeriod period, {int page = 1}) async {
    calls.add('stagnant:$page');
    return {
      'count': empty ? 0 : 60, 'page': page, 'page_size': 50, 'total_value': 9000,
      'results': empty
          ? []
          : [
              {'medicine_id': 4, 'trade_name': 'D', 'category': 'injection', 'quantity': 10, 'stock_value': 9000, 'last_sale': null},
            ],
    };
  }

  @override
  Future<Map<String, dynamic>> inventory({int days = 30}) async {
    calls.add('inventory:$days');
    return {
      'days': days, 'stock_cost_value': 18500, 'stock_sell_value': 37500, 'expected_profit': 19000,
      'expiring': empty
          ? []
          : [
              {'medicine_id': 2, 'batch_id': 7, 'trade_name': 'B', 'expiry_date': '2026-10-27', 'quantity': 4, 'value': 1200, 'supplier_name': 'S2'},
            ],
      'expiring_value': 1200,
      'expired': empty
          ? []
          : [
              {'medicine_id': 3, 'batch_id': 8, 'trade_name': 'C', 'expiry_date': '2026-09-27', 'quantity': 3, 'value': 300, 'supplier_name': ''},
            ],
      'expired_value': 300,
      'low_stock_threshold': 10,
      'low_stock': empty
          ? []
          : [
              {'medicine_id': 5, 'trade_name': 'E', 'quantity': 0, 'category': 'tablet', 'sell_price': 100},
            ],
    };
  }

  @override
  Future<Map<String, dynamic>> purchases(ReportPeriod period) async {
    calls.add('purchases');
    return {
      'purchases_total': 5000, 'invoices_count': 1, 'returns_total': 500, 'payments_total': 2000, 'refunds_received': 0,
      'by_supplier': empty
          ? []
          : [
              {'supplier_id': 1, 'name': 'S1', 'invoices_count': 1, 'total': 5000, 'returns': 500},
            ],
      'total_debt': 3500, 'total_credit': 0,
      'top_debtors': empty
          ? []
          : [
              {'supplier_id': 1, 'name': 'S1', 'debt': 2500},
            ],
    };
  }

  @override
  Future<Map<String, dynamic>> losses(ReportPeriod period) async {
    calls.add('losses');
    return {
      'expenses_total': 350,
      'expenses_by_type': empty
          ? []
          : [
              {'type': 'rent', 'total': 250, 'count': 1},
            ],
      'damage_total': 700,
      'damage_by_reason': empty
          ? []
          : [
              {'reason': 'expired', 'total': 300, 'quantity': 1, 'count': 1},
            ],
      'expired_recorded': 300,
      'expired_not_disposed_value': empty ? 0 : 300,
    };
  }

  @override
  Future<Map<String, dynamic>> invoices(ReportPeriod period,
      {int page = 1, String query = '', String seller = '', bool refunded = false}) async {
    calls.add('invoices:$page:$query:$seller:$refunded');
    return {
      'count': empty ? 0 : 120, 'page': page, 'page_size': 50, 'total_amount': 4400,
      'results': empty
          ? []
          : [
              {'id': 1, 'invoice_number': 'INV-000001', 'created_at': '2026-10-07T10:00:00', 'total_amount': 3000,
                'discount': 100, 'final_amount': 2900, 'seller_name': 'Ali', 'is_refunded': false},
            ],
    };
  }

  @override
  Future<Map<String, dynamic>> sellers(ReportPeriod period) async {
    calls.add('sellers');
    return {
      'sellers': empty
          ? []
          : [
              {'seller_name': 'Ali', 'invoices_count': 1, 'net_sales': 2900},
            ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> invoiceItems(int invoiceId) async => [
        {'trade_name': 'A', 'quantity': 2, 'unit_price': 1000, 'total_price': 2000},
      ];

  @override
  Future<Map<String, dynamic>?> medicine(int medicineId) async => null;
}

final fixedNow = DateTime(2026, 10, 7, 12);

Future<void> pumpReports(WidgetTester tester, FakeReports fake, {Size size = const Size(1400, 1000), bool isOwner = true}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: ReportsScreen(pharmacyId: 1, isOnlineMode: false, isOwner: isOwner, repository: fake, clock: () => fixedNow),
  ));
  await tester.pumpAndSettle();
}

Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

const tabLabels = ['نظرة عامة', 'المبيعات والموظفين', 'الأصناف', 'المخزون', 'المشتريات والمذاخر', 'المصاريف والخسائر'];

void main() {
  setUp(ReportPeriod.resetSessionForTesting);

  testWidgets('default period is this month; KPI cards show values and change vs previous period', (tester) async {
    final fake = FakeReports();
    await pumpReports(tester, fake);
    expect(fake.kpiPeriods.single.startKey, '2026-10-01');
    expect(fake.kpiPeriods.single.endKey, '2026-10-07');
    expect(find.text('صافي المبيعات'), findsWidgets);
    expect(find.text('4,400 د.ع'), findsWidgets);
    expect(find.textContaining('↑ 100% عن الفترة السابقة'), findsWidgets);
    expect(find.textContaining('صنفاً مباعاً بلا سعر كلفة'), findsOneWidget);
  });

  testWidgets('preset selection changes the period and reloads', (tester) async {
    final fake = FakeReports();
    await pumpReports(tester, fake);
    await tester.tap(find.byKey(const Key('preset-last7')));
    await tester.pumpAndSettle();
    expect(fake.kpiPeriods, hasLength(2));
    expect(fake.kpiPeriods.last.startKey, '2026-10-01');
    expect(fake.kpiPeriods.last.preset, ReportPreset.last7);

    await tester.tap(find.byKey(const Key('preset-yesterday')));
    await tester.pumpAndSettle();
    expect(fake.kpiPeriods.last.startKey, '2026-10-06');
    expect(fake.kpiPeriods.last.endKey, '2026-10-06');
    expect(find.textContaining('(1 يوم)'), findsOneWidget);
    // يُتذكَّر خلال الجلسة.
    expect(ReportPeriod.sessionPeriod(now: fixedNow).preset, ReportPreset.yesterday);
  });

  testWidgets('refresh reloads the KPIs and the open tab', (tester) async {
    final fake = FakeReports();
    await pumpReports(tester, fake);
    final before = fake.calls.where((c) => c == 'trend').length;
    await tester.tap(find.byKey(const Key('reports-refresh')));
    await tester.pumpAndSettle();
    expect(fake.kpiPeriods, hasLength(2));
    expect(fake.calls.where((c) => c == 'trend').length, before + 1);
  });

  testWidgets('tabs lazy-load once per period', (tester) async {
    final fake = FakeReports();
    await pumpReports(tester, fake);
    expect(fake.calls, containsAll(['kpis', 'trend', 'categories', 'hours']));
    expect(fake.calls.where((c) => c.startsWith('items') || c.startsWith('inventory') || c == 'purchases' || c == 'losses'), isEmpty);

    await openTab(tester, 'الأصناف');
    expect(fake.calls.where((c) => c == 'items:qty'), hasLength(1));
    expect(fake.calls.where((c) => c.startsWith('stagnant')), hasLength(1));
    expect(find.text('أصناف تُباع بأقل من كلفتها'), findsOneWidget);

    await openTab(tester, 'نظرة عامة');
    await openTab(tester, 'الأصناف');
    expect(fake.calls.where((c) => c == 'items:qty'), hasLength(1), reason: 'cached for the current period');
    expect(fake.calls.where((c) => c == 'trend'), hasLength(1));

    await tester.tap(find.text('بالربح'));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('items:profit'));
  });

  testWidgets('alerts strip opens the related tab', (tester) async {
    final fake = FakeReports();
    await pumpReports(tester, fake);
    expect(find.text('1 أصناف تُباع بأقل من كلفتها'), findsOneWidget);
    expect(find.text('3 أصناف نفدت أو أوشكت على النفاد'), findsOneWidget);
    await tester.tap(find.byKey(const Key('alert-expiry')));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('inventory:30'));
    expect(find.text('منتهية الصلاحية ولم تُسجَّل كتالف'), findsOneWidget);
    expect(find.byKey(const Key('record-expired-8')), findsOneWidget);
  });

  testWidgets('income statement shows unrecorded expiry as information only', (tester) async {
    await pumpReports(tester, FakeReports());
    expect(find.byKey(const Key('net-profit-row')), findsOneWidget);
    expect(find.textContaining('منتهي الصلاحية غير مُسجَّل كتالف: 300 د.ع (لم يُخصم من الربح)'), findsOneWidget);
  });

  testWidgets('empty states everywhere, no alerts', (tester) async {
    final fake = FakeReports(empty: true);
    await pumpReports(tester, fake);
    expect(find.byKey(const Key('alert-below-cost')), findsNothing);
    expect(find.byKey(const Key('expired-not-recorded-row')), findsNothing);
    expect(find.text('لا توجد مبيعات في هذه الفترة.'), findsWidgets);
    expect(find.textContaining('عن الفترة السابقة'), findsNothing, reason: 'hidden when previous value is 0');

    await openTab(tester, 'المبيعات والموظفين');
    expect(find.text('لا توجد فواتير في هذه الفترة.'), findsOneWidget);
    await openTab(tester, 'الأصناف');
    expect(find.text('لا توجد أصناف تُباع بأقل من كلفتها.'), findsOneWidget);
    await openTab(tester, 'المخزون');
    expect(find.text('كل الأصناف متوفرة بكمية كافية.'), findsOneWidget);
    await openTab(tester, 'المصاريف والخسائر');
    expect(find.text('لا توجد مصاريف في هذه الفترة.'), findsOneWidget);
  });

  testWidgets('a failing section shows an error with retry, never stale numbers', (tester) async {
    final fake = FakeReports(failKpis: true);
    await pumpReports(tester, fake);
    expect(find.textContaining('تعذر تحميل هذا القسم'), findsWidgets);
    expect(find.text('4,400 د.ع'), findsNothing);
    fake.failKpis = false;
    await tester.tap(find.text('إعادة المحاولة').first);
    await tester.pumpAndSettle();
    expect(find.text('4,400 د.ع'), findsWidgets);
  });

  testWidgets('sales tab: invoices table, search and pagination', (tester) async {
    final fake = FakeReports();
    await pumpReports(tester, fake);
    await openTab(tester, 'المبيعات والموظفين');
    expect(find.text('INV-000001'), findsOneWidget);
    expect(find.text('صفحة 1 من 3  •  120 سجل'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('التالي'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('التالي'));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('invoices:2:::false'));
    await tester.enterText(find.byKey(const Key('invoice-search')), '0001');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('invoices:1:0001::false'));
    await tester.ensureVisible(find.byTooltip('تفاصيل الفاتورة'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('تفاصيل الفاتورة'));
    await tester.pumpAndSettle();
    expect(find.text('تفاصيل الفاتورة: INV-000001'), findsOneWidget);
  });

  for (final size in [const Size(800, 1200), const Size(560, 1200)]) {
    testWidgets('narrow window ${size.width.toInt()}px: every tab renders without overflow', (tester) async {
      await pumpReports(tester, FakeReports(), size: size);
      for (final label in tabLabels) {
        await tester.ensureVisible(find.text(label));
        await openTab(tester, label);
        expect(tester.takeException(), isNull, reason: label);
      }
    });
  }

  testWidgets('non-owner sees the management-only message', (tester) async {
    final fake = FakeReports();
    await pumpReports(tester, fake, isOwner: false);
    expect(find.text('عذراً، هذه الصفحة مخصصة للإدارة فقط.'), findsOneWidget);
    expect(fake.calls, isEmpty);
  });
}
