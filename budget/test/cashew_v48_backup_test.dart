import 'dart:io';
import 'dart:typed_data';

import 'package:budget/database/backupValidation.dart';
import 'package:budget/database/platform/stagedNativeRestore.dart';
import 'package:budget/database/tables.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory working;
  late File live;
  late File source;

  setUp(() async {
    working = await Directory.systemTemp.createTemp('cashew-v48-test-');
    live = File('${working.path}/live.sqlite');
    source = File('${working.path}/source.sqlite');
    final db = FinanceDatabase(NativeDatabase(source));
    try {
      await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('upstream'), name: 'Imported', order: 0));
      await db.into(db.categories).insert(CategoriesCompanion.insert(
          categoryPk: const Value('daily'), name: 'Daily', order: 0));
      await db.into(db.transactions).insert(Transaction(
          transactionPk: 'original',
          walletFk: 'upstream',
          categoryFk: 'daily',
          name: 'Original entry',
          amount: -30,
          note: '',
          dateCreated: DateTime(2026, 11, 25),
          income: false,
          paid: true,
          skipPaid: false));
    } finally {
      await db.close();
    }
    final upstream = sqlite.sqlite3.open(source.path);
    try {
      upstream.execute(
          'ALTER TABLE wallets ADD COLUMN archived INTEGER NOT NULL DEFAULT 0');
      upstream.execute('UPDATE wallets SET archived = 1');
      upstream.execute('ALTER TABLE wallets ADD COLUMN emoji_icon_name TEXT');
      upstream.execute(
          'ALTER TABLE categories ADD COLUMN archived INTEGER NOT NULL DEFAULT 0');
      upstream.execute(
          'ALTER TABLE associated_titles ADD COLUMN archived INTEGER NOT NULL DEFAULT 0');
      upstream.execute(
          'ALTER TABLE scanner_templates ADD COLUMN default_title TEXT');
      upstream.execute('CREATE TABLE tags (tag_pk TEXT PRIMARY KEY)');
      upstream.execute('CREATE TABLE transaction_to_tag_links '
          '(transaction_pk TEXT, tag_pk TEXT, PRIMARY KEY (transaction_pk, tag_pk))');
      final ownedTables =
          db.allTables.map((table) => table.actualTableName).toSet();
      final tables = upstream.select("SELECT name FROM sqlite_master WHERE "
          "type = 'table' AND name NOT GLOB 'sqlite_*'");
      for (final row in tables) {
        final table = row['name'] as String;
        if (!ownedTables.contains(table) &&
            table != 'tags' &&
            table != 'transaction_to_tag_links') {
          upstream.execute('DROP TABLE "$table"');
        }
      }
      upstream.execute('PRAGMA user_version = 48');
    } finally {
      upstream.dispose();
    }
  });

  tearDown(() => working.delete(recursive: true));

  test(
      'v48 full restore keeps untagged financial records and leaves source bytes intact',
      () async {
    final original = await source.readAsBytes();
    expect(() => validateCashewBackupHeader(original), throwsFormatException);
    await stageNativeRestore(live, original);
    final staged = pendingNativeRestoreFile(live);
    final bytes = await staged.readAsBytes();
    expect(ByteData.sublistView(bytes).getUint32(60), schemaVersionGlobal);
    expect(await applyPendingNativeRestore(live), isTrue);
    final db = FinanceDatabase(NativeDatabase(live));
    try {
      expect((await db.getWalletInstance('upstream')).name, 'Imported');
      expect((await db.getTransactionFromPk('original')).amount, -30);
      expect((await db.getAccountDetails('upstream'))?['archived'], 1);
    } finally {
      await db.close();
    }
    expect(await source.readAsBytes(), original);
  });

  test(
      'v48 with tags, changed layouts and unknown versions leave staging intact',
      () async {
    final original = await source.readAsBytes();
    await stageNativeRestore(live, original);
    final staged = pendingNativeRestoreFile(live);
    final before = await staged.readAsBytes();
    final upstream = sqlite.sqlite3.open(source.path);
    try {
      upstream.execute("INSERT INTO tags VALUES ('saved')");
      await expectLater(stageNativeRestore(live, await source.readAsBytes()),
          throwsA(isA<CashewBackupUnsupportedData>()));
      upstream.execute('DELETE FROM tags');
      upstream.execute("UPDATE wallets SET emoji_icon_name = 'emoji'");
      await expectLater(stageNativeRestore(live, await source.readAsBytes()),
          throwsA(isA<CashewBackupUnsupportedData>()));
      upstream.execute('UPDATE wallets SET emoji_icon_name = NULL');
      upstream.execute('ALTER TABLE wallets ADD COLUMN new_data TEXT');
      await expectLater(stageNativeRestore(live, await source.readAsBytes()),
          throwsA(isA<CashewBackupVersionException>()));
      upstream.execute('PRAGMA user_version = 49');
      await expectLater(stageNativeRestore(live, await source.readAsBytes()),
          throwsA(isA<CashewBackupVersionException>()));
    } finally {
      upstream.dispose();
    }
    expect(await staged.readAsBytes(), before);
  });
}
