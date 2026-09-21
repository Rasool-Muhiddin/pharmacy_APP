import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pharmacy_app/utils/formatters.dart';
import '../database/db_helper.dart'; // مسار الداتابيس
import '../models/medicine_model.dart';
import '../widgets/alert_box.dart';   // استيراد الـ AlertBox الخاص بك
import '../widgets/custom_table.dart'; // استيراد الـ CustomTable الخاص بك

class DashboardScreen extends StatefulWidget {
  final int pharmacyId;

  const DashboardScreen({
    super.key,
    this.pharmacyId = 1,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // ==========================================
  // ألوان النظام الموحّدة
  // ==========================================
  static const Color primaryTeal = Color(0xFF1ABC9C);
  static const Color primaryTealDark = Color(0xFF16A085);
  static const Color darkText = Color(0xFF1E293B);
  static const Color mutedText = Color(0xFF64748B);
  static const Color bgColor = Color(0xFFF4F7FB);
  static const Color cardBorder = Color(0xFFEDF2F7);

  bool _isLoading = true;

  // المؤشرات المباشرة
  int _totalMedicines = 0;
  double _todaySales = 0.0;
  int _todayInvoices = 0;

  // قوائم التنبيهات
  List<Medicine> _expiredMedicines = [];
  List<Medicine> _lowStockMedicines = [];

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
  }

  Future<void> _loadDashboardData() async {
    setState(() => _isLoading = true);

    try {
      final db = DatabaseHelper.instance;

      // 1. جلب البيانات الإحصائية
      final medicinesCount = await db.medicineCountByPharmacy(widget.pharmacyId);
      final salesToday = await db.totalSalesToday(widget.pharmacyId);
      final invoicesToday = await db.todayInvoiceCount(widget.pharmacyId);

      // 2. جلب قوائم التنبيهات
      // 🆕 90 يوماً: فترة عملية تعطي الصيدلي وقتاً كافياً للتصرف
      // (إرجاع للمذخر، تخفيض سعر، أو سحب من الرف) قبل انتهاء الصلاحية فعلياً
      final expiredData = await db.getExpiredMedicines(widget.pharmacyId, daysAhead: 90);
      final lowStockData = await db.getLowStockMedicines(widget.pharmacyId, limit: 10);

      setState(() {
        _totalMedicines = medicinesCount;
        _todaySales = salesToday;
        _todayInvoices = invoicesToday;

        _expiredMedicines = expiredData.map((m) => Medicine.fromMap(m)).toList();
        _lowStockMedicines = lowStockData.map((m) => Medicine.fromMap(m)).toList();

        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('حدث خطأ أثناء تحميل البيانات: $e')),
        );
      }
    }
  }

  String _todayLabel() {
    const days = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];
    const months = [
      'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
      'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'
    ];
    final now = DateTime.now();
    return '${days[now.weekday - 1]}، ${now.day} ${months[now.month - 1]}';
  }

  // عدد الأيام المتبقية لانتهاء الصلاحية (سالب = منتهي فعلاً منذ كم يوم)
  // يرجع null لو التاريخ غير قابل للقراءة
  int? _daysUntilExpiry(String expiryDate) {
    final parsed = DateTime.tryParse(expiryDate);
    if (parsed == null) return null;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiryDateOnly = DateTime(parsed.year, parsed.month, parsed.day);

    return expiryDateOnly.difference(today).inDays;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: bgColor,
      child: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: primaryTeal),
            )
          : RefreshIndicator(
              color: primaryTeal,
              onRefresh: _loadDashboardData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ==========================================
                    // 0. ترويسة ترحيبية
                    // ==========================================
                    _buildHeader(),

                    const SizedBox(height: 24),

                    // ==========================================
                    // 1. المؤشرات المباشرة (Stat Cards)
                    // ==========================================
                    _buildStatCards(),

                    const SizedBox(height: 28),

                    // ==========================================
                    // 2. تنبيهات النظام الذكية
                    // ==========================================
                    LayoutBuilder(
                      builder: (context, constraints) {
                        if (constraints.maxWidth > 950) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildExpiredAlertSection()),
                              const SizedBox(width: 20),
                              Expanded(child: _buildLowStockAlertSection()),
                            ],
                          );
                        } else {
                          return Column(
                            children: [
                              _buildExpiredAlertSection(),
                              const SizedBox(height: 20),
                              _buildLowStockAlertSection(),
                            ],
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  // ودجت الترويسة الترحيبية بتدرج لوني بلون التطبيق
  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [primaryTealDark, primaryTeal],
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: primaryTeal.withValues(alpha: 0.28),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'أهلاً بك 👋',
                  style: GoogleFonts.tajawal(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'نظرة سريعة على أداء الصيدلية اليوم — ${_todayLabel()}',
                  style: GoogleFonts.tajawal(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.local_pharmacy_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
        ],
      ),
    );
  }

  // شبكة بطاقات الإحصائيات
  Widget _buildStatCards() {
    return LayoutBuilder(
      builder: (context, constraints) {
        int crossAxisCount = constraints.maxWidth > 1000 ? 3 : (constraints.maxWidth > 650 ? 2 : 1);

        final stats = [
          _StatData(
            title: 'عدد الأدوية بالمخزن',
            value: '$_totalMedicines',
            subTitle: 'دواء مسجل',
            icon: Icons.medication_liquid_rounded,
            color: const Color(0xFF3498DB),
          ),
          _StatData(
            title: 'مبيعات اليوم',
            value: AppFormatter.iqdWithCurrency(_todaySales),
            subTitle: 'إجمالي المبيعات',
            icon: Icons.payments_rounded,
            color: primaryTeal,
          ),
          _StatData(
            title: 'عدد فواتير اليوم',
            value: '$_todayInvoices',
            subTitle: 'فاتورة صادرة',
            icon: Icons.receipt_long_rounded,
            color: const Color(0xFF9B59B6),
          ),
        ];

        return GridView.count(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 20,
          mainAxisSpacing: 20,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.3,
          children: [
            for (int i = 0; i < stats.length; i++)
              _AnimatedEntry(delayMs: i * 90, child: _buildStatCard(stats[i])),
          ],
        );
      },
    );
  }

  // ودجت بطاقة الإحصائيات — بشريط لوني على الحافة وظل متوهج بلون البطاقة
  Widget _buildStatCard(_StatData s) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          // ظل ملوّن ناعم بلون البطاقة نفسه لإحساس عصري
          BoxShadow(
            color: s.color.withValues(alpha: 0.16),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: const Color(0xFF1A202C).withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Container(
          color: Colors.white,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // الشريط اللوني على حافة البطاقة
                Container(
                  width: 5,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [s.color, s.color.withValues(alpha: 0.6)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 20, 20, 20),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [s.color.withValues(alpha: 0.18), s.color.withValues(alpha: 0.08)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(s.icon, color: s.color, size: 30),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.title,
                                style: GoogleFonts.tajawal(
                                  color: mutedText,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                s.value,
                                style: GoogleFonts.tajawal(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: darkText,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                s.subTitle,
                                style: GoogleFonts.tajawal(fontSize: 10.5, color: mutedText),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // قسم الأدوية منتهية الصلاحية أو الموشكة على الانتهاء (خلال 30 يوماً)
  Widget _buildExpiredAlertSection() {
    return AlertBox(
      title: "تحذيرات الصلاحية",
      icon: Icons.warning_amber_rounded,
      color: const Color(0xFFE74C3C),
      child: _expiredMedicines.isEmpty
          ? _buildEmptyState(
              icon: Icons.verified_rounded,
              message: 'لا توجد أدوية منتهية أو موشكة على الانتهاء خلال 30 يوماً',
              color: const Color(0xFF27AE60),
            )
          : CustomTable(
              headers: const ["اسم الدواء", "الحالة", "العدد"],
              rows: _expiredMedicines.map<List<Widget>>((med) {
                final daysLeft = _daysUntilExpiry(med.expiryDate);
                final bool isAlreadyExpired = daysLeft != null && daysLeft < 0;

                // لون أحمر للمنتهي فعلاً، وبرتقالي للموشك على الانتهاء
                final Color badgeColor = isAlreadyExpired
                    ? const Color(0xFFE74C3C)
                    : const Color(0xFFE67E22);

                final String badgeText = daysLeft == null
                    ? (med.expiryDate.isEmpty ? '-' : med.expiryDate)
                    : isAlreadyExpired
                        ? 'منتهي منذ ${-daysLeft} يوم'
                        : daysLeft == 0
                            ? 'ينتهي اليوم'
                            : 'باقي $daysLeft يوم';

                return [
                  Text(
                    med.tradeName,
                    style: GoogleFonts.tajawal(fontWeight: FontWeight.bold, fontSize: 13, color: darkText),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      badgeText,
                      style: GoogleFonts.tajawal(color: badgeColor, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '${med.quantity}',
                    style: GoogleFonts.tajawal(fontWeight: FontWeight.bold, fontSize: 13, color: darkText),
                  ),
                ];
              }).toList(),
            ),
    );
  }

  // قسم الأدوية التي أوشكت على النفاذ
  Widget _buildLowStockAlertSection() {
    return AlertBox(
      title: "تحذيرات الكمية",
      icon: Icons.inventory_2_rounded,
      color: const Color(0xFFE67E22),
      child: _lowStockMedicines.isEmpty
          ? _buildEmptyState(
              icon: Icons.check_circle_rounded,
              message: 'المخزون بحالة جيدة، لا نواقص حالياً',
              color: const Color(0xFF27AE60),
            )
          : CustomTable(
              headers: const ["اسم الدواء", "المتبقي بالمخزن"],
              rows: _lowStockMedicines.map<List<Widget>>((med) {
                return [
                  Text(
                    med.tradeName,
                    style: GoogleFonts.tajawal(fontWeight: FontWeight.bold, fontSize: 13, color: darkText),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE67E22).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${med.quantity} عبوة',
                      style: GoogleFonts.tajawal(
                        color: const Color(0xFFD35400),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ];
              }).toList(),
            ),
    );
  }

  // حالة فارغة أنيقة بدل ترك الجدول فاضي
  Widget _buildEmptyState({
    required IconData icon,
    required String message,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 30),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: GoogleFonts.tajawal(color: mutedText, fontSize: 13, fontWeight: FontWeight.w500),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// نموذج بيانات مبسّط لبطاقة إحصائية واحدة
class _StatData {
  final String title;
  final String value;
  final String subTitle;
  final IconData icon;
  final Color color;

  _StatData({
    required this.title,
    required this.value,
    required this.subTitle,
    required this.icon,
    required this.color,
  });
}

// تأثير ظهور تدريجي بسيط للبطاقات (fade + slide)
class _AnimatedEntry extends StatelessWidget {
  final Widget child;
  final int delayMs;

  const _AnimatedEntry({required this.child, this.delayMs = 0});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + delayMs),
      curve: Curves.easeOutCubic,
      builder: (context, value, c) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 16),
            child: c,
          ),
        );
      },
      child: child,
    );
  }
}