import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart'
    show database, sharedPreferences;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _wallet = 'checking';
const _secondWallet = 'savings';

Future<void> _seed(FinanceDatabase db) async {
  for (final (id, currency) in [
    (_wallet, 'egp'),
    (_secondWallet, 'egp'),
    ('foreign', 'usd'),
  ]) {
    await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: Value(id),
          name: id,
          order: 0,
          currency: Value(currency),
        ));
  }
  await db.into(db.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('shopping'),
        name: 'Shopping',
        order: 0,
      ));
}

Transaction _payment({String wallet = _wallet, double amount = -1000}) =>
    Transaction(
      transactionPk: 'payment',
      walletFk: wallet,
      categoryFk: 'shopping',
      name: 'Shop',
      amount: amount,
      note: '',
      dateCreated: DateTime(2026, 11, 25, 12),
      paid: true,
      income: false,
      skipPaid: false,
    );

BankCertificate _certificate({int? autoFromDay}) => BankCertificate(
      id: 'monthly',
      name: 'Savings certificate',
      bank: 'My bank',
      walletPk: _wallet,
      currency: 'egp',
      principalMinor: 1000000,
      payoutMinor: 15000,
      firstPayoutDay: 20270131,
      maturityDay: 20270430,
      intervalMonths: 1,
      autoFromDay: autoFromDay,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FinanceDatabase db;

  setUp(() async {
    db = FinanceDatabase(NativeDatabase.memory());
    database = db;
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    await _seed(db);
  });

  tearDown(() => db.close());

  test(
      'a person-to-person InstaPay expense charges once and keeps editable principal',
      () async {
    final draft = _payment();
    final saved = await Future.wait([
      db.saveInstaPayExpense(draft, enabled: true),
      db.saveInstaPayExpense(draft, enabled: true),
    ]);
    expect(saved.map((t) => t.amount), [-1001, -1001]);
    expect(await db.getAllTransactionsFromWallet(_wallet), hasLength(1));
    final details = (await db.getInstaPayExpense(draft.transactionPk))!;
    expect((details.principal, details.fee), (1000, 1));

    final edit = await db.saveInstaPayExpense(
      saved.first.copyWith(amount: -25000),
      enabled: true,
      original: saved.first,
    );
    expect(edit.amount, -25020);
    expect((await db.getInstaPayExpense(edit.transactionPk))!.fee, 20);
    await expectLater(
      db.saveInstaPayExpense(draft, enabled: true, original: saved.first),
      throwsStateError,
    );

    final ordinary = await db.saveInstaPayExpense(
      edit.copyWith(amount: -25000),
      enabled: false,
      original: edit,
    );
    expect(ordinary.amount, -25000);
    expect(await db.getInstaPayExpense(draft.transactionPk), isNull);
  });

  test(
      'InstaPay rejects unsupported and archived accounts and applies the minimum fee',
      () async {
    await expectLater(
      db.saveInstaPayExpense(_payment(wallet: 'foreign'), enabled: true),
      throwsStateError,
    );
    await db.setAccountArchived(_secondWallet, true);
    await expectLater(
      db.saveInstaPayExpense(_payment(wallet: _secondWallet), enabled: true),
      throwsStateError,
    );
    await expectLater(
      db.saveInstaPayExpense(_payment(amount: -100.001), enabled: true),
      throwsArgumentError,
    );
    expect(
      (await db.saveInstaPayExpense(_payment(amount: -100), enabled: true))
          .amount,
      -100.50,
    );
  });

  test(
      'bank message review finds an InstaPay debit by principal or gross amount',
      () async {
    final draft = _payment();
    await db.saveInstaPayExpense(draft, enabled: true);
    for (final amount in [1000.0, 1001.0]) {
      final id = amount.toString();
      await db.stageImportedFinancialEvent(
        eventPk: id,
        sourceType: 'manual',
        rawText: 'InstaPay EGP $id',
        occurredAt: draft.dateCreated,
        amount: amount,
        currency: 'egp',
        direction: 'debit',
      );
      await expectLater(
        db.approveImportedFinancialEvent(
          eventPk: id,
          transactionPk: 'candidate-$id',
          walletPk: _wallet,
          categoryFk: 'shopping',
          duplicateAction: ImportDuplicateAction.ask,
        ),
        throwsA(isA<ImportedTransactionMatch>().having(
          (match) => match.transaction.transactionPk,
          'matching debit',
          'payment',
        )),
      );
      expect(
          await db.approveImportedFinancialEvent(
            eventPk: id,
            transactionPk: 'candidate-$id',
            walletPk: _wallet,
            categoryFk: 'shopping',
            expectedExistingPk: draft.transactionPk,
          ),
          'duplicate');
    }
    expect(await db.getAllTransactionsFromWallet(_wallet), hasLength(1));
  });

  test(
      'certificate payouts respect month ends, configured recipient and repeated sync',
      () async {
    final certificate = _certificate();
    final now = DateTime(2027, 3, 1);
    await db.createBankCertificate(certificate);
    expect(certificate.payoutDays(), [20270131, 20270228, 20270331, 20270430]);
    await db.postAutomaticCertificatePayouts(now);
    expect(await db.getAllTransactionsFromWallet(_wallet), isEmpty);
    await expectLater(
      db.recordCertificatePayout(certificate.id, 20270331, now: now),
      throwsArgumentError,
    );
    final results = await Future.wait([
      db.recordCertificatePayout(certificate.id, 20270131, now: now),
      db.recordCertificatePayout(certificate.id, 20270131, now: now),
    ]);
    expect(results, [true, false]);

    await expectLater(
        db.configureCertificatePayout(certificate.id, 'foreign',
            automatic: true, now: now),
        throwsStateError);
    await db.configureCertificatePayout(certificate.id, _secondWallet,
        automatic: true, now: now);
    await db.postAutomaticCertificatePayouts(DateTime(2027, 4, 1),
        arabic: true);
    await db.postAutomaticCertificatePayouts(DateTime(2027, 4, 2));
    expect(
        await db.recordedCertificateDays(certificate.id), {20270131, 20270331});
    final january = (await db.getAllTransactionsFromWallet(_wallet)).single;
    final march = (await db.getAllTransactionsFromWallet(_secondWallet)).single;
    expect((january.income, january.amount, january.dateCreated),
        (true, 150, DateTime(2027, 1, 31)));
    expect((march.income, march.amount, march.dateCreated, march.name),
        (true, 150, DateTime(2027, 3, 31), 'عائد شهادة · Savings certificate'));
  });

  test(
      'automatic returns wait for an active account and never resurrect a deleted return',
      () async {
    final certificate = _certificate(autoFromDay: 20270101);
    await db.createBankCertificate(certificate);
    await db.setAccountArchived(_wallet, true);
    await db.postAutomaticCertificatePayouts(DateTime(2027, 2, 1));
    expect(await db.recordedCertificateDays(certificate.id), isEmpty);
    await db.configureCertificatePayout(certificate.id, _secondWallet,
        automatic: true, now: DateTime(2027, 2, 1));
    await db.postAutomaticCertificatePayouts(DateTime(2027, 2, 1));
    final entry = (await db.getAllTransactionsFromWallet(_secondWallet)).single;
    await db.deleteTransaction(entry.transactionPk, updateSharedEntry: false);
    await db.postAutomaticCertificatePayouts(DateTime(2027, 2, 1));
    expect(await db.getAllTransactionsFromWallet(_secondWallet), isEmpty);
    expect(await db.recordedCertificateDays(certificate.id), {20270131});
  });

  test('certificate payout links existing same-day income only after review',
      () async {
    final certificate = _certificate(autoFromDay: 20270101);
    await db.createBankCertificate(certificate);
    await db.into(db.transactions).insert(_payment(amount: 150).copyWith(
          name: 'Bank deposit',
          income: true,
          dateCreated: DateTime(2027, 1, 31, 13),
        ));
    final now = DateTime(2027, 2, 1);
    await db.postAutomaticCertificatePayouts(now);
    expect(await db.recordedCertificateDays(certificate.id), isEmpty);
    final matching =
        (await db.certificatePayoutCandidates(certificate, 20270131)).single;
    await expectLater(
      db.recordCertificatePayout(certificate.id, 20270131, now: now),
      throwsStateError,
    );
    expect(
        await db.recordCertificatePayout(
          certificate.id,
          20270131,
          now: now,
          existing: matching,
        ),
        isFalse);
    expect(await db.recordedCertificateDays(certificate.id), {20270131});
    expect(await db.getAllTransactionsFromWallet(_wallet), [matching]);
  });

  test(
      'existing v48 data is preserved when banking tables are provisioned on reopen',
      () async {
    final directory = await Directory.systemTemp.createTemp('cashu-banking');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/cash.sqlite');
    late Transaction stored;
    final original = FinanceDatabase(NativeDatabase(file));
    try {
      await _seed(original);
      await original.into(original.transactions).insert(_payment());
      stored = await original.getTransactionFromPk('payment');
      for (final table in [
        'cashu_certificate_payouts',
        'cashu_bank_certificates',
        'cashu_instapay_expenses'
      ]) {
        await original.customStatement('DROP TABLE $table');
      }
    } finally {
      await original.close();
    }
    final reopened = FinanceDatabase(NativeDatabase(file));
    try {
      expect(
          await reopened
              .customSelect('PRAGMA user_version')
              .getSingle()
              .then((row) => row.read<int>('user_version')),
          48);
      expect(await reopened.getTransactionFromPk('payment'), stored);
      expect(await reopened.getBankCertificates(), isEmpty);
      await reopened.createBankCertificate(_certificate());
      expect(await reopened.getBankCertificates(), hasLength(1));
    } finally {
      await reopened.close();
    }
  });
}
