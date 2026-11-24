// unsupported.dart
import 'dart:typed_data';
import 'package:budget/database/tables.dart';

Future<FinanceDatabase> constructDb(String dbName,
        {Uint8List? initialDataWeb}) =>
    throw UnimplementedError();

Future<DBFileInfo> getCurrentDBFileInfo({bool omitImportMessageBodies = false}) => throw UnimplementedError();

Future overwriteDefaultDB(Uint8List dataStore) => throw UnimplementedError();

Future<void> discardPendingDatabaseRestore() async {}
