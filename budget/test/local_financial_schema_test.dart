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
    final occurredAt = DateTime(2026, 11, 24);
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
