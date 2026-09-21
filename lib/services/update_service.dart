import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'desktop_api_service.dart';

class UpdateService {
  UpdateService._();

  /// يفحص وجود تحديث جديد، وإن وُجد يعرض Dialog للمستخدم.
  /// آمن للاستدعاء بدون انتظار (fire-and-forget) — لا يوقف فتح التطبيق.
  static Future<void> checkForUpdate(BuildContext context) async {
    try {
      final info = await DesktopApiService.instance.checkLatestVersion();
      final remoteVersion = info['version'] as String? ?? '';
      final downloadUrl = info['download_url'] as String? ?? '';
      final isMandatory = info['is_mandatory'] == true;

      if (remoteVersion.isEmpty || downloadUrl.isEmpty) return;

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version; // مثال: "1.0.0"

      if (!_isNewer(remoteVersion, currentVersion)) return;

      if (!context.mounted) return;

      _showUpdateDialog(
        context,
        version: remoteVersion,
        downloadUrl: downloadUrl,
        releaseNotes: info['release_notes'] as String? ?? '',
        isMandatory: isMandatory,
      );
    } catch (_) {
      // فشل الفحص (لا إنترنت مثلاً) لا يجب أن يعطل التطبيق أبداً
    }
  }

  /// مقارنة بسيطة لأرقام إصدار semver مثل "1.0.1" مقابل "1.0.0"
  static bool _isNewer(String remote, String current) {
    final r = remote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final c = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    for (var i = 0; i < 3; i++) {
      final rv = i < r.length ? r[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (rv != cv) return rv > cv;
    }
    return false;
  }

  static void _showUpdateDialog(
    BuildContext context, {
    required String version,
    required String downloadUrl,
    required String releaseNotes,
    required bool isMandatory,
  }) {
    showDialog(
      context: context,
      barrierDismissible: !isMandatory,
      builder: (dialogContext) => AlertDialog(
        title: const Text('يتوفر تحديث جديد'),
        content: Text(
          releaseNotes.isNotEmpty
              ? 'الإصدار $version متوفر الآن.\n\n$releaseNotes'
              : 'الإصدار $version متوفر الآن.',
        ),
        actions: [
          if (!isMandatory)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('لاحقاً'),
            ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _downloadAndInstall(context, downloadUrl, version);
            },
            child: const Text('تحديث الآن'),
          ),
        ],
      ),
    );
  }

  static Future<void> _downloadAndInstall(
    BuildContext context,
    String downloadUrl,
    String version,
  ) async {
    final progressNotifier = ValueNotifier<double>(0);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('جاري تنزيل التحديث...'),
        content: ValueListenableBuilder<double>(
          valueListenable: progressNotifier,
          builder: (_, value, __) => LinearProgressIndicator(value: value),
        ),
      ),
    );

    try {
      final tempDir = Directory.systemTemp;
      final savePath =
          '${tempDir.path}${Platform.pathSeparator}Tera_Pharmacy_Update_$version.exe';
      final file = File(savePath);

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(downloadUrl));
      final response = await request.close();

      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();

      await response.forEach((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          progressNotifier.value = received / total;
        }
      });

      await sink.close();
      client.close(force: true);

      if (context.mounted) Navigator.of(context).pop(); // اغلق dialog التنزيل

      // شغّل installer ثم أغلق التطبيق الحالي
      await Process.start(
        savePath,
        [],
        mode: ProcessStartMode.detached,
      );

      exit(0);
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل تنزيل التحديث: $e')),
        );
      }
    }
  }
}