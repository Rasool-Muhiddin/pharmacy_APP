/// أسباب الإتلاف (المفتاح هو ما يُخزَّن في damaged_medicine.reason). 'correction'
/// لتصحيح خطأ إدخال كمية — لا يُحتسب خسارة. 'expired' لتسجيل دفعة منتهية
/// الصلاحية كتالف (من تقرير المخزون).
const Map<String, String> damageReasons = {
  'broken': 'كسر وضرر',
  'spoiled': 'سوء خزن',
  'withdrawn': 'سحب وزاري',
  'expired': 'انتهاء الصلاحية',
  'correction': 'تصحيح إدخال (خطأ كمية)',
  'other': 'أسباب أخرى',
};

/// مفاتيح الأسباب التي يحوي نصها العربي [text] (للبحث بالسبب كما يُعرض).
List<String> damageReasonKeysMatching(String text) {
  final query = text.trim();
  if (query.isEmpty) return const [];
  return [
    for (final entry in damageReasons.entries)
      if (entry.value.contains(query)) entry.key,
  ];
}
