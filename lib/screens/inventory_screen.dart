import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../database/db_helper.dart';
import '../repository/medicine_repository.dart';
import '../repository/warehouse_repository.dart';
import '../services/medicine_api_service.dart';
import '../services/warehouse_api_service.dart';
import '../models/subscription_plan.dart';
import '../utils/formatters.dart';
import 'package:sqflite/sqflite.dart';

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

  final Map<String, String> _categories = {
    'tablet': 'حبوب / كبسول',
    'injection': 'حقن / فيال / أمبول',
    'syrup': 'شراب / معلق',
    'cream_ointment_gel': 'مرهم / كريم / جل',
    'drops_eye_ear': 'قطرات عين / أذن',
    'suppository': 'تحاميل / لبوس',
    'drops_oral': 'قطرات فموية',
    'powder_sachet': 'بودرة / فوار',
    'inhaler_nebulizer': 'استنشاق / نيبولايزر',
    'drops_nasal': 'قطرات / بخاخ الأنف',
    'oral_care': 'مستحضرات فموية / عناية بالفم',
    'topical_solution': 'محاليل / غسولات موضعية',
  };

  final Map<String, String> _damageReasons = {
    'broken': 'كسر وضرر',
    'spoiled': 'سوء خزن',
    'withdrawn': 'سحب وزاري',
    'correction': 'تصحيح إدخال (خطأ كمية)',
    'other': 'أسباب أخرى',
  };

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

  // تحويل رسائل خطأ قاعدة البيانات الخام (طويلة وتقنية) إلى سبب مباشر
  // ومفهوم للصيدلي، بدل عرض نص الاستثناء الكامل بالـ SnackBar
  String _friendlyDbErrorMessage(Object error) {
    final text = error.toString();

    if (text.contains('UNIQUE constraint failed') && text.contains('barcode')) {
      return 'هذا الباركود مستخدم مسبقاً لدواء آخر بالمخزن. تحقق من الرقم أو اتركه فارغاً.';
    }
    if (text.contains('NOT NULL constraint failed')) {
      return 'يوجد حقل إلزامي فارغ، يرجى تعبئة كل الحقول المطلوبة (*).';
    }
    if (text.contains('CHECK constraint failed')) {
      return 'إحدى القيم المُدخَلة غير صحيحة (مثل كمية أو سعر سالب).';
    }
    if (text.contains('FOREIGN KEY constraint failed')) {
      return 'لا يمكن تنفيذ هذا الإجراء لوجود بيانات أخرى مرتبطة بهذا الدواء.';
    }

    return 'حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.';
  }

  // رسائل MedicineRepositoryException/MedicineApiException جاهزة بالعربية
  // أصلاً من مصدرها (انظر medicine_repository.dart وmedicine_api_service.dart)
  // فتُعرض كما هي، بعكس أخطاء sqflite الخام التي تحتاج _friendlyDbErrorMessage.
  String _friendlyWriteErrorMessage(Object error) {
    if (error is MedicineRepositoryException ||
        error is MedicineApiException ||
        error is WarehouseRepositoryException ||
        error is WarehouseApiException) {
      return error.toString();
    }
    return _friendlyDbErrorMessage(error);
  }

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
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: const [
            Icon(Icons.lock_outline, color: Color(0xFFD97706)),
            SizedBox(width: 10),
            Text('ميزة الباقة الذهبية'),
          ],
        ),
        content: Text(
          'خطتك الحالية لا تسمح بـ "$featureLabel".\n\n'
          'قم بالترقية إلى الباقة الذهبية لتفعيل هذه الميزة.',
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD97706)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('حسناً', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
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
// --- 1. إضافة صنف جديد (تصميم احترافي معدل) ---
void _openAddMedicineDialog() {
    final barcodeCtrl = TextEditingController();
    final tradeCtrl = TextEditingController();
    final scientificCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '0');
    final buyPriceCtrl = TextEditingController(text: '0');
    final sellPriceCtrl = TextEditingController(text: '0');
    final expiryCtrl = TextEditingController();
    final shelfCtrl = TextEditingController();
    String selectedCategory = 'tablet';

    InputDecoration buildInputDecoration({
      String? hintText,
      required IconData prefixIcon,
    }) {
      return InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
        prefixIcon: Icon(prefixIcon, color: const Color(0xFF1ABC9C), size: 20),
        filled: true,
        fillColor: const Color(0xFFF8FAFA),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF1ABC9C), width: 1.5),
        ),
      );
    }

    // تسمية أنيقة فوق الحقل بدل الـ label العائم الذي كان يتقاطع مع
    // إطار الحقل (المشكلة الظاهرة في لقطة الشاشة). النجمة الحمراء
    // تظهر تلقائياً فقط للحقول الإلزامية المنتهية بعلامة *.
    Widget buildFieldLabel(String text) {
      final isRequired = text.trim().endsWith('*');
      final baseLabel = isRequired ? text.replaceAll('*', '').trim() : text;
      return Padding(
        padding: const EdgeInsets.only(bottom: 7, right: 2),
        child: RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
            children: [
              TextSpan(text: baseLabel),
              if (isRequired)
                const TextSpan(text: ' *', style: TextStyle(color: Color(0xFFDC2626))),
            ],
          ),
        ),
      );
    }

    Widget buildLabeledField({required String label, required Widget field}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          buildFieldLabel(label),
          field,
        ],
      );
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Container(
              padding: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
              ),
              child: const Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Color(0xFFE6F7F5),
                    child: Icon(Icons.add_box_rounded, color: Color(0xFF1ABC9C)),
                  ),
                  SizedBox(width: 12),
                  Text('إضافة صنف جديد للمخزن', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            content: SingleChildScrollView(
              child: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 6),

                    // 1. الباركود
                    buildLabeledField(
                      label: 'الباركود (اختياري)',
                      field: TextField(
                        controller: barcodeCtrl,
                        decoration: buildInputDecoration(
                          hintText: 'امسح أو اكتب الباركود...',
                          prefixIcon: Icons.qr_code_scanner,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 2. الاسم التجاري
                    buildLabeledField(
                      label: 'الاسم التجاري *',
                      field: Autocomplete<Map<String, dynamic>>(
                        displayStringForOption: (option) => option['trade_name'] ?? '',
                        optionsBuilder: (TextEditingValue textEditingValue) {
                          if (textEditingValue.text.trim().isEmpty) {
                            return const Iterable<Map<String, dynamic>>.empty();
                          }
                          final query = textEditingValue.text.trim().toLowerCase();
                          // الاقتراحات حسب الاسم التجاري فقط؛ تطابق الاسم العلمي وحده لا يُظهر الدواء.
                          return _masterMedicines.where((med) {
                            final trade = (med['trade_name'] ?? '').toString().toLowerCase();
                            return trade.contains(query);
                          });
                        },
                        onSelected: (Map<String, dynamic> selection) {
                          setDialogState(() {
                            tradeCtrl.text = selection['trade_name'] ?? '';
                            scientificCtrl.text = selection['scientific_name'] ?? '';
                            if (selection['category'] != null && _categories.containsKey(selection['category'])) {
                              selectedCategory = selection['category'];
                            }
                          });
                        },
                        fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
                          return TextField(
                            controller: textController,
                            focusNode: focusNode,
                            decoration: buildInputDecoration(
                              hintText: 'ابحث في القاموس أو اكتب الاسم...',
                              prefixIcon: Icons.medication_outlined,
                            ),
                            onChanged: (val) {
                              tradeCtrl.text = val; // مزامنة النص مع الكنترولر
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 3. الاسم العلمي
                    buildLabeledField(
                      label: 'الاسم العلمي',
                      field: TextField(
                        controller: scientificCtrl,
                        decoration: buildInputDecoration(
                          hintText: 'المادة الفعالة...',
                          prefixIcon: Icons.science_outlined,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 4. الشكل الدوائي
                    buildLabeledField(
                      label: 'الشكل الدوائي',
                      field: DropdownButtonFormField<String>(
                        key: ValueKey(selectedCategory),
                        initialValue: selectedCategory,
                        decoration: buildInputDecoration(
                          prefixIcon: Icons.category_outlined,
                        ),
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        items: _categories.entries
                            .map((e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value)))
                            .toList(),
                        onChanged: (val) => setDialogState(() => selectedCategory = val!),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 5. الكمية والرف
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: buildLabeledField(
                            label: 'الكمية الأولية *',
                            field: TextField(
                              controller: qtyCtrl,
                              keyboardType: TextInputType.number,
                              decoration: buildInputDecoration(
                                prefixIcon: Icons.inventory_2_outlined,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: buildLabeledField(
                            label: 'موقع الرف',
                            field: TextField(
                              controller: shelfCtrl,
                              decoration: buildInputDecoration(
                                hintText: 'مثال: A12',
                                prefixIcon: Icons.grid_view_outlined,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // 6. الأسعار
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: buildLabeledField(
                            label: 'سعر الشراء *',
                            field: TextField(
                              controller: buyPriceCtrl,
                              keyboardType: TextInputType.number,
                              decoration: buildInputDecoration(
                                prefixIcon: Icons.attach_money,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: buildLabeledField(
                            label: 'سعر البيع *',
                            field: TextField(
                              controller: sellPriceCtrl,
                              keyboardType: TextInputType.number,
                              decoration: buildInputDecoration(
                                prefixIcon: Icons.sell_outlined,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // 7. تاريخ الانتهاء
                    buildLabeledField(
                      label: 'تاريخ الانتهاء *',
                      field: TextField(
                        controller: expiryCtrl,
                        readOnly: true,
                        decoration: buildInputDecoration(
                          hintText: 'انقر لاختيار التاريخ',
                          prefixIcon: Icons.calendar_month_outlined,
                        ),
                        onTap: () async {
                          final DateTime now = DateTime.now();
                          final DateTime? pickedDate = await showDatePicker(
                            context: context,
                            initialDate: now,
                            firstDate: now,
                            lastDate: DateTime(2040, 12, 31),
                            builder: (context, child) {
                              return Theme(
                                data: Theme.of(context).copyWith(
                                  colorScheme: const ColorScheme.light(
                                    primary: Color(0xFF1ABC9C),
                                    onPrimary: Colors.white,
                                    onSurface: Colors.black,
                                  ),
                                ),
                                child: child!,
                              );
                            },
                          );

                          if (pickedDate != null) {
                            final String formattedDate =
                                "${pickedDate.year}-${pickedDate.month.toString().padLeft(2, '0')}-${pickedDate.day.toString().padLeft(2, '0')}";
                            setDialogState(() {
                              expiryCtrl.text = formattedDate;
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            actions: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.grey.shade400),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء', style: TextStyle(color: Colors.black87)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1ABC9C),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                  elevation: 0,
                ),
                onPressed: () async {
                  final tradeName = tradeCtrl.text.trim();
                  final expiryDate = expiryCtrl.text.trim();

                  // التحقق من الحقول المطلوبة
                  if (tradeName.isEmpty) {
                    _showSnackBar('يرجى إدخال الاسم التجاري', Colors.red);
                    return;
                  }
                  if (expiryDate.isEmpty) {
                    _showSnackBar('يرجى تحديد تاريخ الانتهاء', Colors.red);
                    return;
                  }

                  try {
                    final db = await DatabaseHelper.instance.database;
                    await db.insert('pharmacy_branch',
                    {
                      'id': widget.pharmacyId, 'name': 'الفرع الرئيسي', 'is_active': 1, 'created_at': DateTime.now().toIso8601String(),
                    },
                    conflictAlgorithm: ConflictAlgorithm.ignore);

                    // محاولة الحفظ (أونلاين عبر السيرفر، أوفلاين محلياً)
                    await MedicineRepository.instance.addMedicine(
                      pharmacyId: widget.pharmacyId,
                      isOnlineMode: widget.isOnlineMode,
                      data: {
                        'barcode': barcodeCtrl.text.trim().isEmpty ? null : barcodeCtrl.text.trim(),
                        'trade_name': tradeName,
                        'scientific_name': scientificCtrl.text.trim(),
                        'category': selectedCategory,
                        'quantity': int.tryParse(qtyCtrl.text) ?? 0,
                        'buy_price': double.tryParse(buyPriceCtrl.text) ?? 0.0,
                        'sell_price': double.tryParse(sellPriceCtrl.text) ?? 0.0,
                        'expiry_date': expiryDate,
                        'shelf_location': shelfCtrl.text.trim(),
                        // يُدخل دائماً في المخزن المختار حالياً (أو الرئيسي
                        // كاحتياط إن لم يُحمَّل شريط المخازن بعد). أونلاين
                        // يُرسَل للخادم كحقل "warehouse" (MedicineRepository).
                        'warehouse_id': _selectedWarehouseId ??
                            await WarehouseRepository.instance.getMainWarehouseId(
                              pharmacyId: widget.pharmacyId,
                              isOnlineMode: widget.isOnlineMode,
                            ),
                      },
                    );

                    // إغلاق النافذة أولاً
                    if (Navigator.canPop(ctx)) {
                      Navigator.pop(ctx);
                    }

                    // مسح شريط البحث وإعادة تحميل القائمة
                    if (mounted) {
                      _searchController.clear();
                      await _loadMedicines();
                      _showSnackBar('تم إضافة الصنف بنجاح', Colors.green);
                    }
                  } catch (e) {
                    // رسالة واضحة تشرح السبب المباشر بدل نص الخطأ التقني الخام
                    if (!mounted) return;
                    _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
                  }
                },
                child: const Text('حفظ الصنف', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }
  // --- 2. تزويد شحنة (مقتصرة على أدوية المخزن المسجلة فقط) ---
void _openSupplyDialog() {
  final addQtyCtrl = TextEditingController();
  final newExpiryCtrl = TextEditingController();
  // سعر الشراء (للمالك فقط) وسعر البيع الموحّد الجديد، يُعبَّآن بقيم الصنف الحالية.
  final purchasePriceCtrl = TextEditingController();
  final salePriceCtrl = TextEditingController();
  final showPurchasePrice = widget.isOwner;
  Map<String, dynamic>? selectedMedicine;

  // أسلوب تصميم موحد ومستقل للحقول (متناسق مع الهوية البرتقالية للتزويد)
  InputDecoration buildInputDecoration({
    required String labelText,
    String? hintText,
    required IconData prefixIcon,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: Icon(prefixIcon, color: const Color(0xFFE67E22), size: 20),
      filled: true,
      fillColor: Colors.grey.shade50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFE67E22), width: 1.5),
      ),
    );
  }

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Container(
            padding: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: const Row(
              children: [
                CircleAvatar(
                  backgroundColor: Color(0xFFFDF2E9),
                  child: Icon(Icons.inventory_2_rounded, color: Color(0xFFE67E22)),
                ),
                SizedBox(width: 12),
                Text('تزويد شحنة جديدة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("اختر الدواء من المخزن الحالي:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),

                  // 1. حقل البحث الإكمال التلقائي
                  Autocomplete<Map<String, dynamic>>(
                    displayStringForOption: (option) =>
                        '${option['trade_name']} ${option['barcode'] != null ? "(${option['barcode']})" : ""}',
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      final query = textEditingValue.text.trim().toLowerCase();
                      if (query.isEmpty) {
                        return const Iterable<Map<String, dynamic>>.empty();
                      }
                      return _medicines.where((m) {
                        final trade = (m['trade_name'] ?? '').toString().toLowerCase();
                        final barcode = (m['barcode'] ?? '').toString().toLowerCase();
                        return trade.contains(query) || barcode.contains(query);
                      });
                    },
                    onSelected: (Map<String, dynamic> selection) {
                      setDialogState(() {
                        selectedMedicine = selection;
                        final avgCost = (selection['avg_cost'] as num?)?.toDouble();
                        purchasePriceCtrl.text = avgCost == null ? '' : _formatPriceInput(avgCost);
                        final sellPrice = (selection['sell_price'] as num?)?.toDouble() ?? 0;
                        salePriceCtrl.text = sellPrice > 0 ? _formatPriceInput(sellPrice) : '';
                      });
                    },
                    fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                      return TextField(
                        controller: textEditingController,
                        focusNode: focusNode,
                        decoration: buildInputDecoration(
                          labelText: 'البحث عن دواء *',
                          hintText: 'ابحث باسم الدواء أو الباركود...',
                          prefixIcon: Icons.search,
                        ),
                      );
                    },
                  ),

                  // بطاقة تأكيد تحديد الدواء
                  if (selectedMedicine != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFCD34D)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle, color: Color(0xFFD97706), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'تم تحديد: ${selectedMedicine!['trade_name']} (المتاح حالياً: ${selectedMedicine!['quantity']})',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF92400E)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),

                  // 2. حقل الكمية المضافة
                  TextField(
                    controller: addQtyCtrl,
                    keyboardType: TextInputType.number,
                    decoration: buildInputDecoration(
                      labelText: 'الكمية المضافة *',
                      hintText: 'أدخل العدد المضاف...',
                      prefixIcon: Icons.add_box_outlined,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 3. سعر الشراء (المالك فقط) وسعر البيع
                  if (showPurchasePrice) ...[
                    TextField(
                      controller: purchasePriceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setDialogState(() {}),
                      decoration: buildInputDecoration(
                        labelText: selectedMedicine != null && selectedMedicine!['avg_cost'] == null
                            ? 'سعر الشراء للوحدة * (مطلوب: كلفة الصنف غير معروفة)'
                            : 'سعر الشراء للوحدة *',
                        hintText: 'كلفة الوحدة في هذه الشحنة',
                        prefixIcon: Icons.shopping_cart_outlined,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: salePriceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setDialogState(() {}),
                    decoration: buildInputDecoration(
                      labelText: 'سعر البيع للوحدة *',
                      hintText: 'يُطبَّق على كل المخزون للمبيعات القادمة',
                      prefixIcon: Icons.sell_outlined,
                    ),
                  ),
                  // تحذير غير مانع: البيع بأقل من سعر الشراء.
                  if (showPurchasePrice &&
                      (double.tryParse(salePriceCtrl.text.trim()) ?? 0) > 0 &&
                      (double.tryParse(salePriceCtrl.text.trim()) ?? 0) <
                          (double.tryParse(purchasePriceCtrl.text.trim()) ?? 0)) ...[
                    const SizedBox(height: 6),
                    const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 16),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'تنبيه: سعر البيع أقل من سعر الشراء.',
                            style: TextStyle(fontSize: 12, color: Color(0xFF92400E), fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),

                  // 4. تاريخ انتهاء هذه الشحنة (دفعة صلاحية مستقلة)
                  TextField(
                    controller: newExpiryCtrl,
                    readOnly: true,
                    decoration: buildInputDecoration(
                      labelText: 'تاريخ انتهاء هذه الشحنة (اختياري)',
                      hintText: 'انقر لاختيار التاريخ',
                      prefixIcon: Icons.calendar_month_outlined,
                    ),
                    onTap: () async {
                      final DateTime now = DateTime.now();
                      final DateTime today = DateTime(now.year, now.month, now.day);

                      final DateTime? pickedDate = await showDatePicker(
                        context: context,
                        initialDate: today,
                        firstDate: today,
                        lastDate: DateTime(2040, 12, 31),
                        builder: (context, child) {
                          return Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: const ColorScheme.light(
                                primary: Color(0xFFE67E22),
                                onPrimary: Colors.white,
                                onSurface: Colors.black,
                              ),
                            ),
                            child: child!,
                          );
                        },
                      );

                      if (pickedDate != null) {
                        final String formattedDate =
                            "${pickedDate.year}-${pickedDate.month.toString().padLeft(2, '0')}-${pickedDate.day.toString().padLeft(2, '0')}";
                        newExpiryCtrl.text = formattedDate;
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          actions: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.grey.shade400),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء', style: TextStyle(color: Colors.black87)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE67E22),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                elevation: 0,
              ),
              onPressed: () async {
                final qtyToAdd = int.tryParse(addQtyCtrl.text) ?? 0;

                if (selectedMedicine == null) {
                  _showSnackBar('يرجى اختيار دواء مسجل في المخزن أولاً', Colors.red);
                  return;
                }

                if (qtyToAdd <= 0) {
                  _showSnackBar('يرجى إدخال كمية صحيحة', Colors.red);
                  return;
                }

                // غير المالك لا يرى سعر الشراء: يُستخدم avg_cost الحالي تلقائياً (null).
                double? purchasePrice;
                if (showPurchasePrice) {
                  purchasePrice = double.tryParse(purchasePriceCtrl.text.trim());
                  if (purchasePrice == null || purchasePrice <= 0) {
                    _showSnackBar('يرجى إدخال سعر شراء أكبر من صفر', Colors.red);
                    return;
                  }
                }
                final salePrice = double.tryParse(salePriceCtrl.text.trim());
                if (salePrice == null || salePrice <= 0) {
                  _showSnackBar('يرجى إدخال سعر بيع أكبر من صفر', Colors.red);
                  return;
                }

                try {
                  await MedicineRepository.instance.supplyMedicine(
                    pharmacyId: widget.pharmacyId,
                    isOnlineMode: widget.isOnlineMode,
                    medicineId: selectedMedicine!['id'],
                    addedQuantity: qtyToAdd,
                    newExpiryDate: newExpiryCtrl.text.trim().isEmpty ? null : newExpiryCtrl.text.trim(),
                    purchasePrice: purchasePrice,
                    salePrice: salePrice,
                  );

                  if (Navigator.canPop(ctx)) Navigator.pop(ctx);
                  if (mounted) {
                    _loadMedicines();
                    _showSnackBar('تم إضافة الشحنة بنجاح', Colors.green);
                  }
                } catch (e) {
                  if (!mounted) return;
                  _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
                }
              },
              child: const Text('إضافة الشحنة', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    ),
  );
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
          width: 420,
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
                          subtitle: widget.isOwner && price != null
                              ? Text('سعر الشراء: ${AppFormatter.iqdWithCurrency(price)}', style: const TextStyle(fontSize: 12))
                              : null,
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

  /// قيمة سعر لحقل إدخال: بلا كسور زائدة (666.6667، 1250).
  String _formatPriceInput(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

// --- 3. تعديل بيانات الدواء ---
  void _openEditDialog(Map<String, dynamic> med) {
    final barcodeCtrl = TextEditingController(text: med['barcode'] ?? '');
    final tradeCtrl = TextEditingController(text: med['trade_name']);
    final scientificCtrl = TextEditingController(text: med['scientific_name'] ?? '');
    final buyPriceCtrl = TextEditingController(text: med['buy_price'].toString());
    final sellPriceCtrl = TextEditingController(text: med['sell_price'].toString());
    final expiryCtrl = TextEditingController(text: med['expiry_date'] ?? '');
    final shelfCtrl = TextEditingController(text: med['shelf_location'] ?? '');
    String selectedCategory = med['category'] ?? '';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.edit_note, color: Color(0xFF3182CE)),
                SizedBox(width: 8),
                Text('تعديل بيانات الدواء', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SingleChildScrollView(
              child: SizedBox(
                width: 450,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // --- بيانات الهوية ---
                    TextField(controller: tradeCtrl, decoration: const InputDecoration(labelText: 'الاسم التجاري *')),
                    const SizedBox(height: 10),
                    TextField(controller: scientificCtrl, decoration: const InputDecoration(labelText: 'الاسم العلمي')),
                    const SizedBox(height: 10),
                    TextField(controller: barcodeCtrl, decoration: const InputDecoration(labelText: 'الباركود')),

                    const SizedBox(height: 18),
                    Divider(color: Colors.grey.shade300),
                    const SizedBox(height: 8),

                    // --- التصنيف والموقع ---
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _categories.containsKey(selectedCategory) ? selectedCategory : _categories.keys.first,
                            decoration: const InputDecoration(labelText: 'الشكل الدوائي'),
                            items: _categories.entries.map((e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value))).toList(),
                            onChanged: (val) => setDialogState(() => selectedCategory = val!),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: TextField(controller: shelfCtrl, decoration: const InputDecoration(labelText: 'موقع الرف'))),
                      ],
                    ),

                    const SizedBox(height: 18),
                    Divider(color: Colors.grey.shade300),
                    const SizedBox(height: 8),

                    // --- التسعير والصلاحية ---
                    Row(
                      children: [
                        Expanded(child: TextField(controller: buyPriceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'آخر سعر شراء *'))),
                        const SizedBox(width: 10),
                        Expanded(child: TextField(controller: sellPriceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'سعر البيع *'))),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // الصلاحية تُدار لكل شحنة (دفعة) عبر "تزويد شحنة"؛ هنا أقربها للعرض فقط.
                    TextField(
                      controller: expiryCtrl,
                      readOnly: true,
                      enabled: false,
                      decoration: const InputDecoration(
                        labelText: 'أقرب تاريخ انتهاء (حسب الشحنات)',
                        prefixIcon: Icon(Icons.calendar_month_outlined, color: Color(0xFF3182CE)),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3182CE)),
                onPressed: () async {
                  try {
                    await MedicineRepository.instance.updateMedicine(
                      pharmacyId: widget.pharmacyId,
                      isOnlineMode: widget.isOnlineMode,
                      id: med['id'],
                      data: {
                        'barcode': barcodeCtrl.text.trim().isEmpty ? null : barcodeCtrl.text.trim(),
                        'trade_name': tradeCtrl.text.trim(),
                        'scientific_name': scientificCtrl.text.trim(),
                        'category': selectedCategory,
                        'buy_price': double.tryParse(buyPriceCtrl.text) ?? 0.0,
                        'sell_price': double.tryParse(sellPriceCtrl.text) ?? 0.0,
                        'shelf_location': shelfCtrl.text.trim(),
                      },
                    );
                    if (Navigator.canPop(ctx)) Navigator.pop(ctx);
                    if (mounted) {
                      _loadMedicines();
                      _showSnackBar('تم حفظ التعديلات بنجاح', Colors.green);
                    }
                  } catch (e) {
                    if (!mounted) return;
                    _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
                  }
                },
                child: const Text('حفظ التعديلات', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  // --- 4. الإتلاف الجزئي ---
  void _openDamageDialog(Map<String, dynamic> med) {
    int currentQty = med['quantity'];
    final damageQtyCtrl = TextEditingController(text: currentQty.toString());
    final notesCtrl = TextEditingController();
    String selectedReason = 'broken';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Color(0xFFE53E3E)),
                SizedBox(width: 8),
                Text('نقل لقائمة التوالف', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE53E3E))),
              ],
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('الدواء المستهدف: ${med['trade_name']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 6),
                  Text('الكمية المتوفرة حالياً: $currentQty قطعة', style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: damageQtyCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'الكمية المراد إتلافها *'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedReason,
                    decoration: const InputDecoration(labelText: 'سبب الإتلاف *'),
                    items: _damageReasons.entries.map((e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value))).toList(),
                    onChanged: (val) => setDialogState(() => selectedReason = val!),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'ملاحظات إضافية (اختياري)'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE53E3E)),
                onPressed: () async {
                  int qtyToDamage = int.tryParse(damageQtyCtrl.text) ?? 0;
                  if (qtyToDamage <= 0 || qtyToDamage > currentQty) {
                    _showSnackBar('يرجى إدخال كمية صحيحة لا تتجاوز المتاح ($currentQty)', Colors.red);
                    return;
                  }

                  try {
                    await MedicineRepository.instance.damageMedicine(
                      pharmacyId: widget.pharmacyId,
                      isOnlineMode: widget.isOnlineMode,
                      medicineId: med['id'],
                      quantityToDamage: qtyToDamage,
                      reason: selectedReason,
                      notes: notesCtrl.text.trim(),
                    );
                    if (Navigator.canPop(ctx)) Navigator.pop(ctx);
                    if (mounted) {
                      _loadMedicines();
                      _showSnackBar('تم نقل الكمية بنجاح إلى جدول التوالف', Colors.orange);
                    }
                  } catch (e) {
                    if (!mounted) return;
                    _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
                  }
                },
                child: const Text('تأكيد الإتلاف', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
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
                if (Navigator.canPop(ctx)) Navigator.pop(ctx);
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
                    onPressed: _openAddMedicineDialog,
                    icon: const Icon(Icons.add, color: Colors.white),
                    label: const Text('صنف جديد', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE67E22),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                    onPressed: _openSupplyDialog,
                    icon: const Icon(Icons.inventory, color: Colors.white),
                    label: const Text('تزويد شحنة', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                                        const DataColumn(label: Text('الرف', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
                                        if (widget.isOwner)
                                          const DataColumn(label: Text('الإجراءات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
                                      ],
                                      rows: _medicines.map((med) {
                                        int qty = med['quantity'] ?? 0;
                                        bool isLowStock = qty <= 5;
                                        String categoryLabel = _categories[med['category']] ?? med['category'] ?? 'غير محدد';

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
                                            // الرف
                                            DataCell(
                                              Text(
                                                (med['shelf_location'] != null && med['shelf_location'].toString().trim().isNotEmpty)
                                                    ? med['shelf_location']
                                                    : '-',
                                                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                                              ),
                                            ),
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