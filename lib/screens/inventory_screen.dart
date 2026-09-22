import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../database/db_helper.dart';
import '../repository/medicine_repository.dart';
import '../services/medicine_api_service.dart';
import 'package:sqflite/sqflite.dart';

class InventoryScreen extends StatefulWidget {
  final int pharmacyId;
  final bool isOwner;
  final bool isOnlineMode;

  const InventoryScreen({
    super.key,
    required this.pharmacyId,
    this.isOwner = true,
    this.isOnlineMode = false,
  });

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _medicines = [];
  List<Map<String, dynamic>> _masterMedicines = []; // القاموس المحمل من iraqi_drugs.json
  bool _isLoading = false;

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
    _loadMedicines();
    _loadMasterMedicinesFromJson(); // تحميل الأدوية من الملف عند فتح الشاشة
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
    if (error is MedicineRepositoryException || error is MedicineApiException) {
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

      setState(() {
        _medicines = data;
      });
    } catch (e) {
      _showSnackBar(_friendlyWriteErrorMessage(e), Colors.red);
    } finally {
      setState(() => _isLoading = false);
    }
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
                          return _masterMedicines.where((med) {
                            final trade = (med['trade_name'] ?? '').toString().toLowerCase();
                            final scientific = (med['scientific_name'] ?? '').toString().toLowerCase();
                            return trade.contains(query) || scientific.contains(query);
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

                  // 3. حقل تاريخ الانتهاء الجديد
                  TextField(
                    controller: newExpiryCtrl,
                    readOnly: true,
                    decoration: buildInputDecoration(
                      labelText: 'تاريخ الانتهاء الجديد (اختياري)',
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

                try {
                  await MedicineRepository.instance.supplyMedicine(
                    pharmacyId: widget.pharmacyId,
                    isOnlineMode: widget.isOnlineMode,
                    medicineId: selectedMedicine!['id'],
                    addedQuantity: qtyToAdd,
                    newExpiryDate: newExpiryCtrl.text.trim().isEmpty ? null : newExpiryCtrl.text.trim(),
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
                        Expanded(child: TextField(controller: buyPriceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'سعر الشراء *'))),
                        const SizedBox(width: 10),
                        Expanded(child: TextField(controller: sellPriceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'سعر البيع *'))),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: expiryCtrl,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: 'تاريخ الانتهاء *',
                        hintText: 'انقر لاختيار التاريخ',
                        prefixIcon: const Icon(Icons.calendar_month_outlined, color: Color(0xFF3182CE)),
                        border: const OutlineInputBorder(),
                      ),
                      onTap: () async {
                        final DateTime now = DateTime.now();
                        final DateTime initial =
                            DateTime.tryParse(expiryCtrl.text.trim()) ?? now;

                        final DateTime? pickedDate = await showDatePicker(
                          context: context,
                          initialDate: initial,
                          firstDate: DateTime(now.year - 5),
                          lastDate: DateTime(2040, 12, 31),
                          builder: (context, child) {
                            return Theme(
                              data: Theme.of(context).copyWith(
                                colorScheme: const ColorScheme.light(
                                  primary: Color(0xFF3182CE),
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
                        'expiry_date': expiryCtrl.text.trim(),
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
                                        const DataColumn(label: Text('سعر الشراء', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFF1F5F9)))),
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

                                        String buyPriceStr = formatAmount(med['buy_price']);
                                        String sellPriceStr = formatAmount(med['sell_price']);

                                        return DataRow(
                                          cells: [
                                            // اسم الدواء والتفاصيل
                                            DataCell(
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
                                            // سعر الشراء
                                            DataCell(
                                              Text(
                                                '$buyPriceStr د.ع',
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
                                            // الصلاحية
                                            DataCell(Text(med['expiry_date'] ?? '-', style: const TextStyle(fontSize: 13))),
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