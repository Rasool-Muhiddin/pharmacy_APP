import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class CustomTable extends StatelessWidget {
  final List<String> headers;
  final List<List<Widget>> rows;

  const CustomTable({
    super.key,
    required this.headers,
    required this.rows,
  });

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
                children: headers.map((header) {
                  return Expanded(
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
                      children: row.map((cell) {
                        return Expanded(
                          child: Center(child: cell),
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