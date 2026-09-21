import 'package:flutter/material.dart';
import 'package:pharmacy_app/utils/formatters.dart';
import '../database/db_helper.dart'; // تأكد من صحة مسار الملف لديك

class PosScreen extends StatefulWidget {
  final int pharmacyId;
  final int userId; // رقم المستخدم الحالى (Cashier)

  const PosScreen({
    super.key,
    required this.pharmacyId,
    required this.userId,
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

  String _discountType = 'amount'; // 'amount' (مبلغ) أو 'percent' (%)
  bool _showSuggestions = false;
  bool _isLoading = false;
  bool _isCheckingOut = false;
  String _searchPlaceholder = '🔍 مرر الباركود أو ابحث بالاسم التجاري/العلمي/الباركود...';

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

// تحميل أدوية الفرع وسجل الفواتير من قاعدة البيانات مباشرة
  Future<void> _loadInitialData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final meds = await DatabaseHelper.instance.getMedicines(widget.pharmacyId);
      final invoices = await DatabaseHelper.instance.getInvoices(widget.pharmacyId);
      final DateTime now = DateTime.now();
      final DateTime today = DateTime(now.year, now.month, now.day);

      if (!mounted) return;
      setState(() {
        // فلترة الأدوية: غير تالفة + كميتها > 0 + غير منتهية الصلاحية
        _availableMedicines = meds.where((m) {
          final isNotDamaged = (m['is_damaged'] ?? 0) == 0;
          final hasQuantity = (m['quantity'] ?? 0) > 0;

          bool isNotExpired = true;
          if (m['expiry_date'] != null && m['expiry_date'].toString().isNotEmpty) {
            final expiry = DateTime.tryParse(m['expiry_date'].toString());
            if (expiry != null) {
              final expiryDateOnly = DateTime(expiry.year, expiry.month, expiry.day);
              isNotExpired = !expiryDateOnly.isBefore(today);
            }
          }

          return isNotDamaged && hasQuantity && isNotExpired;
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

  double get _appliedDiscount {
    double val = double.tryParse(_discountController.text) ?? 0.0;
    if (_discountType == 'percent') {
      if (val > 100) val = 100;
      return (_subtotal * val) / 100;
    } else {
      if (val > _subtotal) val = _subtotal;
      return val;
    }
  }

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
      final exactMatch = await DatabaseHelper.instance.getMedicineByBarcode(query);

      if (!mounted) return;

      // تجهيز تاريخ اليوم للمقارنة
      final DateTime now = DateTime.now();
      final DateTime today = DateTime(now.year, now.month, now.day);

      // فحص التاريخ للدواء الممسوح بالباركود
      bool isNotExpired = true;
      if (exactMatch != null && exactMatch['expiry_date'] != null && exactMatch['expiry_date'].toString().isNotEmpty) {
        final expiry = DateTime.tryParse(exactMatch['expiry_date'].toString());
        if (expiry != null) {
          final expiryDateOnly = DateTime(expiry.year, expiry.month, expiry.day);
          isNotExpired = !expiryDateOnly.isBefore(today);
        }
      }

      // التحقق الشامل: الصيدلية + الكمية + عدم التلف + عدم انتهاء الصلاحية
      final isValid = exactMatch != null &&
          exactMatch['pharmacy_id'] == widget.pharmacyId &&
          (exactMatch['quantity'] ?? 0) > 0 &&
          (exactMatch['is_damaged'] ?? 0) == 0 &&
          isNotExpired;

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
  // --- 2. إضافة وتعديل عناصر السلة ---
  void _addMedicineToCart(Map<String, dynamic> medicine) {
    int maxQty = medicine['quantity'] ?? 0;
    int medId = medicine['id'];

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
      // أ) توليد رقم الفاتورة المنسق
      String invoiceNum = await DatabaseHelper.instance.generateInvoiceNumber();

      // ب) إعداد خريطة بيانات الفاتورة الرئيسية
      final invoiceData = {
        'pharmacy_id': widget.pharmacyId,
        'invoice_number': invoiceNum,
        'cashier_id': widget.userId,
        'total_amount': _subtotal,
        'discount': _appliedDiscount,
        'final_amount': _grandTotal,
        'created_at': DateTime.now().toIso8601String(),
        'is_refunded': 0,
      };

      // جـ) إعداد قائمة عناصر الفاتورة
      final itemsData = _cartItems.map((item) {
        return {
          'trade_name': item['trade_name'],
          'medicine_id': item['id'],
          'quantity': item['selectedQty'],
          'unit_price': item['sell_price'],
          'total_price': item['total_price'],
        };
      }).toList();

      // د) تنفيذ الشراء التكاملي عبر دالة completeSale
      await DatabaseHelper.instance.completeSale(
        invoice: invoiceData,
        items: itemsData,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ تم إتمام الفاتورة $invoiceNum بنجاح!'), backgroundColor: Colors.green),
        );
      }

      // و) إعادة ضبط الشاشة
      setState(() {
        _cartItems.clear();
        _discountController.text = '0';
        _discountType = 'amount';
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
        await DatabaseHelper.instance.refundInvoice(invoice['id']);
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
                                            final int qty = med['quantity'] ?? 0;
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
                                            child: Text(item['trade_name'], style: const TextStyle(fontWeight: FontWeight.bold)),
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
                                          DropdownMenuItem(value: 'amount', child: Text('د.ع')),
                                          DropdownMenuItem(value: 'percent', child: Text('%')),
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