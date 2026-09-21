import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../database/db_helper.dart';

/// خدمة النسخ الاحتياطي المحلي اليومي لقاعدة بيانات الصيدلية.
///
/// تُنشئ نسخة سليمة (عبر VACUUM INTO) مرة واحدة يومياً بمجلد منفصل
/// عن قاعدة البيانات الأصلية، وتحذف النسخ الأقدم من [keepDays] يوم.
class BackupService {
  BackupService._();

  static const int keepDays = 7;
  static const String _lastBackupFileName = 'last_backup.txt';
  static const String _backupFolderName = 'pharmacy_backups';

  /// يُستدعى عند بداية تشغيل التطبيق (بعد فتح القاعدة).
  /// لا يرمي استثناء للخارج أبداً — أي فشل يُسجَّل فقط ولا يوقف التطبيق.
  static Future<void> runDailyBackupIfNeeded() async {
    try {
      final lastBackupDate = await _readLastBackupDate();
      final today = DateTime.now();

      if (lastBackupDate != null && _isSameDay(lastBackupDate, today)) {
        return; // خذنا نسخة اليوم already
      }

      final backupPath = await _createBackup();
      if (backupPath != null) {
        await _cleanOldBackups();
        await _writeLastBackupDate(today);
      }
    } catch (e) {
      // لا نوقف التطبيق أبداً بسبب فشل النسخ الاحتياطي
      // ignore: avoid_print
      print('BackupService: فشل النسخ الاحتياطي اليومي - $e');
    }
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static Future<Directory> _getBackupDir() async {
    final supportDir = await getApplicationSupportDirectory();
    final backupDir = Directory(p.join(supportDir.path, _backupFolderName));
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    return backupDir;
  }

  /// ينشئ نسخة احتياطية جديدة ويتحقق من سلامتها.
  /// يرجع مسار النسخة إذا نجحت، أو null إذا فشلت (وتُحذف النسخة التالفة تلقائياً).
  static Future<String?> _createBackup() async {
    final db = await DatabaseHelper.instance.database;
    final backupDir = await _getBackupDir();

    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final backupPath = p.join(backupDir.path, 'pharmacy_$dateStr.db');

    // لو فيه نسخة بنفس الاسم من محاولة سابقة فاشلة، احذفها أولاً
    final existing = File(backupPath);
    if (await existing.exists()) {
      await existing.delete();
    }

    // VACUUM INTO تعمل نسخة سليمة ومتسقة حتى لو القاعدة مفتوحة حالياً
    await db.execute("VACUUM INTO '${backupPath.replaceAll("'", "''")}'");

    // التحقق من سلامة النسخة قبل اعتمادها
    final isValid = await _verifyBackup(backupPath);
    if (!isValid) {
      if (await existing.exists()) {
        await existing.delete();
      }
      // ignore: avoid_print
      print('BackupService: النسخة الاحتياطية فشلت بفحص السلامة، تم حذفها');
      return null;
    }

    return backupPath;
  }

  static Future<bool> _verifyBackup(String backupPath) async {
    Database? backupDb;
    try {
      backupDb = await openDatabase(backupPath, readOnly: true);
      final result = await backupDb.rawQuery('PRAGMA integrity_check');
      final status = result.first.values.first as String;
      return status == 'ok';
    } catch (_) {
      return false;
    } finally {
      await backupDb?.close();
    }
  }

  static Future<void> _cleanOldBackups() async {
    final backupDir = await _getBackupDir();
    final cutoff = DateTime.now().subtract(const Duration(days: keepDays));

    await for (final entity in backupDir.list()) {
      if (entity is File && entity.path.endsWith('.db')) {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
    }
  }

  static Future<DateTime?> _readLastBackupDate() async {
    try {
      final backupDir = await _getBackupDir();
      final file = File(p.join(backupDir.path, _lastBackupFileName));
      if (!await file.exists()) return null;

      final content = (await file.readAsString()).trim();
      if (content.isEmpty) return null;

      return DateTime.tryParse(content);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeLastBackupDate(DateTime date) async {
    final backupDir = await _getBackupDir();
    final file = File(p.join(backupDir.path, _lastBackupFileName));
    await file.writeAsString(date.toIso8601String());
  }

  /// يرجع قائمة بمسارات النسخ الاحتياطية الموجودة حالياً، الأحدث أولاً.
  /// مفيدة لاحقاً لواجهة "استعادة نسخة احتياطية".
  static Future<List<File>> listBackups() async {
    final backupDir = await _getBackupDir();
    final files = <File>[];

    await for (final entity in backupDir.list()) {
      if (entity is File && entity.path.endsWith('.db')) {
        files.add(entity);
      }
    }

    files.sort((a, b) => b.path.compareTo(a.path)); // الأحدث أولاً (بالاسم اليومي)
    return files;
  }
}