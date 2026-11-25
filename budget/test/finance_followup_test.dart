import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/bankNotificationInbox.dart';
import 'package:budget/struct/investmentMarketPrices.dart';
import 'package:budget/struct/syncClient.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final now = DateTime(2026, 11, 25, 12);
  final prior = now.subtract(const Duration(days: 3));
  final later = now.add(const Duration(days: 1));
  const package = 'eg.test.bank';

  Future<FinanceDatabase> finance() async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('local'),
          name: 'Local',
          order: 0,
          currency: const Value('egp'),
          dateTimeModified: Value(now),
        ));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          categoryPk: const Value('daily'),
          name: 'Daily',
          order: 0,
          dateTimeModified: Value(now),
        ));
    return db;
  }

  Transaction item(
    String id,
    DateTime due,
    double amount, {
    bool paid = false,
    bool skipped = false,
    bool repeating = false,
  }) =>
      Transaction(
        transactionPk: id,
        name: id,
        amount: amount,
        note: '',
        categoryFk: 'daily',
        walletFk: 'local',
        dateCreated: due,
        dateTimeModified: now,
        income: amount > 0,
        paid: paid,
        skipPaid: skipped,
        type: repeating
            ? TransactionSpecialType.subscription
            : TransactionSpecialType.upcoming,
        periodLength: repeating ? 1 : null,
        reoccurrence: repeating ? BudgetReoccurence.daily : null,
      );

  test(
      'equity refresh sends only the selected symbol and exchange and validates the provider date',
      () async {
    final timestamp = now.millisecondsSinceEpoch ~/ 1000;
    final requestClient = MockClient((request) async {
      expect(request.url.host, 'api.twelvedata.com');
      expect(request.url.path, '/quote');
      expect(request.url.queryParameters,
          {'symbol': 'AAPL', 'mic_code': 'XNAS', 'interval': '1day'});
      expect(request.headers['authorization'], 'apikey fixture-token');
      expect(request.followRedirects, isFalse);
      expect(request.body, isEmpty);
      return http.Response(
          jsonEncode({
            'symbol': 'AAPL',
            'mic_code': 'XNAS',
            'currency': 'USD',
            'close': '241.78',
            'timestamp': timestamp - 86400,
            'last_quote_at': timestamp - 5,
          }),
          200);
    });
    addTearDown(requestClient.close);
    final quote = await TwelveDataMarketPrices(requestClient).fetch(
        StockMarketListing(' aapl ', 'xnas', 'usd'), 'fixture-token', now);
    expect(quote.price, 241.78);
    expect(quote.date, now.toUtc().subtract(const Duration(seconds: 5)));
  });

  test('the public demo quote still verifies exchange and currency', () async {
    final client = MockClient((request) async {
      expect(request.url.queryParameters,
          {'symbol': 'AAPL', 'interval': '1day', 'apikey': 'demo'});
      expect(request.headers['authorization'], isNull);
      return http.Response(
          jsonEncode({
            'symbol': 'AAPL',
            'mic_code': 'XNGS',
            'currency': 'USD',
            'close': '250.12',
            'timestamp': now.millisecondsSinceEpoch ~/ 1000,
          }),
          200);
    });
    addTearDown(client.close);
    final provider = TwelveDataMarketPrices(client);
    final result = await provider.fetch(
        StockMarketListing('AAPL', 'XNGS', 'USD'), 'demo', now);
    expect(result.price, 250.12);
    await expectLater(
        provider.fetch(StockMarketListing('AAPL', 'XNAS', 'USD'), 'demo', now),
        throwsFormatException);
  });

  test(
      'equity refresh rejects wrong listings, currencies, stale prices and provider failures',
      () async {
    final timestamp = now.millisecondsSinceEpoch ~/ 1000;
    final good = {
      'symbol': 'AAPL',
      'mic_code': 'XNAS',
      'currency': 'USD',
      'close': '241.78',
      'timestamp': timestamp,
    };
    for (final (fields, status) in [
      ({'symbol': 'APLE'}, 200),
      ({'mic_code': 'XNYS'}, 200),
      ({'currency': 'EGP'}, 200),
      ({'last_quote_at': timestamp + 121}, 200),
      ({'timestamp': timestamp - 11 * 86400}, 200),
      ({'close': 'NaN'}, 200),
      ({'status': 'error'}, 200),
      (<String, Object>{}, 429),
    ]) {
      final client = MockClient(
          (_) async => http.Response(jsonEncode({...good, ...fields}), status));
      addTearDown(client.close);
      await expectLater(
          TwelveDataMarketPrices(client).fetch(
              StockMarketListing('AAPL', 'XNAS', 'USD'), 'fixture-token', now),
          throwsFormatException);
    }
  });

  test(
      'schema-47 sources reopen and switching providers protects in-flight prices',
      () async {
    final dir = await Directory.systemTemp.createTemp('cashew-market');
    addTearDown(() => dir.delete(recursive: true));
    final path = File('${dir.path}/app.sqlite');
    final old = FinanceDatabase(NativeDatabase(path));
    await old.createInvestmentHolding(
        id: 'asset', name: 'Asset', currency: 'usd');
    await old.setInvestmentMarketPrice('asset', 105, now);
    await old.setInvestmentMarketSource('asset', 'btc');
    final original = (await old.getInvestmentMarketSource('asset'))!;
    await old.customStatement('DROP TABLE investment_market_listings');
    await old.close();

    final db = FinanceDatabase(NativeDatabase(path));
    addTearDown(db.close);
    expect(await db.getInvestmentMarketSource('asset'), original);
    await db.setInvestmentMarketSource('asset', 'aapl', mic: 'xnas');
    final stock = (await db.getInvestmentMarketSource('asset'))!;
    expect((stock.symbol, stock.mic, stock.provider),
        ('AAPL', 'XNAS', InvestmentPriceProvider.twelveData));
    expect(
        await db.saveFetchedInvestmentQuote(
            'asset', original.revision, (date: later, price: 90.0)),
        isFalse);
    expect(
        await db.saveFetchedInvestmentQuote(
            'asset', stock.revision, (date: now, price: 91.0)),
        isFalse);
    expect((await db.getInvestmentHoldings()).single.price, 105);
    await db.setInvestmentMarketSource('asset', 'eth');
    expect((await db.getInvestmentMarketSource('asset'))!.mic, isNull);
    await db.setInvestmentMarketSource('asset', null);
    expect((await db.getInvestmentHoldings()).single.price, 105);
  });

  test(
      'persisted alerts coalesce updates after restart and keep concurrent same-time payments',
      () async {
    final dir = await Directory.systemTemp.createTemp('cashew-alert-receipts');
    addTearDown(() => dir.delete(recursive: true));
    final path = File('${dir.path}/app.sqlite');
    var db = FinanceDatabase(NativeDatabase(path));
    addTearDown(() => db.close());
    Future<bool> capture(String id, String hex, DateTime date) =>
        BankNotificationInbox().stageNotification(
          db,
          BankNotification(
            id: id,
            signature: hex * 64,
            packageName: package,
            content: 'Purchase EGP 100 at Private Shop card ending 1234',
            postedAt: date,
          ),
          {package},
          date,
        );
    final results = await Future.wait([
      capture('receipt', 'a', now),
      capture('receipt', 'b', now),
      capture('other', 'a', now),
    ]);
    expect(results, [true, true, true]);
    await db.close();
    db = FinanceDatabase(NativeDatabase(path));
    expect(await capture('receipt', 'a', now.add(const Duration(seconds: 60))),
        isFalse);
    expect(await capture('receipt', 'a', now.add(const Duration(minutes: 3))),
        isTrue);
    expect(
        (await db.getImportedFinancialEvents())
            .map((event) => event['raw_text']),
        everyElement(package));
    expect(await db.select(db.transactions).get(), isEmpty);
    await db.omitImportMessageBodiesFromBackup();
    expect(
        await db.customSelect('SELECT * FROM bank_notification_receipts').get(),
        isEmpty);
    expect(await capture('receipt', 'a', now), isFalse);
  });

  test(
      'legacy notification replay is deduplicated without suppressing a distinct amount',
      () async {
    final db = await finance();
    await db.stageImportedFinancialEvent(
        eventPk: 'legacy',
        sourceType: 'notification',
        sourceSender: package,
        rawText: package,
        occurredAt: prior,
        amount: 100,
        currency: 'egp',
        direction: 'debit');
    Future<bool> capture(int amount, DateTime date, DateTime received) =>
        BankNotificationInbox().stageNotification(
            db,
            BankNotification(
                packageName: package,
                id: 'legacy-id',
                content: 'Purchase EGP $amount',
                postedAt: date),
            {package},
            received);
    expect(await capture(100, prior, prior), isFalse);
    expect(await capture(150, prior, prior), isTrue);
    expect(await capture(200, prior, now), isFalse);
    expect(
        (await db.getImportedFinancialEvents()).map((event) => event['amount']),
        unorderedEquals([100, 150]));
  });

  test(
      'overdue forecast option brings forward only unpaid expenses and keeps recurrence future-only',
      () async {
    final db = await finance();
    await db.savePlanningScenario(
        scenarioPk: 'plan',
        name: 'Forecast',
        baseDate: now,
        horizonDays: 2,
        startingBalance: 1000,
        currency: 'egp');
    for (final row in [
      item('late', prior, -25),
      item('recent', prior, -100, paid: true),
      item('skipped', prior, -100, skipped: true),
      item('old-income', prior, 100),
      item('subscription', prior, -10, repeating: true),
      item('future', later, -50),
    ]) {
      await db.into(db.transactions).insert(row);
    }
    final original =
        await db.calculatePlanningScenario('plan', scheduledWalletPk: 'local');
    expect(original.map((point) => point['item_pk']), [null, 'future']);
    final forecast = await db.calculatePlanningScenario('plan',
        scheduledWalletPk: 'local',
        projectRecurrences: true,
        includeOverdueBills: true);
    final overdue = forecast.where((point) => point['overdue_since'] != null);
    expect(
        overdue.map((point) =>
            (point['item_pk'], point['date'], point['overdue_since'])),
        [('late', now, prior), ('subscription', now, prior)]);
    final recurrences = forecast.where((point) => point['projected'] == true);
    expect(recurrences.map((point) => point['date']),
        [now, later, now.add(const Duration(days: 2))]);
    expect(forecast.last['balance'], 885);
    expect(await db.select(db.transactions).get(), hasLength(6));
  });

  test(
      'metadata revisions stage once, apply reviewed updates and recheck intervening edits',
      () async {
    final db = await finance();
    final original = (await db.getCategoryInstanceOrNull('daily'))!;
    final older =
        original.copyWith(name: 'Remote', dateTimeModified: Value(prior));
    final sync = SyncLog(
        pk: 'daily',
        updateLogType: UpdateLogType.TransactionCategory,
        transactionDateTime: prior,
        itemToUpdate: older);
    await db.processSyncLogs([sync, sync]);
    expect((await db.getCategoryInstanceOrNull('daily'))!.name, 'Daily');
    final conflict = (await db.getOpenSyncConflicts()).single;
    expect(conflict['entity_type'], 'metadata');
    await db.resolveMetadataSyncConflict(conflict['conflict_pk'] as String,
        useRemote: true);
    expect((await db.getCategoryInstanceOrNull('daily'))!.name, 'Remote');
    final stillOlder = older.copyWith(name: 'Another device');
    await db.processSyncLogs([
      SyncLog(
          pk: 'daily',
          updateLogType: UpdateLogType.TransactionCategory,
          transactionDateTime: prior,
          itemToUpdate: stillOlder)
    ]);
    final retry =
        (await db.getOpenSyncConflicts()).single['conflict_pk'] as String;
    await db
        .into(db.categories)
        .insertOnConflictUpdate(original.copyWith(name: 'Local edit'));
    await expectLater(db.resolveMetadataSyncConflict(retry, useRemote: true),
        throwsStateError);
    expect((await db.getCategoryInstanceOrNull('daily'))!.name, 'Local edit');
  });

  test(
      'metadata deletions wait for related ledger changes and block orphaned rows',
      () async {
    final db = await finance();
    await db.into(db.transactions).insert(item('bill', now, -100, paid: true));
    final walletDelete = SyncLog(
        pk: 'local',
        deleteLogType: DeleteLogType.TransactionWallet,
        transactionDateTime: later);
    await db.processSyncLogs([walletDelete]);
    expect(await db.getWalletInstanceOrNull('local'), isNotNull);
    expect(await db.tryGetTransactionFromPk('bill'), isNotNull);
    final conflict =
        (await db.getOpenSyncConflicts()).single['conflict_pk'] as String;
    await expectLater(db.resolveMetadataSyncConflict(conflict, useRemote: true),
        throwsStateError);
    await db.processSyncLogs([
      walletDelete,
      SyncLog(
          pk: 'bill',
          deleteLogType: DeleteLogType.Transaction,
          transactionDateTime: later)
    ]);
    expect(await db.tryGetTransactionFromPk('bill'), isNull);
    expect(await db.getWalletInstanceOrNull('local'), isNull);
    expect((await db.getAllDeleteLogs()).map((row) => row.entryPk),
        containsAll(['bill', 'local']));
  });

  test(
      'paired category removals clear subcategories before checking the parent',
      () async {
    final db = await finance();
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          categoryPk: const Value('child'),
          name: 'Child',
          order: 1,
          dateTimeModified: Value(now),
          mainCategoryPk: const Value('daily'),
        ));
    await db.processSyncLogs([
      for (final pk in ['daily', 'child'])
        SyncLog(
            pk: pk,
            deleteLogType: DeleteLogType.TransactionCategory,
            transactionDateTime: later),
    ]);
    expect(await db.getCategoryInstanceOrNull('daily'), isNull);
    expect(await db.getCategoryInstanceOrNull('child'), isNull);
    expect(await db.getOpenSyncConflicts(), isEmpty);
  });
}
