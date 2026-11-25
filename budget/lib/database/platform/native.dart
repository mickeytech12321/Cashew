import 'package:budget/database/backupValidation.dart';
import 'package:budget/database/platform/stagedNativeRestore.dart';
// native.dart
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'dart:io';

Future<FinanceDatabase> constructDb(String dbName,
    {Uint8List? initialDataWeb}) async {
  final dbFolder = await getApplicationDocumentsDirectory();
  final file = File(p.join(dbFolder.path, '$dbName.sqlite'));
  if (dbName == 'db') {
    await applyPendingNativeRestore(file, onApplied: () async {
      final cursorCleared =
          await sharedPreferences.setString('dateOfLastSyncedWithClient', '{}');
      final eventSaved =
          await sharedPreferences.setBool('nativeBackupRestoreApplied', true);
      if (!cursorCleared || !eventSaved) {
        throw StateError('Could not save restored database preferences');
      }
    });
  }
  final db = LazyDatabase(() async {
    // return NativeDatabase(file);
    QueryExecutor foregroundExecutor = NativeDatabase(file);
    QueryExecutor backgroundExecutor = NativeDatabase.createInBackground(file);
    return MultiExecutor(read: foregroundExecutor, write: backgroundExecutor);
  });
  return FinanceDatabase(db);
}

Future<FinanceDatabase> constructHouseholdDb() async {
  final Directory folder;
  if (Platform.isAndroid) {
    const storage = MethodChannel('cashew/household_storage');
    final path = await storage.invokeMethod<String>('directory');
    if (path == null || path.isEmpty) {
      throw StateError('Household storage directory is unavailable');
    }
    folder = Directory(path);
  } else {
    folder = await getApplicationSupportDirectory();
  }
  final file = File(p.join(folder.path, 'household-sharing.sqlite'));
  return FinanceDatabase(NativeDatabase.createInBackground(file));
}

Future<T> readCashewSyncSnapshot<T>(
  Uint8List bytes, Future<T> Function(FinanceDatabase) read, {
  Directory? scratch,
}) async {
  validateCashewBackupHeader(bytes);
  final root = scratch ?? await getTemporaryDirectory();
  final folder = await root.createTemp('cashew-sync-');
  FinanceDatabase? candidate;
  try {
    final file = File(p.join(folder.path, 'snapshot.sqlite'));
    await file.writeAsBytes(bytes);
    candidate = FinanceDatabase(NativeDatabase.createInBackground(file));
    await validateCashewBackupDatabase(candidate);
    return await read(candidate);
  } finally {
    try {
      await candidate?.close();
    } finally {
      await folder.delete(recursive: true);
    }
  }
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
  await stageNativeRestore(await _defaultDatabaseFile(), dataStore);
}

Future<void> discardPendingDatabaseRestore() async {
  await discardPendingNativeRestore(await _defaultDatabaseFile());
}

Future<({bool previous, bool rejected})> databaseRestoreStatus() async {
  final live = await _defaultDatabaseFile();
  return (
    previous: await previousNativeRestoreFile(live).exists(),
    rejected: await rejectedNativeRestoreFile(live).exists(),
  );
}

Future<void> stagePreviousDatabaseRestore() async {
  final live = await _defaultDatabaseFile();
  await stageNativeRestore(live, await previousNativeRestoreFile(live).readAsBytes());
}

Future<void> dismissRejectedDatabaseRestore() async {
  final rejected = rejectedNativeRestoreFile(await _defaultDatabaseFile());
  if (await rejected.exists()) await rejected.delete();
}

Future<File> _defaultDatabaseFile() async {
  final folder = await getApplicationDocumentsDirectory();
  return File(p.join(folder.path, 'db.sqlite'));
}
