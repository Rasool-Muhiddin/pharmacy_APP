/// الأشكال الدوائية/فئات الأصناف — مصدر واحد للمخزون (الإضافة/التعديل/العرض)
/// والتقارير. المفتاح هو ما يُخزَّن في medicine.category (نص حر على الخادم
/// والمحلي، بلا قائمة اختيارات مقيِّدة)، فإضافة فئة جديدة لا تحتاج ترحيلاً.
const Map<String, String> medicineCategories = {
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
  'medical_supplies': 'مستلزمات طبية / أجهزة',
  'care_cosmetics': 'مستحضرات عناية / تجميل',
  'other': 'أخرى',
};

/// اسم الفئة للعرض: المعروفة بالعربية، وأي قيمة قديمة غير معروفة كما هي.
String medicineCategoryLabel(Object? key) {
  final text = key?.toString().trim() ?? '';
  if (text.isEmpty) return 'غير محدد';
  return medicineCategories[text] ?? text;
}
