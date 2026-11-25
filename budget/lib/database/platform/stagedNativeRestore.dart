import 'dart:io';
import 'dart:typed_data';

import 'package:budget/database/backupValidation.dart';
import 'package:budget/database/tables.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

File pendingNativeRestoreFile(File live) => File('${live.path}.restore');
File previousNativeRestoreFile(File live) =>
    File('${live.path}.before-restore');
File rejectedNativeRestoreFile(File live) =>
    File('${live.path}.restore-rejected');

File _applying(File live) => File('${live.path}.restore-applying');
File _applied(File live) => File('${live.path}.restore-applied');
File _checkpoint(File live) => File('${live.path}.restore-checkpoint');
Directory _restoreWork(File live) => Directory('${live.path}.restore-work');

Future<Directory> _temporaryRestoreDirectory(File live) async {
  final work = await _restoreWork(live).create(recursive: true);
  return work.createTemp();
}

/// Validate and migrate an isolated candidate before publishing it for startup.
Future<void> stageNativeRestore(File live, Uint8List bytes) async {
  validateCashewBackupHeader(bytes);
  final temporary = await _temporaryRestoreDirectory(live);
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

Future<sqlite.Database> _openPendingRestore(File file) async {
  final header = await file.open();
  try {
    validateCashewBackupHeader(await header.read(100));
  } finally {
    await header.close();
  }
  final db = sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
  try {
    final check = db.select('PRAGMA quick_check(1)');
    if (check.length != 1 || check.single.values.single != 'ok') {
      throw const FormatException('The pending backup is corrupted.');
    }
    return db;
  } catch (_) {
    db.dispose();
    rethrow;
  }
}

Future<void> _copyDatabase(sqlite.Database source, File targetFile) async {
  final target = sqlite.sqlite3.open(targetFile.path);
  try {
    await source.backup(target, nPage: -1).drain<void>();
  } finally {
    target.dispose();
  }
}

Future<void> _saveCheckpoint(File live) async {
  if (await _checkpoint(live).exists() || !await live.exists()) return;
  // A checkpoint must include committed WAL data, even after a forced exit.
  final temporary = await _temporaryRestoreDirectory(live);
  try {
    final target = File(p.join(temporary.path, 'checkpoint.sqlite'));
    final source =
        sqlite.sqlite3.open(live.path, mode: sqlite.OpenMode.readOnly);
    try {
      await _copyDatabase(source, target);
    } finally {
      source.dispose();
    }
    await target.rename(_checkpoint(live).path);
  } on sqlite.SqliteException catch (error) {
    // An intact backup can still recover an already corrupted installation.
    if (!_isCorruption(error)) rethrow;
  } finally {
    await temporary.delete(recursive: true);
  }
}

bool _isCorruption(sqlite.SqliteException error) =>
    error.resultCode == 11 || error.resultCode == 26; // CORRUPT, NOTADB.

Future<void> _finishRestore(
    File live, Future<void> Function()? onApplied) async {
  final checkpoint = _checkpoint(live);
  if (await checkpoint.exists()) {
    await checkpoint.rename(previousNativeRestoreFile(live).path);
  }
  await onApplied?.call();
  await _applied(live).delete();
}

/// Run before constructing the primary Drift connection. Keep the checkpoint
/// unchanged until the replacement has completed, including across a retry.
Future<bool> applyPendingNativeRestore(
  File live, {
  Future<void> Function()? onApplied,
}) async {
  if (await _applied(live).exists()) {
    await _finishRestore(live, onApplied);
    return true;
  }

  final pending = pendingNativeRestoreFile(live);
  final applying = _applying(live);
  if (!await applying.exists()) {
    if (!await pending.exists()) return false;
    await pending.rename(applying.path);
  }
  final sqlite.Database source;
  try {
    source = await _openPendingRestore(applying);
  } on FormatException {
    await _rejectRestore(live);
    return false;
  } on sqlite.SqliteException catch (error) {
    if (!_isCorruption(error)) rethrow;
    await _rejectRestore(live);
    return false;
  }

  try {
    await _saveCheckpoint(live);
    await _copyDatabase(source, live);
  } finally {
    source.dispose();
  }
  await applying.rename(_applied(live).path);
  await _finishRestore(live, onApplied);
  return true;
}

Future<void> _rejectRestore(File live) async {
  final checkpoint = _checkpoint(live);
  if (await checkpoint.exists()) {
    await checkpoint.rename(previousNativeRestoreFile(live).path);
  }
  await _applying(live).rename(rejectedNativeRestoreFile(live).path);
}

Future<void> discardPendingNativeRestore(File live) async {
  for (final file in [
    pendingNativeRestoreFile(live),
    _applying(live),
    _applied(live),
    _checkpoint(live),
    previousNativeRestoreFile(live),
    rejectedNativeRestoreFile(live),
  ]) {
    if (await file.exists()) await file.delete();
  }
  final work = _restoreWork(live);
  if (await work.exists()) await work.delete(recursive: true);
}

Future<void> deletePreviousNativeRestore(File live) async {
  final previous = previousNativeRestoreFile(live);
  if (await previous.exists()) await previous.delete();
}
