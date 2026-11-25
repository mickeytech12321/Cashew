import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/cardStatementRepayment.dart';
import 'package:budget/struct/syncClient.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> addWallet(FinanceDatabase db, String id) async {
  await db.into(db.wallets).insert(WalletsCompanion.insert(
        walletPk: Value(id),
        name: id,
        order: 0,
        currency: const Value('egp'),
      ));
}

Transaction leg(String id, double amount, DateTime edited, {String? peer}) =>
    Transaction(
      transactionPk: id,
      name: 'Transfer',
      amount: amount,
      note: '',
      walletFk: id == 'a' ? 'source' : 'target',
      categoryFk: '0',
      pairedTransactionFk: peer,
      dateCreated: DateTime(2026, 10, 10),
      dateTimeModified: edited,
      income: amount > 0,
      paid: true,
      skipPaid: false,
    );

SyncLog syncRow(Transaction row, {String? snapshot}) => SyncLog(
      pk: row.transactionPk,
      transactionDateTime: row.dateTimeModified,
      updateLogType: UpdateLogType.Transaction,
      itemToUpdate: row,
      sourceSnapshot: snapshot,
    );

SyncLog syncDelete(String id, DateTime date, {String? snapshot}) => SyncLog(
      pk: id,
      transactionDateTime: date,
      deleteLogType: DeleteLogType.Transaction,
      sourceSnapshot: snapshot,
    );

Future<FinanceDatabase> transferDatabase() async {
  final db = FinanceDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await addWallet(db, 'source');
  await addWallet(db, 'target');
  await db.into(db.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('0'),
        name: 'Balance correction',
        order: 0,
      ));
  return db;
}

void main() {
  final first = DateTime(2026, 11, 20, 12);
  final changed = first.add(const Duration(hours: 1));
  final later = changed.add(const Duration(hours: 1));

  test('sync includes the old companion when one transfer leg changed',
      () async {
    final db = await transferDatabase();
    await db.into(db.transactions).insert(leg('a', -50, changed, peer: 'b'));
    await db.into(db.transactions).insert(leg('b', 50, first, peer: 'a'));
    final rows = await db.getAllNewTransactions(changed);
    expect(rows.map((row) => row.transactionPk), unorderedEquals(['a', 'b']));
  });

  test(
      'transfer sync accepts both legs, deduplicates replay and blocks split deletes',
      () async {
    final db = await transferDatabase();
    final up = [
      syncRow(leg('a', -50, first, peer: 'b')),
      syncRow(leg('b', 50, first, peer: 'a')),
    ];
    await db.processSyncLogs(up);
    await db.processSyncLogs(up);
    expect((await db.select(db.transactions).get()).length, 2);
    await db.processSyncLogs([syncDelete('a', changed)]);
    expect((await db.select(db.transactions).get()).length, 2);
    final partial = (await db.getOpenSyncConflicts()).single;
    await expectLater(
      db.resolveTransferSyncConflict(partial['conflict_pk'] as String,
          useRemote: true),
      throwsStateError,
    );
    await db.resolveTransferSyncConflict(partial['conflict_pk'] as String,
        useRemote: false);
    final deletions = [syncDelete('a', changed), syncDelete('b', changed)];
    await db.processSyncLogs(deletions);
    await db.processSyncLogs(deletions);
    await db.processSyncLogs(up);
    expect(await db.select(db.transactions).get(), isEmpty);
    expect((await db.select(db.deleteLogs).get()).length, 2);
  });

  test(
      'unrelated snapshots cannot supply the missing half of a transfer update',
      () async {
    final db = await transferDatabase();
    await db.processSyncLogs([
      syncRow(leg('a', -50, first, peer: 'b'), snapshot: 'left'),
      syncRow(leg('b', 50, changed, peer: 'a'), snapshot: 'right'),
    ]);
    expect(await db.select(db.transactions).get(), isEmpty);
    expect((await db.getOpenSyncConflicts()).length, 2);
  });

  test('one stale leg blocks the pair until both are explicitly approved',
      () async {
    final db = await transferDatabase();
    await db.processSyncLogs([
      syncRow(leg('a', -50, later, peer: 'b')),
      syncRow(leg('b', 50, first, peer: 'a')),
    ]);
    final update = [
      syncRow(leg('a', -75, changed, peer: 'b')),
      syncRow(leg('b', 75, changed, peer: 'a')),
    ];
    await db.processSyncLogs(update);
    await db.processSyncLogs(update);
    expect((await db.getTransactionFromPk('a')).amount, -50);
    expect((await db.getTransactionFromPk('b')).amount, 50);
    final conflict = (await db.getOpenSyncConflicts()).single;
    expect(conflict['entity_type'], 'transfer');
    await db.resolveTransferSyncConflict(conflict['conflict_pk'] as String,
        useRemote: true);
    expect((await db.getTransactionFromPk('a')).amount, -75);
    expect((await db.getTransactionFromPk('b')).amount, 75);
  });

  test(
      'explicit approval rechecks both local rows and leaves stale deletes unapplied',
      () async {
    final db = await transferDatabase();
    await db.processSyncLogs([
      syncRow(leg('a', -50, later, peer: 'b')),
      syncRow(leg('b', 50, first, peer: 'a')),
    ]);
    await db
        .processSyncLogs([syncDelete('a', changed), syncDelete('b', changed)]);
    final conflict = (await db.getOpenSyncConflicts()).single;
    final update = leg('b', 50, later, peer: 'a').copyWith(note: 'Edited');
    await db.into(db.transactions).insertOnConflictUpdate(update);
    await expectLater(
      db.resolveTransferSyncConflict(conflict['conflict_pk'] as String,
          useRemote: true),
      throwsStateError,
    );
    expect((await db.select(db.transactions).get()).length, 2);
    expect(await db.select(db.deleteLogs).get(), isEmpty);
  });

  test(
      'forecast includes all of its final calendar day and excludes the next day',
      () async {
    final db = await transferDatabase();
    final start = DateTime(2026, 11, 20);
    await db.savePlanningScenario(
      scenarioPk: 'test',
      name: 'Forecast',
      baseDate: start,
      horizonDays: 2,
      startingBalance: 100,
      currency: 'egp',
    );
    await db.savePlanningScenarioItem(
      itemPk: 'manual',
      scenarioPk: 'test',
      name: 'Manual',
      amount: 5,
      income: false,
      firstDate: DateTime(2026, 11, 22, 19),
    );
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          categoryPk: const Value('daily'),
          name: 'Daily',
          order: 1,
        ));
    for (final (id, date) in [
      ('last-day', DateTime(2026, 11, 22, 23, 59, 59)),
      ('next-day', DateTime(2026, 11, 23)),
    ]) {
      await db.into(db.transactions).insert(leg(id, -10, first).copyWith(
            walletFk: 'source',
            categoryFk: 'daily',
            dateCreated: date,
            paid: false,
            type: const Value(TransactionSpecialType.upcoming),
          ));
    }
    final forecast =
        await db.calculatePlanningScenario('test', scheduledWalletPk: 'source');
    expect(forecast.map((point) => point['item_pk']),
        [null, 'manual', 'last-day']);
    expect(forecast.last['balance'], 85);
  });

  test(
      'spending widget can distinguish two active accounts in the same currency',
      () async {
    final db = await transferDatabase();
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          categoryPk: const Value('daily'),
          name: 'Daily',
          order: 1,
        ));
    for (final (id, wallet, amount, date) in [
      ('A', 'source', -30.0, DateTime(2026, 11, 20)),
      ('B', 'target', -75.0, DateTime(2026, 11, 20)),
      ('prior', 'source', -100.0, DateTime(2026, 10, 30)),
      ('future', 'source', -100.0, DateTime(2026, 11, 25)),
    ]) {
      await db.into(db.transactions).insert(leg(id, amount, first).copyWith(
            walletFk: wallet,
            categoryFk: 'daily',
            dateCreated: date,
          ));
    }
    expect(await db.watchMonthlySpendingInCurrency('egp', first).first, 105);
    expect(
        await db
            .watchMonthlySpendingInCurrency('egp', first, walletPk: 'source')
            .first,
        30);
    expect(
        await db
            .watchMonthlySpendingInCurrency('egp', first, walletPk: 'target')
            .first,
        75);
    expect(
        await db
            .watchMonthlySpendingInCurrency('egp', DateTime(2026, 12, 1),
                walletPk: 'source')
            .first,
        0);
  });

  test(
      'market source changes and retries preserve manual quotes and older history',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.createInvestmentHolding(
        id: 'holding', name: 'Asset', currency: 'usd');
    expect(await db.getInvestmentMarketSource('holding'), isNull);
    await db.setInvestmentMarketPrice('holding', 100, changed);
    await db.setInvestmentMarketSource('holding', 'btc');
    final source = (await db.getInvestmentMarketSource('holding'))!;
    expect(source.symbol, 'BTC');
    expect(
        await db.saveFetchedInvestmentQuote(
            'holding', source.revision, (price: 95.0, date: first)),
        isTrue);
    expect(
        await db.saveFetchedInvestmentQuote(
            'holding', source.revision, (price: 93.0, date: changed)),
        isFalse);
    expect((await db.getInvestmentHoldings()).single.price, 100);
    await db.setInvestmentMarketSource('holding', 'eth');
    expect(
        await db.saveFetchedInvestmentQuote(
            'holding', source.revision, (price: 120.0, date: later)),
        isFalse);
    final newSource = (await db.getInvestmentMarketSource('holding'))!;
    expect(
        await db.saveFetchedInvestmentQuote(
            'holding', newSource.revision, (price: 120.0, date: later)),
        isTrue);
    await db.setInvestmentMarketSource('holding', null);
    expect((await db.getInvestmentHoldings()).single.price, 120);
    expect(
        (await db.getInvestmentPriceHistory('holding')).map((row) => row.price),
        [120.0, 100.0, 95.0]);
  });

  test(
      'existing schema 47 reopens with both optional tables and keeps old rows',
      () async {
    final directory = await Directory.systemTemp.createTemp('cashew-batch-db');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/budget.sqlite');
    final old = FinanceDatabase(NativeDatabase(file));
    await addWallet(old, 'card');
    await old.saveAccountDetails(walletPk: 'card', accountType: 'credit');
    await old.saveCreditCardDetails(walletPk: 'card', minimumPayment: 35);
    await old.createInvestmentHolding(
        id: 'legacy', name: 'Legacy', currency: 'eur');
    await old.setInvestmentMarketPrice('legacy', 42, first);
    await old.customStatement('DROP TABLE credit_card_payment_rules');
    await old.customStatement('DROP TABLE investment_market_sources');
    await old.close();

    final reopened = FinanceDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    expect(reopened.schemaVersion, 47);
    expect(
        (await reopened.getCreditCardDetails('card'))?['minimum_payment'], 35);
    expect(await reopened.getInvestmentMarketSource('legacy'), isNull);
    expect((await reopened.getInvestmentHoldings()).single.price, 42);
    await reopened.setInvestmentMarketSource('legacy', 'BTC');
    expect((await reopened.getInvestmentMarketSource('legacy'))?.symbol, 'BTC');
  });

  test(
      'optional card rules use a floor, respect due-date credits and never post a fee',
      () async {
    final db = await transferDatabase();
    await db.saveAccountDetails(walletPk: 'source', accountType: 'credit');
    await db.saveCreditCardDetails(
      walletPk: 'source',
      statementDay: 15,
      dueDay: 25,
      minimumPayment: 35,
    );
    await db.into(db.transactions).insert(
          leg('a', -1000, first).copyWith(dateCreated: DateTime(2026, 11, 10)),
        );
    final asOf = DateTime(2026, 11, 27);
    final legacy = await db.getCreditCardSummary('source', asOf: asOf);
    expect(legacy['estimated_minimum_remaining'], 35);
    expect(legacy['estimated_late_fee'], isNull);

    await db.saveCreditCardDetails(
      walletPk: 'source',
      statementDay: 15,
      dueDay: 25,
      minimumPayment: 35,
      minimumPercent: 5,
      lateFee: 22,
    );
    final beforeDue =
        await db.getCreditCardSummary('source', asOf: DateTime(2026, 11, 24));
    expect(beforeDue['estimated_minimum_remaining'], 50);
    expect(beforeDue['estimated_late_fee'], isNull);
    await db.into(db.transactions).insert(
          leg('credit', 50, first).copyWith(
              walletFk: 'source', dateCreated: DateTime(2026, 11, 26)),
        );
    final late = await db.getCreditCardSummary('source', asOf: asOf);
    expect(late['estimated_minimum_remaining'], 0);
    expect(late['estimated_late_fee'], 22);
    final payment = await db.getTransactionFromPk('credit');
    await db.into(db.transactions).insertOnConflictUpdate(
          payment.copyWith(dateCreated: DateTime(2026, 11, 25, 23, 59, 59)),
        );
    final onTime = await db.getCreditCardSummary('source', asOf: asOf);
    expect(onTime['estimated_late_fee'], isNull);
    expect((await db.select(db.transactions).get()).length, 2);
  });

  test('a recorded statement repayment rechecks the balance and writes one paired transfer',
      () async {
    final db = await transferDatabase();
    final closing = DateTime(2026, 11, 15);
    final asOf = DateTime(2026, 11, 24, 12);
    await db.saveAccountDetails(walletPk: 'target', accountType: 'credit');
    await db.saveCreditCardDetails(walletPk: 'target', linkedBankWalletFk: 'source');
    await db.saveCreditCardStatement(
        walletPk: 'target',
        closingDate: closing,
        dueDate: DateTime(2026, 12, 5),
        statementBalance: 400,
        minimumDue: 60);

    Future<CardStatementRepayment?> reload() =>
        loadCardStatementRepayment(db, 'target', closing, asOf: asOf);
    final reviewed = (await reload())!;
    expect(reviewed.source.walletPk, 'source');
    expect((reviewed.minimum, reviewed.remaining), (60, 400));
    expect(await db.select(db.transactions).get(), isEmpty);
    final debit = leg('a', -60, asOf).copyWith(dateCreated: asOf);
    final credit = leg('b', 60, asOf).copyWith(dateCreated: asOf);
    Future<bool?> pay() => saveCardStatementRepayment(
        db, reviewed, debit, credit, idempotencyKey: 'minimum', asOf: asOf);

    await db.saveAccountDetails(walletPk: 'source', accountType: 'bank', archived: true);
    expect(await pay(), isNull);
    await db.saveAccountDetails(walletPk: 'source', accountType: 'bank');
    expect(await pay(), isTrue);
    expect(await pay(), isNull);
    expect((await db.getTransactionFromPk('a')).pairedTransactionFk, 'b');
    expect((await db.getTransactionFromPk('b')).pairedTransactionFk, 'a');
    final after = (await reload())!;
    expect((after.minimum, after.remaining), (0, 340));
    expect(await db.select(db.transactions).get(), hasLength(2));
    expect(await db.undoLocalTransfer('a'), isTrue);
    expect((await reload())!.remaining, 400);
    expect(await db.redoLocalTransfer('a'), isTrue);
    expect((await reload())!.remaining, 340);
    expect((await db.getTransactionFromPk('b')).dateCreated, asOf);
  });
}
