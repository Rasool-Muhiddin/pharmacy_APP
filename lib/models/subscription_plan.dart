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
}

enum SubscriptionPlan {
  basic,
  gold,
  diamond,
}

class SubscriptionEntitlements {
  const SubscriptionEntitlements({
    required this.plan,
    required this.features,
  });

  /// كل خصائص الإصدار الحالي متاحة في Basic بناءً على سياسة الباقات الحالية.
  static final Set<AppFeature> basicFeatures =
      Set<AppFeature>.unmodifiable(AppFeature.values);

  /// مكان مخصص للخصائص التي ستضاف لاحقاً إلى Gold دون تغيير Basic.
  static const Set<AppFeature> goldAdditionalFeatures = <AppFeature>{};

  /// مكان مخصص للخصائص الحصرية لـ Diamond التي ستضاف لاحقاً.
  static const Set<AppFeature> diamondAdditionalFeatures = <AppFeature>{};

  final SubscriptionPlan plan;
  final Set<AppFeature> features;

  factory SubscriptionEntitlements.basic() {
    return SubscriptionEntitlements(
      plan: SubscriptionPlan.basic,
      features: basicFeatures,
    );
  }

  /// يتوافق مع الخادم الحالي الذي يعيد license.type، ومع الخادم بعد إضافة
  /// license.plan أو license.features. القيمة غير المعروفة تبقى Basic حتى لا
  /// يحرم العملاء الحاليون من خصائصهم عند ترقية التطبيق قبل الخادم.
  factory SubscriptionEntitlements.fromLicense(Map<String, dynamic> license) {
    final plan = _planFrom(
      (license['plan'] ?? license['type'] ?? '').toString(),
    );
    final serverFeatures = license['features'];

    if (serverFeatures is List) {
      final parsed = serverFeatures
          .map((value) => _featureFrom(value.toString()))
          .whereType<AppFeature>()
          .toSet();
      return SubscriptionEntitlements(plan: plan, features: parsed);
    }

    return SubscriptionEntitlements(
      plan: plan,
      features: _featuresForPlan(plan),
    );
  }

  bool allows(AppFeature feature) => features.contains(feature);

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
        _ => null,
      };
}
