import 'dart:io';
import 'dart:typed_data';

import 'package:budget/database/backupValidation.dart';
import 'package:budget/database/tables.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

File pendingNativeRestoreFile(File live) => File('${live.path}.restore');

/// Validate and migrate an isolated candidate before publishing it for startup.
Future<void> stageNativeRestore(File live, Uint8List bytes) async {
  validateCashewBackupHeader(bytes);
  final temporary = await live.parent.createTemp('cashew-restore-');
  try {
    final candidate = await File(p.join(temporary.path, 'candidate.sqlite'))
        .writeAsBytes(bytes, flush: true);
    final db = FinanceDatabase(NativeDatabase.createInBackground(candidate));
    try {
      await validateCashewBackupDatabase(db);
    } finally {
      await db.close();
    }
    await candidate.rename(pendingNativeRestoreFile(live).path);
  } finally {
    await temporary.delete(recursive: true);
  }
}

/// Run before constructing the primary Drift connection.
Future<bool> applyPendingNativeRestore(File live) async {
  final pending = pendingNativeRestoreFile(live);
  if (!await pending.exists()) return false;
  final headerFile = await pending.open();
  try {
    validateCashewBackupHeader(await headerFile.read(100));
  } finally {
    await headerFile.close();
  }

  final source =
      sqlite.sqlite3.open(pending.path, mode: sqlite.OpenMode.readOnly);
  try {
    final check = source.select('PRAGMA quick_check(1)');
    if (check.length != 1 || check.single.values.single != 'ok') {
      throw const FormatException('The pending backup is corrupted.');
    }
    final target = sqlite.sqlite3.open(live.path);
    try {
      // This updates the destination through SQLite, including its journal.
      await source.backup(target, nPage: -1).drain<void>();
    } finally {
      target.dispose();
    }
  } finally {
    source.dispose();
  }
  await pending.delete();
  return true;
}

Future<void> discardPendingNativeRestore(File live) async {
  final pending = pendingNativeRestoreFile(live);
  if (await pending.exists()) await pending.delete();
}
