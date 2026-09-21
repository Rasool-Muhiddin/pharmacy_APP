import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../screens/login_screen.dart';
import '../services/desktop_auth_storage.dart';
import '../models/subscription_plan.dart';

class AppSidebar extends StatelessWidget {
  final String currentPage;
  final bool isOwner;
  final SubscriptionEntitlements entitlements;
  final Function(String) onItemSelected;


  AppSidebar({
    super.key,
    required this.currentPage,
    this.isOwner = true,
    SubscriptionEntitlements? entitlements,
    required this.onItemSelected,
  }) : entitlements = entitlements ?? SubscriptionEntitlements.basic();

  static const Color primaryColor = Color(0xff1abc9c);
  static const Color secondaryColor = Color(0xff148f77);

  // نافذة تأكيد تسجيل الخروج
  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Row(
            children: [
              const Icon(Icons.logout_rounded, color: Colors.red, size: 24),
              const SizedBox(width: 8),
              Text(
                'تأكيد تسجيل الخروج',
                style: GoogleFonts.tajawal(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ],
          ),
          content: Text(
            'هل أنت تأكد من رغبتك في الخروج من النظام والعودة لشاشة الدخول؟',
            style: GoogleFonts.tajawal(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'إلغاء',
                style: GoogleFonts.tajawal(color: Colors.grey.shade700, fontWeight: FontWeight.bold),
              ),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                Navigator.pop(ctx); // إغلاق النافذة

                // امسح الجلسة المحفوظة أولاً - وإلا التطبيق يعيد تسجيل
                // الدخول تلقائياً بالمرة الجاية اللي يفتح فيها.
                await DesktopAuthStorage.instance.clearSession();

                if (!context.mounted) return;

                // العودة لشاشة AuthScreen وتصفير المسارات الشاشات المفتوحة
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (context) => const AuthScreen()),
                  (route) => false,
                );
              },
              icon: const Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
              label: Text(
                'تسجيل الخروج',
                style: GoogleFonts.tajawal(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      if (entitlements.allows(AppFeature.dashboard)) _SidebarItem("الرئيسية", Icons.dashboard_rounded),
      if (entitlements.allows(AppFeature.inventory)) _SidebarItem("المخزن والأدوية", Icons.medication_rounded),
      if (entitlements.allows(AppFeature.pointOfSale)) _SidebarItem("نقطة البيع POS", Icons.point_of_sale_rounded),
      if (entitlements.allows(AppFeature.salesHistory)) _SidebarItem("سجل المبيعات", Icons.receipt_long_rounded),

      if (isOwner && entitlements.allows(AppFeature.suppliersAndPurchases)) _SidebarItem("المذاخر والمشتريات", Icons.local_shipping_rounded),
      if (isOwner && entitlements.allows(AppFeature.damagedMedicines)) _SidebarItem("الأدوية التالفة", Icons.delete_forever_rounded),
      if (isOwner && entitlements.allows(AppFeature.expenses)) _SidebarItem("المصروفات", Icons.account_balance_wallet_rounded),
      if (isOwner && entitlements.allows(AppFeature.reports)) _SidebarItem("التقارير والتحليلات", Icons.bar_chart_rounded),
    ];

    return Container(
      width: 260,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            primaryColor,
            secondaryColor,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        children: [
          //==========================
          // Header (تم إضافة صورة الشعار هنا)
          //==========================
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28),
            color: Colors.black.withValues(alpha: .12),
            child: Column(
              children: [
                Container(
                  width: 95,
                  height: 95,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(60),
                    border: Border.all(
                      color: Colors.white,
                      width: 4,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 15,
                        color: Colors.black26,
                      )
                    ],
                  ),
                  // 🟢 عرض الشعار داخل الدائرة بحجم متناسق
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Image.asset(
                      'assets/image/tera_logo.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                Text(
                  "تيرا للحلول البرمجية",
                  style: GoogleFonts.tajawal(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  "Tera Software Solutions",
                  style: GoogleFonts.tajawal(
                    color: Colors.white70,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 15),

          //==========================
          // Navigation Items List
          //==========================
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = item.title == currentPage;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    decoration: BoxDecoration(
                      color: selected ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: selected
                          ? [
                              const BoxShadow(
                                color: Colors.black26,
                                blurRadius: 8,
                              )
                            ]
                          : [],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => onItemSelected(item.title),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 13,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                item.icon,
                                color: selected ? secondaryColor : Colors.white,
                              ),
                              const SizedBox(width: 15),
                              Expanded(
                                child: Text(
                                  item.title,
                                  textAlign: TextAlign.right,
                                  style: GoogleFonts.tajawal(
                                    fontWeight: FontWeight.bold,
                                    color: selected ? secondaryColor : Colors.white,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          //==========================
          // Logout Button & Footer
          //==========================
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
            child: Divider(color: Colors.white.withValues(alpha: 0.25), thickness: 1),
          ),

          // زر تسجيل الخروج
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _showLogoutDialog(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.logout_rounded,
                        color: Color(0xFFFFEBEE),
                        size: 20,
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: Text(
                          "تسجيل الخروج",
                          textAlign: TextAlign.right,
                          style: GoogleFonts.tajawal(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.only(
              bottom: 16,
              top: 12,
            ),
            child: Text(
              "Version 1.0",
              style: GoogleFonts.tajawal(
                color: Colors.white54,
                fontSize: 11,
              ),
            ),
          )
        ],
      ),
    );
  }
}

class _SidebarItem {
  final String title;
  final IconData icon;

  const _SidebarItem(
    this.title,
    this.icon,
  );
}
