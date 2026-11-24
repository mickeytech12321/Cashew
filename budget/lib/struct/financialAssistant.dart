import 'financialMessageParser.dart';

enum FinancialAssistantIntentType {
  addExpense,
  addIncome,
  transfer,
  queryBalance,
  querySpending,
  unknown,
}

class FinancialAssistantIntent {
  final FinancialAssistantIntentType type;
  final double? amount;
  final String? currency;
  final String? merchantOrTitle;
  final String rawText;
  final bool requiresConfirmation;

  const FinancialAssistantIntent({
    required this.type,
    required this.rawText,
    this.amount,
    this.currency,
    this.merchantOrTitle,
    required this.requiresConfirmation,
  });
}

class FinancialAssistant {
  const FinancialAssistant();

  /// Local deterministic parser. It does not send financial data to a network.
  FinancialAssistantIntent parse(String input) {
    final raw = input.trim();
    final lower = raw.toLowerCase();
    final parsed = FinancialMessageParser.parse(raw);

    FinancialAssistantIntentType type = FinancialAssistantIntentType.unknown;
    if (RegExp(r'حول|حوّل|transfer', caseSensitive: false).hasMatch(lower)) {
      type = FinancialAssistantIntentType.transfer;
    } else if (RegExp(r'رصيد|\bbalance\b').hasMatch(lower)) {
      type = FinancialAssistantIntentType.queryBalance;
    } else if (RegExp(r'صرف.*كام|كام.*صرف|\b(?:spend|spending)\b')
        .hasMatch(lower)) {
      type = FinancialAssistantIntentType.querySpending;
    } else if (RegExp(
      r'قبضت|استلمت|دخل|income|received|salary',
      caseSensitive: false,
    ).hasMatch(lower)) {
      type = FinancialAssistantIntentType.addIncome;
    } else if (RegExp(
      r'دفعت|اشتريت|صرف|expense|spent|paid|bought',
      caseSensitive: false,
    ).hasMatch(lower)) {
      type = FinancialAssistantIntentType.addExpense;
    }

    return FinancialAssistantIntent(
      type: type,
      rawText: raw,
      amount: parsed.amount,
      currency: parsed.currency,
      merchantOrTitle: parsed.merchant,
      requiresConfirmation: {
        FinancialAssistantIntentType.addExpense,
        FinancialAssistantIntentType.addIncome,
        FinancialAssistantIntentType.transfer,
      }.contains(type),
    );
  }
}

/// Network AI providers are deliberately optional. A provider may interpret text,
/// but execution of any write intent must still go through explicit confirmation.
abstract class OptionalFinancialAiProvider {
  String get providerId;
  Future<FinancialAssistantIntent> interpret(String input);
}
