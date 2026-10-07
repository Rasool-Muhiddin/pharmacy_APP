import 'package:flutter/material.dart';
import 'package:pharmacy_app/utils/formatters.dart';
import '../database/db_helper.dart'; // تأكد من صحة مسار الملف لديك
import '../repository/invoice_repository.dart';
import '../repository/medicine_repository.dart';
import '../repository/warehouse_repository.dart';
import '../utils/invoice_discount.dart';
import '../widgets/cart_quantity_field.dart';
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
  String _searchPlaceholder = 'امسح الباركود أو ابحث بالاسم التجاري/العلمي/الباركود...';

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

    // لوحة "سجل الفواتير الأخيرة" تحتاج صفحة واحدة صغيرة فقط (لا السجل
    // كاملاً)؛ تُطلب بالتوازي مع مزامنة المخزون. الخطأ يُحفظ ويُرمى بعد
    // انتظارها كي لا يبقى Future فاشل بلا معالجة.
    Object? recentError;
    final recentFuture = InvoiceRepository.instance
        .getRecentInvoices(pharmacyId: widget.pharmacyId, isOnlineMode: widget.isOnlineMode)
        .catchError((Object e) {
      recentError = e;
      return <Map<String, dynamic>>[];
    });

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
      final invoices = await recentFuture;
      if (recentError != null) throw recentError!;
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
              _searchPlaceholder = 'امسح الباركود أو ابحث بالاسم التجاري/العلمي/الباركود...';
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

  /// كتابة الكمية مباشرة في السلة: CartQuantityField يضمن 1..المخزون مسبقاً.
  void _setCartQty(int index, int newQty) {
    setState(() {
      _cartItems[index]['selectedQty'] = newQty;
      _cartItems[index]['total_price'] = newQty * (_cartItems[index]['sell_price'] as double);
    });
  }

  void _showCappedMessage(int maxQty) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('الحد الأقصى المتوفر بالمخزن هو $maxQty قطعة.'),
        backgroundColor: _warning,
        duration: const Duration(seconds: 2),
      ));
  }

  int get _totalUnits => _cartItems.fold(0, (sum, item) => sum + (item['selectedQty'] as int));

  // ================== الواجهة ==================

  static const Color _primary = Color(0xFF1ABC9C);
  static const Color _primaryDark = Color(0xFF16A085);
  static const Color _canvas = Color(0xFFF8FAFC);
  static const Color _border = Color(0xFFE2E8F0);
  static const Color _textMain = Color(0xFF2C3E50);
  static const Color _textSecondary = Color(0xFF7F8C8D);
  static const Color _danger = Color(0xFFE74C3C);
  static const Color _warning = Color(0xFFF39C12);
  static const Color _success = Color(0xFF2ECC71);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _canvas,
      appBar: AppBar(
        title: const Text(
          'نقطة البيع',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white),
        ),
        elevation: 6,
        shadowColor: const Color(0xFF0D9488).withValues(alpha: 0.35),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(bottom: Radius.circular(16))),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
            gradient: LinearGradient(
              colors: [Color(0xFF0D9488), Color(0xFF16A085)],
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 980;
                final sale = wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _buildSaleColumn()),
                          const SizedBox(width: 16),
                          SizedBox(width: 340, child: _buildSummaryPanel()),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [_buildSaleColumn(), const SizedBox(height: 16), _buildSummaryPanel()],
                      );
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [sale, const SizedBox(height: 20), _buildRecentInvoices()],
                  ),
                );
              },
            ),
    );
  }

  BoxDecoration get _cardDecoration => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .03), blurRadius: 12, offset: const Offset(0, 4))],
      );

  Widget _cardTitle(IconData icon, String title, {Widget? trailing}) => Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: _primary.withValues(alpha: .12), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: _primaryDark, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _textMain)),
          ),
          if (trailing != null) trailing,
        ],
      );

  /// شريط البحث/الباركود مع المقترحات، ثم جدول السلة.
  Widget _buildSaleColumn() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle(
            Icons.point_of_sale_rounded,
            'الفاتورة الحالية',
            trailing: _cartItems.isEmpty
                ? null
                : Text('${_cartItems.length} صنف', style: const TextStyle(color: _textSecondary)),
          ),
          const SizedBox(height: 14),
          _buildSearchBar(),
          const SizedBox(height: 14),
          _buildCartTable(),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          autofocus: true,
          onChanged: _onSearchChanged,
          onSubmitted: _onScannerSubmit,
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            hintText: _searchPlaceholder,
            hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 14),
            prefixIcon: const Icon(Icons.qr_code_scanner_rounded, color: _primary),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () {
                      _searchController.clear();
                      _onSearchChanged('');
                      _searchFocusNode.requestFocus();
                    },
                  )
                : null,
            filled: true,
            fillColor: const Color(0xFFF8FAFA),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _primary, width: 1.8),
            ),
          ),
        ),
        // المقترحات تحت الحقل مباشرة (لا تغطي السلة إلا عند البحث).
        if (_showSuggestions)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 280),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 14, offset: const Offset(0, 6))],
            ),
            child: _filteredSuggestions.isEmpty
                ? const ListTile(
                    leading: Icon(Icons.search_off_rounded, color: _danger),
                    title: Text('لا يتوفر هذا الصنف في المخزن!', style: TextStyle(color: _danger)),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _filteredSuggestions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final med = _filteredSuggestions[index];
                      final qty = _sellableQty(med);
                      final lowStock = qty <= kLowStockThreshold;
                      final barcode = (med['barcode'] ?? '').toString();
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.medication_outlined, color: _primaryDark),
                        title: Text(med['trade_name'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(
                          [med['scientific_name'] ?? '', if (barcode.isNotEmpty) barcode]
                              .where((t) => t.toString().isNotEmpty)
                              .join('  •  '),
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              AppFormatter.iqdWithCurrency(med['sell_price']),
                              style: const TextStyle(fontWeight: FontWeight.bold, color: _primaryDark),
                            ),
                            const SizedBox(width: 10),
                            _pill(lowStock ? 'شحيح: $qty' : 'متوفر: $qty', lowStock ? _danger : _textSecondary),
                          ],
                        ),
                        onTap: () => _addMedicineToCart(med),
                      );
                    },
                  ),
          ),
      ],
    );
  }

  Widget _buildCartTable() {
    if (_cartItems.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 48),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
        ),
        child: Column(
          children: [
            Icon(Icons.shopping_cart_outlined, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 10),
            const Text(
              'امسح الباركود أو ابحث بالاسم لإضافة الأدوية للفاتورة.',
              style: TextStyle(color: _textSecondary, fontSize: 15),
            ),
          ],
        ),
      );
    }

    const headerStyle = TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: _textMain);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: _border)),
      child: Column(
        children: [
          Container(
            color: const Color(0xFFF0F4F5),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: const Row(
              children: [
                SizedBox(width: 28),
                Expanded(flex: 4, child: Text('الصنف', style: headerStyle)),
                Expanded(flex: 2, child: Text('سعر الوحدة', style: headerStyle)),
                SizedBox(width: 150, child: Center(child: Text('الكمية', style: headerStyle))),
                Expanded(flex: 2, child: Text('الإجمالي', style: headerStyle, textAlign: TextAlign.end)),
                SizedBox(width: 44),
              ],
            ),
          ),
          for (var index = 0; index < _cartItems.length; index++) _buildCartRow(index),
        ],
      ),
    );
  }

  Widget _buildCartRow(int index) {
    final item = _cartItems[index];
    final qty = item['selectedQty'] as int;
    final maxQty = item['maxQty'] as int;
    return Container(
      // مفتاح ثابت لكل صنف: حقل الكمية يحتفظ بحالته عند حذف سطر آخر.
      key: ValueKey('cart-${item['id']}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: index.isEven ? Colors.white : const Color(0xFFFAFCFC),
        border: const Border(top: BorderSide(color: _border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${index + 1}', style: const TextStyle(color: _textSecondary, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item['trade_name'], style: const TextStyle(fontWeight: FontWeight.bold, color: _textMain)),
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
            child: Text(AppFormatter.iqdWithCurrency(item['sell_price']), style: const TextStyle(color: _textMain)),
          ),
          SizedBox(
            width: 150,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'إنقاص',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.remove_circle_outline, color: qty > 1 ? _danger : Colors.grey.shade400, size: 20),
                  onPressed: () => _updateCartQty(index, qty - 1),
                ),
                CartQuantityField(
                  quantity: qty,
                  maxQuantity: maxQty,
                  onChanged: (value) => _setCartQty(index, value),
                  onCapped: _showCappedMessage,
                  onSubmitted: _searchFocusNode.requestFocus,
                ),
                IconButton(
                  tooltip: 'زيادة',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.add_circle_outline, color: qty < maxQty ? _primary : Colors.grey.shade400, size: 20),
                  onPressed: () => _updateCartQty(index, qty + 1),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              AppFormatter.iqdWithCurrency(item['total_price']),
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w800, color: _primaryDark),
            ),
          ),
          SizedBox(
            width: 44,
            child: IconButton(
              tooltip: 'حذف من الفاتورة',
              icon: const Icon(Icons.delete_outline_rounded, color: _danger),
              onPressed: () => _removeCartItem(index),
            ),
          ),
        ],
      ),
    );
  }

  /// ملخص ثابت: عدد الأصناف والقطع، المجموع، الخصم، الصافي، وزر الإتمام.
  Widget _buildSummaryPanel() {
    Widget line(String label, String value, {Color color = _textMain, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(color: _textSecondary))),
              Text(value, style: TextStyle(color: color, fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle(Icons.receipt_long_rounded, 'ملخص الفاتورة'),
          const SizedBox(height: 12),
          line('عدد الأصناف', '${_cartItems.length}'),
          line('عدد القطع', '$_totalUnits'),
          line('المجموع قبل الخصم', AppFormatter.iqdWithCurrency(_subtotal), bold: true),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _discountController,
                  keyboardType: TextInputType.number,
                  inputFormatters: InvoiceDiscount.inputFormatters,
                  decoration: InputDecoration(
                    labelText: 'الخصم',
                    isDense: true,
                    prefixIcon: const Icon(Icons.discount_outlined, color: _primary, size: 19),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _discountType,
                  isExpanded: true,
                  decoration: InputDecoration(isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
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
          const SizedBox(height: 6),
          line('قيمة الخصم', '-${AppFormatter.iqdWithCurrency(_appliedDiscount)}', color: _danger),
          const Divider(height: 22),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(color: const Color(0xFFE6F7F5), borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                const Expanded(
                  child: Text('الصافي المطلوب', style: TextStyle(fontWeight: FontWeight.w800, color: _textMain)),
                ),
                Text(
                  AppFormatter.iqdWithCurrency(_grandTotal),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: _primaryDark),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 56,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                disabledBackgroundColor: _primary.withValues(alpha: .45),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _isCheckingOut ? null : _processCheckout,
              icon: _isCheckingOut
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle_outline_rounded, color: Colors.white),
              label: const Text(
                'إتمام البيع',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentInvoices() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle(Icons.history_rounded, 'سجل الفواتير الأخيرة'),
          const SizedBox(height: 12),
          if (_recentInvoices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: Text('لا توجد مبيعات سابقة مسجلة.', style: TextStyle(color: _textSecondary))),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(const Color(0xFFF0F4F5)),
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
                  final isRefunded = (inv['is_refunded'] ?? 0) == 1;
                  return DataRow(cells: [
                    DataCell(Text(inv['invoice_number'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold))),
                    DataCell(Text((inv['created_at'] ?? '').toString().replaceFirst('T', ' ').split('.').first)),
                    DataCell(Text(AppFormatter.iqdWithCurrency(inv['total_amount']))),
                    DataCell(Text(AppFormatter.iqdWithCurrency(inv['discount']), style: const TextStyle(color: _danger))),
                    DataCell(Text(
                      AppFormatter.iqdWithCurrency(inv['final_amount']),
                      style: const TextStyle(color: _primaryDark, fontWeight: FontWeight.bold),
                    )),
                    DataCell(_pill(isRefunded ? 'مرتجعة' : 'مكتملة', isRefunded ? _danger : _success)),
                    DataCell(
                      isRefunded
                          ? const Text('مرتجعة مسبقاً', style: TextStyle(color: _textSecondary, fontStyle: FontStyle.italic))
                          : OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _danger,
                                side: const BorderSide(color: _danger),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () => _confirmRefund(inv),
                              icon: const Icon(Icons.undo_rounded, size: 16),
                              label: const Text('إرجاع'),
                            ),
                    ),
                  ]);
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: .13), borderRadius: BorderRadius.circular(14)),
        child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11.5)),
      );
}
