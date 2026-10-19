import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class CustomTable extends StatelessWidget {
  final List<String> headers;
  final List<List<Widget>> rows;

  /// نسبة عرض كل عمود (افتراضياً متساوية)، مثلاً [3, 2, 1] يعطي العمود الأول مساحة أكبر.
  final List<int>? flex;

  const CustomTable({
    super.key,
    required this.headers,
    required this.rows,
    this.flex,
  });

  int _flexAt(int i) => (flex != null && i < flex!.length) ? flex![i] : 1;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: const Color(0xffEDF2F7),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          children: [

            // Header
            Container(
              color: const Color(0xffF7FAFC),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: headers.asMap().entries.map((e) {
                  final header = e.value;
                  return Expanded(
                    flex: _flexAt(e.key),
                    child: Text(
                      header,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.tajawal(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: const Color(0xff4A5568),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

            const Divider(
              height: 1,
              thickness: 1,
            ),

            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 25),
                child: Text(
                  "لا توجد بيانات",
                  style: GoogleFonts.tajawal(
                    fontSize: 14,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),

            ...rows.map(
              (row) => Column(
                children: [

                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                    ),
                    child: Row(
                      children: row.asMap().entries.map((e) {
                        return Expanded(
                          flex: _flexAt(e.key),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Center(child: e.value),
                          ),
                        );
                      }).toList(),
                    ),
                  ),

                  const Divider(
                    height: 1,
                    thickness: 1,
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