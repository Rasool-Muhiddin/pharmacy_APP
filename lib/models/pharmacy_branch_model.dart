class PharmacyBranch {
  final int? id;
  final String name;
  final bool isActive;
  final DateTime createdAt;

  PharmacyBranch({
    this.id,
    required this.name,
    this.isActive = true,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory PharmacyBranch.fromMap(Map<String, dynamic> map) {
    return PharmacyBranch(
      id: map['id'],
      name: map['name'],
      isActive: map['is_active'] == 1,
      createdAt: DateTime.parse(map['created_at']),
    );
  }
}