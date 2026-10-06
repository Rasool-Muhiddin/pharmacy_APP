import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database/db_helper.dart';
import '../models/purchase_list.dart';
import '../repository/medicine_repository.dart';
import '../repository/suppliers_repository.dart';
import '../services/medicine_api_service.dart';
import '../services/suppliers_api_service.dart';
import '../utils/formatters.dart';
import '../widgets/unsaved_changes_guard.dart';

/// نافذة "إضافة قائمة مذخر" — الطريق الوحيد لإدخال المخزون: قائمة مذخر
/// (تُنشئ فاتورة الشراء تحت المذخر تلقائياً) أو رصيد افتتاحي (بلا مذخر ولا
/// فاتورة). ترجع true بعد الحفظ الناجح.
Future<bool> showPurchaseListDialog(
  BuildContext context, {
  required int pharmacyId,
  required bool isOnlineMode,
  required List<Map<String, dynamic>> warehouses,
  required int initialWarehouseId,
  required bool allowWarehouseChoice,
  required List<Map<String, dynamic>> masterMedicines,
  required Map<String, String> categories,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (_) => PurchaseListDialog(
      pharmacyId: pharmacyId,
      isOnlineMode: isOnlineMode,
      warehouses: warehouses,
      initialWarehouseId: initialWarehouseId,
      allowWarehouseChoice: allowWarehouseChoice,
      masterMedicines: masterMedicines,
      categories: categories,
    ),
  );
  return saved == true;
}

const _primary = Color(0xFF1ABC9C);
const _primaryDark = Color(0xFF16A085);
const _textMain = Color(0xFF2C3E50);
const _textSecondary = Color(0xFF7F8C8D);
const _border = Color(0xFFE2E8F0);
const _danger = Color(0xFFDC2626);
const _free = Color(0xFF2ECC71);
const _existing = Color(0xFF2980B9);
const _newItem = Color(0xFFE67E22);

class PurchaseListDialog extends StatefulWidget {
  final int pharmacyId;
  final bool isOnlineMode;
  final List<Map<String, dynamic>> warehouses;
  final int initialWarehouseId;
  final bool allowWarehouseChoice;
  final List<Map<String, dynamic>> masterMedicines;
  final Map<String, String> categories;

  const PurchaseListDialog({
    super.key,
    required this.pharmacyId,
    required this.isOnlineMode,
    required this.warehouses,
    required this.initialWarehouseId,
    required this.allowWarehouseChoice,
    required this.masterMedicines,
    required this.categories,
  });

  @override
  State<PurchaseListDialog> createState() => _PurchaseListDialogState();
}

/// سطر واحد في القائمة (حقوله وحالة لوحته).
class _Line {
  final name = TextEditingController();
  final barcode = TextEditingController();
  final scientific = TextEditingController();
  final shelf = TextEditingController();
  final quantity = TextEditingController();
  final bonus = TextEditingController();
  final buyPrice = TextEditingController();
  final sellPrice = TextEditingController();
  final expiry = TextEditingController();
  final nameFocus = FocusNode();
  final quantityFocus = FocusNode();
  final bonusFocus = FocusNode();
  final buyFocus = FocusNode();
  final sellFocus = FocusNode();
  final expiryFocus = FocusNode();
  final barcodeFocus = FocusNode();
  final scientificFocus = FocusNode();
  final shelfFocus = FocusNode();
  final key = GlobalKey();
  String category = 'tablet';
  bool isFree = false;

  /// اختير اسم الصنف فظهرت بقية الحقول.
  bool committed = false;
  bool expanded = true;

  /// الصنف الموجود في المخزن المختار (نفس الباركود أو الاسم)، أو null = صنف جديد.
  Map<String, dynamic>? existing;
  String? error;

  bool get isBlank => !committed && name.text.trim().isEmpty;

  void dispose() {
    for (final c in [name, barcode, scientific, shelf, quantity, bonus, buyPrice, sellPrice, expiry]) {
      c.dispose();
    }
    for (final f in [
      nameFocus,
      quantityFocus,
      bonusFocus,
      buyFocus,
      sellFocus,
      expiryFocus,
      barcodeFocus,
      scientificFocus,
      shelfFocus,
    ]) {
      f.dispose();
    }
  }
}

double? _parseNum(String text) {
  final cleaned = text.trim().replaceAll(',', '').replaceAll('٫', '.');
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}

double _round2(double v) => (v * 100).round() / 100;

class _PurchaseListDialogState extends State<PurchaseListDialog> {
  PurchaseListMode _mode = PurchaseListMode.supplierList;

  // رأس القائمة
  List<Map<String, dynamic>> _suppliers = [];
  String? _suppliersError;
  Map<String, dynamic>? _selectedSupplier;
  final _supplierName = TextEditingController();
  final _supplierPhone = TextEditingController();
  final _invoiceNumber = TextEditingController();
  final _paidNow = TextEditingController();
  DateTime _invoiceDate = DateTime.now();
  late int _warehouseId = widget.initialWarehouseId;

  /// أرقام فواتير المذخر المختار (للتحذير من التكرار قبل الحفظ).
  Set<String> _supplierInvoiceNumbers = {};

  // أصناف المخزن المختار (للإكمال التلقائي وشارة "صنف موجود").
  List<Map<String, dynamic>> _inventory = [];

  final List<_Line> _lines = [];
  final _scroll = ScrollController();
  bool _saving = false;
  String? _headerError;

  bool get _isSupplierList => _mode == PurchaseListMode.supplierList;

  /// رصيد الصيدلية لدى المذخر المختار (مذخر جديد: 0). يُخصم تلقائياً من الفاتورة
  /// عند الحفظ حتى إجماليها، قبل "المدفوع الآن".
  double get _availableCredit {
    final value = _selectedSupplier?['available_credit'];
    return value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _creditApplied(double invoiceTotal) =>
      _isSupplierList ? (_availableCredit < invoiceTotal ? _availableCredit : invoiceTotal) : 0;

  @override
  void initState() {
    super.initState();
    _lines.add(_Line());
    _loadSuppliers();
    _loadInventory();
    _invoiceNumber.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    _supplierName.dispose();
    _supplierPhone.dispose();
    _invoiceNumber.dispose();
    _paidNow.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ================== البيانات ==================

  Future<void> _loadSuppliers() async {
    try {
      final rows = await SuppliersRepository.instance.getSuppliersWithFinancials(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
      );
      if (mounted) setState(() => _suppliers = rows);
    } catch (e) {
      if (mounted) setState(() => _suppliersError = e.toString());
    }
  }

  Future<void> _loadInventory() async {
    final rows = await DatabaseHelper.instance.getMedicines(widget.pharmacyId, warehouseId: _warehouseId);
    if (!mounted) return;
    setState(() {
      _inventory = rows;
      for (final line in _lines.where((l) => l.committed)) {
        line.existing = _matchExisting(line);
      }
    });
  }

  Future<void> _loadSupplierInvoices(int supplierId) async {
    try {
      final rows = await SuppliersRepository.instance.getPurchaseInvoicesBySupplier(
        supplierId: supplierId,
        isOnlineMode: widget.isOnlineMode,
      );
      if (!mounted || _selectedSupplier?['id'] != supplierId) return;
      setState(() {
        _supplierInvoiceNumbers =
            rows.map((r) => (r['invoice_number'] ?? '').toString().trim()).where((n) => n.isNotEmpty).toSet();
      });
    } catch (_) {
      // التحذير المسبق تحسين فقط؛ الحفظ نفسه يرفض الرقم المكرر.
    }
  }

  /// نفس قاعدة الحفظ (findPurchaseListMedicine / find_existing_medicine):
  /// نفس الباركود في المخزن، وإلا نفس الاسم التجاري بلا حساسية لحالة الأحرف.
  Map<String, dynamic>? _matchExisting(_Line line) {
    final barcode = line.barcode.text.trim();
    if (barcode.isNotEmpty) {
      for (final m in _inventory) {
        if ((m['barcode'] ?? '').toString().trim() == barcode) return m;
      }
    }
    final name = line.name.text.trim().toLowerCase();
    if (name.isEmpty) return null;
    Map<String, dynamic>? best;
    for (final m in _inventory) {
      if ((m['trade_name'] ?? '').toString().trim().toLowerCase() == name) {
        if (best == null || (m['id'] as int) < (best['id'] as int)) best = m;
      }
    }
    return best;
  }

  bool get _duplicateInvoiceNumber {
    if (!_isSupplierList || _selectedSupplier == null) return false;
    return _supplierInvoiceNumbers.contains(_invoiceNumber.text.trim());
  }

  bool _isDirty() =>
      _lines.any((l) => !l.isBlank) ||
      _supplierName.text.trim().isNotEmpty ||
      _selectedSupplier != null ||
      _invoiceNumber.text.trim().isNotEmpty;

  // ================== منطق الأسطر ==================

  /// يثبّت اسم الصنف: يفتح لوحة الحقول، ويعبّئ ما يُعرف مسبقاً (من الصنف
  /// الموجود أو من القاموس)، وينقل التركيز لحقل الكمية.
  void _commitName(_Line line, {Map<String, dynamic>? option}) {
    final typed = line.name.text.trim();
    if (typed.isEmpty && option == null) return;

    // باركود ماسح ضوئي في حقل الاسم يطابق صنفاً في المخزن مباشرة.
    if (option == null) {
      for (final m in _inventory) {
        if ((m['barcode'] ?? '').toString().trim() == typed && typed.isNotEmpty) {
          option = {...m, '_inventory': true};
          break;
        }
      }
    }

    setState(() {
      if (option != null) {
        line.name.text = (option['trade_name'] ?? typed).toString();
        if (option['_inventory'] == true) line.barcode.text = (option['barcode'] ?? '').toString();
        final scientific = (option['scientific_name'] ?? '').toString();
        if (scientific.isNotEmpty) line.scientific.text = scientific;
        final category = option['category']?.toString();
        if (category != null && widget.categories.containsKey(category)) line.category = category;
      }
      line.committed = true;
      line.expanded = true;
      line.error = null;
      line.existing = _matchExisting(line);
      final existing = line.existing;
      if (existing != null) {
        // بيانات الصنف الموجود للعرض؛ سعر البيع الحالي اقتراح قابل للتعديل.
        line.barcode.text = (existing['barcode'] ?? '').toString();
        line.scientific.text = (existing['scientific_name'] ?? '').toString();
        line.shelf.text = (existing['shelf_location'] ?? '').toString();
        final category = existing['category']?.toString();
        if (category != null && widget.categories.containsKey(category)) line.category = category;
        final sell = (existing['sell_price'] as num?)?.toDouble() ?? 0;
        if (line.sellPrice.text.trim().isEmpty && sell > 0) line.sellPrice.text = _fmtInput(sell);
        final buy = (existing['buy_price'] as num?)?.toDouble() ?? 0;
        if (line.buyPrice.text.trim().isEmpty && buy > 0 && !line.isFree) line.buyPrice.text = _fmtInput(buy);
      }
      // كل سطر مكتمل الاسم يضمن وجود سطر فارغ بعده للصنف التالي.
      if (identical(line, _lines.last)) _lines.add(_Line());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      (line.isFree ? line.bonusFocus : line.quantityFocus).requestFocus();
    });
  }

  /// إنهاء الصنف: طيّ لوحته وتركيز سطر الصنف التالي الفارغ.
  void _finishLine(_Line line) {
    final error = validatePurchaseLine(_lineData(line), _mode, isNew: line.existing == null);
    setState(() {
      line.error = error;
      line.expanded = error != null;
      if (_lines.last.committed) _lines.add(_Line());
    });
    if (error != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lines.last.nameFocus.requestFocus();
      _scrollToEnd();
    });
  }

  void _removeLine(_Line line) {
    setState(() {
      _lines.remove(line);
      line.dispose();
      if (_lines.isEmpty || _lines.last.committed) _lines.add(_Line());
    });
  }

  void _toggleLine(_Line line) {
    setState(() => line.expanded = !line.expanded);
    if (line.expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => line.quantityFocus.requestFocus());
    }
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _setMode(PurchaseListMode mode) {
    setState(() {
      _mode = mode;
      _headerError = null;
      if (mode == PurchaseListMode.openingStock) {
        for (final line in _lines) {
          line.isFree = false;
          line.bonus.clear();
          line.error = null;
        }
      }
    });
  }

  Future<void> _changeWarehouse(int id) async {
    setState(() => _warehouseId = id);
    await _loadInventory();
  }

  /// بيانات السطر بمفاتيح الخادم نفسها (تُرسل كما هي أونلاين وتُحفظ محلياً أوفلاين).
  Map<String, dynamic> _lineData(_Line line) {
    final isFree = _isSupplierList && line.isFree;
    final buy = _parseNum(line.buyPrice.text);
    final sell = _parseNum(line.sellPrice.text);
    final expiryText = line.expiry.text.trim();
    return {
      'trade_name': line.name.text.trim(),
      'barcode': line.barcode.text.trim(),
      'scientific_name': line.scientific.text.trim(),
      'category': line.category,
      'shelf_location': line.shelf.text.trim(),
      'is_free': isFree,
      'quantity': isFree ? 0 : (_parseNum(line.quantity.text)?.toInt() ?? 0),
      'bonus_quantity': _isSupplierList ? (_parseNum(line.bonus.text)?.toInt() ?? 0) : 0,
      'buy_price': isFree ? null : (buy == null ? null : _round2(buy)),
      'sell_price': sell == null ? null : _round2(sell),
      // نص غير مفهوم يبقى فارغاً فيُرفض بـ"يرجى تحديد تاريخ الانتهاء".
      'expiry_date': expiryText.isEmpty ? '' : (normalizeExpiryInput(expiryText) ?? ''),
    };
  }

  Iterable<_Line> get _activeLines => _lines.where((l) => l.committed);

  // ================== الحفظ ==================

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _headerError = null);

    final lines = _activeLines.toList();
    if (lines.isEmpty) {
      setState(() => _headerError = 'أضف صنفاً واحداً على الأقل إلى القائمة.');
      return;
    }
    if (_isSupplierList) {
      if (_selectedSupplier == null && _supplierName.text.trim().isEmpty) {
        setState(() => _headerError = 'يرجى اختيار المذخر أو كتابة اسم مذخر جديد.');
        return;
      }
      if (_invoiceNumber.text.trim().isEmpty) {
        setState(() => _headerError = 'رقم فاتورة المذخر مطلوب.');
        return;
      }
      if (_duplicateInvoiceNumber) {
        setState(() => _headerError = 'رقم الفاتورة ${_invoiceNumber.text.trim()} مسجّل مسبقاً لهذا المذخر.');
        return;
      }
    }

    // تحقق محلي لكل الأسطر أولاً: كل الأسطر الخاطئة تُبرز معاً.
    _Line? firstBad;
    setState(() {
      for (final line in lines) {
        line.existing = _matchExisting(line);
        line.error = validatePurchaseLine(_lineData(line), _mode, isNew: line.existing == null);
        if (line.error != null) {
          line.expanded = true;
          firstBad ??= line;
        }
      }
    });
    if (firstBad != null) {
      _revealLine(firstBad!);
      return;
    }

    final items = lines.map(_lineData).toList();
    final totals = PurchaseListTotals.of(items);
    final paid = _isSupplierList ? (_parseNum(_paidNow.text) ?? 0) : 0.0;
    final payable = totals.invoiceTotal - _creditApplied(totals.invoiceTotal);
    if (paid < 0 || paid > payable + 0.001) {
      setState(() => _headerError = _creditApplied(totals.invoiceTotal) > 0
          ? 'المبلغ المدفوع الآن يجب أن يكون بين 0 والمتبقي بعد الخصم من رصيد المذخر (${AppFormatter.iqd(payable)}).'
          : 'المبلغ المدفوع الآن يجب أن يكون بين 0 وإجمالي الفاتورة.');
      return;
    }

    setState(() => _saving = true);
    try {
      if (_isSupplierList) {
        await SuppliersRepository.instance.createPurchaseList(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: widget.isOnlineMode,
          warehouseId: _warehouseId,
          invoiceNumber: _invoiceNumber.text.trim(),
          invoiceDate: _fmtDate(_invoiceDate),
          items: items,
          supplierId: _selectedSupplier?['id'] as int?,
          supplierName: _selectedSupplier == null ? _supplierName.text.trim() : null,
          supplierPhone: _selectedSupplier == null ? _supplierPhone.text.trim() : null,
          paidAmount: _round2(paid),
        );
      } else {
        await MedicineRepository.instance.createOpeningStock(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: widget.isOnlineMode,
          warehouseId: _warehouseId,
          items: items,
        );
      }
      if (!mounted) return;
      // pop (لا maybePop) كي لا يسأل UnsavedChangesGuard بعد الحفظ.
      Navigator.of(context).pop(true);
    } on PurchaseListException catch (e) {
      if (!mounted) return;
      final index = e.line;
      setState(() {
        _saving = false;
        if (index != null && index >= 0 && index < lines.length) {
          lines[index].error = e.message;
          lines[index].expanded = true;
        } else {
          _headerError = e.message;
        }
      });
      if (index != null && index >= 0 && index < lines.length) _revealLine(lines[index]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _headerError = _errorText(e);
      });
    }
  }

  String _errorText(Object e) {
    if (e is SuppliersRepositoryException ||
        e is MedicineRepositoryException ||
        e is SuppliersApiException ||
        e is MedicineApiException) {
      return e.toString();
    }
    return 'تعذر حفظ القائمة، لم يُحفظ أي صنف. حاول مرة أخرى.';
  }

  void _revealLine(_Line line) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = line.key.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250), alignment: 0.2);
    });
  }

  // ================== الواجهة ==================

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final width = (screen.width * 0.9).clamp(720.0, 1600.0).clamp(0.0, screen.width - 24);
    final height = (screen.height * 0.9).clamp(520.0, 1100.0).clamp(0.0, screen.height - 24);

    return UnsavedChangesGuard(
      isDirty: _isDirty,
      message: 'لم يتم حفظ القائمة، هل تريد الخروج بدون حفظ؟',
      leaveLabel: 'خروج بدون حفظ',
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Dialog(
          insetPadding: const EdgeInsets.all(12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              children: [
                _buildTitleBar(),
                _buildHeader(),
                const Divider(height: 1),
                Expanded(child: _buildLines()),
                _buildFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFFE6F7F5),
            child: Icon(Icons.playlist_add_rounded, color: _primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 20,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'إضافة قائمة مذخر',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _textMain),
                ),
                SegmentedButton<PurchaseListMode>(
                  segments: const [
                    ButtonSegment(
                      value: PurchaseListMode.supplierList,
                      icon: Icon(Icons.local_shipping_outlined, size: 18),
                      label: Text('قائمة مذخر'),
                    ),
                    ButtonSegment(
                      value: PurchaseListMode.openingStock,
                      icon: Icon(Icons.inventory_2_outlined, size: 18),
                      label: Text('رصيد افتتاحي'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: _saving ? null : (s) => _setMode(s.first),
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: const Color(0xFFE6F7F5),
                    selectedForegroundColor: _primaryDark,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'إغلاق',
            // maybePop كي يمر عبر UnsavedChangesGuard.
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final warehouseField = widget.allowWarehouseChoice && widget.warehouses.length > 1
        ? SizedBox(
            key: const ValueKey('warehouse'),
            width: 200,
            child: DropdownButtonFormField<int>(
              initialValue: _warehouseId,
              isExpanded: true,
              decoration: _decoration('المخزن', Icons.warehouse_outlined),
              items: [
                for (final w in widget.warehouses)
                  DropdownMenuItem(
                      value: w['id'] as int, child: Text(w['name'].toString(), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _saving || _activeLines.isNotEmpty
                  ? null
                  : (v) {
                      if (v != null) _changeWarehouse(v);
                    },
            ),
          )
        : SizedBox(
            key: const ValueKey('warehouse'),
            width: 200,
            child: InputDecorator(
              decoration: _decoration('المخزن', Icons.warehouse_outlined),
              child: Text(_warehouseName(_warehouseId), overflow: TextOverflow.ellipsis),
            ),
          );

    return Container(
      color: const Color(0xFFF8FAFA),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // مفاتيح ثابتة: ظهور حقل الهاتف بعد أول حرف من اسم مذخر جديد لا
              // يُزيح عناصر الحقول التالية (كان رقم الفاتورة يُربط بالحقل الخطأ).
              if (_isSupplierList) ...[
                SizedBox(key: const ValueKey('supplier'), width: 280, child: _buildSupplierField()),
                if (_selectedSupplier == null && _supplierName.text.trim().isNotEmpty)
                  SizedBox(
                    key: const ValueKey('supplier-phone'),
                    width: 170,
                    child: TextField(
                      controller: _supplierPhone,
                      keyboardType: TextInputType.phone,
                      decoration: _decoration('هاتف المذخر (اختياري)', Icons.phone_outlined),
                    ),
                  ),
                SizedBox(
                  key: const ValueKey('invoice-number'),
                  width: 190,
                  child: TextField(
                    controller: _invoiceNumber,
                    decoration: _decoration('رقم فاتورة المذخر *', Icons.tag_rounded).copyWith(
                      errorText: _duplicateInvoiceNumber ? 'هذا الرقم مسجّل مسبقاً لهذا المذخر' : null,
                    ),
                  ),
                ),
                SizedBox(
                  key: const ValueKey('invoice-date'),
                  width: 170,
                  child: InkWell(
                    onTap: _pickInvoiceDate,
                    child: InputDecorator(
                      decoration: _decoration('تاريخ الفاتورة', Icons.event_outlined),
                      child: Text(_fmtDate(_invoiceDate)),
                    ),
                  ),
                ),
              ] else
                const SizedBox(
                  width: 520,
                  child: Text(
                    'رصيد افتتاحي: المخزون الموجود على الرفوف عند بدء استخدام النظام. لا مذخر ولا فاتورة ولا دين.',
                    style: TextStyle(color: _textSecondary),
                  ),
                ),
              warehouseField,
            ],
          ),
          if (_headerError != null) ...[
            const SizedBox(height: 10),
            _errorBanner(_headerError!),
          ],
        ],
      ),
    );
  }

  Widget _buildSupplierField() {
    if (_selectedSupplier != null) {
      return InputDecorator(
        decoration: _decoration('المذخر *', Icons.local_shipping_outlined),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _selectedSupplier!['name'].toString(),
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            InkWell(
              onTap: _saving
                  ? null
                  : () => setState(() {
                        _selectedSupplier = null;
                        _supplierInvoiceNumbers = {};
                        _supplierName.clear();
                      }),
              child: const Icon(Icons.close_rounded, size: 18, color: _textSecondary),
            ),
          ],
        ),
      );
    }
    return Autocomplete<Map<String, dynamic>>(
      displayStringForOption: (o) => o['name']?.toString() ?? '',
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return _suppliers;
        return _suppliers.where((s) => (s['name'] ?? '').toString().toLowerCase().contains(q));
      },
      onSelected: (supplier) {
        setState(() {
          _selectedSupplier = supplier;
          _supplierName.clear();
          _supplierInvoiceNumbers = {};
        });
        _loadSupplierInvoices(supplier['id'] as int);
      },
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
        final typed = controller.text.trim();
        final isNew = typed.isNotEmpty &&
            !_suppliers.any((s) => (s['name'] ?? '').toString().trim().toLowerCase() == typed.toLowerCase());
        return TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: (v) => setState(() => _supplierName.text = v),
          decoration: _decoration('المذخر * (ابحث أو اكتب اسماً جديداً)', Icons.local_shipping_outlined).copyWith(
            helperText: _suppliersError != null
                ? 'تعذر تحميل المذاخر: يمكنك كتابة الاسم مباشرة'
                : (isNew ? 'مذخر جديد — سيُنشأ عند الحفظ' : null),
            helperStyle: const TextStyle(color: _newItem),
          ),
        );
      },
    );
  }

  Widget _buildLines() {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: _lines.length + 1,
      itemBuilder: (context, i) {
        if (i == _lines.length) {
          return const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Enter للانتقال بين الحقول • Enter في حقل الصلاحية ينهي الصنف ويبدأ صنفاً جديداً • الصلاحية: 2027-05 أو 05/2027 أو تاريخ كامل',
              style: TextStyle(color: _textSecondary, fontSize: 12),
            ),
          );
        }
        final line = _lines[i];
        return KeyedSubtree(
          key: line.key,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildLineCard(line, i),
          ),
        );
      },
    );
  }

  Widget _buildLineCard(_Line line, int index) {
    final hasError = line.error != null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: hasError ? _danger : (line.expanded && line.committed ? _primary : _border),
            width: hasError ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!line.committed)
            Padding(padding: const EdgeInsets.all(10), child: _buildNameField(line, index))
          else if (!line.expanded)
            _buildSummaryRow(line, index)
          else ...[
            _buildPanelHeader(line, index),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _buildPanelFields(line),
            ),
          ],
          if (hasError)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text(line.error!, style: const TextStyle(color: _danger, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  /// حقل اسم الصنف بالإكمال التلقائي: أصناف المخزن المختار أولاً ثم القاموس.
  Widget _buildNameField(_Line line, int index) {
    return Autocomplete<Map<String, dynamic>>(
      textEditingController: line.name,
      focusNode: line.nameFocus,
      displayStringForOption: (o) => o['trade_name']?.toString() ?? '',
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return const Iterable<Map<String, dynamic>>.empty();
        final results = <Map<String, dynamic>>[];
        final seen = <String>{};
        for (final m in _inventory) {
          final name = (m['trade_name'] ?? '').toString();
          final barcode = (m['barcode'] ?? '').toString();
          if (name.toLowerCase().contains(q) || (barcode.isNotEmpty && barcode == value.text.trim())) {
            results.add({...m, '_inventory': true});
            seen.add(name.toLowerCase());
          }
          if (results.length >= 15) break;
        }
        for (final m in widget.masterMedicines) {
          if (results.length >= 30) break;
          final name = (m['trade_name'] ?? '').toString();
          if (name.toLowerCase().contains(q) && seen.add(name.toLowerCase())) results.add(m);
        }
        return results;
      },
      onSelected: (option) => _commitName(line, option: option),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: AlignmentDirectional.topStart,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320, maxWidth: 560),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final o in options)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      o['_inventory'] == true ? Icons.inventory_2_outlined : Icons.menu_book_outlined,
                      color: o['_inventory'] == true ? _existing : _textSecondary,
                      size: 20,
                    ),
                    title: Text(o['trade_name']?.toString() ?? ''),
                    subtitle: Text(
                      o['_inventory'] == true
                          ? 'في المخزن • الكمية ${o['quantity'] ?? 0}'
                          : (o['scientific_name']?.toString() ?? ''),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => onSelected(o),
                  ),
              ],
            ),
          ),
        ),
      ),
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) => Row(
        children: [
          _indexBadge(index),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: index == 0,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _commitName(line),
              decoration: _decoration(
                index == 0
                    ? 'اكتب اسم الصنف الأول أو امسح الباركود...'
                    : 'الصنف التالي: اكتب الاسم أو امسح الباركود...',
                Icons.medication_outlined,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanelHeader(_Line line, int index) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      child: Row(
        children: [
          _indexBadge(index),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: line.name,
              onChanged: (_) => setState(() {
                line.existing = _matchExisting(line);
              }),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              decoration: const InputDecoration(isDense: true, border: InputBorder.none),
            ),
          ),
          _statusBadge(line),
          const SizedBox(width: 6),
          TextButton.icon(
            onPressed: () => _finishLine(line),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('تم'),
            style: TextButton.styleFrom(foregroundColor: _primaryDark),
          ),
          IconButton(
            tooltip: 'حذف الصنف',
            onPressed: () => _removeLine(line),
            icon: const Icon(Icons.delete_outline_rounded, color: _danger, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildPanelFields(_Line line) {
    final existing = line.existing != null;
    final isFree = _isSupplierList && line.isFree;
    // الحقول بترتيب Tab/Enter: الكميات والأسعار والصلاحية أولاً، ثم التفاصيل الاختيارية.
    final numbers = Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_isSupplierList)
          FilterChip(
            label: const Text('مجاني'),
            avatar: Icon(isFree ? Icons.card_giftcard : Icons.card_giftcard_outlined, size: 16, color: _free),
            selected: isFree,
            selectedColor: _free.withValues(alpha: .16),
            tooltip: 'صنف أضافه المذخر مجاناً (غير مطبوع في الفاتورة): لا كمية مدفوعة ولا سعر شراء',
            onSelected: (v) => setState(() {
              line.isFree = v;
              line.error = null;
              if (v) {
                line.quantity.clear();
                line.buyPrice.clear();
              }
            }),
          ),
        if (!isFree)
          _numField(line.quantity, line.quantityFocus, _isSupplierList ? 'الكمية المدفوعة *' : 'الكمية *', 130,
              next: _isSupplierList ? line.bonusFocus : line.buyFocus, integer: true),
        if (_isSupplierList)
          _numField(line.bonus, line.bonusFocus, isFree ? 'الكمية المجانية *' : 'بونص (مجاني)', 130,
              next: isFree ? line.sellFocus : line.buyFocus, integer: true),
        if (!isFree)
          _numField(line.buyPrice, line.buyFocus, _isSupplierList ? 'سعر الشراء *' : 'سعر الشراء (0 = غير معروف)', 160,
              next: line.sellFocus),
        _numField(line.sellPrice, line.sellFocus, existing && isFree ? 'سعر البيع (اختياري)' : 'سعر البيع *', 140,
            next: line.expiryFocus),
        SizedBox(
          width: 190,
          child: TextField(
            controller: line.expiry,
            focusNode: line.expiryFocus,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _finishLine(line),
            decoration: _decoration('الصلاحية *', Icons.event_outlined).copyWith(
              hintText: '2027-05',
              helperText: _expiryHelper(line.expiry.text),
              suffixIcon: IconButton(
                icon: const Icon(Icons.calendar_month_outlined, size: 18),
                onPressed: () => _pickExpiry(line),
              ),
            ),
          ),
        ),
        _lineTotalChip(line),
      ],
    );

    final details = Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        SizedBox(
          width: 190,
          child: TextField(
            controller: line.barcode,
            focusNode: line.barcodeFocus,
            enabled: !existing,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() => line.existing = _matchExisting(line)),
            onSubmitted: (_) => line.scientificFocus.requestFocus(),
            decoration: _decoration('الباركود', Icons.qr_code_scanner),
          ),
        ),
        SizedBox(
          width: 220,
          child: TextField(
            controller: line.scientific,
            focusNode: line.scientificFocus,
            enabled: !existing,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => line.shelfFocus.requestFocus(),
            decoration: _decoration('الاسم العلمي', Icons.science_outlined),
          ),
        ),
        SizedBox(
          width: 210,
          child: DropdownButtonFormField<String>(
            key: ValueKey('${line.hashCode}-${line.category}-$existing'),
            initialValue: widget.categories.containsKey(line.category) ? line.category : null,
            isExpanded: true,
            decoration: _decoration('الشكل الدوائي', Icons.category_outlined),
            items: widget.categories.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: existing ? null : (v) => setState(() => line.category = v ?? line.category),
          ),
        ),
        SizedBox(
          width: 150,
          child: TextField(
            controller: line.shelf,
            focusNode: line.shelfFocus,
            enabled: !existing,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _finishLine(line),
            decoration: _decoration('موقع الرف', Icons.grid_view_outlined),
          ),
        ),
        if (existing)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'بيانات الصنف الموجود تُعدَّل من نافذة "تعديل" في المخزون.',
              style: TextStyle(color: _textSecondary, fontSize: 12),
            ),
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [numbers, const SizedBox(height: 10), details],
    );
  }

  /// سطر مطوي: الاسم · الكمية (+بونص) · سعر الشراء · الصلاحية · إجمالي السطر.
  Widget _buildSummaryRow(_Line line, int index) {
    final data = _lineData(line);
    final isFree = data['is_free'] == true;
    final qty = data['quantity'] as int;
    final bonus = data['bonus_quantity'] as int;
    final qtyText = isFree ? 'مجاني × $bonus' : (bonus > 0 ? '$qty (+$bonus)' : '$qty');
    final buy = data['buy_price'] as double?;
    final expiry = (data['expiry_date'] as String).isEmpty ? line.expiry.text.trim() : data['expiry_date'] as String;

    return InkWell(
      onTap: () => _toggleLine(line),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            _indexBadge(index),
            const SizedBox(width: 10),
            Expanded(
              flex: 4,
              child: Text(line.name.text.trim(),
                  style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
            ),
            _statusBadge(line),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: _summaryCell('الكمية', qtyText)),
            Expanded(
              flex: 2,
              child: _summaryCell('الشراء', isFree ? '-' : (buy == null ? '-' : AppFormatter.iqd(buy))),
            ),
            Expanded(flex: 2, child: _summaryCell('الصلاحية', expiry.isEmpty ? '-' : expiry)),
            Expanded(flex: 2, child: _summaryCell('الإجمالي', AppFormatter.iqd(_lineTotal(data)))),
            IconButton(
              tooltip: 'تعديل',
              onPressed: () => _toggleLine(line),
              icon: const Icon(Icons.edit_outlined, size: 18, color: _primaryDark),
            ),
            IconButton(
              tooltip: 'حذف الصنف',
              onPressed: () => _removeLine(line),
              icon: const Icon(Icons.delete_outline_rounded, size: 18, color: _danger),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final items = _activeLines.map(_lineData).toList();
    final totals = PurchaseListTotals.of(items);
    final paid = _parseNum(_paidNow.text) ?? 0;
    final creditApplied = _creditApplied(totals.invoiceTotal);
    final due = totals.invoiceTotal - creditApplied - paid;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: Color(0xFFF1F8F8),
        border: Border(top: BorderSide(color: _border)),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 22,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _footerStat('عدد الأصناف', '${totals.itemCount}'),
              _footerStat(_isSupplierList ? 'الكمية المدفوعة' : 'إجمالي الكمية', '${totals.paidQuantity}'),
              if (_isSupplierList) _footerStat('البونص / المجاني', '${totals.bonusQuantity}'),
              if (_isSupplierList && totals.freeItemCount > 0)
                _footerStat('أصناف مجانية', '${totals.freeItemCount}', color: _free),
              if (_isSupplierList)
                _footerStat('إجمالي الفاتورة', AppFormatter.iqdWithCurrency(totals.invoiceTotal), color: _primaryDark),
              if (creditApplied > 0)
                _footerStat('خصم من رصيد سابق', AppFormatter.iqdWithCurrency(creditApplied), color: _free),
              if (_isSupplierList && (paid > 0 || creditApplied > 0))
                _footerStat('المتبقي على المذخر', AppFormatter.iqdWithCurrency(due),
                    color: due < 0 ? _danger : _textMain),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Spacer(),
              if (_isSupplierList) ...[
                SizedBox(
                  width: 170,
                  child: TextField(
                    controller: _paidNow,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                    onChanged: (_) => setState(() {}),
                    decoration: _decoration('المدفوع الآن (اختياري)', Icons.payments_outlined),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              OutlinedButton(
                onPressed: _saving ? null : () => Navigator.maybePop(context),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
                child: const Text('إلغاء', style: TextStyle(color: Colors.black87)),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                  elevation: 0,
                ),
                icon: _saving
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save_outlined, color: Colors.white),
                label: Text(
                  _isSupplierList ? 'حفظ القائمة والفاتورة' : 'حفظ الرصيد الافتتاحي',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ================== عناصر صغيرة ==================

  double _lineTotal(Map<String, dynamic> data) => data['is_free'] == true
      ? 0
      : purchaseLineTotal(paidQty: data['quantity'] as int, buyPrice: (data['buy_price'] as double?) ?? 0);

  Widget _lineTotalChip(_Line line) {
    final data = _lineData(line);
    final qty = (data['quantity'] as int) + (data['bonus_quantity'] as int);
    final buy = data['buy_price'] as double?;
    final bonus = data['bonus_quantity'] as int;
    String? costNote;
    if (_isSupplierList && data['is_free'] != true && bonus > 0 && buy != null && qty > 0) {
      final unit = effectiveUnitCost(paidQty: data['quantity'] as int, bonusQty: bonus, buyPrice: buy);
      costNote = 'كلفة الوحدة الفعلية ${AppFormatter.iqd(unit)}';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isSupplierList ? 'إجمالي السطر: ${AppFormatter.iqd(_lineTotal(data))}' : 'الكمية الداخلة: $qty',
          style: const TextStyle(fontWeight: FontWeight.w800, color: _primaryDark),
        ),
        if (_isSupplierList && qty > 0)
          Text('يدخل المخزون: $qty قطعة', style: const TextStyle(fontSize: 12, color: _textSecondary)),
        if (costNote != null) Text(costNote, style: const TextStyle(fontSize: 12, color: _textSecondary)),
      ],
    );
  }

  Widget _numField(TextEditingController c, FocusNode f, String label, double width,
      {required FocusNode next, bool integer = false}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        focusNode: f,
        keyboardType: TextInputType.numberWithOptions(decimal: !integer),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(integer ? r'[0-9]' : r'[0-9.,]'))],
        textInputAction: TextInputAction.next,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => next.requestFocus(),
        decoration: _decoration(label, null),
      ),
    );
  }

  String? _expiryHelper(String text) {
    if (text.trim().isEmpty) return null;
    final normalized = normalizeExpiryInput(text);
    return normalized ?? 'صيغة غير مفهومة';
  }

  Widget _statusBadge(_Line line) {
    final existing = line.existing != null;
    final color = existing ? _existing : _newItem;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isSupplierList && line.isFree) _badge('مجاني', _free),
        if (_isSupplierList && line.isFree) const SizedBox(width: 6),
        Tooltip(
          message: existing
              ? 'يُضاف للصنف الموجود (الكمية الحالية ${line.existing!['quantity'] ?? 0}) كدفعة جديدة، وسعر البيع الجديد يحل محل القديم'
              : 'صنف جديد يُنشأ في المخزن عند الحفظ',
          child: _badge(existing ? 'صنف موجود' : 'صنف جديد', color),
        ),
      ],
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: .13), borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
      );

  Widget _indexBadge(int index) => CircleAvatar(
        radius: 13,
        backgroundColor: const Color(0xFFE6F7F5),
        child: Text('${index + 1}',
            style: const TextStyle(fontSize: 12, color: _primaryDark, fontWeight: FontWeight.bold)),
      );

  Widget _summaryCell(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: _textSecondary)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
        ],
      );

  Widget _footerStat(String label, String value, {Color color = _textMain}) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ', style: const TextStyle(color: _textSecondary)),
          Text(value, style: TextStyle(fontWeight: FontWeight.w800, color: color)),
        ],
      );

  Widget _errorBanner(String message) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _danger.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _danger.withValues(alpha: .4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: _danger, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(color: _danger, fontWeight: FontWeight.w600))),
          ],
        ),
      );

  InputDecoration _decoration(String label, IconData? icon) => InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        prefixIcon: icon == null ? null : Icon(icon, color: _primary, size: 19),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _primary, width: 1.5),
        ),
      );

  String _warehouseName(int id) {
    final match = widget.warehouses.where((w) => w['id'] == id);
    return match.isEmpty ? 'المخزن الرئيسي' : match.first['name'].toString();
  }

  String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _fmtInput(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }

  Future<void> _pickInvoiceDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _invoiceDate,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _invoiceDate = picked);
  }

  Future<void> _pickExpiry(_Line line) async {
    final now = DateTime.now();
    final current = DateTime.tryParse(normalizeExpiryInput(line.expiry.text) ?? '');
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(2045, 12, 31),
    );
    if (picked != null) {
      setState(() => line.expiry.text = _fmtDate(picked));
      line.expiryFocus.requestFocus();
    }
  }
}
