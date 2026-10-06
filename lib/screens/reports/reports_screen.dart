import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../models/report_period.dart';
import '../../repository/reports_repository.dart';
import 'report_widgets.dart';
import 'reports_scope.dart';
import 'tabs/inventory_tab.dart';
import 'tabs/items_tab.dart';
import 'tabs/losses_tab.dart';
import 'tabs/overview_tab.dart';
import 'tabs/purchases_tab.dart';
import 'tabs/sales_tab.dart';

/// شاشة التقارير التحليلية (للمالك فقط).
///
/// أونلاين: كل التجميع على الخادم (/api/reports/* في ReportsViewSet) فتشمل
/// بيانات كل أجهزة الصيدلية؛ عند تعذر الاتصال يعرض كل قسم رسالة خطأ بدل
/// أرقام قديمة مضلِّلة. أوفلاين: ReportsLocalService على SQLite بنفس الصيغ.
///
/// المؤشرات تُحمَّل أولاً، وكل تبويب يُحمَّل عند فتحه لأول مرة ثم يُحفظ للفترة
/// الحالية (يُمسح الكاش عند تغيير الفترة أو التحديث).
class ReportsScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOwner;
  final bool isOnlineMode;

  /// للاختبارات: مصدر بيانات بديل وساعة ثابتة.
  final ReportsDataSource? repository;
  final DateTime Function()? clock;

  const ReportsScreen({
    super.key,
    required this.pharmacyId,
    required this.isOnlineMode,
    this.isOwner = true,
    this.repository,
    this.clock,
  });

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class ReportTab {
  static const overview = 0;
  static const sales = 1;
  static const items = 2;
  static const inventory = 3;
  static const purchases = 4;
  static const losses = 5;

  static const labels = ['نظرة عامة', 'المبيعات والموظفين', 'الأصناف', 'المخزون', 'المشتريات والمذاخر', 'المصاريف والخسائر'];
  static const icons = [
    Icons.dashboard_outlined,
    Icons.point_of_sale,
    Icons.medication_outlined,
    Icons.inventory_2_outlined,
    Icons.local_shipping_outlined,
    Icons.money_off_outlined,
  ];
}

class _ReportsScreenState extends State<ReportsScreen> with SingleTickerProviderStateMixin {
  late final ReportsDataSource _repo =
      widget.repository ?? ReportsRepository(pharmacyId: widget.pharmacyId, isOnlineMode: widget.isOnlineMode);
  late ReportPeriod _period = ReportPeriod.sessionPeriod(now: _now());
  final ReportsCache _cache = ReportsCache();
  late final TabController _tabs = TabController(length: ReportTab.labels.length, vsync: this);
  DateTime _updatedAt = DateTime.now();
  int _generation = 0;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  ReportsScope get _scope => ReportsScope(
        repo: _repo,
        period: _period,
        cache: _cache,
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        isOwner: widget.isOwner,
        onDataChanged: _refresh,
        openTab: _openTab,
      );

  void _setPeriod(ReportPeriod period) {
    if (period == _period) return;
    ReportPeriod.remember(period);
    setState(() {
      _period = period;
      _cache.clear();
      _generation++;
      _updatedAt = DateTime.now();
    });
  }

  void _refresh() {
    setState(() {
      _cache.clear();
      _generation++;
      _updatedAt = DateTime.now();
    });
  }

  void _openTab(int index) => _tabs.animateTo(index);

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: dateOnly(_now()),
      initialDateRange: DateTimeRange(start: _period.start, end: _period.end.isAfter(_now()) ? dateOnly(_now()) : _period.end),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(colorScheme: const ColorScheme.light(primary: RC.tealDark, onPrimary: Colors.white)),
        child: Directionality(textDirection: TextDirection.rtl, child: child!),
      ),
    );
    if (picked != null) _setPeriod(ReportPeriod.custom(picked.start, picked.end));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOwner) {
      return const Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Center(
            child: Text(
              "عذراً، هذه الصفحة مخصصة للإدارة فقط.",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFC53030), fontFamily: 'Tajawal'),
            ),
          ),
        ),
      );
    }

    final scope = _scope;
    final kpis = scope.load('kpis', () => _repo.kpis(_period));
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: RC.page,
        body: Column(
          children: [
            _header(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _KpiSection(future: kpis, onRetry: _refresh),
                    const SizedBox(height: 14),
                    _AlertsStrip(future: kpis, onOpen: _openTab),
                    const SizedBox(height: 14),
                    Container(
                      decoration: cardDecoration(),
                      child: TabBar(
                        controller: _tabs,
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        labelColor: RC.tealDark,
                        unselectedLabelColor: RC.muted,
                        indicatorColor: RC.tealDark,
                        labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, fontFamily: 'Tajawal'),
                        tabs: [
                          for (var i = 0; i < ReportTab.labels.length; i++)
                            Tab(height: 46, icon: null, child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(ReportTab.icons[i], size: 18),
                              const SizedBox(width: 6),
                              Text(ReportTab.labels[i]),
                            ])),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    KeyedSubtree(
                      key: ValueKey('${_period.cacheKey}#$_generation#${_tabs.index}'),
                      child: _tabBody(scope, kpis),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabBody(ReportsScope scope, Future<Map<String, dynamic>> kpis) {
    switch (_tabs.index) {
      case ReportTab.sales:
        return SalesTab(scope: scope, kpis: kpis);
      case ReportTab.items:
        return ItemsTab(scope: scope);
      case ReportTab.inventory:
        return InventoryTab(scope: scope);
      case ReportTab.purchases:
        return PurchasesTab(scope: scope);
      case ReportTab.losses:
        return LossesTab(scope: scope);
      default:
        return OverviewTab(scope: scope, kpis: kpis);
    }
  }

  Widget _header() {
    final f = DateFormat('yyyy/MM/dd');
    final range = _period.days == 1 ? f.format(_period.start) : '${f.format(_period.start)} - ${f.format(_period.end)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: RC.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insert_chart_rounded, color: RC.teal, size: 26),
              const SizedBox(width: 8),
              const Text('التقارير',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50), fontFamily: 'Tajawal')),
              const Spacer(),
              Text('آخر تحديث ${DateFormat('HH:mm').format(_updatedAt)}', style: const TextStyle(fontSize: 12, color: RC.muted)),
              IconButton(
                key: const Key('reports-refresh'),
                tooltip: 'تحديث',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh, color: RC.tealDark),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final preset in ReportPreset.values)
                ChoiceChip(
                  key: Key('preset-${preset.name}'),
                  label: Text(reportPresetLabels[preset]!),
                  selected: _period.preset == preset,
                  showCheckmark: false,
                  labelStyle: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _period.preset == preset ? Colors.white : RC.text,
                  ),
                  selectedColor: RC.tealDark,
                  backgroundColor: RC.faint,
                  side: const BorderSide(color: RC.border),
                  onSelected: (_) {
                    if (preset == ReportPreset.custom) {
                      _pickRange();
                    } else {
                      _setPeriod(ReportPeriod.fromPreset(preset, now: _now()));
                    }
                  },
                ),
              ActionChip(
                key: const Key('period-range'),
                avatar: const Icon(Icons.date_range, size: 18, color: RC.tealDark),
                label: Text('$range  (${_period.days} يوم)'),
                labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: RC.tealDark),
                backgroundColor: const Color(0xFFE8F8F5),
                side: const BorderSide(color: RC.tealLight),
                onPressed: _pickRange,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// بطاقات المؤشرات الأربع
// ---------------------------------------------------------------------------

class _KpiSection extends StatelessWidget {
  const _KpiSection({required this.future, required this.onRetry});

  final Future<Map<String, dynamic>> future;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Container(decoration: cardDecoration(), padding: const EdgeInsets.all(16),
              child: SectionError(error: snap.error!, onRetry: onRetry));
        }
        final data = snap.data;
        final cur = data?['current'] as Map<String, dynamic>?;
        final prev = data?['previous'] as Map<String, dynamic>?;
        double c(String k) => jn(cur?[k]);
        double p(String k) => jn(prev?[k]);
        final costedSales = c('net_sales') - c('uncosted_revenue');
        final cards = <Widget>[
          KpiCard(
            title: 'صافي المبيعات',
            icon: Icons.payments_outlined,
            value: cur == null ? null : iqd(c('net_sales')),
            hint: 'بعد الخصومات، بلا المسترجع',
            current: c('net_sales'),
            previous: p('net_sales'),
          ),
          KpiCard(
            title: 'الربح الإجمالي',
            icon: Icons.trending_up,
            value: cur == null ? null : iqd(c('gross_profit')),
            hint: 'هامش الربح ${pct(costedSales > 0 ? c('gross_profit') / costedSales * 100 : 0)}',
            current: c('gross_profit'),
            previous: p('gross_profit'),
          ),
          KpiCard(
            title: 'صافي الربح',
            icon: Icons.account_balance_wallet_outlined,
            value: cur == null ? null : iqd(c('net_profit')),
            valueColor: c('net_profit') < 0 ? RC.red : null,
            hint: 'بعد المصاريف والتوالف المسجّلة',
            current: c('net_profit'),
            previous: p('net_profit'),
          ),
          KpiCard(
            title: 'عدد الفواتير',
            icon: Icons.receipt_long_outlined,
            value: cur == null ? null : '${ji(cur['invoices_count'])} فاتورة',
            hint: 'متوسط الفاتورة ${iqd(c('invoices_count') > 0 ? c('net_sales') / c('invoices_count') : 0)}',
            current: c('invoices_count'),
            previous: p('invoices_count'),
          ),
        ];
        final missing = ji(cur?['items_without_cost']);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(builder: (context, constraints) {
              final perRow = constraints.maxWidth >= 900 ? 4 : 2;
              final width = (constraints.maxWidth - (perRow - 1) * 14) / perRow;
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [for (final card in cards) SizedBox(width: width, child: card)],
              );
            }),
            if (missing > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFDBA74)),
                ),
                child: Text(
                  '$missing صنفاً مباعاً بلا سعر كلفة — قد تكون الأرقام غير مكتملة.',
                  style: const TextStyle(color: Color(0xFF9A3412), fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.title,
    required this.icon,
    required this.value,
    required this.current,
    required this.previous,
    this.hint,
    this.valueColor,
  });

  final String title;
  final IconData icon;

  /// null أثناء التحميل.
  final String? value;
  final String? hint;
  final double current;
  final double previous;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 132),
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(color: const Color(0xFFE8F8F5), borderRadius: BorderRadius.circular(9)),
                child: Icon(icon, color: RC.tealDark, size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: RC.muted, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (value == null)
            const SkeletonBlock(height: 52, lines: 2)
          else ...[
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(value!,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: valueColor ?? RC.text)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (previous != 0) ChangePill(current: current, previous: previous),
                if (hint != null) Text(hint!, style: const TextStyle(fontSize: 11.5, color: RC.muted)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// "↑ 12% عن الفترة السابقة" أخضر/أحمر.
class ChangePill extends StatelessWidget {
  const ChangePill({super.key, required this.current, required this.previous});

  final double current;
  final double previous;

  @override
  Widget build(BuildContext context) {
    final change = (current - previous) / previous.abs() * 100;
    final up = change > 0.05, down = change < -0.05;
    final color = up ? RC.green : (down ? RC.red : RC.muted);
    final bg = up ? RC.greenBg : (down ? RC.redBg : RC.faint);
    final arrow = up ? '↑' : (down ? '↓' : '=');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(50)),
      child: Text('$arrow ${pct(change.abs())} عن الفترة السابقة',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
    );
  }
}

// ---------------------------------------------------------------------------
// شريط التنبيهات (الوضع الحالي)
// ---------------------------------------------------------------------------

class _AlertsStrip extends StatelessWidget {
  const _AlertsStrip({required this.future, required this.onOpen});

  final Future<Map<String, dynamic>> future;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snap) {
        final a = snap.data?['alerts'] as Map<String, dynamic>?;
        if (a == null) return const SizedBox.shrink();
        final belowCost = ji(a['below_cost_count']);
        final expiring = ji(a['expiring_count']);
        final expired = ji(a['expired_count']);
        final low = ji(a['low_stock_count']);
        final chips = <Widget>[
          if (belowCost > 0)
            _AlertChip(
              key: const Key('alert-below-cost'),
              text: '$belowCost أصناف تُباع بأقل من كلفتها',
              icon: Icons.trending_down,
              color: RC.red,
              background: RC.redBg,
              onTap: () => onOpen(ReportTab.items),
            ),
          if (expiring > 0 || expired > 0)
            _AlertChip(
              key: const Key('alert-expiry'),
              text: [
                if (expiring > 0)
                  '$expiring صنفاً تنتهي صلاحيتها خلال ${a['expiring_days'] ?? 30} يوماً بقيمة ${iqd(a['expiring_value'])}',
                if (expired > 0) '$expired منتهية غير مُسجَّلة كتالف بقيمة ${iqd(a['expired_value'])}',
              ].join('  •  '),
              icon: Icons.event_busy_outlined,
              color: RC.orange,
              background: RC.orangeBg,
              onTap: () => onOpen(ReportTab.inventory),
            ),
          if (low > 0)
            _AlertChip(
              key: const Key('alert-low-stock'),
              text: '$low أصناف نفدت أو أوشكت على النفاد',
              icon: Icons.inventory_outlined,
              color: RC.blue,
              background: RC.blueBg,
              onTap: () => onOpen(ReportTab.inventory),
            ),
        ];
        if (chips.isEmpty) return const SizedBox.shrink();
        return Wrap(spacing: 10, runSpacing: 10, children: chips);
      },
    );
  }
}

class _AlertChip extends StatelessWidget {
  const _AlertChip({
    super.key,
    required this.text,
    required this.icon,
    required this.color,
    required this.background,
    required this.onTap,
  });

  final String text;
  final IconData icon;
  final Color color;
  final Color background;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12.5)),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_left, color: color, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
