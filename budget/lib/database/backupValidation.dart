import 'dart:typed_data';

import 'package:budget/database/tables.dart';

void validateCashewBackupHeader(Uint8List bytes) {
  const header = 'SQLite format 3\u0000';
  if (bytes.length < 100 || String.fromCharCodes(bytes.take(16)) != header) {
    throw const FormatException('The selected file is not a SQLite backup.');
  }
  final version = ByteData.sublistView(bytes).getUint32(60, Endian.big);
  if (version == 0 || version > schemaVersionGlobal) {
    throw const FormatException('This backup uses an unsupported Cashew schema.');
  }
}

Future<void> validateCashewBackupDatabase(FinanceDatabase candidate) async {
  final check = await candidate.customSelect('PRAGMA quick_check(1)').get();
  if (check.length != 1 || check.single.data.values.single != 'ok') {
    throw const FormatException('The selected backup is corrupted.');
  }
  final tables = await candidate.customSelect(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name IN ('wallets', 'transactions', 'categories')",
  ).get();
  if (tables.length != 3) {
    throw const FormatException('The selected database is missing Cashew data tables.');
  }
  await candidate.customSelect('SELECT wallet_pk, name FROM wallets LIMIT 1').get();
  await candidate.customSelect(
    'SELECT transaction_pk, wallet_fk, category_fk, amount FROM transactions LIMIT 1',
  ).get();
  await candidate.customSelect('SELECT category_pk, name FROM categories LIMIT 1').get();
}
