// unsupported.dart
import 'dart:typed_data';
import 'package:budget/database/tables.dart';

Future<FinanceDatabase> constructDb(String dbName,
        {Uint8List? initialDataWeb}) =>
    throw UnimplementedError();

Future<FinanceDatabase> constructHouseholdDb() =>
    throw UnsupportedError('Household storage is unavailable on this platform.');

Future<T> readCashewSyncSnapshot<T>(
  Uint8List bytes, Future<T> Function(FinanceDatabase) read,
) => throw UnsupportedError('Sync snapshots are unavailable on this platform.');

Future<DBFileInfo> getCurrentDBFileInfo({bool omitImportMessageBodies = false}) => throw UnimplementedError();

Future overwriteDefaultDB(Uint8List dataStore) => throw UnimplementedError();

Future<void> discardPendingDatabaseRestore() async {}
