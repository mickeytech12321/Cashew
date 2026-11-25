import 'package:budget/database/tables.dart';
import 'package:budget/struct/instaPayTransfer.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('InstaPay fees use the EGP limits and round to piastres', () {
    expect(instaPayTransferFee(0.01), .50);
    expect(instaPayTransferFee(500), .50);
    expect(instaPayTransferFee(1234.56), 1.23);
    expect(instaPayTransferFee(1235), 1.24);
    expect(instaPayTransferFee(19990), 19.99);
    expect(instaPayTransferFee(20000), 20);
    expect(instaPayTransferFee(30000), 20);
    for (final invalid in [
      0.0,
      -1.0,
      1.001,
      .001,
      double.nan,
      double.infinity
    ]) {
      expect(instaPayTransferFee(invalid), isNull);
    }
  });

  test('local transfer and sender fee commit, retry, undo and redo together',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final (id, currency) in [
      ('sender', 'EGP'),
      ('recipient', 'egp'),
      ('usd', 'usd')
    ]) {
      await db.into(db.wallets).insert(WalletsCompanion.insert(
            walletPk: Value(id),
            name: id,
            order: 0,
            currency: Value(currency),
          ));
    }
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          categoryPk: const Value('0'),
          name: 'Transfer',
          order: 0,
        ));
    Transaction leg(String id, String wallet, double amount) => Transaction(
          transactionPk: id,
          name: 'Transfer',
          amount: amount,
          note: '',
          categoryFk: '0',
          walletFk: wallet,
          dateCreated: DateTime(2026, 11, 25),
          income: amount > 0,
          paid: true,
          skipPaid: false,
        );

    final debit = leg('debit', 'sender', -1235);
    final credit = leg('credit', 'recipient', 1235);
    final foreignCredit = leg('foreign', 'usd', 1235);
    await expectLater(
      db.saveAtomicLocalTransfer(debit, foreignCredit,
          idempotencyKey: 'foreign', instaPay: true),
      throwsArgumentError,
    );
    await db.setAccountArchived('recipient', true);
    await expectLater(
      db.saveAtomicLocalTransfer(debit, credit,
          idempotencyKey: 'archived', instaPay: true),
      throwsStateError,
    );
    expect(await db.select(db.transactions).get(), isEmpty);
    await db.setAccountArchived('recipient', false);

    Future<bool> save() => db.saveAtomicLocalTransfer(
          debit,
          credit,
          idempotencyKey: 'payment',
          instaPay: true,
        );
    final results = await Future.wait([save(), save()]);
    expect(results, unorderedEquals([true, false]));
    final entries = await db.select(db.transactions).get();
    expect(entries, hasLength(3));
    final fee = entries.singleWhere((entry) => entry.categoryFk != '0');
    expect(fee.walletFk, 'sender');
    expect(fee.amount, -1.24);
    expect(fee.income, isFalse);
    expect(fee.pairedTransactionFk, isNull);
    expect(await db.getLocalFinancialActionChanges('debit'), hasLength(3));
    expect(await db.undoLocalTransfer('debit'), isTrue);
    expect(await db.select(db.transactions).get(), isEmpty);
    expect((await db.getAllDeleteLogs()).map((entry) => entry.entryPk),
        unorderedEquals(['debit', 'credit', fee.transactionPk]));
    expect(await db.redoLocalTransfer('debit'), isTrue);
    expect((await db.getTransactionFromPk(fee.transactionPk)).amount, -1.24);
    expect(await db.getAllDeleteLogs(), isEmpty);

    await db.createOrUpdateTransaction(
      fee.copyWith(amount: -2),
      updateSharedEntry: false,
    );
    await expectLater(db.undoLocalTransfer('debit'), throwsStateError);
    expect(await db.select(db.transactions).get(), hasLength(3));
  });
}
