class Medicine {
  final int? id;

  final int pharmacyId;

  /// المخزن الذي ينتمي إليه هذا الصف (خاصية الباقة الذهبية: تعدد المخازن).
  /// لكل الأصناف القديمة، والصيدليات على الباقة الأساسية، هذه القيمة هي
  /// دائماً معرّف المخزن الرئيسي — استخدم
  /// DatabaseHelper.instance.ensureMainWarehouse(pharmacyId) للحصول عليه
  /// عند إنشاء صنف جديد إن لم يكن معروفاً مسبقاً في الشاشة.
  final int warehouseId;

  final String tradeName;

  final String scientificName;

  final String category;

  final int quantity;

  final double buyPrice;

  final double sellPrice;

  final String expiryDate;

  final String shelfLocation;

  final bool isDamaged;

  final String barcode;

  Medicine({
    this.id,
    required this.pharmacyId,
    required this.warehouseId,
    required this.tradeName,
    required this.scientificName,
    required this.category,
    required this.quantity,
    required this.buyPrice,
    required this.sellPrice,
    required this.expiryDate,
    required this.shelfLocation,
    this.isDamaged = false,
    required this.barcode,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'pharmacy_id': pharmacyId,
      'warehouse_id': warehouseId,
      'trade_name': tradeName,
      'scientific_name': scientificName,
      'category': category,
      'quantity': quantity,
      'buy_price': buyPrice,
      'sell_price': sellPrice,
      'expiry_date': expiryDate,
      'shelf_location': shelfLocation,
      'is_damaged': isDamaged ? 1 : 0,
      'barcode': barcode,
    };
  }

  factory Medicine.fromMap(Map<String, dynamic> map) {
    return Medicine(
      id: map['id'],
      pharmacyId: map['pharmacy_id'],
      // احتياط فقط: كل صف حقيقي في قاعدة البيانات لديه warehouse_id (عمود
      // NOT NULL). القيمة 0 هنا لا تطابق أي مخزن حقيقي، وتُستخدم فقط إن
      // جاءت الخريطة من مصدر خارجي (مثلاً استجابة سيرفر أونلاين) لا يعرف
      // بعد عن مفهوم المخازن.
      warehouseId: map['warehouse_id'] ?? 0,
      tradeName: map['trade_name'] ?? '',
      scientificName: map['scientific_name'] ?? '',
      category: map['category'] ?? '',
      quantity: map['quantity'] ?? 0,
      buyPrice: (map['buy_price'] as num?)?.toDouble() ?? 0.0,
      sellPrice: (map['sell_price'] as num?)?.toDouble() ?? 0.0,
      expiryDate: map['expiry_date'] ?? '',
      shelfLocation: map['shelf_location'] ?? '',
      isDamaged: map['is_damaged'] == 1,
      barcode: map['barcode'] ?? '',
    );
  }
}