/// خصائص النظام التي يمكن ربطها بالباقات.
///
/// جميع الخصائص الموجودة عند إنشاء هذا النظام تقع في الباقة الأساسية.
/// عند إضافة خصائص جديدة لاحقاً، لا تضاف إلى [basicFeatures] وإنما إلى
/// [goldAdditionalFeatures] أو [diamondAdditionalFeatures] حسب القرار التجاري.
enum AppFeature {
  dashboard,
  inventory,
  pointOfSale,
  salesHistory,
  suppliersAndPurchases,
  damagedMedicines,
  expenses,
  reports,

  /// إمكانية إضافة مخازن إضافية لنفس الصيدلية (حتى
  /// [SubscriptionEntitlements.maxWarehouses])، والنقل بينها. البيع يبقى
  /// دائماً من المخزن الرئيسي فقط.
  multiWarehouse,

  /// تصدير شاشة التقارير إلى Excel/PDF. زر "تصدير" يبقى ظاهراً في Basic
  /// ويعرض نافذة الترقية بدل التصدير.
  reportExport,
}

/// الخصائص "المرئية لكن مقفولة" في الباقة الأساسية: تظهر في الواجهة مع
/// شارة "خطتك الحالية لا تسمح..." بدل إخفائها بالكامل مثل باقي الخصائص.
/// أضف هنا أي خاصية جديدة تريدها ظاهرة-لكن-مقفولة في Basic؛ أي خاصية غير
/// موجودة في هذه المجموعة تُخفى بالكامل عن Basic كما كان يحدث سابقاً.
const Set<AppFeature> lockedButVisibleInBasic = <AppFeature>{
  AppFeature.multiWarehouse,
  AppFeature.reportExport,
};

enum SubscriptionPlan {
  basic,
  gold,
  diamond,
}

class SubscriptionEntitlements {
  const SubscriptionEntitlements({
    required this.plan,
    required this.features,
    int? maxWarehouses,
  }) : _maxWarehouses = maxWarehouses;

  /// الحد الافتراضي لعدد المخازن (الرئيسي ضمنها) لباقات Gold/Diamond عندما
  /// لا يرسل الخادم license.max_warehouses (ترخيص مخزَّن من إصدار أقدم).
  static const int defaultMultiWarehouseLimit = 2;

  /// كل خصائص الإصدار الحالي متاحة في Basic بناءً على سياسة الباقات الحالية.
  static final Set<AppFeature> basicFeatures =
      Set<AppFeature>.unmodifiable(<AppFeature>{
    AppFeature.dashboard,
    AppFeature.inventory,
    AppFeature.pointOfSale,
    AppFeature.salesHistory,
    AppFeature.suppliersAndPurchases,
    AppFeature.damagedMedicines,
    AppFeature.expenses,
    AppFeature.reports,
  });

  /// مكان مخصص للخصائص التي ستضاف لاحقاً إلى Gold دون تغيير Basic.
  static const Set<AppFeature> goldAdditionalFeatures = <AppFeature>{
    AppFeature.multiWarehouse,
    AppFeature.reportExport,
  };

  /// مكان مخصص للخصائص الحصرية لـ Diamond التي ستضاف لاحقاً.
  static const Set<AppFeature> diamondAdditionalFeatures = <AppFeature>{};

  final SubscriptionPlan plan;
  final Set<AppFeature> features;
  final int? _maxWarehouses;

  /// العدد المسموح من المخازن (الرئيسي ضمنها). 1 دائماً إن لم تسمح الباقة
  /// بتعدد المخازن، وإلا القيمة القادمة من الخادم (license.max_warehouses)
  /// — نفس desktop_api.permissions.max_warehouses_for، فيُفرض نفس الحد
  /// أوفلاين وأونلاين.
  int get maxWarehouses {
    if (!allows(AppFeature.multiWarehouse)) return 1;
    final value = _maxWarehouses ?? defaultMultiWarehouseLimit;
    return value < 1 ? 1 : value;
  }

  factory SubscriptionEntitlements.basic() {
    return SubscriptionEntitlements(
      plan: SubscriptionPlan.basic,
      features: basicFeatures,
    );
  }

  /// يتوافق مع الخادم الحالي الذي يعيد license.type، ومع الخادم بعد إضافة
  /// license.plan أو license.features. القيمة غير المعروفة تبقى Basic حتى لا
  /// يحرم العملاء الحاليون من خصائصهم عند ترقية التطبيق قبل الخادم.
  ///
  /// license.features من الخادم (desktop_api.permissions.PLAN_FEATURES) يحوي
  /// الخصائص الإضافية فوق Basic فقط، لذا تُضاف دائماً إلى [basicFeatures].
  factory SubscriptionEntitlements.fromLicense(Map<String, dynamic> license) {
    final plan = _planFrom(
      (license['plan'] ?? license['type'] ?? '').toString(),
    );
    final serverFeatures = license['features'];
    final maxWarehouses = (license['max_warehouses'] as num?)?.toInt();

    if (serverFeatures is List) {
      final parsed = serverFeatures
          .map((value) => _featureFrom(value.toString()))
          .whereType<AppFeature>();
      return SubscriptionEntitlements(
        plan: plan,
        features: Set<AppFeature>.unmodifiable(<AppFeature>{...basicFeatures, ...parsed}),
        maxWarehouses: maxWarehouses,
      );
    }

    return SubscriptionEntitlements(
      plan: plan,
      features: _featuresForPlan(plan),
      maxWarehouses: maxWarehouses,
    );
  }

  bool allows(AppFeature feature) => features.contains(feature);

  /// خاص بالخصائص "المرئية-لكن-مقفولة": استخدم هذا بدل [allows] في أي
  /// شاشة/ويدجت تخص خاصية ضمن [lockedButVisibleInBasic]، لأنها يجب أن
  /// تظهر دائماً في الواجهة (ممكّنة أو مقفولة) ولا تُخفى أبداً.
  bool isLocked(AppFeature feature) =>
      lockedButVisibleInBasic.contains(feature) && !allows(feature);

  String get displayName => switch (plan) {
        SubscriptionPlan.basic => 'Basic',
        SubscriptionPlan.gold => 'Gold',
        SubscriptionPlan.diamond => 'Diamond',
      };

  static SubscriptionPlan _planFrom(String value) => switch (value.toLowerCase()) {
        'gold' => SubscriptionPlan.gold,
        'diamond' => SubscriptionPlan.diamond,
        _ => SubscriptionPlan.basic,
      };

  static Set<AppFeature> _featuresForPlan(SubscriptionPlan plan) {
    final features = <AppFeature>{...basicFeatures};
    if (plan == SubscriptionPlan.gold || plan == SubscriptionPlan.diamond) {
      features.addAll(goldAdditionalFeatures);
    }
    if (plan == SubscriptionPlan.diamond) {
      features.addAll(diamondAdditionalFeatures);
    }
    return Set<AppFeature>.unmodifiable(features);
  }

  static AppFeature? _featureFrom(String value) => switch (value) {
        'dashboard' => AppFeature.dashboard,
        'inventory' => AppFeature.inventory,
        'point_of_sale' => AppFeature.pointOfSale,
        'sales_history' => AppFeature.salesHistory,
        'suppliers_and_purchases' => AppFeature.suppliersAndPurchases,
        'damaged_medicines' => AppFeature.damagedMedicines,
        'expenses' => AppFeature.expenses,
        'reports' => AppFeature.reports,
        'multi_warehouse' => AppFeature.multiWarehouse,
        'report_export' => AppFeature.reportExport,
        _ => null,
      };
}