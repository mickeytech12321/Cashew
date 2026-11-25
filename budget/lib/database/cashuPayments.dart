part of 'tables.dart';

class InstaPayExpense {
  const InstaPayExpense(this.principal, this.fee);
  final double principal;
  final double fee;
}

// Entered cash amounts use integer piastres. The ledger still uses the
// original transaction representation, so reports and exports see the debit.
Future<void> _createCashuPaymentSchema(FinanceDatabase db) async {
  await db
      .customStatement('''CREATE TABLE IF NOT EXISTS cashu_instapay_expenses (
    transaction_fk TEXT PRIMARY KEY NOT NULL REFERENCES transactions(transaction_pk) ON DELETE CASCADE,
    wallet_fk TEXT NOT NULL,
    principal_minor INTEGER NOT NULL CHECK (principal_minor > 0),
    fee_minor INTEGER NOT NULL CHECK (fee_minor BETWEEN 50 AND 2000)
  )''');
  await db
      .customStatement('''CREATE TABLE IF NOT EXISTS cashu_bank_certificates (
    certificate_pk TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    bank_name TEXT NOT NULL,
    wallet_fk TEXT NOT NULL,
    currency TEXT NOT NULL,
    principal_minor INTEGER NOT NULL CHECK (principal_minor > 0),
    payout_minor INTEGER NOT NULL CHECK (payout_minor > 0),
    first_payout_day INTEGER NOT NULL,
    maturity_day INTEGER NOT NULL CHECK (maturity_day >= first_payout_day),
    interval_months INTEGER NOT NULL CHECK (interval_months IN (0, 1, 3, 6, 12)),
    auto_from_day INTEGER
  )''');
  await db
      .customStatement('''CREATE TABLE IF NOT EXISTS cashu_certificate_payouts (
    certificate_fk TEXT NOT NULL REFERENCES cashu_bank_certificates(certificate_pk),
    due_day INTEGER NOT NULL,
    transaction_fk TEXT UNIQUE NOT NULL,
    PRIMARY KEY (certificate_fk, due_day)
  )''');
}

int _egpMinor(double amount) {
  if (!amount.isFinite || amount <= 0 || amount > 999999999999) {
    throw ArgumentError('Invalid amount');
  }
  final minor = (amount * 100).round();
  if (minor < 1 || (minor / 100 - amount).abs() > 0.000000001) {
    throw ArgumentError('Use at most two decimal places');
  }
  return minor;
}

bool _paymentSnapshotMatches(Transaction? current, Transaction expected) =>
    current != null &&
    listEquals(current.budgetFksExclude, expected.budgetFksExclude) &&
    current.copyWith(budgetFksExclude: const Value(null)) ==
        expected.copyWith(budgetFksExclude: const Value(null));

extension CashuExpensePayments on FinanceDatabase {
  Future<InstaPayExpense?> getInstaPayExpense(String transactionPk) async {
    final row = await customSelect(
      'SELECT p.principal_minor, p.fee_minor FROM cashu_instapay_expenses p '
      'JOIN transactions t ON t.transaction_pk = p.transaction_fk AND t.wallet_fk = p.wallet_fk '
      'JOIN wallets w ON w.wallet_pk = t.wallet_fk '
      "WHERE p.transaction_fk = ? AND LOWER(w.currency) = 'egp' "
      'AND t.income = 0 AND t.paid = 1 AND t.type IS NULL '
      'AND ROUND(-t.amount * 100) = p.principal_minor + p.fee_minor',
      variables: [Variable<String>(transactionPk)],
    ).getSingleOrNull();
    if (row == null) return null;
    return InstaPayExpense(row.read<int>('principal_minor') / 100,
        row.read<int>('fee_minor') / 100);
  }

  Future<Transaction> saveInstaPayExpense(
    Transaction expense, {
    required bool enabled,
    Transaction? original,
  }) async {
    if (expense.transactionPk.trim().isEmpty ||
        expense.transactionPk == '-1' ||
        expense.sharedKey != null ||
        (original != null && original.transactionPk != expense.transactionPk)) {
      throw ArgumentError('Use a local expense');
    }
    final principal = enabled ? _egpMinor(-expense.amount) : 0;
    final fee = enabled ? instaPayTransferFee(-expense.amount) : null;
    if (enabled &&
        (fee == null ||
            expense.categoryFk == '0' ||
            expense.income ||
            !expense.paid ||
            expense.type != null ||
            expense.pairedTransactionFk != null ||
            expense.objectiveLoanFk != null)) {
      throw ArgumentError('InstaPay needs a paid expense');
    }
    final feeMinor = fee == null ? 0 : (fee * 100).round();
    final debit = enabled ? (principal + feeMinor) / 100 : -expense.amount;
    if (enabled && debit > 999999999999)
      throw ArgumentError('Invalid total debit');

    return transaction(() async {
      final budgetPk = expense.sharedReferenceBudgetPk;
      if (budgetPk != null &&
          (await getBudgetInstance(budgetPk)).sharedKey != null) {
        throw StateError('Use a local budget for the InstaPay expense');
      }
      final wallet = await getWalletInstanceOrNull(expense.walletFk);
      if (wallet == null ||
          (await getAccountDetails(wallet.walletPk))?['archived'] == 1 ||
          (enabled && !isInstaPayCurrency(wallet.currency))) {
        throw StateError('Choose an active account in the supported currency');
      }

      final current = await tryGetTransactionFromPk(expense.transactionPk);
      if (original != null && !_paymentSnapshotMatches(current, original)) {
        throw StateError('The expense changed. Reopen it before saving');
      }
      if (original == null && current != null) {
        final method = await getInstaPayExpense(expense.transactionPk);
        if (enabled &&
            method?.principal == principal / 100 &&
            current.walletFk == expense.walletFk &&
            current.categoryFk == expense.categoryFk &&
            current.name == expense.name.trim() &&
            current.note == expense.note &&
            current.subCategoryFk == expense.subCategoryFk &&
            current.objectiveFk == expense.objectiveFk &&
            current.sharedReferenceBudgetPk ==
                expense.sharedReferenceBudgetPk &&
            listEquals(current.budgetFksExclude, expense.budgetFksExclude) &&
            current.dateCreated.millisecondsSinceEpoch ~/ 1000 ==
                expense.dateCreated.millisecondsSinceEpoch ~/ 1000 &&
            current.amount == -debit) {
          return current;
        }
        throw StateError('The expense already exists');
      }

      final saved = await createOrUpdateTransaction(
        enabled ? expense.copyWith(amount: -debit, skipPaid: false) : expense,
        originalTransaction: original,
        updateSharedEntry: false,
      );
      if (saved == null) throw StateError('Could not save expense');
      if (enabled) {
        await customStatement(
          'INSERT INTO cashu_instapay_expenses (transaction_fk, wallet_fk, principal_minor, fee_minor) '
          'VALUES (?, ?, ?, ?) ON CONFLICT(transaction_fk) DO UPDATE SET '
          'wallet_fk = excluded.wallet_fk, principal_minor = excluded.principal_minor, '
          'fee_minor = excluded.fee_minor',
          [expense.transactionPk, expense.walletFk, principal, feeMinor],
        );
      } else {
        await customStatement(
          'DELETE FROM cashu_instapay_expenses WHERE transaction_fk = ?',
          [expense.transactionPk],
        );
      }
      return getTransactionFromPk(expense.transactionPk);
    });
  }
}

int certificateDay(DateTime date) =>
    date.year * 10000 + date.month * 100 + date.day;
DateTime certificateDate(int day) =>
    DateTime(day ~/ 10000, day ~/ 100 % 100, day % 100);

class BankCertificate {
  const BankCertificate({
    required this.id,
    required this.name,
    required this.bank,
    required this.walletPk,
    required this.currency,
    required this.principalMinor,
    required this.payoutMinor,
    required this.firstPayoutDay,
    required this.maturityDay,
    required this.intervalMonths,
    this.autoFromDay,
  });

  factory BankCertificate.fromRow(QueryRow row) => BankCertificate(
        id: row.read<String>('certificate_pk'),
        name: row.read<String>('name'),
        bank: row.read<String>('bank_name'),
        walletPk: row.read<String>('wallet_fk'),
        currency: row.read<String>('currency'),
        principalMinor: row.read<int>('principal_minor'),
        payoutMinor: row.read<int>('payout_minor'),
        firstPayoutDay: row.read<int>('first_payout_day'),
        maturityDay: row.read<int>('maturity_day'),
        intervalMonths: row.read<int>('interval_months'),
        autoFromDay: row.readNullable<int>('auto_from_day'),
      );

  final String id;
  final String name;
  final String bank;
  final String walletPk;
  final String currency;
  final int principalMinor;
  final int payoutMinor;
  final int firstPayoutDay;
  final int maturityDay;
  final int intervalMonths;
  final int? autoFromDay;

  Iterable<int> payoutDays() sync* {
    final first = certificateDate(firstPayoutDay);
    if (intervalMonths == 0) {
      yield maturityDay;
      return;
    }
    var date = first;
    for (var months = intervalMonths;
        certificateDay(date) <= maturityDay;
        months += intervalMonths) {
      yield certificateDay(date);
      date = nextRecurringDate(first, BudgetReoccurence.monthly, months)!;
    }
  }
}

extension CashuCertificates on FinanceDatabase {
  Future<TransactionWallet> _certificateWallet(
      String walletPk, String currency) async {
    final wallet = await getWalletInstanceOrNull(walletPk);
    if (wallet == null ||
        wallet.currency?.toLowerCase() != currency ||
        (await getAccountDetails(walletPk))?['archived'] == 1) {
      throw StateError(
          'Choose an active payout account in the certificate currency');
    }
    return wallet;
  }

  Future<void> createBankCertificate(BankCertificate certificate) async {
    if (certificate.id.trim().isEmpty ||
        certificate.name.trim().isEmpty ||
        certificate.name.trim().length > NAME_LIMIT - 32 ||
        certificate.bank.trim().length > NAME_LIMIT ||
        !isInstaPayCurrency(certificate.currency) ||
        certificate.principalMinor <= 0 ||
        certificate.principalMinor > 99999999999900 ||
        certificate.payoutMinor <= 0 ||
        certificate.payoutMinor > 99999999999900 ||
        certificate.maturityDay < certificate.firstPayoutDay ||
        certificate.maturityDay ~/ 10000 - certificate.firstPayoutDay ~/ 10000 >
            50 ||
        !const {0, 1, 3, 6, 12}.contains(certificate.intervalMonths) ||
        (certificate.intervalMonths == 0 &&
            certificate.firstPayoutDay != certificate.maturityDay) ||
        certificateDay(certificateDate(certificate.firstPayoutDay)) !=
            certificate.firstPayoutDay ||
        certificateDay(certificateDate(certificate.maturityDay)) !=
            certificate.maturityDay) {
      throw ArgumentError('Invalid certificate terms');
    }
    await transaction(() async {
      await _certificateWallet(certificate.walletPk, certificate.currency);
      await customStatement(
        'INSERT INTO cashu_bank_certificates '
        '(certificate_pk, name, bank_name, wallet_fk, currency, principal_minor, payout_minor, '
        'first_payout_day, maturity_day, interval_months, auto_from_day) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          certificate.id,
          certificate.name.trim(),
          certificate.bank.trim(),
          certificate.walletPk,
          certificate.currency,
          certificate.principalMinor,
          certificate.payoutMinor,
          certificate.firstPayoutDay,
          certificate.maturityDay,
          certificate.intervalMonths,
          certificate.autoFromDay
        ],
      );
    });
  }

  Future<
      List<BankCertificate>> getBankCertificates() async => (await customSelect(
              'SELECT * FROM cashu_bank_certificates ORDER BY maturity_day, name')
          .get())
      .map(BankCertificate.fromRow)
      .toList();

  Future<BankCertificate> getBankCertificate(String id) async =>
      BankCertificate.fromRow(await customSelect(
        'SELECT * FROM cashu_bank_certificates WHERE certificate_pk = ?',
        variables: [Variable<String>(id)],
      ).getSingle());

  Future<Set<int>> recordedCertificateDays(String id) async =>
      (await customSelect(
        'SELECT due_day FROM cashu_certificate_payouts WHERE certificate_fk = ?',
        variables: [Variable<String>(id)],
      ).get())
          .map((row) => row.read<int>('due_day'))
          .toSet();

  Future<void> configureCertificatePayout(
    String id,
    String walletPk, {
    required bool automatic,
    required DateTime now,
  }) =>
      transaction(() async {
        final certificate = await getBankCertificate(id);
        await _certificateWallet(walletPk, certificate.currency);
        await customStatement(
          'UPDATE cashu_bank_certificates SET wallet_fk = ?, auto_from_day = ? WHERE certificate_pk = ?',
          [
            walletPk,
            automatic ? certificate.autoFromDay ?? certificateDay(now) : null,
            id
          ],
        );
      });

  Future<List<Transaction>> certificatePayoutCandidates(
    BankCertificate certificate,
    int dueDay,
  ) {
    final date = certificateDate(dueDay);
    final amount = certificate.payoutMinor / 100;
    return customSelect(
      'SELECT t.* FROM transactions t WHERE t.wallet_fk = ? '
      'AND t.income = 1 AND t.paid = 1 AND t.skip_paid = 0 AND t.type IS NULL '
      "AND t.category_fk != '0' AND t.paired_transaction_fk IS NULL "
      'AND t.amount BETWEEN ? AND ? AND t.date_created >= ? AND t.date_created < ? '
      'AND NOT EXISTS (SELECT 1 FROM cashu_certificate_payouts p WHERE p.transaction_fk = t.transaction_pk) '
      'ORDER BY t.date_created, t.transaction_pk',
      variables: [
        Variable<String>(certificate.walletPk),
        Variable<double>(amount - 0.00000001),
        Variable<double>(amount + 0.00000001),
        Variable<DateTime>(date),
        Variable<DateTime>(DateTime(date.year, date.month, date.day + 1)),
      ],
    ).map((row) => transactions.map(row.data)).get();
  }

  Future<bool> recordCertificatePayout(
    String id,
    int dueDay, {
    required DateTime now,
    bool automatic = false,
    bool arabic = false,
    Transaction? existing,
    bool confirmedSeparate = false,
  }) =>
      transaction(() async {
        final certificate = await getBankCertificate(id);
        if (dueDay > certificateDay(now) ||
            !certificate.payoutDays().contains(dueDay)) {
          throw ArgumentError('This payout is not due');
        }
        if (automatic &&
            (certificate.autoFromDay == null ||
                dueDay < certificate.autoFromDay!)) return false;

        final alreadyRecorded = await customSelect(
          'SELECT 1 FROM cashu_certificate_payouts WHERE certificate_fk = ? AND due_day = ?',
          variables: [Variable<String>(id), Variable<int>(dueDay)],
        ).getSingleOrNull();
        if (alreadyRecorded != null) return false;

        final wallet = await _certificateWallet(
            certificate.walletPk, certificate.currency);
        const categoryPk = 'cashu-certificate-interest';
        final label = arabic ? 'عائد شهادة' : 'Certificate interest';
        final entryPk = 'cashu-certificate:$id:$dueDay';
        final synced = await tryGetTransactionFromPk(entryPk);
        final deleted = await customSelect(
          'SELECT 1 FROM delete_logs WHERE entry_pk = ? AND type = ? LIMIT 1',
          variables: [
            Variable<String>(entryPk),
            Variable<int>(DeleteLogType.Transaction.index)
          ],
        ).getSingleOrNull();

        if (synced == null && deleted == null) {
          final candidates =
              await certificatePayoutCandidates(certificate, dueDay);
          if (existing != null &&
              !candidates
                  .any((entry) => _paymentSnapshotMatches(entry, existing))) {
            throw StateError('The matching income changed');
          }
          if (existing == null && !confirmedSeparate && candidates.isNotEmpty) {
            if (automatic) return false;
            throw StateError(
                'Review the existing income before adding another');
          }
        }
        final createIncome =
            synced == null && deleted == null && existing == null;
        if (createIncome) {
          await into(categories).insert(
            CategoriesCompanion.insert(
              categoryPk: const Value(categoryPk),
              name: label,
              order: await getAmountOfCategories(),
              income: const Value(true),
            ),
            mode: InsertMode.insertOrIgnore,
          );
          final timestamp = now.isAfter(certificateDate(dueDay))
              ? certificateDate(dueDay)
              : now;
          await into(transactions).insert(Transaction(
            transactionPk: entryPk,
            walletFk: wallet.walletPk,
            categoryFk: categoryPk,
            name: '$label · ${certificate.name}',
            amount: certificate.payoutMinor / 100,
            note: '',
            dateCreated: timestamp,
            dateTimeModified: now,
            income: true,
            paid: true,
            skipPaid: false,
          ));
        }
        await customStatement(
          'INSERT INTO cashu_certificate_payouts (certificate_fk, due_day, transaction_fk) VALUES (?, ?, ?)',
          [
            id,
            dueDay,
            synced == null && deleted == null
                ? existing?.transactionPk ?? entryPk
                : entryPk
          ],
        );
        return createIncome;
      });

  Future<void> postAutomaticCertificatePayouts(DateTime now,
      {bool arabic = false}) async {
    for (final certificate in await getBankCertificates()) {
      final from = certificate.autoFromDay;
      if (from == null) continue;
      final recorded = await recordedCertificateDays(certificate.id);
      for (final day in certificate.payoutDays()) {
        if (day > certificateDay(now)) break;
        if (day < from || recorded.contains(day)) continue;
        try {
          await recordCertificatePayout(certificate.id, day,
              now: now, automatic: true, arabic: arabic);
        } on StateError {
          // The account was removed or archived. Leave the due payout for review.
          break;
        }
      }
    }
  }
}
