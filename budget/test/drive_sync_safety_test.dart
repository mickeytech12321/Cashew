import 'dart:io';
import 'dart:typed_data';

import 'package:budget/database/platform/native.dart' as native;
import 'package:budget/database/tables.dart';
import 'package:budget/struct/syncClient.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  final first = DateTime.utc(2026, 11, 22);
  final deleted = DateTime.utc(2026, 11, 23);
  final restored = DateTime.utc(2026, 11, 24);

  test(
      'identical model names have independent Drive cursors and old cursors cannot win',
      () {
    const name1 = 'sync-Xiaomi_Redmi-1764001000000.sqlite';
    const name2 = 'sync-Xiaomi_Redmi-1764002000000.sqlite';
    final one = syncBackupClientId(name1)!;
    final two = syncBackupClientId(name2)!;
    expect(one, isNot(two));
    expect(getDeviceFromSyncBackupFileName(name1),
        getDeviceFromSyncBackupFileName(name2));
    expect(isSyncBackupFile('cashew-sync-foo.sqlite'), isFalse);
    expect(isSyncBackupFile('sync-.sqlite'), isFalse);
    expect(isSyncBackupFile('sync-foo.sqlite.zip'), isFalse);
    expect(isSyncBackupFile('sync-foo/bar.sqlite'), isFalse);
    expect(readSyncCursors('invalid json'), isEmpty);
    expect(readSyncCursors('[]'), isEmpty);
    final cursors =
        readSyncCursors('{"bad":1,"Xiaomi_Redmi":"2026-11-25T00:00:00Z"}');
    expect(cursors.keys, ['Xiaomi_Redmi']);
    expect(cursors[one], isNull);
    expect(
        advanceSyncCursors(
            {one: restored, two: first}, {one: deleted, two: deleted}),
        {one: restored, two: deleted});
  });

  test(
      'sync opens a verified isolated snapshot and cleans it after success or failure',
      () async {
    final root = await Directory.systemTemp.createTemp('cashew-drive-test');
    addTearDown(() => root.delete(recursive: true));
    final origin = File('${root.path}/origin.sqlite');
    final db = FinanceDatabase(NativeDatabase(origin));
    await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('seed'),
          name: 'Seed',
          order: 0,
        ));
    await db.close();
    final backup = await origin.readAsBytes();
    final imported = await native.readCashewSyncSnapshot(
        backup, (candidate) => candidate.getAllWallets(),
        scratch: root);
    expect(imported.single.name, 'Seed');
    await expectLater(
        native.readCashewSyncSnapshot(
            backup, (_) async => throw StateError('read interrupted'),
            scratch: root),
        throwsStateError);

    final wrong = File('${root.path}/unrelated.sqlite');
    final wrongDb = sqlite.sqlite3.open(wrong.path);
    wrongDb.execute(
        'CREATE TABLE unrelated(id INTEGER); PRAGMA user_version = 47;');
    wrongDb.dispose();
    await expectLater(
        native.readCashewSyncSnapshot(await wrong.readAsBytes(),
            (_) async => fail('invalid schema was opened for import'),
            scratch: root),
        throwsFormatException);
    await expectLater(
        native.readCashewSyncSnapshot(Uint8List(100),
            (_) async => fail('invalid header was opened for import'),
            scratch: root),
        throwsFormatException);
    expect(await root.list().where((entry) => entry is Directory).toList(),
        isEmpty);
  });

  test(
      'typed tracked metadata deletions prevent stale resurrection after a new pull',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    SyncLog wallet(String id, DateTime at, String name) => SyncLog(
          pk: id,
          updateLogType: UpdateLogType.TransactionWallet,
          transactionDateTime: at,
          itemToUpdate: TransactionWallet(
              walletPk: id,
              name: name,
              dateCreated: first,
              order: 0,
              decimals: 2,
              dateTimeModified: at),
        );
    SyncLog deleteWallet(String id) => SyncLog(
          pk: id,
          deleteLogType: DeleteLogType.TransactionWallet,
          transactionDateTime: deleted,
        );
    final category = SyncLog(
      pk: 'common',
      updateLogType: UpdateLogType.TransactionCategory,
      transactionDateTime: first,
      itemToUpdate: TransactionCategory(
          categoryPk: 'common',
          name: 'Category',
          dateCreated: first,
          dateTimeModified: first,
          income: false,
          order: 0),
    );
    await db.processSyncLogs(
        [wallet('common', first, 'Original'), wallet('0', first, 'Main')]);
    await db.processSyncLogs([deleteWallet('common'), deleteWallet('0')]);
    await db.processSyncLogs([
      deleteWallet('common'),
      wallet('common', first, 'Old snapshot'),
      category
    ]);
    expect(await db.getWalletInstanceOrNull('common'), isNull);
    expect((await db.getCategoryInstanceOrNull('common'))?.name, 'Category');
    expect((await db.getWalletInstanceOrNull('0'))?.name, 'Main');
    expect((await db.getAllDeleteLogs()).map((log) => (log.type, log.entryPk)),
        [(DeleteLogType.TransactionWallet, 'common')]);
    await db.processSyncLogs([wallet('common', restored, 'New version')]);
    expect((await db.getWalletInstanceOrNull('common'))?.name, 'New version');
  });

  test(
      'scanner revisions survive stale deletes and local limit deletes log their own type',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.scannerTemplates).insert(ScannerTemplate(
          scannerTemplatePk: 'scanner',
          dateCreated: first,
          dateTimeModified: restored,
          templateName: 'Current template',
          contains: 'Payment',
          titleTransactionBefore: '',
          titleTransactionAfter: '',
          amountTransactionBefore: '',
          amountTransactionAfter: '',
          defaultCategoryFk: '0',
          walletFk: '0',
          ignore: false,
        ));
    await db.processSyncLogs([
      SyncLog(
        pk: 'scanner',
        transactionDateTime: deleted,
        deleteLogType: DeleteLogType.ScannerTemplate,
      )
    ]);
    expect((await db.getScannerTemplateInstance('scanner')).templateName,
        'Current template');
    await db.into(db.categoryBudgetLimits).insert(CategoryBudgetLimit(
          categoryLimitPk: 'limit',
          categoryFk: 'category',
          budgetFk: 'budget',
          amount: 100,
          walletFk: '0',
        ));
    await db.deleteCategoryBudgetLimitsInBudget('budget');
    expect(await db.select(db.categoryBudgetLimits).get(), isEmpty);
    expect(
        (await db.getAllDeleteLogs())
            .where((log) => log.entryPk == 'limit')
            .single
            .type,
        DeleteLogType.CategoryBudgetLimit);
  });
}
