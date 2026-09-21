class Medicine {
  final int? id;

  final int pharmacyId;

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