import 'package:budget/struct/investmentQuoteCsv.dart';
import 'package:budget/database/platform/stagedNativeRestore.dart';
import 'package:budget/struct/creditStatementCsv.dart';
import 'package:budget/database/backupValidation.dart';
import 'dart:typed_data';
import 'dart:async';
import 'package:budget/pages/transactionFilters.dart';
import 'package:budget/struct/syncClient.dart' show SyncLog;
import 'package:budget/struct/investmentLedger.dart';
import 'package:budget/struct/bankNotificationInbox.dart';
import 'dart:io';

import 'package:budget/database/schema_versions.dart';
import 'package:budget/database/tables.dart';
import 'package:drift/drift.dart' show MigrationStrategy, Migrator, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _Version46Database extends FinanceDatabase {
  _Version46Database(super.executor);

  @override
  int get schemaVersion => 46;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (_) => Migrator(this, Schema46(database: this)).createAll(),
      );
}

void main() {
  test('bank import keeps the stored schema-47 fingerprint value', () {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
      db.financialImportFingerprint(
        sourceType: ' SMS ',
        sender: 'CIB',
        rawText: ' Purchase EGP 125 ',
        occurredAt: DateTime.utc(2026, 11, 25, 9, 30),
      ),
      '769d4159e763bd0e',
    );
  });

  test('bank import pauses before linking a duplicate and can save a separate payment',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final time = DateTime(2026, 11, 25, 12);
    await db.into(db.wallets).insert(WalletsCompanion.insert(
        walletPk: const Value('wallet'), name: 'Wallet', order: 0,
        currency: const Value('egp')));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('daily'), name: 'Daily', order: 0));
    await db.into(db.transactions).insert(Transaction(
      transactionPk: 'existing', name: 'First payment', amount: -50,
      note: '', categoryFk: 'daily', walletFk: 'wallet', dateCreated: time,
      income: false, paid: true, skipPaid: false,
    ));
    await db.stageImportedFinancialEvent(
      eventPk: 'second', sourceType: 'manual', rawText: 'second payment',
      occurredAt: time, amount: 50, currency: 'egp', direction: 'debit',
    );
    Future<String> approve(ImportDuplicateAction action) =>
      db.approveImportedFinancialEvent(eventPk: 'second', transactionPk: 'new',
          categoryFk: 'daily', walletPk: 'wallet', duplicateAction: action);
    await expectLater(approve(ImportDuplicateAction.ask), throwsA(
      isA<ImportedTransactionMatch>().having(
        (match) => match.transaction.transactionPk, 'matching ID', 'existing'),
    ));
    expect(await db.getImportedFinancialEvents(), hasLength(1));
    expect(await db.select(db.transactions).get(), hasLength(1));
    expect(await approve(ImportDuplicateAction.saveSeparate), 'approved');
    expect(await db.select(db.transactions).get(), hasLength(2));
  });

  test('notification account links are app and currency scoped', () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final (id, currency) in [('bank', 'egp'), ('other', 'egp'), ('card', 'usd')]) {
      await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: Value(id), name: id, order: 0, currency: Value(currency)));
    }
    const package = 'com.example.Wallet';
    expect(await db.addImportNotificationLink('bank', package), isTrue);
    expect(await db.addImportNotificationLink('other', package), isFalse);
    expect(await db.addImportNotificationLink('card', package), isTrue);
    expect(await db.suggestImportedNotificationWallet(package, 'EGP'), 'bank');
    expect(await db.suggestImportedNotificationWallet(package, 'usd'), 'card');
    expect(await db.suggestImportedNotificationWallet(package.toLowerCase(), 'egp'), isNull);
    await db.setAccountArchived('bank', true);
    expect(await db.suggestImportedNotificationWallet(package, 'egp'), isNull);
    final links = await db.getImportNotificationLinks();
    expect(links, hasLength(2));
    await db.removeImportNotificationLink(links.firstWhere((l) => l.currency == 'usd').id);
    expect(await db.suggestImportedNotificationWallet(package, 'usd'), isNull);
  });

  test('import history pages deterministically and only restores ignored entries',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final date = DateTime(2026, 11, 24);
    for (final id in ['a', 'b', 'c']) {
      await db.stageImportedFinancialEvent(
        eventPk: id, sourceType: id == 'b' ? 'notification' : 'manual',
        rawText: 'message $id', occurredAt: date, amount: 5,
        currency: 'egp', direction: id == 'c' ? 'credit' : 'debit',
      );
    }
    expect((await db.getImportedFinancialEvents(limit: 1, offset: 1))
        .single['event_pk'], 'b');
    expect((await db.getImportedFinancialEvents(
        direction: 'debit', sourceType: 'notification')).single['event_pk'], 'b');
    await db.setImportedFinancialEventStatus('a', 'ignored');
    await db.setImportedFinancialEventStatus('b', 'approved', transactionFk: 'saved');
    expect(await db.restoreIgnoredFinancialEvent('b'), isFalse);
    expect(await db.restoreIgnoredFinancialEvent('a'), isTrue);
    expect(await db.restoreIgnoredFinancialEvent('a'), isFalse);
    final restored = (await db.getImportedFinancialEvents(
        direction: 'debit', sourceType: 'manual')).single;
    expect(restored['event_pk'], 'a');
    expect(restored['raw_text'], '');
    expect((await db.getImportedFinancialEvents(status: 'approved'))
        .single['transaction_fk'], 'saved');
  });

  test('investment quote export keeps latest prices by date and round trips', () {
    final quotes = [
      (date: DateTime(2026, 1, 1), price: 10.0),
      (date: DateTime(2026, 1, 1, 18), price: 12.0),
      (date: DateTime(2026, 1, 2), price: 13.0),
    ];
    final imported = parseInvestmentQuoteCsv(
        exportInvestmentQuoteCsv(quotes), DateTime(2026, 1, 2));
    expect(imported.map((quote) => quote.price), [13, 12]);
  });

  test('investment quote imports skip retries and retain the latest price', () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.createInvestmentHolding(id: 'fund', name: 'Fund', currency: 'egp');
    await db.setInvestmentMarketPrice('fund', 100, DateTime(2026, 1, 20));
    final quotes = parseInvestmentQuoteCsv(
      'date,price\n2026-01-20,1\n2026-01-25,١٢٣٫٥\n2026-01-05,90',
      DateTime(2026, 1, 25),
    );
    expect(await db.importInvestmentQuotes('fund', quotes), 2);
    expect(await db.importInvestmentQuotes('fund', quotes), 0);
    expect((await db.getInvestmentHoldings()).single.price, 123.5);
    expect((await db.getInvestmentPriceHistory('fund')).map((q) => q.price),
        [123.5, 100, 90]);
    final secondPage = await db.getInvestmentPriceHistory('fund', limit: 1, offset: 1);
    expect(secondPage.single.price, 100);
    expect(await db.deleteInvestmentQuote('fund', (date: quotes[1].date, price: 1)), isFalse);
    expect(await db.deleteInvestmentQuote('fund', quotes[1]), isTrue);
    expect((await db.getInvestmentHoldings()).single.price, 100);
    expect(await db.deleteInvestmentQuote('fund', secondPage.single), isTrue);
    expect(await db.deleteInvestmentQuote('fund', quotes[2]), isTrue);
    expect((await db.getInvestmentHoldings()).single.price, isNull);
    expect(() => parseInvestmentQuoteCsv(
        'date,price\n2026-02-30,10', DateTime(2026, 3, 5)), throwsFormatException);
  });

  test('staged restore leaves the live database intact until the next opening', () async {
    final folder = await Directory.systemTemp.createTemp('cashew-staged-test-');
    addTearDown(() => folder.delete(recursive: true));
    final liveFile = File('${folder.path}/db.sqlite');
    final sourceFile = File('${folder.path}/incoming.sqlite');
    final live = FinanceDatabase(NativeDatabase(liveFile));
    final source = FinanceDatabase(NativeDatabase(sourceFile));
    Future<void> seed(FinanceDatabase db, String name) =>
        db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('wallet'), name: name, order: 0,
        )).then((_) {});
    await seed(source, 'Restored');
    await source.close();
    await seed(live, 'Keep until restart');
    await stageNativeRestore(liveFile, await sourceFile.readAsBytes());
    expect((await live.getWalletInstance('wallet')).name, 'Keep until restart');
    await expectLater(stageNativeRestore(liveFile, Uint8List(200)), throwsFormatException);
    expect(await pendingNativeRestoreFile(liveFile).exists(), isTrue);
    await live.close();
    expect(await applyPendingNativeRestore(liveFile), isTrue);
    expect(await applyPendingNativeRestore(liveFile), isFalse);
    final restored = FinanceDatabase(NativeDatabase(liveFile));
    expect((await restored.getWalletInstance('wallet')).name, 'Restored');
    await restored.close();
    final previous = previousNativeRestoreFile(liveFile);
    await stageNativeRestore(liveFile, await previous.readAsBytes());
    expect(await applyPendingNativeRestore(liveFile), isTrue);
    final recovered = FinanceDatabase(NativeDatabase(liveFile));
    addTearDown(recovered.close);
    expect((await recovered.getWalletInstance('wallet')).name, 'Keep until restart');
    expect(await previous.exists(), isTrue);
    await deletePreviousNativeRestore(liveFile);
    await deletePreviousNativeRestore(liveFile);
    expect(await previous.exists(), isFalse);
    expect((await recovered.getWalletInstance('wallet')).name, 'Keep until restart');
  });

  test('a broken staged backup is reported and startup keeps the live ledger',
      () async {
    final folder = await Directory.systemTemp.createTemp('cashew-broken-stage-');
    addTearDown(() => folder.delete(recursive: true));
    final liveFile = File('${folder.path}/db.sqlite');
    final live = FinanceDatabase(NativeDatabase(liveFile));
    await live.into(live.wallets).insert(WalletsCompanion.insert(
        walletPk: const Value('wallet'), name: 'Intact', order: 0));
    await live.close();
    final truncated = (await liveFile.readAsBytes()).sublist(0, 512);
    validateCashewBackupHeader(truncated);
    await pendingNativeRestoreFile(liveFile).writeAsBytes(truncated);

    expect(await applyPendingNativeRestore(liveFile), isFalse);
    expect(await applyPendingNativeRestore(liveFile), isFalse);
    expect(await rejectedNativeRestoreFile(liveFile).exists(), isTrue);
    final reopened = FinanceDatabase(NativeDatabase(liveFile));
    addTearDown(reopened.close);
    expect((await reopened.getWalletInstance('wallet')).name, 'Intact');
  });

  test('startup retry keeps the original checkpoint after SQLite has copied the backup',
      () async {
    final folder = await Directory.systemTemp.createTemp('cashew-restore-retry-');
    addTearDown(() => folder.delete(recursive: true));
    final liveFile = File('${folder.path}/db.sqlite');
    Future<void> seed(File file, String name) async {
      final db = FinanceDatabase(NativeDatabase(file));
      try {
        await db.into(db.wallets).insert(WalletsCompanion.insert(
            walletPk: const Value('wallet'), name: name, order: 0));
      } finally {
        await db.close();
      }
    }
    final checkpoint = File('${liveFile.path}.restore-checkpoint');
    await seed(checkpoint, 'Original ledger');
    await seed(liveFile, 'Already copied');
    await liveFile.copy('${liveFile.path}.restore-applying');

    await expectLater(
        applyPendingNativeRestore(liveFile, onApplied: () async {
          throw StateError('Simulated interruption before saving restore preferences');
        }),
        throwsStateError);
    var resumed = false;
    expect(
        await applyPendingNativeRestore(liveFile, onApplied: () async {
          resumed = true;
        }),
        isTrue);
    expect(resumed, isTrue);
    expect(await checkpoint.exists(), isFalse);
    final previous = FinanceDatabase(NativeDatabase(previousNativeRestoreFile(liveFile)));
    addTearDown(previous.close);
    expect((await previous.getWalletInstance('wallet')).name, 'Original ledger');
  });

  test('credit CSV imports atomically and preserves a previously saved statement', () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.wallets).insert(WalletsCompanion.insert(
      walletPk: const Value('card'), name: 'Card', order: 0, currency: const Value('egp'),
    ));
    await db.saveAccountDetails(walletPk: 'card', accountType: 'credit');
    final statements = parseCreditStatementCsv(
      '$creditStatementCsvHeader\n2027-01-31,2027-02-16,200,30\n2027-02-28,2027-03-16,250,35',
    );
    expect(parseCreditStatementCsv(exportCreditStatementCsv(statements)), statements);
    expect(await db.importCreditCardStatements('card', statements), 2);
    expect(await db.importCreditCardStatements('card', statements), 0);
    expect(() => parseCreditStatementCsv(
        '$creditStatementCsvHeader\n2027-02-30,2027-03-16,250,35'),
        throwsFormatException);
    expect(() => parseCreditStatementCsv(
        '$creditStatementCsvHeader\n2027-02-28,2027-03-16,250,260'),
        throwsFormatException);
    await expectLater(db.importCreditCardStatements('card', [
      (closed: DateTime(2027, 3, 31), due: DateTime(2027, 4, 16), balance: 10.0, minimum: 2.0),
      (closed: DateTime(2027, 4, 30), due: DateTime(2027, 4, 16), balance: 10.0, minimum: 2.0),
    ]), throwsArgumentError);
    expect(await db.getCreditCardStatements('card'), hasLength(2));
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('duplicate hints respect day, labels, account, category and transaction type', () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final morning = DateTime(2027, 2, 1, 10);
    final existing = Transaction(
      transactionPk: 'old', name: 'Coffee', amount: -30, note: '',
      categoryFk: 'daily', walletFk: 'wallet', dateCreated: morning,
      income: false, paid: true, skipPaid: false,
    );
    await db.into(db.transactions).insert(existing);
    final draft = existing.copyWith(
      transactionPk: 'new', dateCreated: DateTime(2027, 2, 1, 20), name: ' coffee ',
    );
    expect((await db.findLikelyDuplicateTransaction(draft))?.transactionPk, 'old');
    for (final unmatched in [
      draft.copyWith(amount: -31),
      draft.copyWith(name: 'Groceries'),
      draft.copyWith(walletFk: 'other'),
      draft.copyWith(categoryFk: 'other'),
      draft.copyWith(dateCreated: DateTime(2027, 2, 2)),
      draft.copyWith(paid: false),
      draft.copyWith(type: const Value(TransactionSpecialType.upcoming)),
    ]) {
      expect(await db.findLikelyDuplicateTransaction(unmatched), isNull);
    }
    final nameless = existing.copyWith(transactionPk: 'unnamed', name: '');
    await db.into(db.transactions).insert(nameless);
    expect(await db.findLikelyDuplicateTransaction(nameless.copyWith(
      dateCreated: morning.add(const Duration(minutes: 6)),
    )), isNull);
  });

  test('restore validation rejects invalid and future files before replacement', () async {
    expect(() => validateCashewBackupHeader(Uint8List.fromList([1, 2, 3])),
        throwsFormatException);
    final folder = await Directory.systemTemp.createTemp('cashew-validate-');
    final original = FinanceDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await original.close();
      await folder.delete(recursive: true);
    });
    final file = File('${folder.path}/validation.sqlite');
    await original.customStatement('VACUUM INTO ?', [file.path]);
    final bytes = await file.readAsBytes();
    validateCashewBackupHeader(bytes);
    ByteData.sublistView(bytes).setUint32(60, schemaVersionGlobal + 1);
    expect(() => validateCashewBackupHeader(bytes), throwsFormatException);
    await validateCashewBackupDatabase(original);
    await original.customStatement('DROP TABLE categories');
    await expectLater(validateCashewBackupDatabase(original), throwsFormatException);
  });

  test('bank card statement reconciliation uses the closing ledger without posting entries', () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.wallets).insert(WalletsCompanion.insert(
      walletPk: const Value('card'), name: 'Card', order: 0, currency: const Value('egp'),
    ));
    await db.saveAccountDetails(walletPk: 'card', accountType: 'credit');
    final closing = DateTime(2027, 2, 28);
    final due = DateTime(2027, 3, 12);
    for (final (id, date, amount) in [
      ('included', DateTime(2027, 2, 28, 21), -100.0),
      ('later', DateTime(2027, 3, 1), -20.0),
    ]) {
      await db.into(db.transactions).insert(Transaction(
        transactionPk: id, name: id, amount: amount, note: '',
        categoryFk: 'daily', walletFk: 'card', dateCreated: date,
        income: false, paid: true, skipPaid: false,
      ));
    }
    Future<void> record(double minimum) => db.saveCreditCardStatement(
      walletPk: 'card', closingDate: closing, dueDate: due,
      statementBalance: 105, minimumDue: minimum,
    );
    await expectLater(record(120), throwsArgumentError);
    await record(25);
    await record(30);
    await db.into(db.transactions).insert(Transaction(
      transactionPk: 'credit', name: 'Credit', amount: 20, note: '',
      categoryFk: 'daily', walletFk: 'card', dateCreated: DateTime(2027, 3, 2),
      income: true, paid: true, skipPaid: false,
    ));
    final beforeDue = (await db.getCreditCardStatements('card', asOf: due)).single;
    expect(beforeDue.overdue, isFalse);
    final statement = (await db.getCreditCardStatements('card',
        asOf: DateTime(2027, 3, 13))).single;
    expect(statement.credits, 20);
    expect(statement.remaining, 85);
    expect(statement.minimumRemaining, 10);
    expect(statement.overdue, isTrue);
    expect(statement.closed, closing);
    expect(statement.due, due);
    expect(statement.balance, 105);
    expect(statement.minimum, 30);
    expect(statement.ledgerBalance, 100);
    expect(await db.select(db.transactions).get(), hasLength(3));
    final nextClosing = DateTime(2027, 3, 31);
    await db.saveCreditCardStatement(
      walletPk: 'card', closingDate: nextClosing, dueDate: DateTime(2027, 4, 15),
      statementBalance: 90, minimumDue: 25,
    );
    await db.into(db.transactions).insert(Transaction(
      transactionPk: 'later-credit', name: 'Later credit', amount: 15, note: '',
      categoryFk: 'daily', walletFk: 'card', dateCreated: DateTime(2027, 4, 1),
      income: true, paid: true, skipPaid: false,
    ));
    final rows = await db.getCreditCardStatements('card', asOf: DateTime(2027, 4, 2));
    expect(rows.map((row) => row.credits), [15, 20]);
    expect(rows.first.superseded, isFalse);
    expect(rows.last.superseded, isTrue);
    expect(rows.last.overdue, isFalse);
    expect(await db.deleteCreditCardStatement('card', nextClosing), isTrue);
    expect(await db.deleteCreditCardStatement('other', closing), isFalse);
    expect(await db.deleteCreditCardStatement('card', closing), isTrue);
    expect(await db.getCreditCardStatements('card'), isEmpty);
    expect(await db.select(db.transactions).get(), hasLength(4));
  });

  test('stale sync preserves edits, exposes conflicts and applies explicit choices', () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final early = DateTime(2026, 11, 24, 10);
    final late = DateTime(2026, 11, 24, 11);
    await db.into(db.wallets).insert(WalletsCompanion.insert(
      walletPk: const Value('wallet'), name: 'Account', order: 0,
    ));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
      categoryPk: const Value('daily'), name: 'Daily', order: 0,
    ));
    final local = Transaction(
      transactionPk: 'row', name: 'Local', amount: -20, note: '',
      categoryFk: 'daily', walletFk: 'wallet', dateCreated: early,
      dateTimeModified: late, income: false, paid: true, skipPaid: false,
    );
    await db.into(db.transactions).insert(local);
    final remote = local.copyWith(name: 'Incoming', amount: -10,
        dateTimeModified: Value(early));
    final sync = SyncLog(updateLogType: UpdateLogType.Transaction,
        pk: 'row', transactionDateTime: early, itemToUpdate: remote);
    await db.processSyncLogs([sync]);
    await db.processSyncLogs([sync]);
    expect((await db.select(db.transactions).get()).single.amount, -20);
    final conflict = (await db.getOpenSyncConflicts()).single['conflict_pk'] as String;
    expect(await db.resolveTransactionSyncConflict(conflict, useRemote: true), isTrue);
    expect((await db.select(db.transactions).get()).single.amount, -10);
    expect(await db.getOpenSyncConflicts(), isEmpty);
  });

  test('a stale remote deletion is reviewed once and only deletes on approval',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final before = DateTime(2026, 11, 24, 10);
    final after = DateTime(2026, 11, 24, 11);
    final row = Transaction(
      transactionPk: 'row', name: 'Edited', amount: -20, note: '',
      categoryFk: 'daily', walletFk: 'wallet', dateCreated: before,
      dateTimeModified: after, income: false, paid: true, skipPaid: false,
    );
    await db.into(db.transactions).insert(row);
    final deletion = SyncLog(deleteLogType: DeleteLogType.Transaction,
        pk: 'row', transactionDateTime: before);
    await db.processSyncLogs([deletion]);
    await db.processSyncLogs([deletion]);
    expect((await db.select(db.transactions).get()).single.name, 'Edited');
    final conflict = (await db.getOpenSyncConflicts()).single;
    expect(conflict['entity_type'], 'transaction_delete');
    final conflictPk = conflict['conflict_pk'] as String;
    expect(await db.resolveTransactionSyncConflict(conflictPk, useRemote: true),
        isTrue);
    expect(await db.select(db.transactions).get(), isEmpty);
    expect(await db.resolveTransactionSyncConflict(conflictPk, useRemote: true),
        isFalse);
    await db.processSyncLogs([SyncLog(updateLogType: UpdateLogType.Transaction,
        pk: 'row', transactionDateTime: after, itemToUpdate: row)]);
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('a synced transaction deletion blocks stale recreation in a later pull', () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final early = DateTime(2026, 11, 24, 10);
    final late = DateTime(2026, 11, 24, 11);
    final row = Transaction(
      transactionPk: 'row', name: 'Remote', amount: -20, note: '',
      categoryFk: 'daily', walletFk: 'wallet', dateCreated: early,
      dateTimeModified: early, income: false, paid: true, skipPaid: false,
    );
    final sync = SyncLog(updateLogType: UpdateLogType.Transaction,
        pk: 'row', transactionDateTime: early, itemToUpdate: row);
    await db.processSyncLogs([sync]);
    await db.processSyncLogs([SyncLog(deleteLogType: DeleteLogType.Transaction,
        pk: 'row', transactionDateTime: late)]);
    await db.processSyncLogs([sync]);
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('backup redaction preserves parsed review fields and clears raw bytes', () async {
    final folder = await Directory.systemTemp.createTemp('cashew-backup-test-');
    final original = File('${folder.path}/original.sqlite');
    final file = File('${folder.path}/snapshot.sqlite');
    final db = FinanceDatabase(NativeDatabase(original));
    addTearDown(() async {
      await db.close();
      await folder.delete(recursive: true);
    });
    const message = 'private-bank-message-should-not-exist-in-snapshot';
    await db.stageImportedFinancialEvent(eventPk: 'event', sourceType: 'manual',
        rawText: message, occurredAt: DateTime(2026, 11, 24),
        amount: 10, currency: 'egp', direction: 'debit');
    await db.customStatement('VACUUM INTO ?', [file.path]);
    final snapshot = FinanceDatabase(NativeDatabase(file));
    addTearDown(snapshot.close);
    await snapshot.omitImportMessageBodiesFromBackup();
    final item = (await snapshot.getImportedFinancialEvents()).single;
    expect((await db.getImportedFinancialEvents()).single['raw_text'], message);
    expect(item['raw_text'], isEmpty);
    expect(item['amount'], 10);
    expect(String.fromCharCodes(await file.readAsBytes()), isNot(contains(message)));
  });

  test('household previews enforce account visibility and role limits', () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final date = DateTime(2027, 2, 1);
    for (final id in ['shared', 'personal', 'archived']) {
      await db.into(db.wallets).insert(WalletsCompanion.insert(
        walletPk: Value(id), name: id, order: 0, currency: const Value('egp'),
      ));
      await db.into(db.transactions).insert(Transaction(
        transactionPk: id, name: id, amount: 100, note: '', categoryFk: 'category',
        walletFk: id, dateCreated: date, income: true, paid: true, skipPaid: false,
      ));
    }
    await db.saveAccountDetails(walletPk: 'archived', accountType: 'cash', archived: true);
    await db.saveHouseholdMember(memberPk: 'person', displayName: 'Person', role: 'editor');
    await db.saveHouseholdMember(memberPk: 'owner', displayName: 'Owner', role: 'owner');
    await db.saveHouseholdMember(memberPk: 'remote', displayName: 'Remote', role: 'owner',
        localOnly: false);
    await db.setHouseholdAccountAccess(memberPk: 'person', walletPk: 'shared',
        canView: true, canEdit: true);
    await db.setHouseholdAccountAccess(memberPk: 'person', walletPk: 'archived',
        canView: true, canEdit: true);
    final preview = await db.previewLocalHouseholdBalances('person', date);
    expect(preview.map((row) => (row.name, row.balance)), [('shared', 100.0)]);
    expect((await db.previewLocalHouseholdBalances('owner', date)).map((row) => row.name),
        ['personal', 'shared']);
    expect(await db.previewLocalHouseholdBalances('remote', date), isEmpty);
    await db.saveHouseholdMember(memberPk: 'person', displayName: 'Person', role: 'viewer');
    final access = await db.getLocalHouseholdAccountAccess('person');
    expect(access.singleWhere((row) => row.id == 'shared').canEdit, isFalse);
    await expectLater(db.setHouseholdAccountAccess(memberPk: 'person', walletPk: 'shared',
        canView: true, canEdit: true), throwsArgumentError);
    await db.saveHouseholdMember(memberPk: 'person', displayName: 'Person', role: 'editor');
    expect((await db.getLocalHouseholdAccountAccess('person'))
        .singleWhere((row) => row.id == 'shared').canEdit, isFalse);
    await db.setHouseholdAccountAccess(memberPk: 'person', walletPk: 'shared',
        canView: false, canEdit: false);
    expect(await db.previewLocalHouseholdBalances('person', date), isEmpty);
    await db.removeLocalHouseholdMember('person');
    expect((await db.getLocalHouseholdMembers()).single.id, 'owner');
    expect(await db.select(db.transactions).get(), hasLength(3));
  });


  test(
    'valuation includes open investments only when requested and priced',
    () async {
      final db = FinanceDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final date = DateTime(2027, 2, 1);
      await db.createInvestmentHolding(
        id: 'holding',
        name: 'Fund',
        currency: 'USD',
      );
      await db.addInvestmentTrade(
        'holding',
        InvestmentTrade(
          id: 'buy',
          date: date,
          buy: true,
          units: 2,
          price: 10,
          fees: 0,
        ),
      );
      expect((await db.getWealthValuation('usd')).total, isNull);
      final unpriced = await db.getWealthValuation(
        'usd',
        includeInvestments: true,
      );
      expect(unpriced.total, isNull);
      expect(unpriced.unpricedHoldings, 1);
      await db.setInvestmentMarketPrice('holding', 15, date);
      expect(
        (await db.getWealthValuation('usd', includeInvestments: true)).total,
        30,
      );
      expect(
        await db.captureWealthSnapshot(
          snapshotPk: 'snapshot',
          capturedAt: date,
          currency: 'usd',
          includeInvestments: true,
        ),
        isTrue,
      );
      await db.setInvestmentMarketPrice('holding', 20, date);
      final saved = (await db.getWealthSnapshotHistory()).single;
      expect(saved.total, 30);
      expect(saved.includesInvestments, isTrue);
      await db.addInvestmentTrade(
        'holding',
        InvestmentTrade(
          id: 'sell',
          date: date.add(const Duration(days: 1)),
          buy: false,
          units: 2,
          price: 20,
          fees: 0,
        ),
      );
      expect(
        (await db.getWealthValuation('usd', includeInvestments: true)).total,
        isNull,
      );
    },
  );

  test('scenario goals persist and are removed with their scenario', () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final base = DateTime(2027, 2, 1);
    await db.into(db.wallets).insert(
          WalletsCompanion.insert(
            walletPk: const Value('wallet'),
            name: 'Account',
            order: 0,
            currency: const Value('egp'),
          ),
        );
    for (final id in ['a', 'b']) {
      await db.into(db.objectives).insert(
            ObjectivesCompanion.insert(
              objectivePk: Value(id),
              name: id,
              amount: 100,
              order: 0,
              walletFk: const Value('wallet'),
              endDate: Value(base.add(const Duration(days: 2))),
            ),
          );
    }
    await db.savePlanningScenario(
      scenarioPk: 'plan',
      name: 'Plan',
      baseDate: base,
      horizonDays: 7,
      startingBalance: 1000,
      currency: 'egp',
    );
    await db.setPlanningScenarioGoals('plan', {'a', 'b'});
    expect(await db.getPlanningScenarioGoals('plan'), {'a', 'b'});
    expect((await db.calculatePlanningScenario('plan')).last['balance'], 800);
    await expectLater(
      db.setPlanningScenarioGoals('plan', {'missing'}),
      throwsStateError,
    );
    expect(await db.getPlanningScenarioGoals('plan'), {'a', 'b'});
    await db.deletePlanningScenario('plan');
    expect(await db.getPlanningScenarioGoals('plan'), isEmpty);
  });


  test('investment ledger weights costs and rolls back invalid history edits',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.createInvestmentHolding(
        id: 'holding', name: 'Fund', currency: 'EGP');
    Future<void> trade(String id, int day, bool buy, double units, double price,
            double fees) =>
        db.addInvestmentTrade(
            'holding',
            InvestmentTrade(
              id: id,
              date: DateTime(2027, 2, day),
              buy: buy,
              units: units,
              price: price,
              fees: fees,
            ));
    await trade('a', 1, true, 10, 10, 10);
    await trade('b', 2, true, 10, 20, 0);
    await trade('c', 3, false, 15, 30, 5);
    final summary =
        InvestmentBalance.fromTrades(await db.getInvestmentTrades('holding'));
    expect(summary.units, 5);
    expect(summary.cost, closeTo(77.5, 0.00001));
    expect(summary.realized, closeTo(212.5, 0.00001));
    final fifo = InvestmentBalance.fromTrades(
      await db.getInvestmentTrades('holding'),
      method: InvestmentCostBasis.fifo,
    );
    expect(fifo.units, 5);
    expect(fifo.cost, closeTo(100, 0.00001));
    expect(fifo.realized, closeTo(235, 0.00001));
    await expectLater(trade('invalid', 1, false, 11, 30, 0), throwsStateError);
    await expectLater(
        db.removeInvestmentTrade('holding', 'a'), throwsStateError);
    expect(await db.getInvestmentTrades('holding'), hasLength(3));
    await db.setInvestmentMarketPrice('holding', 31, DateTime(2027, 2, 5));
    await db.setInvestmentMarketPrice('holding', 29, DateTime(2027, 2, 4));
    expect((await db.getInvestmentHoldings()).single.price, 31);
    expect(
        (await db.getInvestmentPriceHistory('holding'))
            .map((quote) => quote.price),
        [31, 29]);
  });

  test('FIFO reuses partial lots and clears the basis on liquidation', () {
    final day = DateTime(2027, 2, 1);
    final trades = [
      InvestmentTrade(id: 'a', date: day, buy: true, units: 1.5, price: 8, fees: 3),
      InvestmentTrade(id: 'b', date: day, buy: true, units: 0.5, price: 20, fees: 0),
      InvestmentTrade(id: 'c', date: day, buy: false, units: 0.75, price: 30, fees: 1),
      InvestmentTrade(id: 'd', date: day, buy: false, units: 1, price: 30, fees: 2),
    ];
    final partial = InvestmentBalance.fromTrades(
      trades,
      method: InvestmentCostBasis.fifo,
      includeBreakdown: true,
    );
    expect(partial.units, 0.25);
    expect(partial.cost, 5);
    expect(partial.realized, 29.5);
    expect(partial.openLots, [(date: day, units: 0.25, cost: 5.0)]);
    expect(partial.realizedBySale, {'c': 14.0, 'd': 15.5});

    trades.add(InvestmentTrade(
        id: 'e', date: day, buy: false, units: 0.25, price: 40, fees: 1));
    final closed = InvestmentBalance.fromTrades(
      trades,
      method: InvestmentCostBasis.fifo,
      includeBreakdown: true,
    );
    expect(closed.units, 0);
    expect(closed.cost, 0);
    expect(closed.realized, 33.5);
    expect(closed.openLots, isEmpty);
    expect(closed.realizedBySale['e'], 4.0);
  });

  test('goal forecast offsets past contributions and scheduled payments once',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final start = DateTime(2027, 2, 2);
    final due = DateTime(2027, 2, 7);
    await db.savePlanningScenario(
        scenarioPk: 'plan',
        name: 'Plan',
        baseDate: start,
        horizonDays: 15,
        startingBalance: 1000,
        currency: 'EGP');
    await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('wallet'),
          name: 'Account',
          order: 0,
          currency: const Value('egp'),
        ));
    await db.into(db.objectives).insert(ObjectivesCompanion.insert(
          objectivePk: const Value('goal'),
          name: 'Trip',
          amount: 300,
          order: 0,
          walletFk: const Value('wallet'),
          endDate: Value(due),
        ));
    Future<void> expense(
        String id, double amount, DateTime date, bool paid) async {
      await db.into(db.transactions).insert(Transaction(
            transactionPk: id,
            name: id,
            amount: amount,
            note: '',
            categoryFk: 'category',
            walletFk: 'wallet',
            dateCreated: date,
            income: false,
            paid: paid,
            skipPaid: false,
            type: paid ? null : TransactionSpecialType.upcoming,
            objectiveFk: 'goal',
          ));
    }

    await expense(
        'covered', -100, start.subtract(const Duration(days: 1)), true);
    await expense('scheduled', -50, due.add(const Duration(hours: 10)), false);
    final withScheduled = await db.calculatePlanningScenario('plan',
        goalPk: 'goal', scheduledWalletPk: 'wallet');
    expect(
        withScheduled.where((point) => point['goal'] == true).single['amount'],
        -150);
    expect(withScheduled.last['balance'], 800);
    final withoutScheduled =
        await db.calculatePlanningScenario('plan', goalPk: 'goal');
    expect(withoutScheduled.last['balance'], 800);
    expect(await db.select(db.transactions).get(), hasLength(2));
  });

  test(
      'notification inbox filters sources and stages only parsed transaction fields',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final inbox = BankNotificationInbox();
    final now = DateTime(2027, 2, 1, 10);
    const allowed = {'eg.test.bank'};
    Future<bool> stage(
      String content, {
      String package = 'eg.test.bank',
      DateTime? time,
    }) =>
        inbox.stageNotification(
          db,
          BankNotification(
              id: 'test',
              packageName: package,
              content: content,
              postedAt: time ?? now),
          allowed,
          time ?? now,
        );
    const message = 'Purchase EGP 100 at Private Shop card ending 1234';
    expect(await stage(message, package: 'eg.other.app'), isFalse);
    expect(await stage('OTP 987654 for purchase EGP 100'), isFalse);
    expect(await stage(message), isTrue);
    expect(await stage(message, time: now.add(const Duration(seconds: 4))),
        isFalse);
    final event = (await db.getImportedFinancialEvents()).single;
    expect(event['source_sender'], 'eg.test.bank');
    expect(event['raw_text'], 'eg.test.bank');
    expect(event['merchant'], isNull);
    expect(event['amount'], 100);
    expect(event['identifier_last4'], '1234');
    expect(await db.select(db.transactions).get(), isEmpty);
    expect(await stage(message, time: now.add(const Duration(minutes: 3))),
        isTrue);
    expect(await db.getImportedFinancialEvents(), hasLength(2));
  });

  test('notification app list allows exact package names only', () {
    expect(
        BankNotificationInbox.parsePackages(
            'eg.bank.app, eg.other.app eg.bank.app'),
        ['eg.bank.app', 'eg.other.app']);
    expect(() => BankNotificationInbox.parsePackages('eg.bank.*'),
        throwsFormatException);
  });

  test('converts scheduled amounts only with a known scenario currency rate',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final date = DateTime(2027, 2, 1);
    await db.savePlanningScenario(
        scenarioPk: 'plan',
        name: 'Plan',
        baseDate: date,
        horizonDays: 7,
        startingBalance: 1000,
        currency: 'EGP');
    await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('usd'),
          name: 'Dollars',
          order: 0,
          currency: const Value('usd'),
        ));
    await db.into(db.transactions).insert(Transaction(
          transactionPk: 'scheduled',
          name: 'Subscription',
          amount: -10,
          note: '',
          categoryFk: 'category',
          walletFk: 'usd',
          dateCreated: date,
          income: false,
          paid: false,
          skipPaid: false,
          type: TransactionSpecialType.upcoming,
        ));
    expect((await db.getPlanningScenarios()).single['currency'], 'egp');
    await expectLater(
        db.calculatePlanningScenario('plan',
            scheduledWalletPk: 'usd', rateSettings: {}),
        throwsA(isA<PlanningRateUnavailable>()));
    final result = await db.calculatePlanningScenario('plan',
        scheduledWalletPk: 'usd',
        rateSettings: {
          'cachedCurrencyExchange': {'egp': 50}
        });
    expect(result.map((row) => row['balance']), [1000, 500]);
    await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('egp'),
          name: 'Pounds',
          order: 1,
          currency: const Value('egp'),
        ));
    await db.into(db.transactions).insert(Transaction(
          transactionPk: 'local-bill',
          name: 'Bill',
          amount: -80,
          note: '',
          categoryFk: 'category',
          walletFk: 'egp',
          dateCreated: date.add(const Duration(days: 1)),
          income: false,
          paid: false,
          skipPaid: false,
          type: TransactionSpecialType.upcoming,
        ));
    final combined = await db.calculatePlanningScenario('plan',
        scheduledWalletPk: 'usd',
        scheduledWalletPks: {'usd', 'egp'},
        rateSettings: {
          'cachedCurrencyExchange': {'egp': 50}
        });
    expect(combined.map((row) => row['balance']), [1000, 500, 420]);
    await expectLater(
        db.calculatePlanningScenario('plan',
            scheduledWalletPks: {'usd', 'egp'}, rateSettings: {}),
        throwsA(isA<PlanningRateUnavailable>()));

    await expectLater(
        db.savePlanningScenario(
            scenarioPk: 'plan',
            name: 'Replace',
            baseDate: date,
            horizonDays: 7,
            startingBalance: 100,
            currency: 'USD'),
        throwsStateError);
    expect((await db.getPlanningScenarios()).single['name'], 'Plan');
    await db.deletePlanningScenario('plan');
    await db.savePlanningScenario(
        scenarioPk: 'plan',
        name: 'New',
        baseDate: date,
        horizonDays: 7,
        startingBalance: 100);
    expect((await db.getPlanningScenarios()).single['currency'], isNull);
    final legacy = await db.calculatePlanningScenario('plan',
        scheduledWalletPk: 'usd', rateSettings: {});
    expect(legacy.last['balance'], 90);
    await expectLater(
        db.calculatePlanningScenario('plan',
            scheduledWalletPks: {'usd', 'egp'}, rateSettings: {}),
        throwsArgumentError);

  });

  test('insights group settled cash flow by month, category and currency',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final id in ['egp', 'usd', 'archived']) {
      await db.into(db.wallets).insert(WalletsCompanion.insert(
            walletPk: Value(id),
            name: id,
            order: 0,
            currency: Value(id == 'archived' ? 'egp' : id),
          ));
    }
    await db.saveAccountDetails(
        walletPk: 'archived', accountType: 'cash', archived: true);
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          categoryPk: const Value('daily'),
          name: 'Daily',
          order: 0,
        ));
    var count = 0;
    Future<void> add(
      double amount,
      String wallet, {
      String category = 'daily',
      bool paid = true,
      bool skipped = false,
      int month = 2,
    }) async {
      await db.into(db.transactions).insert(Transaction(
            transactionPk: 't${count++}',
            name: 'Entry',
            amount: amount,
            note: '',
            categoryFk: category,
            walletFk: wallet,
            dateCreated: DateTime(2027, month, 1),
            income: amount > 0,
            paid: paid,
            skipPaid: skipped,
          ));
    }

    await add(200, 'egp');
    await add(-30, 'egp');
    await add(-4, 'usd');
    await add(-1000, 'archived');
    await add(-1000, 'egp', category: '0');
    await add(-1000, 'egp', paid: false);
    await add(-1000, 'egp', skipped: true);
    await add(-1000, 'egp', month: 3);
    final rows =
        await db.getFinancialInsights(DateTime(2027, 2), DateTime(2027, 3));
    expect(
        rows.map(
            (row) => (row.currency, row.category, row.income, row.expenses)),
        [('egp', 'Daily', 200.0, 30.0), ('usd', 'Daily', 0.0, 4.0)]);
    final start = DateTime(2027, 2);
    final end = DateTime(2027, 3);
    final accounts = await db.getFinancialInsightsAccounts();
    expect(accounts.map((account) => account.id), ['egp', 'usd']);
    expect((await db.getFinancialInsights(start, end, walletPk: 'usd')).single,
        (currency: 'usd', category: 'Daily', income: 0.0, expenses: 4.0));
    expect(await db.getFinancialInsights(start, end, walletPk: 'archived'),
        isEmpty);
    expect(await db.watchMonthlySpendingInCurrency('egp', DateTime(2027, 2, 1)).first, 30);
    expect(await db.watchMonthlySpendingInCurrency('usd', DateTime(2027, 2, 1)).first, 4);

    final scopes = StreamIterator(db.watchWalletPksExcludedFromNetWorth());
    addTearDown(scopes.cancel);
    expect(await scopes.moveNext(), isTrue);
    expect(scopes.current, {'archived'});
    await db.setAccountExcludedFromNetWorth('egp', true);
    expect(await scopes.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect(scopes.current, {'archived', 'egp'});

    Future<List<Transaction>> report(SearchFilters filters) =>
        (db.select(db.transactions)..where((table) =>
          db.onlyShowIfFollowsSearchFilters(
            table,
            filters,
            joinedWithSubcategoriesTable: null,
            joinedWithObjectiveLoans: null,
            joinedWithCategories: false,
            joinedWithBudgets: false,
            joinedWithObjectives: false,
          ),
        )).get();
    final filters = SearchFilters(excludedWalletPks: scopes.current);
    expect((await report(filters)).map((transaction) => transaction.walletFk),
        ['usd']);
    expect(await report(filters.copyWith(walletPks: ['egp'])), isEmpty);
    expect((await db.getFinancialInsights(start, end, walletPk: 'egp')).single.expenses,
        30);
  });

  test('credit statement separates closing balance from later card activity',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('card'),
          name: 'Card',
          order: 0,
        ));
    await db.saveAccountDetails(walletPk: 'card', accountType: 'credit');
    await db.saveCreditCardDetails(
        walletPk: 'card', statementDay: 31, dueDay: 12, creditLimit: 1000, minimumPayment: 100);
    var count = 0;
    Future<void> add(double amount, DateTime date) async {
      await db.into(db.transactions).insert(Transaction(
            transactionPk: 't${count++}',
            name: 'Entry',
            amount: amount,
            note: '',
            categoryFk: 'daily',
            walletFk: 'card',
            dateCreated: date,
            income: amount > 0,
            paid: true,
            skipPaid: false,
          ));
    }

    await add(-300, DateTime(2027, 2, 28, 21));
    await add(-50, DateTime(2027, 3, 1));
    await add(75, DateTime(2027, 3, 2));
    await add(-1000, DateTime(2027, 3, 15));
    final card =
        await db.getCreditCardSummary('card', asOf: DateTime(2027, 3, 5));
    expect(card['last_statement_date'], DateTime(2027, 2, 28, 23, 59, 59));
    expect(card['last_statement_due_date'], DateTime(2027, 3, 12, 23, 59, 59));
    expect(card['estimated_statement_balance'], 300);
    expect(card['estimated_statement_remaining'], 225);
    expect(card['outstanding'], 275);
    expect(card['available_credit'], 725);
    expect(card['utilization_percent'], closeTo(27.5, 0.001));
    expect(card['estimated_minimum_remaining'], 25);
    expect(card['over_limit_amount'], 0);
    expect(card['statement_credits'], 75);
    expect(card['charges_after_statement'], 50);
    expect(card['estimated_statement_overdue'], isFalse);
    final overdue =
        await db.getCreditCardSummary('card', asOf: DateTime(2027, 3, 13));
    expect(overdue['estimated_statement_overdue'], isTrue);
    final overLimit =
        await db.getCreditCardSummary('card', asOf: DateTime(2027, 3, 16));
    expect(overLimit['over_limit_amount'], 275);
  });

  test('bank import suggests only a unique active card in the same currency',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final id in ['credit', 'debit', 'foreign']) {
      await db.into(db.wallets).insert(WalletsCompanion.insert(
            walletPk: Value(id),
            name: id,
            order: 0,
            currency: Value(id == 'foreign' ? 'usd' : 'egp'),
          ));
    }
    await db.saveAccountDetails(walletPk: 'credit', accountType: 'credit');
    await db.saveCreditCardDetails(walletPk: 'credit', lastFour: '1234');
    await db.saveAccountDetails(walletPk: 'foreign', accountType: 'credit');
    await db.saveCreditCardDetails(walletPk: 'foreign', lastFour: '1234');
    expect(await db.suggestImportedCardWallet('1234', 'EGP'), 'credit');
    await db.saveAccountIdentifier(
        identifierPk: 'debit-id',
        walletPk: 'debit',
        identifierType: 'card_last4',
        identifierValue: '1234');
    expect(await db.suggestImportedCardWallet('1234', 'egp'), isNull);
    await db.saveAccountDetails(
        walletPk: 'credit', accountType: 'credit', archived: true);
    expect(await db.suggestImportedCardWallet('1234', 'egp'), 'debit');
    expect(await db.addImportCardLink('foreign', '1234'), isFalse);
    expect((await db.getImportCardLinks()).single.account, 'debit');
    await db.removeImportCardLink((await db.getImportCardLinks()).single.id);
    expect(await db.suggestImportedCardWallet('1234', 'egp'), isNull);
    expect(await db.addImportCardLink('debit', '1234'), isTrue);
    expect(await db.suggestImportedCardWallet('1234', 'egp'), 'debit');
    expect(await db.suggestImportedCardWallet('123', 'egp'), isNull);
  });

  test('projects calendar recurrences once per series through its end date',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.savePlanningScenario(
        scenarioPk: 'plan',
        name: 'Plan',
        baseDate: DateTime(2027, 1, 1),
        horizonDays: 150,
        startingBalance: 100);
    Future<void> scheduled(String id, DateTime date) => db
        .into(db.transactions)
        .insert(Transaction(
          transactionPk: id,
          name: 'Subscription',
          amount: -10,
          note: '',
          categoryFk: 'category',
          walletFk: 'account',
          dateCreated: date,
          income: false,
          paid: false,
          skipPaid: false,
          reoccurrence: BudgetReoccurence.monthly,
          periodLength: 1,
          type: TransactionSpecialType.subscription,
          endDate: DateTime(2027, 4, 1),
        ))
        .then((_) {});
    await scheduled('series', DateTime(2027, 1, 31));
    final initial = await db.calculatePlanningScenario('plan',
        scheduledWalletPk: 'account', projectRecurrences: true);
    expect(initial.map((row) => row['date']), [
      DateTime(2027, 1, 1),
      DateTime(2027, 1, 31),
      DateTime(2027, 2, 28),
      DateTime(2027, 3, 28),
    ]);
    await scheduled('series::predict::1', DateTime(2027, 2, 28));
    final updated = await db.calculatePlanningScenario('plan',
        scheduledWalletPk: 'account', projectRecurrences: true);
    expect(updated.map((row) => row['balance']), [100, 90, 80, 70]);
    expect(updated.where((row) => row['projected'] == true), hasLength(1));
    expect(await db.select(db.transactions).get(), hasLength(2));
  });

  test('wealth snapshots require known rates and preserve capture values',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.saveWealthAsset(
        assetPk: 'cash',
        name: 'Cash',
        assetType: 'Cash',
        currency: 'USD',
        quantity: 2,
        unitValue: 10);
    await db.saveWealthAsset(
        assetPk: 'debt',
        name: 'Debt',
        assetType: 'Debt',
        currency: 'EGP',
        unitValue: 50,
        liability: true);
    final settings = <String, dynamic>{};
    final date = DateTime(2026, 11, 24);
    Future<bool> capture() => db.captureWealthSnapshot(
        snapshotPk: 'snapshot',
        capturedAt: date,
        currency: 'EGP',
        rateSettings: settings);
    expect(
        (await db.getWealthValuation('egp', rateSettings: settings))
            .missingCurrencies,
        ['usd']);
    expect(await capture(), isFalse);
    expect(await db.getWealthSnapshotHistory(), isEmpty);
    settings['cachedCurrencyExchange'] = {'egp': 50};
    expect(await capture(), isTrue);
    settings['cachedCurrencyExchange'] = {'egp': 60};
    expect(await capture(), isTrue);
    expect((await db.getWealthValuation('egp', rateSettings: settings)).total,
        1150);
    final allocation = await db.getWealthAllocation();
    expect(
        allocation
            .map((row) => (row.type, row.currency, row.liability, row.value)),
        [('Debt', 'egp', true, 50.0), ('Cash', 'usd', false, 20.0)]);
    final history = await db.getWealthSnapshotHistory();
    expect(history.single.total, 950);
    expect(history.single.currency, 'egp');
    expect(history.single.capturedAt, date);
  });

  test(
      'scenario previews only eligible scheduled entries from the selected account',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final date = DateTime(2026, 11, 24);
    await db.savePlanningScenario(
        scenarioPk: 'plan',
        name: 'Plan',
        baseDate: date,
        horizonDays: 7,
        startingBalance: 100);
    Future<void> entry(
      String id,
      DateTime due, {
      String wallet = 'account',
      bool paid = false,
      bool skip = false,
      TransactionSpecialType? type = TransactionSpecialType.upcoming,
    }) async {
      await db.into(db.transactions).insert(Transaction(
            transactionPk: id,
            name: id,
            amount: -20,
            note: '',
            categoryFk: 'category',
            walletFk: wallet,
            dateCreated: due,
            income: false,
            paid: paid,
            skipPaid: skip,
            type: type,
          ));
    }

    await entry('start', date);
    await entry('end', date.add(const Duration(days: 7)),
        type: TransactionSpecialType.subscription);
    await entry('later', date.add(const Duration(days: 8)));
    await entry('paid', date, paid: true);
    await entry('skipped', date, skip: true);
    await entry('ordinary', date, type: null);
    await entry('other-wallet', date, wallet: 'other');
    expect((await db.calculatePlanningScenario('plan')).single['balance'], 100);
    final forecast = await db.calculatePlanningScenario('plan',
        scheduledWalletPk: 'account');
    expect(forecast.map((row) => row['balance']), [100, 80, 60]);
    expect(forecast.skip(1).every((row) => row['scheduled'] == true), isTrue);
  });

  test('scenario edits recompute forecasts and deletions stay scoped',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final date = DateTime(2026, 11, 24);
    Future<void> save(String id, double balance) => db.savePlanningScenario(
          scenarioPk: id,
          name: id,
          baseDate: date,
          horizonDays: 7,
          startingBalance: balance,
        );
    await save('a', 100);
    await save('b', 250);
    Future<void> item(double amount) => db.savePlanningScenarioItem(
          itemPk: 'expense',
          scenarioPk: 'a',
          name: 'Expense',
          amount: amount,
          income: false,
          firstDate: date,
        );
    await item(20);
    await item(30);
    await save('a', 200);
    expect((await db.calculatePlanningScenario('a')).last['balance'], 170);
    await db.deletePlanningScenarioItem('b', 'expense');
    expect(await db.getPlanningScenarioItems('a'), hasLength(1));
    await db.deletePlanningScenarioItem('a', 'expense');
    expect((await db.calculatePlanningScenario('a')).last['balance'], 200);
    await item(40);
    await db.deletePlanningScenario('a');
    expect(await db.getPlanningScenarioItems('a'), isEmpty);
    expect((await db.getPlanningScenarios()).single['scenario_pk'], 'b');
  });

  test('upgrades generated version 46 schema and keeps existing wallets',
      () async {
    final directory = await Directory.systemTemp.createTemp('cashew-v46-test');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/budget.sqlite');
    final legacy = _Version46Database(NativeDatabase(file));
    try {
      await legacy.into(legacy.wallets).insert(WalletsCompanion.insert(
            walletPk: const Value('existing'),
            name: 'Existing wallet',
            order: 0,
            currency: const Value('egp'),
          ));
    } finally {
      await legacy.close();
    }

    final restoredFile = File('${directory.path}/db.sqlite');
    await stageNativeRestore(restoredFile, await file.readAsBytes());
    expect(await applyPendingNativeRestore(restoredFile), isTrue);
    final restored = FinanceDatabase(NativeDatabase(restoredFile));
    expect((await restored.getWalletInstance('existing')).name, 'Existing wallet');
    await restored.close();

    final upgraded = FinanceDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    expect(
        (await upgraded.getWalletInstance('existing')).name, 'Existing wallet');
    await upgraded.saveAccountDetails(
        walletPk: 'existing', accountType: 'bank');
    expect((await upgraded.getAccountDetails('existing'))?['account_type'],
        'bank');
    expect(
        (await upgraded.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        47);
  });

  test(
    'reopens a partial version 47 schema and preserves local data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cashew-schema-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/budget.sqlite');

      final original = FinanceDatabase(NativeDatabase(file));
      try {
        await original.savePlanningScenario(
          scenarioPk: 'scenario',
          name: 'Existing plan',
          baseDate: DateTime(2026, 11, 24),
          horizonDays: 7,
          startingBalance: 100,
        );
        await original.customStatement('DROP TABLE credit_card_details');
      } finally {
        await original.close();
      }

      final reopened = FinanceDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(await reopened.getCreditCardDetails('missing'), isNull);
      final plan = await reopened.calculatePlanningScenario('scenario');
      expect(plan.single['balance'], 100);
    },
  );

  test(
    'forecast starts at the base balance and skips earlier occurrences',
    () async {
      final database = FinanceDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final base = DateTime(2026, 11, 24);
      await database.savePlanningScenario(
        scenarioPk: 'scenario',
        name: 'Weekly plan',
        baseDate: base,
        horizonDays: 7,
        startingBalance: 100,
      );
      await database.savePlanningScenarioItem(
        itemPk: 'past-bill',
        scenarioPk: 'scenario',
        name: 'Past bill',
        amount: 30,
        income: false,
        firstDate: base.subtract(const Duration(days: 1)),
      );
      await database.savePlanningScenarioItem(
        itemPk: 'weekly-bill',
        scenarioPk: 'scenario',
        name: 'Weekly bill',
        amount: 20,
        income: false,
        firstDate: base.subtract(const Duration(days: 7)),
        recurrenceDays: 7,
      );
      final forecast = await database.calculatePlanningScenario('scenario');
      expect(forecast.map((point) => point['balance']), [100, 80, 60]);
      expect(forecast.first['date'], base);
    },
  );
  test('import staging deduplicates and approval checks wallet currency',
      () async {
    final database = FinanceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    for (final currency in ['egp', 'usd']) {
      await database.into(database.wallets).insert(WalletsCompanion.insert(
            walletPk: Value(currency),
            name: currency,
            order: 0,
            currency: Value(currency),
          ));
    }
    await database.into(database.categories).insert(CategoriesCompanion.insert(
          categoryPk: const Value('shopping'),
          name: 'Shopping',
          order: 0,
        ));
    final occurredAt = DateTime(2026, 11, 24, 9, 45);
    Future<bool> stage(String id) => database.stageImportedFinancialEvent(
          eventPk: id,
          sourceType: 'manual',
          rawText: 'Purchase EGP 100 at Shop',
          occurredAt: occurredAt,
          amount: 100,
          currency: 'egp',
          direction: 'debit',
        );
    final staged = await Future.wait([stage('one'), stage('two')]);
    expect(staged.where((value) => value), hasLength(1));
    final event = (await database.getImportedFinancialEvents()).single;
    final eventPk = event['event_pk'] as String;

    Future<String> approve(String wallet) =>
        database.approveImportedFinancialEvent(
          eventPk: eventPk,
          transactionPk: 'transaction',
          categoryFk: 'shopping',
          walletPk: wallet,
        );
    await expectLater(approve('usd'), throwsStateError);
    expect(await database.select(database.transactions).get(), isEmpty);
    expect(await approve('egp'), 'approved');
    await expectLater(approve('egp'), throwsStateError);
    final saved = (await database.select(database.transactions).get()).single;
    expect(saved.amount, -100);
    expect(saved.dateCreated, occurredAt);
    expect(saved.note, isEmpty);
    final approved =
        await database.getImportedFinancialEvents(status: 'approved');
    expect(approved.single['raw_text'], isEmpty);
  });
  test('paired repayment remains undoable after redo', () async {
    final database = FinanceDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    for (final id in ['bank', 'credit']) {
      await database.into(database.wallets).insert(WalletsCompanion.insert(
            walletPk: Value(id),
            name: id,
            order: 0,
            currency: const Value('egp'),
          ));
    }
    await database.into(database.categories).insert(CategoriesCompanion.insert(
          categoryPk: const Value('0'),
          name: 'Balance transfer',
          order: 0,
        ));
    Transaction leg(String id, String wallet, double amount) => Transaction(
          transactionPk: id,
          name: 'Repayment',
          amount: amount,
          note: '',
          categoryFk: '0',
          walletFk: wallet,
          dateCreated: DateTime(2026, 11, 24),
          income: amount > 0,
          paid: true,
          skipPaid: false,
        );
    final debit = leg('out', 'bank', -250);
    final credit = leg('in', 'credit', 250);
    expect(
        await database.saveAtomicLocalTransfer(debit, credit,
            idempotencyKey: 'repayment'),
        isTrue);
    expect(
        await database.saveAtomicLocalTransfer(debit, credit,
            idempotencyKey: 'repayment'),
        isFalse);
    final paired = await database.select(database.transactions).get();
    final totals = await database.getAssistantAccountTotals(
      monthlySpending: false,
      asOf: DateTime(2026, 11, 25),
    );
    expect(totals.map((row) => row['total']), [-250, 250]);
    final spending = await database.getAssistantAccountTotals(
      monthlySpending: true,
      asOf: DateTime(2026, 11, 25),
    );
    expect(spending.map((row) => row['total']), [0, 0]);
    expect(paired.map((row) => row.pairedTransactionFk),
        unorderedEquals(['out', 'in']));
    expect(await database.undoLocalTransfer('out'), isTrue);
    expect(await database.select(database.transactions).get(), isEmpty);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await database.redoLocalTransfer('out'), isTrue);
    expect(await database.undoLocalTransfer('out'), isTrue);
    expect(await database.select(database.transactions).get(), isEmpty);
  });
}
