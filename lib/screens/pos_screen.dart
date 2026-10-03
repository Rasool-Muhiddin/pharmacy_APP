import 'package:flutter/material.dart';
import 'package:pharmacy_app/utils/formatters.dart';
import '../database/db_helper.dart'; // تأكد من صحة مسار الملف لديك
import '../repository/invoice_repository.dart';
import '../repository/medicine_repository.dart';
import '../repository/warehouse_repository.dart';
import '../utils/invoice_discount.dart';
import '../widgets/unsaved_changes_guard.dart';

class PosScreen extends StatefulWidget {
  final int pharmacyId;
  final int userId; // رقم المستخدم الحالى (Cashier)
  final bool isOnlineMode; // من license.mode القادم من التفعيل/تسجيل الدخول

  const PosScreen({
    super.key,
    required this.pharmacyId,
    required this.userId,
    this.isOnlineMode = false, // قيمة افتراضية آمنة (أوفلاين)
  });

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _discountController = TextEditingController(text: '0');
  final FocusNode _searchFocusNode = FocusNode();

  List<Map<String, dynamic>> _availableMedicines = [];
  List<Map<String, dynamic>> _filteredSuggestions = [];
  final List<Map<String, dynamic>> _cartItems = [];
  List<Map<String, dynamic>> _recentInvoices = [];

  // خاصية الباقة الذهبية (تعدد المخازن): البيع دائماً من المخزن الرئيسي
  // فقط، بغض النظر عن أي مخزن ثانٍ قد تملكه الصيدلية. يُحمَّل مرة واحدة في
  // _loadInitialData ويُستخدم لكل من قائمة الأصناف والبحث بالباركود.
  int? _mainWarehouseId;

  String _discountType = InvoiceDiscount.amount; // مبلغ أو نسبة (%) — أعداد صحيحة فقط
  bool _showSuggestions = false;
  bool _isLoading = false;
  bool _isCheckingOut = false;
  String _searchPlaceholder = '🔍 مرر الباركود أو ابحث بالاسم التجاري/العلمي/الباركود...';

  // حارس المغادرة من MainLayout (الشريط الجانبي/تسجيل الخروج) أثناء فاتورة غير مكتملة.
  LeaveGuardController? _leaveGuard;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final guard = LeaveGuardScope.maybeOf(context);
    if (guard != _leaveGuard) {
      _leaveGuard?.detach(_confirmLeave);
      _leaveGuard = guard?..attach(_confirmLeave);
    }
  }

  @override
  void dispose() {
    _leaveGuard?.detach(_confirmLeave);
    _searchController.dispose();
    _discountController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// فاتورة جارية: صنف واحد على الأقل أو خصم مُدخل. بعد إتمام البيع تُفرَّغ
  /// السلة ويعود الخصم إلى 0 فلا يُسأل المستخدم.
  bool get _hasUnsavedInvoice =>
      _cartItems.isNotEmpty || (int.tryParse(_discountController.text.trim()) ?? 0) != 0;

  Future<bool?> _confirmLeave() async {
    if (!_hasUnsavedInvoice || !mounted) return null;
    return confirmDiscardChanges(
      context,
      message: 'الفاتورة غير مكتملة، هل تريد فعلاً الخروج؟',
      leaveLabel: 'خروج',
    );
  }

// تحميل أدوية الفرع وسجل الفواتير من قاعدة البيانات مباشرة
  Future<void> _loadInitialData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      // أونلاين: نحدّث كاش المخازن والمخزون من الخادم أولاً (إن توفر اتصال)
      // كي تعكس الشاشة الكميات الحالية من كل الأجهزة؛ الفشل لا يمنع البيع
      // من آخر كاش محفوظ (والخادم يتحقق من الكمية عند checkout أصلاً).
      if (widget.isOnlineMode) {
        try {
          await MedicineRepository.instance.getMedicines(
            pharmacyId: widget.pharmacyId,
            isOnlineMode: true,
          );
        } catch (_) {}
      }
      // ⚠️ المخزن الرئيسي فقط عمداً: البيع مقصور عليه ولو كانت الصيدلية على
      // الباقة الذهبية وتملك مخازن أخرى (الخادم يفرض نفس القاعدة).
      _mainWarehouseId = await WarehouseRepository.instance.getMainWarehouseId(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
      );
      final meds = await DatabaseHelper.instance.getMedicines(
        widget.pharmacyId,
        warehouseId: _mainWarehouseId,
      );
      final invoices = await InvoiceRepository.instance.getInvoices(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
      );
      if (!mounted) return;
      setState(() {
        // فلترة الأدوية: غير تالفة + لها كمية في دفعات غير منتهية الصلاحية
        // (sellable_quantity؛ البيع يخصم منها بترتيب FEFO).
        _availableMedicines = meds.where((m) {
          final isNotDamaged = (m['is_damaged'] ?? 0) == 0;
          return isNotDamaged && _sellableQty(m) > 0;
        }).toList();

        _recentInvoices = invoices;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ أثناء تحميل البيانات: $e')),
      );
    }
  }

  // --- الحسابات اللحظية للفاتورة ---
  double get _subtotal {
    return _cartItems.fold(0.0, (sum, item) => sum + (item['total_price'] as double));
  }

  // خصم الفاتورة: أعداد صحيحة فقط، النسبة ≤ 100 والمبلغ ≤ المجموع، والناتج
  // مقرَّب نصف-للأعلى لخانتين (نفس القيمة أوفلاين وأونلاين).
  double get _appliedDiscount => InvoiceDiscount.compute(
        subtotal: _subtotal,
        type: _discountType,
        input: _discountController.text,
      );

  double get _grandTotal {
    double total = _subtotal - _appliedDiscount;
    return total < 0 ? 0.0 : total;
  }

  // --- 1. البحث الحي ودعم الماسح الضوئي (Scanner) ---
  void _onSearchChanged(String query) {
    final cleanQuery = query.trim().toLowerCase();
    if (cleanQuery.isEmpty) {
      setState(() {
        _filteredSuggestions = [];
        _showSuggestions = false;
      });
      return;
    }

    final filtered = _availableMedicines.where((med) {
      final tradeName = (med['trade_name'] ?? '').toString().toLowerCase();
      final scientificName = (med['scientific_name'] ?? '').toString().toLowerCase();
      final barcode = (med['barcode'] ?? '').toString().toLowerCase();

      return tradeName.contains(cleanQuery) ||
          scientificName.contains(cleanQuery) ||
          barcode.contains(cleanQuery);
    }).toList();

    setState(() {
      _filteredSuggestions = filtered;
      _showSuggestions = true;
    });
  }

// استجابة لقراءة حزمة السكنر عند الضغط على Enter (مع فحص التلف والصلاحية)
  Future<void> _onScannerSubmit(String value) async {
    final query = value.trim();
    if (query.isEmpty) return;

    try {
      // نفس تقييد المخزن الرئيسي المطبّق في _loadInitialData، حتى لا يبيع
      // الماسح صنفاً موجوداً فقط في المخزن الثانوي.
      final warehouseId = _mainWarehouseId ??= await WarehouseRepository.instance.getMainWarehouseId(
        pharmacyId: widget.pharmacyId,
        isOnlineMode: widget.isOnlineMode,
      );
      final exactMatch = await DatabaseHelper.instance.getMedicineByBarcode(query, warehouseId: warehouseId);

      if (!mounted) return;

      // التحقق الشامل: الصيدلية + كمية صالحة (دفعات غير منتهية) + عدم التلف
      final isValid = exactMatch != null &&
          exactMatch['pharmacy_id'] == widget.pharmacyId &&
          _sellableQty(exactMatch) > 0 &&
          (exactMatch['is_damaged'] ?? 0) == 0;

      if (isValid) {
        _addMedicineToCart(exactMatch);
        _searchController.clear();
        setState(() => _showSuggestions = false);
        _searchFocusNode.requestFocus();
      } else {
        _searchController.clear();
        setState(() {
          _showSuggestions = false;
          _searchPlaceholder = '❌ هذا الدواء إما غير مسجل، نفذت كميته، تالف، أو منتهي الصلاحية!';
        });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() {
              _searchPlaceholder = '🔍 مرر الباركود أو ابحث بالاسم التجاري/العلمي/الباركود...';
            });
          }
        });
        _searchFocusNode.requestFocus();
      }
    } catch (e) {
      if (!mounted) return;
      _searchController.clear();
      setState(() => _showSuggestions = false);
      _showAlert('حدث خطأ أثناء قراءة الباركود: $e');
      _searchFocusNode.requestFocus();
    }
  }
  /// الكمية القابلة للبيع فعلاً: مجموع الدفعات غير المنتهية (sellable_quantity
  /// من DatabaseHelper)، مع الرجوع للكمية الكلية لصف لا يحملها.
  int _sellableQty(Map<String, dynamic> medicine) =>
      ((medicine['sellable_quantity'] ?? medicine['quantity'] ?? 0) as num).toInt();

  // --- 2. إضافة وتعديل عناصر السلة ---
  /// باركود الصنف يُحفظ في سطر السلة ليُعرض تحت اسمه في الفاتورة (سواء أُضيف
  /// بالماسح أو بالاسم) فيتأكد الصيدلي من الصنف المختار؛ لا يدخل في بيانات البيع.
  void _addMedicineToCart(Map<String, dynamic> medicine) {
    int maxQty = _sellableQty(medicine);
    int medId = medicine['id'];
    final barcode = (medicine['barcode'] ?? '').toString().trim();

    int existingIndex = _cartItems.indexWhere((item) => item['id'] == medId);

    if (existingIndex >= 0) {
      int currentQty = _cartItems[existingIndex]['selectedQty'];
      if (currentQty < maxQty) {
        setState(() {
          _cartItems[existingIndex]['selectedQty'] = currentQty + 1;
          _cartItems[existingIndex]['total_price'] = (currentQty + 1) * (_cartItems[existingIndex]['sell_price'] as double);
        });
      } else {
        _showAlert('⚠️ عذراً، لقد تجاوزت الكمية المتاحة بالمخزن لهذا الدواء!');
      }
    } else {
      setState(() {
        _cartItems.add({
          'id': medId,
          'trade_name': medicine['trade_name'],
          'sell_price': (medicine['sell_price'] as num).toDouble(),
          'maxQty': maxQty,
          'selectedQty': 1,
          'total_price': (medicine['sell_price'] as num).toDouble(),
          if (barcode.isNotEmpty) 'barcode': barcode,
        });
      });
    }

    _searchController.clear();
    setState(() => _showSuggestions = false);
    _searchFocusNode.requestFocus();
  }

  void _updateCartQty(int index, int newQty) {
    if (newQty <= 0) return;
    int maxQty = _cartItems[index]['maxQty'];

    if (newQty > maxQty) {
      _showAlert('⚠️ الحد الأقصى المتوفر بالمخزن هو $maxQty قطعة فقط!');
      newQty = maxQty;
    }

    setState(() {
      _cartItems[index]['selectedQty'] = newQty;
      _cartItems[index]['total_price'] = newQty * (_cartItems[index]['sell_price'] as double);
    });
  }

  void _removeCartItem(int index) {
    setState(() {
      _cartItems.removeAt(index);
    });
    _searchFocusNode.requestFocus();
  }

  // --- 3. إتمام البيع الحقيقي والتأثير بالمخزن (عبر completeSale) ---
  Future<void> _processCheckout() async {
    if (_cartItems.isEmpty) {
      _showAlert('⚠️ لا يمكن إتمام عملية البيع: الفاتورة فارغة!');
      return;
    }
    if (_isCheckingOut) return;          
    setState(() => _isCheckingOut = true);  

    try {
      // إعداد قائمة عناصر الفاتورة — نفس الشكل يُستخدم محلياً وأونلاين؛
      // InvoiceRepository يستخرج medicine_id/quantity منها عند الأونلاين
      // ويتجاهل الباقي (السعر والاسم يأتيان من السيرفر وقت البيع).
      final itemsData = _cartItems.map((item) {
        return {
          'trade_name': item['trade_name'],
          'medicine_id': item['id'],
          'quantity': item['selectedQty'],
          'unit_price': item['sell_price'],
          'total_price': item['total_price'],
        };
      }).toList();

      String invoiceNum;

      if (widget.isOnlineMode) {
        // أونلاين: رقم الفاتورة وسعر كل صنف يُحدَّدان من السيرفر دائماً،
        // لا نولّدهما أو نفترضهما محلياً هنا.
        final created = await InvoiceRepository.instance.checkout(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: true,
          invoice: {'discount': _appliedDiscount},
          items: itemsData,
        );
        invoiceNum = created['invoice_number'] as String;
      } else {
        // أ) توليد رقم الفاتورة المنسق محلياً
        invoiceNum = await DatabaseHelper.instance.generateInvoiceNumber();

        // ب) إعداد خريطة بيانات الفاتورة الرئيسية
        final invoiceData = {
          'pharmacy_id': widget.pharmacyId,
          'invoice_number': invoiceNum,
          'cashier_id': widget.userId,
          'total_amount': DatabaseHelper.roundMoney(_subtotal),
          'discount': _appliedDiscount,
          'final_amount': DatabaseHelper.roundMoney(_grandTotal),
          'created_at': DateTime.now().toIso8601String(),
          'is_refunded': 0,
        };

        // جـ) تنفيذ الشراء التكاملي عبر completeSale (نفس السلوك السابق
        // تماماً، فقط مُمرَّر الآن عبر InvoiceRepository)
        await InvoiceRepository.instance.checkout(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: false,
          invoice: invoiceData,
          items: itemsData,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ تم إتمام الفاتورة $invoiceNum بنجاح!'), backgroundColor: Colors.green),
        );
      }

      // و) إعادة ضبط الشاشة
      setState(() {
        _cartItems.clear();
        _discountController.text = '0';
        _discountType = InvoiceDiscount.amount;
      });

      _loadInitialData();
      _searchFocusNode.requestFocus();
    } catch (e) {
      _showAlert('حدث خطأ أثناء حفظ الفاتورة: $e');
      } finally {
        if (mounted) {
          setState(() => _isCheckingOut = false);
        }  
      }
  }

  // --- 4. إرجاع الفاتورة (عبر refundInvoice) ---
  Future<void> _confirmRefund(Map<String, dynamic> invoice) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إرجاع الفاتورة'),
        content: Text(
          'هل أنت متأكد من رغبتك في إرجاع الفاتورة رقم #${invoice['invoice_number']}؟\n\n'
          'الصافي المدفوع المسترجع للزبون: ${AppFormatter.iqdWithCurrency(invoice['final_amount'])}\n\n'
          'ستتم إعادة الأدوية فوراً للمخزن.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('موافق (إرجاع)', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await InvoiceRepository.instance.refund(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: widget.isOnlineMode,
          invoiceId: invoice['id'],
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('🔄 تم إرجاع الفاتورة وإعادة كمياتها للمخزن بنجاح'), backgroundColor: Colors.orange),
          );
        }
        _loadInitialData();
      } catch (e) {
        _showAlert('خطأ أثناء عملية الإرجاع: $e');
      }
    }
  }

  void _showAlert(String msg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تنبيه'),
        content: Text(msg),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('حسناً'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'شاشة البيع المباشر pos',
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ==========================================
                  // 1️⃣ القسم الأول: الفاتورة النشطة والبحث
                  // ==========================================
                  Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Color(0xFF1ABC9C), width: 2),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '🛒 نقطة البيع الحالية',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50)),
                          ),
                          const Divider(),
                          const SizedBox(height: 10),

                          // 🔍 حقل البحث التفاعلي والسكنر
                          Stack(
                            children: [
                              Column(
                                children: [
                                  TextField(
                                    controller: _searchController,
                                    focusNode: _searchFocusNode,
                                    autofocus: true,
                                    onChanged: _onSearchChanged,
                                    onSubmitted: _onScannerSubmit,
                                    decoration: InputDecoration(
                                      hintText: _searchPlaceholder,
                                      prefixIcon: const Icon(Icons.qr_code_scanner, color: Color(0xFF1ABC9C)),
                                      suffixIcon: _searchController.text.isNotEmpty
                                          ? IconButton(
                                              icon: const Icon(Icons.clear),
                                              onPressed: () {
                                                _searchController.clear();
                                                _onSearchChanged('');
                                              },
                                            )
                                          : null,
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(color: Color(0xFF1ABC9C), width: 2),
                                      ),
                                    ),
                                  ),
                                ],
                              ),

                              // قائمة المقترحات المنسدلة للبحث المباشر
                              if (_showSuggestions)
                                Container(
                                  margin: const EdgeInsets.only(top: 55),
                                  constraints: const BoxConstraints(maxHeight: 250),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
                                  ),
                                  child: _filteredSuggestions.isEmpty
                                      ? const ListTile(
                                          title: Text('❌ لا يتوفر هذا الصنف في المخزن!', style: TextStyle(color: Colors.red)),
                                        )
                                      : ListView.separated(
                                          shrinkWrap: true,
                                          itemCount: _filteredSuggestions.length,
                                          separatorBuilder: (_, __) => const Divider(height: 1),
                                          itemBuilder: (context, index) {
                                            final med = _filteredSuggestions[index];
                                            final int qty = _sellableQty(med);
                                            final bool isLowStock = qty <= 5;

                                            return ListTile(
                                              dense: true,
                                              title: Text(med['trade_name'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                                              subtitle: Text('${med['scientific_name'] ?? ''} ${med['barcode'] != null ? ' | ' + med['barcode'] : ''}'),
                                              trailing: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    AppFormatter.iqdWithCurrency(med['sell_price']),
                                                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                    decoration: BoxDecoration(
                                                      color: isLowStock ? Colors.red : Colors.grey,
                                                      borderRadius: BorderRadius.circular(4),
                                                    ),
                                                    child: Text(
                                                      isLowStock ? '⚠️ شحيح: $qty' : 'متوفر: $qty',
                                                      style: const TextStyle(color: Colors.white, fontSize: 11),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              onTap: () => _addMedicineToCart(med),
                                            );
                                          },
                                        ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 15),

                          // جدول السلة
                          _cartItems.isEmpty
                              ? Container(
                                  padding: const EdgeInsets.all(30),
                                  width: double.infinity,
                                  alignment: Alignment.center,
                                  child: const Text(
                                    'قم بمرور الباركود أو البحث لإضافة الأدوية للفاتورة.',
                                    style: TextStyle(color: Colors.grey, fontSize: 15),
                                  ),
                                )
                              : ListView.separated(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _cartItems.length,
                                  separatorBuilder: (_, __) => const Divider(height: 1),
                                  itemBuilder: (context, index) {
                                    final item = _cartItems[index];
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 6.0),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            flex: 3,
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(item['trade_name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                                                // نفس شكل الباركود في شاشة المخزن.
                                                if (item['barcode'] != null) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    '║ ${item['barcode']}',
                                                    style: TextStyle(color: Colors.grey.shade500, fontSize: 11, fontFamily: 'monospace'),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          Expanded(
                                            flex: 2,
                                            child: Text(AppFormatter.iqdWithCurrency(item['sell_price']), style: const TextStyle(fontWeight: FontWeight.bold)),
                                          ),
                                          Expanded(
                                            flex: 2,
                                            child: Row(
                                              children: [
                                                IconButton(
                                                  icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20),
                                                  onPressed: () => _updateCartQty(index, item['selectedQty'] - 1),
                                                ),
                                                Text('${item['selectedQty']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                                IconButton(
                                                  icon: const Icon(Icons.add_circle_outline, color: Color(0xFF1ABC9C), size: 20),
                                                  onPressed: () => _updateCartQty(index, item['selectedQty'] + 1),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Expanded(
                                            flex: 2,
                                            child: Text(
                                              AppFormatter.iqdWithCurrency(item['total_price']),
                                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.close, color: Colors.red),
                                            onPressed: () => _removeCartItem(index),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),

                          const SizedBox(height: 20),

                          // صندوق الحسابات والخصومات
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text('المجموع الإجمالي قبل الخصم:'),
                                    Text(AppFormatter.iqdWithCurrency(_subtotal), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                  ],
                                ),
                                const SizedBox(height: 12),

                                Row(
                                  children: [
                                    Expanded(
                                      flex: 2,
                                      child: TextField(
                                        controller: _discountController,
                                        keyboardType: TextInputType.number,
                                        inputFormatters: InvoiceDiscount.inputFormatters,
                                        decoration: const InputDecoration(
                                          labelText: 'قيمة الخصم',
                                          isDense: true,
                                          border: OutlineInputBorder(),
                                        ),
                                        onChanged: (_) => setState(() {}),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      flex: 1,
                                      child: DropdownButtonFormField<String>(
                                        initialValue: _discountType,
                                        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                                        items: const [
                                          DropdownMenuItem(value: InvoiceDiscount.amount, child: Text('د.ع')),
                                          DropdownMenuItem(value: InvoiceDiscount.percent, child: Text('%')),
                                        ],
                                        onChanged: (val) {
                                          if (val != null) setState(() => _discountType = val);
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),

                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text('قيمة الخصم المقتطعة:', style: TextStyle(color: Colors.red)),
                                    Text('-${AppFormatter.iqdWithCurrency(_appliedDiscount)}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                                  ],
                                ),
                                const Divider(),

                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text('الصافي النهائي للمدفوع:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                    Text(
                                      AppFormatter.iqdWithCurrency(_grandTotal),
                                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1ABC9C)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 15),

                                SizedBox(
                                  width: double.infinity,
                                  height: 48,
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF1ABC9C),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    onPressed: _isCheckingOut ? null : _processCheckout,
                                    icon: const Icon(Icons.save, color: Colors.white),
                                    label: const Text(
                                      '💾 إتمام عملية البيع وحفظ الفاتورة',
                                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 30),

                  // ==========================================
                  // 2️⃣ القسم الثاني: الفواتير السابقة والإرجاع
                  // ==========================================
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '📜 سجل الفواتير الأخيرة',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF2C3E50)),
                          ),
                          const Divider(),
                          _recentInvoices.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.all(20.0),
                                  child: Center(child: Text('لا توجد مبيعات سابقة مسجلة.', style: TextStyle(color: Colors.grey))),
                                )
                              : SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: DataTable(
                                    columns: const [
                                      DataColumn(label: Text('رقم الفاتورة')),
                                      DataColumn(label: Text('التاريخ')),
                                      DataColumn(label: Text('المجموع')),
                                      DataColumn(label: Text('الخصم')),
                                      DataColumn(label: Text('الصافي')),
                                      DataColumn(label: Text('الحالة')),
                                      DataColumn(label: Text('الإجراءات')),
                                    ],
                                    rows: _recentInvoices.map((inv) {
                                      bool isRefunded = (inv['is_refunded'] ?? 0) == 1;
                                      return DataRow(cells: [
                                        DataCell(Text(inv['invoice_number'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold))),
                                        DataCell(Text((inv['created_at'] ?? '').toString().replaceFirst('T', ' ').split('.').first)),
                                        DataCell(Text(AppFormatter.iqdWithCurrency(inv['total_amount']))),
                                        DataCell(Text(AppFormatter.iqdWithCurrency(inv['discount']), style: const TextStyle(color: Colors.red))),
                                        DataCell(Text(AppFormatter.iqdWithCurrency(inv['final_amount']), style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold))),
                                        DataCell(
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: isRefunded ? Colors.red : Colors.green,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              isRefunded ? '🚫 مرتجعة' : 'مكتملة',
                                              style: const TextStyle(color: Colors.white, fontSize: 11),
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          isRefunded
                                              ? const Text('مرتجعة مسبقاً', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic))
                                              : ElevatedButton.icon(
                                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                                                  onPressed: () => _confirmRefund(inv),
                                                  icon: const Icon(Icons.refresh, size: 16),
                                                  label: const Text('🔄 إرجاع'),
                                                ),
                                        ),
                                      ]);
                                    }).toList(),
                                  ),
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
}