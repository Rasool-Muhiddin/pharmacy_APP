import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppHeader extends StatelessWidget {
  final String pharmacyName; // 👈 اسم الصيدلية المفتوحة
  final String? pageTitle;    // اسم الصفحة الحالية (اخيتياري)
  final IconData? icon;
  final Widget? trailing;

  const AppHeader({
    super.key,
    required this.pharmacyName,
    this.pageTitle,
    this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.grey.shade300,
          ),
        ),
      ),
      child: Row(
        children: [
          // 🟢 عرض اسم الصيدلية المفتوحة
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xff1abc9c).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.local_pharmacy_rounded,
                  color: Color(0xff1abc9c),
                  size: 26,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                pharmacyName.isNotEmpty ? pharmacyName : "جارِ التحميل...",
                style: GoogleFonts.tajawal(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xff2c3e50),
                ),
              ),
            ],
          ),

          // 🟢 عرض اسم الصفحة الحالية بجانب اسم الصيدلية
          if (pageTitle != null) ...[
            const SizedBox(width: 16),
            Text(
              "|",
              style: TextStyle(
                color: Colors.grey.shade400,
                fontSize: 20,
              ),
            ),
            const SizedBox(width: 16),
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: Colors.grey[600]),
                  const SizedBox(width: 8),
                ],
                Text(
                  pageTitle!,
                  style: GoogleFonts.tajawal(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
              ],
            ),
          ],

          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}