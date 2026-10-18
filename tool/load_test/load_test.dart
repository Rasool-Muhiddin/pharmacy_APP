// ignore_for_file: invalid_use_of_visible_for_testing_member — أداة تُشغَّل عبر flutter test وتستخدم خطافات القاعدة المخصصة للاختبار (مسار بديل/إعادة فتح).
// أداة اختبار الحمل لصيدلية أوفلاين واحدة على قاعدة SQLite المحلية.
//
// التشغيل (من جذر المشروع، والتطبيق مغلق):
//   flutter test tool/load_test/load_test.dart \
//     --dart-define=LT_ACTION=generate|cleanup|restore|measure \
//     --dart-define=LT_DB="<مسار pharmacy.db>" --dart-define=LT_PHARMACY=4 \
//     --dart-define=LT_OWNER=<اسم المالك> --dart-define=LT_STAFF=<اسم الموظف>
//   restore يحتاج أيضاً --dart-define=LT_BACKUP="<مسار النسخة>".
//
// generate: نسخة احتياطية مختومة بالوقت ← حفظ أعلى معرّف لكل جدول (ملف حالة
//   خارج المستودع) ← توليد سنة من البيانات عبر منطق التطبيق (generator.dart).
// cleanup: يحذف فقط الصفوف الأعلى من تلك المعرّفات (بيانات التوليد وحدها).
// restore: يعيد نسخة احتياطية كما هي.
// measure: يقيس زمن تحميل/بحث الشاشات الرئيسية (measure.dart).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_app/database/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'generator.dart';
import 'load_test_common.dart';
import 'measure.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  void log(String message) => stdout.writeln('[load-test] $message');

  Future<void> open() async {
    DatabaseHelper.databasePathOverride = LoadTestConfig.dbPath;
    await DatabaseHelper.resetForTesting();
    DatabaseHelper.instance.setSessionMode(isOnline: false);
    await DatabaseHelper.instance.database;
  }

  tearDownAll(DatabaseHelper.resetForTesting);

  switch (LoadTestConfig.action) {
    case 'generate':
      test('generate', () async {
        LoadTestConfig.validate(users: true);
        await assertAppClosed();
        LoadTestConfig.require(readState() == null,
            'يوجد توليد سابق (${LoadTestConfig.stateFile}) — شغّل cleanup أو restore أولاً.');
        final sizeBefore = fileSizeMb(LoadTestConfig.dbPath);
        final backup = '${File(LoadTestConfig.stateFile).parent.path}${Platform.pathSeparator}'
            'pharmacy_before_generate_${stamp(DateTime.now())}.db';
        File(backup).parent.createSync(recursive: true);
        File(LoadTestConfig.dbPath).copySync(backup);
        log('Backup: $backup');

        await open();
        final countsBefore = await tableCounts();
        writeState({
          'pharmacy_id': LoadTestConfig.pharmacyId,
          'started_at': DateTime.now().toIso8601String(),
          'backup': backup,
          'watermarks': await tableWatermarks(),
          'counts_before': countsBefore,
          'size_mb_before': sizeBefore,
        });

        final db = await DatabaseHelper.instance.database;
        // أسرع للكتابة الكثيفة (كل عملية تبقى في معاملتها الخاصة كما في التطبيق)؛
        // يُعاد للوضع الافتراضي بعدها. أي انقطاع: النسخة الاحتياطية أعلاه.
        await db.execute('PRAGMA synchronous = OFF');
        final watch = Stopwatch()..start();
        final stats = await LoadTestGenerator(log: log).run();
        await db.execute('PRAGMA synchronous = FULL');
        final countsAfter = await tableCounts();
        await DatabaseHelper.resetForTesting();
        final state = readState()!
          ..['finished_at'] = DateTime.now().toIso8601String()
          ..['duration_seconds'] = watch.elapsed.inSeconds
          ..['stats'] = stats
          ..['counts_after'] = countsAfter
          ..['size_mb_after'] = fileSizeMb(LoadTestConfig.dbPath);
        writeState(state);
        log('Counts before: $countsBefore');
        log('Counts after:  $countsAfter');
        log('DB size: $sizeBefore MB → ${state['size_mb_after']} MB; took ${watch.elapsed.inSeconds}s');
      }, timeout: Timeout.none);

    case 'cleanup':
      test('cleanup', () async {
        LoadTestConfig.validate();
        await assertAppClosed();
        final state = readState();
        LoadTestConfig.require(state != null, 'لا يوجد ملف حالة (${LoadTestConfig.stateFile}).');
        LoadTestConfig.require(state!['pharmacy_id'] == LoadTestConfig.pharmacyId, 'ملف الحالة لصيدلية أخرى.');
        final marks = (state['watermarks'] as Map).cast<String, int>();
        await open();
        final db = await DatabaseHelper.instance.database;
        await db.transaction((txn) async {
          for (final table in generatedTables) {
            final n = await txn.rawDelete('DELETE FROM $table WHERE id > ?', [marks[table]]);
            log('$table: deleted $n');
          }
        });
        log('Counts now: ${await tableCounts()} (before generate: ${state['counts_before']})');
        await DatabaseHelper.resetForTesting();
        File(LoadTestConfig.stateFile).deleteSync();
      }, timeout: Timeout.none);

    case 'restore':
      test('restore', () async {
        LoadTestConfig.validate();
        await assertAppClosed();
        const backup = LoadTestConfig.backupPath;
        LoadTestConfig.require(backup.isNotEmpty && File(backup).existsSync(), 'LT_BACKUP غير موجود: "$backup"');
        await DatabaseHelper.resetForTesting();
        File(backup).copySync(LoadTestConfig.dbPath);
        final state = File(LoadTestConfig.stateFile);
        if (state.existsSync()) state.deleteSync();
        log('Restored $backup → ${LoadTestConfig.dbPath}');
      });

    case 'measure':
      measureScreens(log: log, open: open);

    default:
      test('usage', () => fail('LT_ACTION مطلوب: generate | cleanup | restore | measure'));
  }
}
