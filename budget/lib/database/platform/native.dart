import 'package:budget/database/backupValidation.dart';
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
  // the LazyDatabase util lets us find the right location for the file async.
  final db = LazyDatabase(() async {
    // put the database file, called db.sqlite here, into the documents folder
    // for your app.
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, dbName + '.sqlite'));
    // return NativeDatabase(file);
    QueryExecutor foregroundExecutor = NativeDatabase(file);
    QueryExecutor backgroundExecutor = NativeDatabase.createInBackground(file);
    return MultiExecutor(read: foregroundExecutor, write: backgroundExecutor);
  });
  return FinanceDatabase(db);
}

Future<DBFileInfo> getCurrentDBFileInfo({bool omitImportMessageBodies = false}) async {
  if (omitImportMessageBodies) {
    final folder = await (await getTemporaryDirectory()).createTemp('cashew-drive-');
    try {
      final file = File(p.join(folder.path, 'snapshot.sqlite'));
      await database.customStatement('VACUUM INTO ?', [file.path]);
      final backup = FinanceDatabase(NativeDatabase.createInBackground(file));
      try {
        await backup.omitImportMessageBodiesFromBackup();
      } finally {
        await backup.close();
      }
      final bytes = await file.readAsBytes();
      return DBFileInfo(bytes, Stream.value(bytes));
    } finally {
      await folder.delete(recursive: true);
    }
  }

  Uint8List dbFileBytes;
  late Stream<List<int>> mediaStream;

  final dbFolder = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(dbFolder.path, 'db.sqlite'));
  //print("FILE SIZE:" + (dbFile.lengthSync() / 1e+6).toString());
  dbFileBytes = await dbFile.readAsBytes();
  mediaStream = Stream.value(List<int>.from(dbFileBytes));

  return DBFileInfo(dbFileBytes, mediaStream);
}

Future overwriteDefaultDB(Uint8List dataStore) async {
  validateCashewBackupHeader(dataStore);
  final scratch = await (await getTemporaryDirectory()).createTemp('cashew-restore-');
  try {
    final file = await File(p.join(scratch.path, 'candidate.sqlite')).writeAsBytes(dataStore);
    final candidate = FinanceDatabase(NativeDatabase.createInBackground(file));
    try {
      await validateCashewBackupDatabase(candidate);
    } finally {
      await candidate.close();
    }
  } finally {
    await scratch.delete(recursive: true);
  }
  final dbFolder = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(dbFolder.path, 'db.sqlite'));
  await dbFile.writeAsBytes(dataStore);
  // we need to be able to sync with others after the restore
  await sharedPreferences.setString("dateOfLastSyncedWithClient", "{}");
}
