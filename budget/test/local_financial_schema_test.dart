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
        walletPk: 'card', statementDay: 31, dueDay: 12, creditLimit: 1000);
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
