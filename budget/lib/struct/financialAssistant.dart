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
    final amountMatch = RegExp(r'([0-9][0-9,]*(?:\\.[0-9]{1,2})?)')
        .firstMatch(raw);
    final amount =
        double.tryParse((amountMatch?.group(1) ?? '').replaceAll(',', ''));
    String? currency;
    if (RegExp(r'\\begp\\b|جنيه|ج\\.م', caseSensitive: false)
        .hasMatch(raw)) currency = 'egp';
    if (RegExp(r'\\busd\\b|دولار', caseSensitive: false)
        .hasMatch(raw)) currency = 'usd';

    FinancialAssistantIntentType type = FinancialAssistantIntentType.unknown;
    if (RegExp(r'حول|حوّل|transfer', caseSensitive: false).hasMatch(lower)) {
      type = FinancialAssistantIntentType.transfer;
    } else if (RegExp(r'قبضت|استلمت|دخل|income|received|salary',
            caseSensitive: false).hasMatch(lower)) {
      type = FinancialAssistantIntentType.addIncome;
    } else if (RegExp(r'دفعت|اشتريت|صرف|expense|spent|paid|bought',
            caseSensitive: false).hasMatch(lower)) {
      type = FinancialAssistantIntentType.addExpense;
    } else if (RegExp(r'رصيد|balance', caseSensitive: false).hasMatch(lower)) {
      type = FinancialAssistantIntentType.queryBalance;
    } else if (RegExp(r'صرف.*كام|spend|spending', caseSensitive: false)
        .hasMatch(lower)) {
      type = FinancialAssistantIntentType.querySpending;
    }

    return FinancialAssistantIntent(
      type: type,
      rawText: raw,
      amount: amount,
      currency: currency,
      merchantOrTitle: null,
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
