import 'package:budget/database/platform/stagedNativeRestore.dart';
// native.dart
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:drift/drift.dart';
import 'dart:io';

Future<FinanceDatabase> constructDb(String dbName,
    {Uint8List? initialDataWeb}) async {
  final dbFolder = await getApplicationDocumentsDirectory();
  final file = File(p.join(dbFolder.path, '$dbName.sqlite'));
  if (dbName == 'db' && await applyPendingNativeRestore(file)) {
    await sharedPreferences.setString("dateOfLastSyncedWithClient", "{}");
  }
  final db = LazyDatabase(() async {
    // return NativeDatabase(file);
    QueryExecutor foregroundExecutor = NativeDatabase(file);
    QueryExecutor backgroundExecutor = NativeDatabase.createInBackground(file);
    return MultiExecutor(read: foregroundExecutor, write: backgroundExecutor);
  });
  return FinanceDatabase(db);
}

Future<DBFileInfo> getCurrentDBFileInfo({bool omitImportMessageBodies = false}) async {
  final folder = await (await getTemporaryDirectory()).createTemp('cashew-backup-');
  try {
    final file = File(p.join(folder.path, 'snapshot.sqlite'));
    await database.customStatement('VACUUM INTO ?', [file.path]);
    if (omitImportMessageBodies) {
      final backup = FinanceDatabase(NativeDatabase.createInBackground(file));
      try {
        await backup.omitImportMessageBodiesFromBackup();
      } finally {
        await backup.close();
      }
    }
    final bytes = await file.readAsBytes();
    return DBFileInfo(bytes, Stream.value(bytes));
  } finally {
    await folder.delete(recursive: true);
  }
}

Future<void> overwriteDefaultDB(Uint8List dataStore) async {
  final folder = await getApplicationDocumentsDirectory();
  await stageNativeRestore(File(p.join(folder.path, 'db.sqlite')), dataStore);
}

Future<void> discardPendingDatabaseRestore() async {
  final folder = await getApplicationDocumentsDirectory();
  await discardPendingNativeRestore(File(p.join(folder.path, 'db.sqlite')));
}
