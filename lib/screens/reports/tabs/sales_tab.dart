import 'dart:async';

import 'package:flutter/material.dart';

import '../invoice_details_dialog.dart';
import '../report_widgets.dart';
import '../reports_scope.dart';

/// الفواتير (بحث، فلتر بائع، ترقيم صفحات من المصدر)، المسترجع، الخصومات،
/// وملخص لكل بائع (بديل نافذة الشفتات القديمة).
class SalesTab extends StatefulWidget {
  const SalesTab({super.key, required this.scope, required this.kpis});

  final ReportsScope scope;
  final Future<Map<String, dynamic>> kpis;

  @override
  State<SalesTab> createState() => _SalesTabState();
}

class _SalesTabState extends State<SalesTab> {
  ReportsScope get s => widget.scope;

  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String _seller = '';
  bool _refunded = false;
  int _page = 1;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _retry() => setState(() {});

  String get _invoicesKey => 'invoices?p=$_page&q=$_query&s=$_seller&r=$_refunded';

  void _onSearch(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(() {
        _query = text.trim();
        _page = 1;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final sellers = s.load('sellers', () => s.repo.sellers(s.period));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionFuture(
          future: widget.kpis,
          onRetry: s.onDataChanged,
          skeletonHeight: 80,
          builder: (data) {
            final c = data['current'] as Map<String, dynamic>;
            return StatGrid(tiles: [
              StatTile(label: 'الخصومات الممنوحة', value: iqd(c['discounts']), color: RC.orange,
                  hint: '${ji(c['discounted_invoices_count'])} فاتورة بخصم'),
              StatTile(label: 'الفواتير المسترجعة', value: '${ji(c['refunded_count'])} فاتورة', color: RC.red,
                  hint: 'بقيمة ${iqd(c['refunded_value'])}'),
              StatTile(label: 'إجمالي المبيعات قبل الخصم', value: iqd(c['gross_sales'])),
              StatTile(label: 'متوسط الفاتورة',
                  value: iqd(ji(c['invoices_count']) > 0 ? jn(c['net_sales']) / ji(c['invoices_count']) : 0)),
            ]);
          },
        ),
        const SizedBox(height: 16),
        ReportCard(
          title: 'ملخص البائعين',
          subtitle: 'الفواتير وصافي المبيعات لكل بائع في الفترة',
          icon: Icons.badge_outlined,
          child: SectionFuture(
            future: sellers,
            onRetry: _retry,
            builder: (data) {
              final rows = List<Map<String, dynamic>>.from(data['sellers'] as List);
              if (rows.isEmpty) return const EmptyState('لا توجد مبيعات مسجلة للبائعين في هذه الفترة.');
              return Column(children: [for (final r in rows) _SellerTile(scope: s, seller: r)]);
            },
          ),
        ),
        const SizedBox(height: 16),
        ReportCard(
          title: _refunded ? 'الفواتير المسترجعة' : 'الفواتير',
          icon: Icons.receipt_long_outlined,
          trailing: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('الصادرة')),
              ButtonSegment(value: true, label: Text('المسترجعة')),
            ],
            selected: {_refunded},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(selectedBackgroundColor: RC.tealDark, selectedForegroundColor: Colors.white),
            onSelectionChanged: (v) => setState(() {
              _refunded = v.first;
              _page = 1;
            }),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 240,
                    child: TextField(
                      key: const Key('invoice-search'),
                      controller: _search,
                      onChanged: _onSearch,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'بحث برقم الفاتورة',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  FutureBuilder<Map<String, dynamic>>(
                    future: sellers,
                    builder: (context, snap) {
                      final names = [
                        for (final r in (snap.data?['sellers'] as List? ?? const [])) (r as Map)['seller_name'] as String,
                      ];
                      return SizedBox(
                        width: 220,
                        child: DropdownButtonFormField<String>(
                          key: const Key('seller-filter'),
                          isExpanded: true,
                          initialValue: names.contains(_seller) ? _seller : '',
                          isDense: true,
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: 'البائع',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          items: [
                            const DropdownMenuItem(value: '', child: Text('كل البائعين')),
                            for (final n in names) DropdownMenuItem(value: n, child: Text(n, overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) => setState(() {
                            _seller = v ?? '';
                            _page = 1;
                          }),
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SectionFuture(
                future: s.load(_invoicesKey, () => s.repo.invoices(s.period,
                    page: _page, query: _query, seller: _seller, refunded: _refunded)),
                onRetry: _retry,
                builder: (data) {
                  final rows = List<Map<String, dynamic>>.from(data['results'] as List);
                  if (rows.isEmpty) {
                    return EmptyState(_query.isNotEmpty || _seller.isNotEmpty
                        ? 'لا توجد فواتير مطابقة للبحث.'
                        : (_refunded ? 'لا توجد فواتير مسترجعة في هذه الفترة.' : 'لا توجد فواتير في هذه الفترة.'));
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('${ji(data['count'])} فاتورة بمجموع ${iqd(data['total_amount'])}',
                          style: const TextStyle(fontSize: 12, color: RC.muted)),
                      const SizedBox(height: 8),
                      InvoicesTable(scope: s, rows: rows),
                      Pager(
                        page: ji(data['page']),
                        pageSize: ji(data['page_size']),
                        count: ji(data['count']),
                        onPage: (p) => setState(() => _page = p),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class InvoicesTable extends StatelessWidget {
  const InvoicesTable({super.key, required this.scope, required this.rows, this.showSeller = true});

  final ReportsScope scope;
  final List<Map<String, dynamic>> rows;
  final bool showSeller;

  @override
  Widget build(BuildContext context) {
    return ReportTable(
      columns: [
        const RCol('رقم الفاتورة', width: 130),
        const RCol('التاريخ والوقت', width: 150),
        if (showSeller) const RCol('البائع', width: 130),
        const RCol('الإجمالي', width: 110),
        const RCol('الخصم', width: 90),
        const RCol('الصافي', width: 110),
        const RCol('عرض', width: 60),
      ],
      rows: [
        for (final inv in rows)
          [
            cellText('${inv['invoice_number'] ?? '-'}', bold: true),
            cellText(shortDateTime(inv['created_at']), color: RC.muted),
            if (showSeller) cellText('${inv['seller_name'] ?? '-'}'),
            cellText(iqd(inv['total_amount'])),
            cellText(jn(inv['discount']) > 0 ? iqd(inv['discount']) : '-', color: RC.orange),
            cellText(iqd(inv['final_amount']), bold: true, color: RC.green),
            IconButton(
              tooltip: 'تفاصيل الفاتورة',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.visibility_outlined, size: 18, color: RC.blue),
              onPressed: () => showInvoiceDetails(context, scope.repo, inv),
            ),
          ],
      ],
    );
  }
}

/// بائع قابل للتوسيع إلى فواتيره في الفترة (مرقّمة من المصدر).
class _SellerTile extends StatefulWidget {
  const _SellerTile({required this.scope, required this.seller});

  final ReportsScope scope;
  final Map<String, dynamic> seller;

  @override
  State<_SellerTile> createState() => _SellerTileState();
}

class _SellerTileState extends State<_SellerTile> {
  bool _open = false;
  int _page = 1;

  @override
  Widget build(BuildContext context) {
    final s = widget.scope;
    final name = widget.seller['seller_name'] as String;
    final count = ji(widget.seller['invoices_count']);
    final net = jn(widget.seller['net_sales']);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: RC.border)),
      child: ExpansionTile(
        shape: const Border(),
        onExpansionChanged: (v) => setState(() => _open = v),
        leading: const CircleAvatar(backgroundColor: RC.blueBg, child: Icon(Icons.person, color: RC.blue)),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: RC.text)),
        subtitle: Text('$count فاتورة  •  متوسط الفاتورة ${iqd(count > 0 ? net / count : 0)}',
            style: const TextStyle(fontSize: 12, color: RC.muted)),
        trailing: Tag(iqd(net), color: RC.tealDark, background: const Color(0xFFE8F8F5)),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (_open)
            SectionFuture(
              future: s.load('seller:$name:$_page', () => s.repo.invoices(s.period, seller: name, page: _page)),
              onRetry: () => setState(() {}),
              builder: (data) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InvoicesTable(scope: s, rows: List<Map<String, dynamic>>.from(data['results'] as List), showSeller: false),
                  Pager(
                    page: ji(data['page']),
                    pageSize: ji(data['page_size']),
                    count: ji(data['count']),
                    onPage: (p) => setState(() => _page = p),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
