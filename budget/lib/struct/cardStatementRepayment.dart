import 'package:budget/database/tables.dart';

typedef CardStatementRepayment = ({
  TransactionWallet source,
  TransactionWallet card,
  DateTime closed,
  double minimum,
  double remaining,
});

/// Read the current statement and the saved repayment account together.
Future<CardStatementRepayment?> loadCardStatementRepayment(
  FinanceDatabase db,
  String cardId,
  DateTime closed, {
  DateTime? asOf,
}) =>
    db.transaction(() async {
      final card = await db.getWalletInstanceOrNull(cardId);
      final account = await db.getAccountDetails(cardId);
      final details = await db.getCreditCardDetails(cardId);
      final bankId = details?['linked_bank_wallet_fk'] as String?;
      if (card == null ||
          account?['account_type'] != 'credit' ||
          account?['archived'] == 1 ||
          bankId == null ||
          bankId == cardId) return null;
      final source = await db.getWalletInstanceOrNull(bankId);
      final bankAccount = await db.getAccountDetails(bankId);
      if (source == null ||
          source.currency?.trim().isNotEmpty != true ||
          bankAccount?['archived'] == 1) return null;
      final statements = await db.getCreditCardStatements(cardId, asOf: asOf);
      final statement =
          statements.where((row) => row.closed == closed).firstOrNull;
      if (statement == null ||
          statement.superseded ||
          statement.currency != card.currency?.toLowerCase()) return null;

      final decimals = card.decimals.clamp(0, 12);
      final remaining =
          double.parse((statement.remaining ?? 0).toStringAsFixed(decimals));
      final minimum = double.parse(
          (statement.minimumRemaining ?? 0).toStringAsFixed(decimals));
      if (!remaining.isFinite || remaining <= 0 || !minimum.isFinite)
        return null;
      return (
        source: source,
        card: card,
        closed: closed,
        minimum: minimum,
        remaining: remaining
      );
    });

/// Return null when the statement or active repayment account changed.
Future<bool?> saveCardStatementRepayment(
  FinanceDatabase db,
  CardStatementRepayment reviewed,
  Transaction debit,
  Transaction credit, {
  required String idempotencyKey,
  DateTime? asOf,
}) =>
    db.transaction(() async {
      final current = await loadCardStatementRepayment(
          db, reviewed.card.walletPk, reviewed.closed,
          asOf: asOf);
      if (current != reviewed) return null;
      if (debit.walletFk != reviewed.source.walletPk ||
          credit.walletFk != reviewed.card.walletPk) {
        throw ArgumentError(
            'Repayment accounts do not match the reviewed statement');
      }
      return db.saveAtomicLocalTransfer(debit, credit,
          idempotencyKey: idempotencyKey, preserveTime: true);
    });
