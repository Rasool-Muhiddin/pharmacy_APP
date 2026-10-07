import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../database/db_helper.dart';
import '../repository/medicine_repository.dart';
import '../repository/warehouse_repository.dart';
import '../services/medicine_api_service.dart';
import '../models/medicine_categories.dart';
import '../models/purchase_list.dart';
import '../models/subscription_plan.dart';
import '../utils/formatters.dart';
import 'purchase_list_dialog.dart';
import '../widgets/medicine_dialogs.dart';
import '../widgets/upgrade_required_dialog.dart';

class InventoryScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOwner;
  final bool isOnlineMode;

  /// صلاحيات الباقة الحالية — تُستخدم لتحديد ما إذا كانت خاصية تعدد
  /// المخازن مفعّلة (Gold) أو ظاهرة-لكن-مقفولة (Basic)، وحدّها الأقصى.
  final SubscriptionEntitlements entitlements;

  const InventoryScreen({
    super.key,
    required this.pharmacyId,
    this.isOwner = true,
    this.isOnlineMode = false,
    required this.entitlements,
  });

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _medicines = [];
  List<Map<String, dynamic>> _masterMedicines = []; // القاموس المحمل من iraqi_drugs.json
  bool _isLoading = false;

  // خاصية الباقة الذهبية: تعدد المخازن، أوفلاين وأونلاين عبر
  // WarehouseRepository. العرض مقيَّد دائماً بالمخزن المختار (الرئيسي افتراضياً).
  List<Map<String, dynamic>> _warehouses = [];
  int? _selectedWarehouseId;

  int? get _mainWarehouseId {
    if (_warehouses.isEmpty) return null;
    final main = _warehouses.firstWhere(
      (w) => (w['is_main'] as int) == 1,
      orElse: () => _warehouses.first,
    );
    return main['id'] as int;
  }

  // الأشكال الدوائية من المصدر المشترك (المخزون + التقارير).
  final Map<String, String> _categories = medicineCategories;

  @override
  void initState() {
    super.initState();
    _loadMasterMedicinesFromJson(); // تحميل الأدوية من الملف عند فتح الشاشة
    _refreshAll();
  }

  /// المخازن أولاً (لتحديد المخزن المختار)، ثم أصناف ذلك المخزن.
  Future<void> _refreshAll() async {
    await _loadWarehouses();
    await _loadMedicines();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // --- قراءة ملف assets/data/iraqi_drugs.json ---
  Future<void> _loadMasterMedicinesFromJson() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/data/iraqi_drugs.json');
      final List<dynamic> jsonList = json.decode(jsonString);
      setState(() {
        _masterMedicines = List<Map<String, dynamic>>.from(jsonList);
      });
    } catch (e) {
      debugPrint('تنبيه: لم يتم العثور على ملف assets/data/iraqi_drugs.json أو حدث خطأ أثناء القراءة: $e');
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _friendlyWriteErrorMessage(Object error) => friendlyWriteErrorMessage(error);

  // --- تحميل أدوية المخزن الحالية من قاعدة البيانات ---
  Future<void> _loadMedicines() async {
    setState(() => _isLoading = true);
    try {
      final query = _searchController.text.trim();
      List<Map<String, dynamic>> data;

      if (query.isEmpty) {
        data = await MedicineRepository.instance.getMedicines(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: widget.isOnlineMode,
        );
      } else {
        // البحث يبقى محلياً دائماً (على الكاش المتزامن آخر مرة)، بلا فرق
        // بين الوضعين — أونلاين أو أوفلاين.
        data = await DatabaseHelper.instance.searchMedicines(widget.pharmacyId, query);
      }

      // تقييد العرض بالمخزن المختار حالياً (الرئيسي افتراضياً). أونلاين هذا
      // يُخفي أيضاً أي صفوف أوفلاين قديمة لم تُرفع بعد (مخزنها ليس من الخادم).
      if (_selectedWarehouseId != null) {
        data = data.where((m) => m['warehouse_id'] == _selectedWarehouseId).toList();
      }

      // تحديث عدد الأصناف/الكميات على شرائح المخازن من الكاش المحلي (بلا
      // طلب شبكة إضافي) بعد أي إضافة/توريد/إتلاف/حذف.
      final warehouses = await DatabaseHelper.instance.getWarehouses(
        widget.pharmacyId,
        syncedOnly: widget.isOnlineMode,
      );

      if (!mounted) return;
      setState(() {
        _medicines = data;
        if (warehouses.isNotEmpty) _warehouses = warehouses;
      });
    } catch (e) {
      if (mounted) _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // --- خاصية الباقة الذهبية: تعدد المخازن ---

  Future<void> _loadWarehouses() async {
    try {
      final warehouses = await WarehouseRepository.instance.getWarehouses(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
      );
      if (!mounted) return;
      setState(() {
        _warehouses = warehouses;
        // المخزن المختار قد يكون حُذف (من هذا الجهاز أو جهاز آخر أونلاين).
        final stillExists = warehouses.any((w) => w['id'] == _selectedWarehouseId);
        if (!stillExists) _selectedWarehouseId = _mainWarehouseId;
      });
    } catch (e) {
      if (mounted) _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
    }
  }

  /// تُعرض بدل فتح أي حوار فعلي عندما تكون الصيدلية على الباقة الأساسية —
  /// الميزة تبقى ظاهرة دائماً وفق طلب العمل، لا تُخفى، لكنها مقفولة.
  void _showUpgradeRequiredDialog(String featureLabel) {
    showUpgradeRequiredDialog(
      context,
      message: 'خطتك الحالية لا تسمح بـ "$featureLabel".\n\n'
          'قم بالترقية إلى الباقة الذهبية لتفعيل هذه الميزة.',
    );
  }

  bool get _multiWarehouseLocked => widget.entitlements.isLocked(AppFeature.multiWarehouse);

  bool get _atWarehouseLimit => _warehouses.length >= widget.entitlements.maxWarehouses;

  String _warehouseName(int? id) {
    final match = _warehouses.where((w) => w['id'] == id);
    return match.isEmpty ? '' : match.first['name'] as String;
  }

  /// حوار موحَّد لإدخال اسم مخزن (إضافة أو إعادة تسمية).
  Future<void> _showWarehouseNameDialog({
    required String title,
    required String initialName,
    required String actionLabel,
    required Future<void> Function(String name) onSubmit,
    required String successMessage,
  }) async {
    final nameCtrl = TextEditingController(text: initialName);
    var isSaving = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(title),
          content: TextField(
            controller: nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'اسم المخزن', border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(onPressed: isSaving ? null : () => Navigator.pop(ctx), child: const Text('إلغاء')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1ABC9C)),
              onPressed: isSaving
                  ? null
                  : () async {
                      final name = nameCtrl.text.trim();
                      if (name.isEmpty) {
                        _showSnackBar('اسم المخزن مطلوب', Colors.red);
                        return;
                      }
                      setDialogState(() => isSaving = true);
                      try {
                        await onSubmit(name);
                        if (ctx.mounted && Navigator.canPop(ctx)) Navigator.pop(ctx);
                        await _loadWarehouses();
                        if (mounted) _showSnackBar(successMessage, Colors.green);
                      } catch (e) {
                        if (ctx.mounted) setDialogState(() => isSaving = false);
                        if (mounted) _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
                      }
                    },
              child: Text(actionLabel, style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _openAddWarehouseDialog() {
    if (_multiWarehouseLocked) {
      _showUpgradeRequiredDialog('إضافة مخازن إضافية');
      return;
    }
    if (_atWarehouseLimit) {
      _showSnackBar(
        'وصلت للحد الأقصى لعدد المخازن في باقتك (${widget.entitlements.maxWarehouses}).',
        Colors.orange,
      );
      return;
    }
    _showWarehouseNameDialog(
      title: 'إضافة مخزن جديد',
      initialName: 'مخزن ${_warehouses.length + 1}',
      actionLabel: 'إضافة',
      successMessage: 'تم إضافة المخزن بنجاح',
      onSubmit: (name) => WarehouseRepository.instance.addWarehouse(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        entitlements: widget.entitlements,
        name: name,
      ),
    );
  }

  void _openRenameWarehouseDialog(Map<String, dynamic> warehouse) {
    _showWarehouseNameDialog(
      title: 'إعادة تسمية المخزن',
      initialName: warehouse['name'] as String,
      actionLabel: 'حفظ',
      successMessage: 'تم تعديل اسم المخزن',
      onSubmit: (name) => WarehouseRepository.instance.renameWarehouse(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        warehouseId: warehouse['id'] as int,
        name: name,
      ),
    );
  }

  Future<void> _confirmDeleteWarehouse(Map<String, dynamic> warehouse) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف المخزن'),
        content: Text(
          'هل تريد حذف "${warehouse['name']}"؟\n\n'
          'يجب أن يكون المخزن فارغاً (انقل أصنافه إلى مخزن آخر أولاً).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await WarehouseRepository.instance.deleteWarehouse(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
        warehouseId: warehouse['id'] as int,
      );
      await _refreshAll();
      if (mounted) _showSnackBar('تم حذف المخزن', Colors.green);
    } catch (e) {
      if (mounted) _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
    }
  }

  /// شريط اختيار المخزن. يظهر دائماً (حتى للباقة الأساسية) وفق طلب العمل:
  /// الميزة "ظاهرة لكن مقفولة"، لا مخفية. أزرار الإدارة (إضافة/تسمية/حذف/نقل)
  /// للمالك فقط، تماماً كما يفرضها الخادم أونلاين.
  Widget _buildWarehouseBar() {
    final isLocked = _multiWarehouseLocked;
    final maxWarehouses = widget.entitlements.maxWarehouses;
    final hasSecondary = _warehouses.length > 1;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const Icon(Icons.warehouse_outlined, size: 18, color: Color(0xFF64748B)),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final w in _warehouses)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        avatar: (w['is_main'] as int) == 1
                            ? const Icon(Icons.storefront_outlined, size: 16)
                            : null,
                        label: Text('${w['name']} (${w['item_count'] ?? 0})'),
                        tooltip: (w['is_main'] as int) == 1
                            ? 'المخزن الرئيسي — البيع يتم منه فقط'
                            : 'إجمالي الكمية: ${w['total_quantity'] ?? 0}',
                        selected: _selectedWarehouseId == w['id'],
                        onSelected: (_) {
                          setState(() => _selectedWarehouseId = w['id'] as int);
                          _loadMedicines();
                        },
                      ),
                    ),
                  if (widget.isOwner) ...[
                    ActionChip(
                      avatar: Icon(isLocked ? Icons.lock_outline : Icons.add, size: 16),
                      label: Text(isLocked ? 'مخزن إضافي' : 'مخزن جديد (${_warehouses.length}/$maxWarehouses)'),
                      onPressed: !isLocked && _atWarehouseLimit ? null : _openAddWarehouseDialog,
                    ),
                    const SizedBox(width: 8),
                    // بعد تخفيض الباقة يبقى النقل متاحاً لتفريغ المخازن الإضافية
                    // إلى الرئيسي (الوجهة الوحيدة المسموحة حينها).
                    if (!isLocked || hasSecondary)
                      ActionChip(
                        avatar: const Icon(Icons.sync_alt, size: 16),
                        label: const Text('نقل مخزون'),
                        onPressed: hasSecondary ? _openTransferDialog : null,
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (widget.isOwner && _selectedWarehouse != null && (_selectedWarehouse!['is_main'] as int) != 1)
            PopupMenuButton<String>(
              tooltip: 'إدارة المخزن',
              icon: const Icon(Icons.more_vert, color: Color(0xFF64748B)),
              onSelected: (value) {
                final warehouse = _selectedWarehouse!;
                if (value == 'rename') _openRenameWarehouseDialog(warehouse);
                if (value == 'delete') _confirmDeleteWarehouse(warehouse);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('إعادة تسمية المخزن')),
                PopupMenuItem(value: 'delete', child: Text('حذف المخزن', style: TextStyle(color: Colors.red))),
              ],
            ),
        ],
      ),
    );
  }

  Map<String, dynamic>? get _selectedWarehouse {
    final match = _warehouses.where((w) => w['id'] == _selectedWarehouseId);
    return match.isEmpty ? null : match.first;
  }

  void _openTransferDialog() {
    final transferable = _medicines.where((m) => ((m['quantity'] as num?) ?? 0) > 0).toList();
    if (transferable.isEmpty) {
      _showSnackBar('لا توجد أصناف بكمية متوفرة في هذا المخزن لنقلها.', Colors.orange);
      return;
    }
    // الوجهات: كل مخازن الصيدلية عدا المخزن الحالي. إن كانت الباقة لا تسمح
    // بتعدد المخازن (بعد تخفيضها) فالوجهة الوحيدة هي المخزن الرئيسي.
    final destinations = _warehouses
        .where((w) => w['id'] != _selectedWarehouseId)
        .where((w) => !_multiWarehouseLocked || (w['is_main'] as int) == 1)
        .toList();
    if (destinations.isEmpty) {
      _showSnackBar('لا يوجد مخزن آخر متاح للنقل إليه.', Colors.orange);
      return;
    }

    Map<String, dynamic>? selectedMedicine;
    int? destWarehouseId = destinations.length == 1 ? destinations.first['id'] as int : null;
    final qtyCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    var isSaving = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final available = (selectedMedicine?['quantity'] as num?)?.toInt();
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: Text('نقل مخزون من "${_warehouseName(_selectedWarehouseId)}"'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<Map<String, dynamic>>(
                    initialValue: selectedMedicine,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'الصنف', border: OutlineInputBorder()),
                    items: transferable
                        .map((m) => DropdownMenuItem(
                              value: m,
                              child: Text(
                                '${m['trade_name']} (${m['quantity']} قطعة)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (val) => setDialogState(() {
                      selectedMedicine = val;
                      qtyCtrl.text = '${val?['quantity'] ?? ''}';
                    }),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: destWarehouseId,
                    decoration: const InputDecoration(labelText: 'المخزن الهدف', border: OutlineInputBorder()),
                    items: destinations
                        .map((w) => DropdownMenuItem(
                              value: w['id'] as int,
                              child: Text(w['name'] as String),
                            ))
                        .toList(),
                    onChanged: (val) => setDialogState(() => destWarehouseId = val),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: qtyCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'الكمية المنقولة',
                      helperText: available != null ? 'المتوفر: $available' : null,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesCtrl,
                    decoration: const InputDecoration(labelText: 'ملاحظات (اختياري)', border: OutlineInputBorder()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: isSaving ? null : () => Navigator.pop(ctx), child: const Text('إلغاء')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1ABC9C)),
                onPressed: isSaving
                    ? null
                    : () async {
                        final qty = int.tryParse(qtyCtrl.text.trim());
                        if (selectedMedicine == null || destWarehouseId == null || qty == null || qty <= 0) {
                          _showSnackBar('أكمل كل الحقول بكمية صحيحة أكبر من صفر', Colors.red);
                          return;
                        }
                        if (available != null && qty > available) {
                          _showSnackBar('الكمية أكبر من المتوفر ($available)', Colors.red);
                          return;
                        }
                        setDialogState(() => isSaving = true);
                        try {
                          await WarehouseRepository.instance.transferStock(
                            pharmacyId: widget.pharmacyId,
                            isOnlineMode: widget.isOnlineMode,
                            entitlements: widget.entitlements,
                            medicineId: selectedMedicine!['id'] as int,
                            toWarehouseId: destWarehouseId!,
                            quantity: qty,
                            notes: notesCtrl.text.trim(),
                          );
                          if (ctx.mounted && Navigator.canPop(ctx)) Navigator.pop(ctx);
                          await _loadWarehouses();
                          await _loadMedicines();
                          if (mounted) {
                            _showSnackBar(
                              'تم نقل $qty من ${selectedMedicine!['trade_name']} إلى ${_warehouseName(destWarehouseId)}',
                              Colors.green,
                            );
                          }
                        } catch (e) {
                          if (ctx.mounted) setDialogState(() => isSaving = false);
                          if (mounted) _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
                        }
                      },
                child: const Text('نقل', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }
// --- 1. إضافة قائمة مذخر / رصيد افتتاحي (الطريق الوحيد لإدخال المخزون) ---
  Future<void> _openPurchaseListDialog() async {
    final warehouseId = _selectedWarehouseId ??
        await WarehouseRepository.instance.getMainWarehouseId(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: widget.isOnlineMode,
        );
    if (!mounted) return;
    final saved = await showPurchaseListDialog(
      context,
      pharmacyId: widget.pharmacyId,
      isOnlineMode: widget.isOnlineMode,
      warehouses: _warehouses,
      initialWarehouseId: warehouseId,
      allowWarehouseChoice: !_multiWarehouseLocked,
      masterMedicines: _masterMedicines,
      categories: _categories,
    );
    if (!saved || !mounted) return;
    _searchController.clear();
    await _loadMedicines();
    if (mounted) _showSnackBar('تم حفظ القائمة وتحديث المخزون بنجاح', Colors.green);
  }

  /// تفاصيل دفعات الصلاحية لصنف (للعرض فقط). سعر شراء الدفعة للمالك فقط.
  Future<void> _showBatchesDialog(Map<String, dynamic> med) async {
    final batches = await DatabaseHelper.instance.getMedicineBatches(med['id'] as int);
    if (!mounted) return;
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('دفعات الصلاحية — ${med['trade_name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 480,
          child: batches.isEmpty
              ? const Text('لا توجد كمية متوفرة حالياً.')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final b in batches)
                      Builder(builder: (context) {
                        final expiry = DateTime.tryParse((b['expiry_date'] ?? '').toString());
                        final expired = expiry != null && expiry.isBefore(todayDate);
                        final price = b['purchase_price'] as num?;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            expired ? Icons.warning_amber_rounded : Icons.event_available_outlined,
                            color: expired ? Colors.red : const Color(0xFF1ABC9C),
                          ),
                          title: Text(
                            'الانتهاء: ${b['expiry_date'] ?? 'غير محدد'}${expired ? ' (منتهية)' : ''}',
                            style: TextStyle(fontSize: 13, color: expired ? Colors.red : null),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_batchSourceText(b), style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
                              if (widget.isOwner && price != null)
                                Text('سعر الشراء: ${AppFormatter.iqdWithCurrency(price)}', style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                          trailing: Text('${b['quantity']} قطعة', style: const TextStyle(fontWeight: FontWeight.bold)),
                        );
                      }),
                  ],
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))],
      ),
    );
  }

  /// مصدر الدفعة للتتبّع (إرجاع لمذخر / إيقاف التعامل معه).
  String _batchSourceText(Map<String, dynamic> batch) {
    if (batch['source'] == BatchSource.openingStock) return 'رصيد افتتاحي';
    final supplier = (batch['supplier_name'] ?? '').toString().trim();
    final invoice = (batch['invoice_number'] ?? '').toString().trim();
    if (supplier.isEmpty && invoice.isEmpty) return 'المصدر: غير مسجّل (قبل قوائم المذاخر)';
    return 'المذخر: ${supplier.isEmpty ? '-' : supplier}${invoice.isEmpty ? '' : '  •  فاتورة #$invoice'}';
  }

// --- 3. تعديل بيانات الدواء ---
  Future<void> _openEditDialog(Map<String, dynamic> med) async {
    final saved = await showMedicineEditDialog(context, med: med, pharmacyId: widget.pharmacyId, isOnlineMode: widget.isOnlineMode);
    if (saved && mounted) {
      _loadMedicines();
      _showSnackBar('تم حفظ التعديلات بنجاح', Colors.green);
    }
  }

  // --- 4. الإتلاف الجزئي ---
  Future<void> _openDamageDialog(Map<String, dynamic> med) async {
    final done = await showMedicineDamageDialog(context, med: med, pharmacyId: widget.pharmacyId, isOnlineMode: widget.isOnlineMode);
    if (done && mounted) {
      _loadMedicines();
      _showSnackBar('تم نقل الكمية بنجاح إلى جدول التوالف', Colors.orange);
    }
  }
  // --- 5. الحذف النهائي ---
  void _confirmDeleteMedicine(Map<String, dynamic> med) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.delete_forever, color: Color(0xFFE53E3E)),
            SizedBox(width: 8),
            Text('تأكيد الحذف النهائي', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text('هل أنت أثق من حذف الدواء "${med['trade_name']}" نهائياً من قاعدة البيانات؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE53E3E)),
            onPressed: () async {
              try {
                await MedicineRepository.instance.deleteMedicine(
                  isOnlineMode: widget.isOnlineMode,
                  id: med['id'],
                );
                if (ctx.mounted && Navigator.canPop(ctx)) Navigator.pop(ctx);
                if (mounted) {
                  _loadMedicines();
                  _showSnackBar('تم حذف الدواء بنجاح من المخزن', Colors.red);
                }
              } catch (e) {
                if (!mounted) return;
                if (e is MedicineRepositoryException || e is MedicineApiException) {
                  _showSnackBar(e.toString(), Colors.red);
                  return;
                }
                final errorText = e.toString();
                if (errorText.contains('FOREIGN KEY constraint failed')) {
                  _showSnackBar(
                    'لا يمكن حذف هذا الدواء لأن له سجل مبيعات أو إتلاف سابق. يمكنك تصفير كميته بدلاً من حذفه.',
                    Colors.red,
                  );
                } else {
                  _showSnackBar('حدث خطأ أثناء الحذف: $e', Colors.red);
                }
              }
            },
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

@override
  Widget build(BuildContext context) {
    // دالة داخلية لتنسيق المبالغ المالية (إزالة الأصفار العشرية الزائدة وإضافة فواصل الآلاف)
    String formatAmount(dynamic value) {
      if (value == null) return '0';
      double numVal = double.tryParse(value.toString()) ?? 0;
      String str = numVal % 1 == 0
          ? numVal.toInt().toString()
          : numVal.toStringAsFixed(2);
      return str.replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (Match m) => '${m[1]},',
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text(
          'إدارة مخزن الأدوية',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        elevation: 6,
        shadowColor: const Color(0xFF0D9488).withValues(alpha: 0.35),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            bottom: Radius.circular(16),
          ),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(
              bottom: Radius.circular(16),
            ),
            gradient: LinearGradient(
              colors: [Color(0xFF0D9488), Color(0xFF16A085)],
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
            ),
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildWarehouseBar(),
            // شريط البحث والأزرار العلوية
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '🔍 ابحث عن دواء بالاسم أو الباركود...',
                      fillColor: Colors.white,
                      filled: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0xFF1ABC9C), width: 1.5),
                      ),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.search, color: Color(0xFF1ABC9C)),
                        onPressed: _loadMedicines,
                      ),
                    ),
                    onSubmitted: (_) => _loadMedicines(),
                  ),
                ),
                if (widget.isOwner) ...[
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1ABC9C),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                    onPressed: _openPurchaseListDialog,
                    icon: const Icon(Icons.playlist_add_rounded, color: Colors.white),
                    label: const Text('إضافة قائمة مذخر', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),

            // جدول البيانات الرئيسي
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF1ABC9C)))
                  : _medicines.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.inventory_2_outlined, size: 60, color: Colors.grey.shade400),
                              const SizedBox(height: 12),
                              Text(
                                'المخزن فارغ أو لا توجد نتائج للبحث.',
                                style: TextStyle(fontSize: 16, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        )
                      : Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade200),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return SingleChildScrollView(
                                scrollDirection: Axis.vertical,
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                                    child: DataTable(
                                      horizontalMargin: 18,
                                      columnSpacing: 24,
                                      headingRowHeight: 50,
                                      dataRowMinHeight: 68,
                                      dataRowMaxHeight: 78,
                                      headingRowColor: WidgetStateProperty.all(const Color(0xFF1ABC9C)),
                                      dividerThickness: 0.8,
                                      columns: [
                                        const DataColumn(label: Text('اسم الدواء', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
                                        const DataColumn(label: Text('الكمية', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
                                        // الكلفة وسعر الشراء للمالك فقط.
                                        if (widget.isOwner)
                                          const DataColumn(label: Text('الكلفة (متوسط)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
                                        const DataColumn(label: Text('سعر البيع', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
                                        const DataColumn(label: Text('الصلاحية', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
                                        const DataColumn(label: Text('الشكل الدوائي', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
                                        if (widget.isOwner)
                                          const DataColumn(label: Text('الإجراءات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
                                      ],
                                      rows: _medicines.map((med) {
                                        int qty = med['quantity'] ?? 0;
                                        bool isLowStock = qty <= kLowStockThreshold;
                                        String categoryLabel = medicineCategoryLabel(med['category']);

                                        String tradeName = med['trade_name'] ?? '';
                                        String scientificName = med['scientific_name'] ?? '';
                                        String barcode = med['barcode'] ?? '';

                                        final avgCost = med['avg_cost'] as num?;
                                        String buyPriceStr = avgCost == null ? '-' : '${formatAmount(avgCost)} د.ع';
                                        String sellPriceStr = formatAmount(med['sell_price']);

                                        return DataRow(
                                          cells: [
                                            // اسم الدواء والتفاصيل (النقر يعرض دفعات الصلاحية)
                                            DataCell(
                                              onTap: () => _showBatchesDialog(med),
                                              Padding(
                                                padding: const EdgeInsets.symmetric(vertical: 6.0),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Text(
                                                      tradeName,
                                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B)),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    if (scientificName.isNotEmpty) ...[
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        scientificName,
                                                        style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ],
                                                    if (barcode.isNotEmpty) ...[
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        '║ $barcode',
                                                        style: TextStyle(color: Colors.grey.shade500, fontSize: 11, fontFamily: 'monospace'),
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ),
                                            // شارة الكمية
                                            DataCell(
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                                decoration: BoxDecoration(
                                                  color: isLowStock ? const Color(0xFFFEF2F2) : const Color(0xFFF0FDF4),
                                                  borderRadius: BorderRadius.circular(20),
                                                  border: Border.all(
                                                    color: isLowStock ? const Color(0xFFFCA5A5) : const Color(0xFF86EFAC),
                                                  ),
                                                ),
                                                child: Text(
                                                  '$qty قطعة',
                                                  style: TextStyle(
                                                    color: isLowStock ? const Color(0xFFDC2626) : const Color(0xFF166534),
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            // متوسط الكلفة (المالك فقط)
                                            if (widget.isOwner)
                                              DataCell(
                                                Text(
                                                  buyPriceStr,
                                                  style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
                                                ),
                                              ),
                                            // سعر البيع
                                            DataCell(
                                              Text(
                                                '$sellPriceStr د.ع',
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1ABC9C)),
                                              ),
                                            ),
                                            // الصلاحية: أقرب دفعة؛ النقر يعرض كل الدفعات
                                            DataCell(
                                              onTap: () => _showBatchesDialog(med),
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(med['expiry_date'] ?? '-', style: const TextStyle(fontSize: 13)),
                                                  const SizedBox(width: 4),
                                                  Icon(Icons.layers_outlined, size: 14, color: Colors.grey.shade500),
                                                ],
                                              ),
                                            ),
                                            // الشكل الدوائي
                                            DataCell(Text(categoryLabel, style: const TextStyle(fontSize: 13))),
                                            // أزرار الإجراءات التفاعلية
                                            if (widget.isOwner)
                                              DataCell(
                                                Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Tooltip(
                                                      message: 'تعديل',
                                                      child: InkWell(
                                                        onTap: () => _openEditDialog(med),
                                                        borderRadius: BorderRadius.circular(8),
                                                        child: Container(
                                                          padding: const EdgeInsets.all(6),
                                                          decoration: BoxDecoration(
                                                            color: const Color(0xFFEFF6FF),
                                                            borderRadius: BorderRadius.circular(8),
                                                          ),
                                                          child: const Icon(Icons.edit_outlined, color: Color(0xFF2563EB), size: 18),
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Tooltip(
                                                      message: 'إتلاف',
                                                      child: InkWell(
                                                        onTap: () => _openDamageDialog(med),
                                                        borderRadius: BorderRadius.circular(8),
                                                        child: Container(
                                                          padding: const EdgeInsets.all(6),
                                                          decoration: BoxDecoration(
                                                            color: const Color(0xFFFFFBEB),
                                                            borderRadius: BorderRadius.circular(8),
                                                          ),
                                                          child: const Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 18),
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Tooltip(
                                                      message: 'حذف نهائي',
                                                      child: InkWell(
                                                        onTap: () => _confirmDeleteMedicine(med),
                                                        borderRadius: BorderRadius.circular(8),
                                                        child: Container(
                                                          padding: const EdgeInsets.all(6),
                                                          decoration: BoxDecoration(
                                                            color: const Color(0xFFFEF2F2),
                                                            borderRadius: BorderRadius.circular(8),
                                                          ),
                                                          child: const Icon(Icons.delete_outline, color: Color(0xFFDC2626), size: 18),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                          ],
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
