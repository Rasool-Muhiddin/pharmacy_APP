import 'package:flutter/material.dart';

// استيراد قاعدة البيانات وموديل الصيدلية
import '../database/db_helper.dart';
import '../models/pharmacy_branch_model.dart'; // 👈 تأكد من صحة المسار

// استيراد المكونات المخصصة
import '../widgets/app_sidebar.dart';
import '../widgets/app_header.dart';

// استيراد الشاشات
import '../screens/dashboard_screen.dart';
import '../screens/inventory_screen.dart'; 
import '../screens/pos_screen.dart'; 
import '../screens/sales_history_screen.dart';
import '../screens/damaged_screen.dart';
import '../screens/reports_screen.dart';
import '../screens/missing_suppliers.dart';
import '../screens/expenses_screen.dart';
import '../screens/offline_migration_screen.dart';
import '../services/migration_api_service.dart';
import '../models/subscription_plan.dart';

class MainLayout extends StatefulWidget {
  final int pharmacyId; // رقم الفرع الحالي
  final int userId;     // رقم الصيدلي / الكاشير الحالي
  final bool isOwner;   // صلاحية المالك/المدير
  final bool isOnlineMode; // من license.mode القادم من التفعيل/تسجيل الدخول
  final SubscriptionEntitlements entitlements;

  MainLayout({
    super.key, 
    required this.pharmacyId,
    this.userId = 1, // قيمة افتراضية في حال عدم التمرير
    this.isOwner = true, // قيمة افتراضية
    this.isOnlineMode = false, // قيمة افتراضية آمنة (أوفلاين) قبل ربط الاستدعاءات القديمة
    SubscriptionEntitlements? entitlements,
  }) : entitlements = entitlements ?? SubscriptionEntitlements.basic();

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  // اسم الصفحة النشطة حالياً
  String _currentPage = "الرئيسية";

  // اسم الصيدلية المفتوحة حالياً
  String _pharmacyName = "";

  // خريطة أيقونات الأقسام
  final Map<String, IconData> _pageIcons = const {
    "الرئيسية": Icons.dashboard_rounded,
    "المخزن والأدوية": Icons.medication_rounded,
    "نقطة البيع POS": Icons.point_of_sale_rounded,
    "سجل المبيعات": Icons.receipt_long_rounded,
    "المذاخر والمشتريات": Icons.local_shipping_rounded,
    "الأدوية التالفة": Icons.delete_forever_rounded,
    "المصروفات": Icons.account_balance_wallet_rounded,
    "التقارير والتحليلات": Icons.bar_chart_rounded,
  };

  static const Map<String, AppFeature> _pageFeatures = {
    'الرئيسية': AppFeature.dashboard,
    'المخزن والأدوية': AppFeature.inventory,
    'نقطة البيع POS': AppFeature.pointOfSale,
    'سجل المبيعات': AppFeature.salesHistory,
    'المذاخر والمشتريات': AppFeature.suppliersAndPurchases,
    'الأدوية التالفة': AppFeature.damagedMedicines,
    'المصروفات': AppFeature.expenses,
    'التقارير والتحليلات': AppFeature.reports,
  };

  @override
  void initState() {
    super.initState();
    _loadPharmacyData(); // 👈 جلب بيانات الصيدلية عند فتح الشاشة
    _maybeSuggestOfflineMigration();
  }

  /// نقطة 5: يُسأل المالك مرة كل دخول أونلاين (طالما لم يرفع بعد) عن رفع
  /// بيانات كانت محلية بحتة قبل التحويل. لا يُزعج إن لم توجد بيانات محلية
  /// أصلاً (صيدلية أونلاين جديدة من البداية)، ولا يكرر السؤال إن كانت
  /// الصيدلية مرفوعة بالفعل (migrated=true من /api/migration/status/).
  Future<void> _maybeSuggestOfflineMigration() async {
    if (!widget.isOnlineMode || !widget.isOwner) return;

    try {
      final hasLocalData = await DatabaseHelper.instance.hasLocalDataWorthMigrating(widget.pharmacyId);
      if (!hasLocalData) return;

      final status = await MigrationApiService.instance.checkStatus();
      if (status['migrated'] == true) return;
      // بيانات أونلاين حقيقية موجودة مسبقاً لهذه الصيدلية (حالة استثنائية)
      // — السيرفر سيرفض أي محاولة رفع فوقها، فلا داعي لعرض اقتراح مضمون
      // الفشل على المالك.
      if (status['has_existing_online_data'] == true) return;

      if (!mounted) return;
      final shouldOpen = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('لديك بيانات محلية لم تُرفع بعد'),
          content: const Text(
            'صيدليتك الآن أونلاين، لكن لديك مخزوناً وموردين مسجّلين محلياً من '
            'قبل. هل تريد رفعها إلى السيرفر الآن؟',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('لاحقاً')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('رفع الآن')),
          ],
        ),
      );

      if (shouldOpen == true && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => OfflineMigrationScreen(pharmacyId: widget.pharmacyId),
          ),
        );
      }
    } catch (_) {
      // فشل فحص حالة الرفع (لا اتصال، إلخ) لا يجب أن يعطّل فتح الشاشة
      // الرئيسية — سيُعاد السؤال في الدخول التالي.
    }
  }

  // دالة جلب بيانات الصيدلية من قاعدة البيانات
  Future<void> _loadPharmacyData() async {
    final data = await DatabaseHelper.instance.getPharmacy(widget.pharmacyId);

    if (!mounted || data == null) return;

    final pharmacy = PharmacyBranch.fromMap(data);
    setState(() {
      _pharmacyName = pharmacy.name; // تعيين اسم الصيدلية
    });
  }

  // دالة تحديد وتوجيه محتوى الشاشة
  Widget _buildScreenContent() {
    final feature = _pageFeatures[_currentPage];
    if (feature != null && !widget.entitlements.allows(feature)) {
      return const Center(child: Text('هذه الخاصية غير مشمولة في باقتك.'));
    }
    switch (_currentPage) {
      case "الرئيسية":
        return DashboardScreen(pharmacyId: widget.pharmacyId, isOnlineMode: widget.isOnlineMode);
      case "المخزن والأدوية":
        return InventoryScreen(
          pharmacyId: widget.pharmacyId,
          isOwner: widget.isOwner,
          isOnlineMode: widget.isOnlineMode,
        );
      case "نقطة البيع POS":
        return PosScreen(
          pharmacyId: widget.pharmacyId,
          userId: widget.userId,
          isOnlineMode: widget.isOnlineMode,
        );
      case "سجل المبيعات":
        return SalesHistoryScreen(
          pharmacyId: widget.pharmacyId,
          isOwner: widget.isOwner,
          isOnlineMode: widget.isOnlineMode,
        );
      case "المذاخر والمشتريات":
        return MissingSuppliersScreen(
          pharmacyId: widget.pharmacyId,
          isOnlineMode: widget.isOnlineMode,
        );
      case "الأدوية التالفة":
        return DamagedScreen(
          pharmacyId: widget.pharmacyId,
          isOwner: widget.isOwner,
          isOnlineMode: widget.isOnlineMode,
        );
      case "المصروفات":
        return ExpensesScreen(
          pharmacyId: widget.pharmacyId,
          isOwner: widget.isOwner,
          isOnlineMode: widget.isOnlineMode,
        );
      case "التقارير والتحليلات":
        return ReportsScreen(
          pharmacyId: widget.pharmacyId,
          isOwner: widget.isOwner,
          isOnlineMode: widget.isOnlineMode,
        );
      default:
        return DashboardScreen(pharmacyId: widget.pharmacyId, isOnlineMode: widget.isOnlineMode);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xfff8f9fa),
        body: Row(
          children: [
            // 1. القائمة الجانبية الثابتة (AppSidebar)
            AppSidebar(
              currentPage: _currentPage,
              isOwner: widget.isOwner, 
              entitlements: widget.entitlements,
              onItemSelected: (selectedTitle) {
                setState(() {
                  _currentPage = selectedTitle;
                });
              },
            ),

            // 2. الهيدر ومحتوى الشاشة المعروضة
            Expanded(
              child: Column(
                children: [
                  // 🟢 الهيدر العلوي يعرض اسم الصيدلية المفتوحة + اسم الصفحة
                  AppHeader(
                    pharmacyName: _pharmacyName,
                    pageTitle: _currentPage,
                    icon: _pageIcons[_currentPage] ?? Icons.circle,
                  ),

                  // الشاشة النشطة
                  Expanded(
                    child: _buildScreenContent(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}