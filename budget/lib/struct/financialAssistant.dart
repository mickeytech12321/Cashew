import 'financialMessageParser.dart';

enum SpendingPeriod {
  currentMonth,
  previousMonth,
  currentWeek,
  previousWeek,
  currentYear;

  ({DateTime start, DateTime? end}) range(DateTime now) {
    final monday = DateTime(now.year, now.month, now.day - now.weekday + 1);
    return switch (this) {
      currentMonth => (start: DateTime(now.year, now.month), end: null),
      previousMonth => (
          start: DateTime(now.year, now.month - 1),
          end: DateTime(now.year, now.month),
        ),
      currentWeek => (start: monday, end: null),
      previousWeek => (
          start: DateTime(monday.year, monday.month, monday.day - 7),
          end: monday,
        ),
      currentYear => (start: DateTime(now.year), end: null),
    };
  }
}

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
  final SpendingPeriod spendingPeriod;

  const FinancialAssistantIntent({
    required this.type,
    required this.rawText,
    this.amount,
    this.currency,
    this.merchantOrTitle,
    required this.requiresConfirmation,
    this.spendingPeriod = SpendingPeriod.currentMonth,
  });
}

class FinancialAssistant {
  const FinancialAssistant();

  /// Local deterministic parser. It does not send financial data to a network.
  FinancialAssistantIntent parse(String input) {
    final raw = input.trim();
    final lower = raw.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final parsed = FinancialMessageParser.parse(raw);

    FinancialAssistantIntentType type = FinancialAssistantIntentType.unknown;
    if (RegExp(r'^(?:(?:please|log|record)\s+)*(?:transfer\b|(?:حوّلت|حولت|حوّل|حول)(?:\s|$))').hasMatch(lower)) {
      type = FinancialAssistantIntentType.transfer;
    } else if (RegExp(r'رصيد|\bbalance\b').hasMatch(lower)) {
      type = FinancialAssistantIntentType.queryBalance;
    } else if (RegExp(r'صرف.*(?:كام|قد إيه)|(?:كام|كم|قد إيه).*صرف|مصروفاتي|\b(?:spend|spending)\b|\bhow much\b.*\b(?:spent|expenses)\b')
        .hasMatch(lower)) {
      type = FinancialAssistantIntentType.querySpending;
    } else if (RegExp(
      r'قبضت|استلمت|دخل|\b(?:income|received|salary)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      type = FinancialAssistantIntentType.addIncome;
    } else if (RegExp(
      r'دفعت|اشتريت|صرف|\b(?:expense|spent|paid|bought)\b',
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
      spendingPeriod: switch (lower) {
        final value when RegExp(r'\blast month\b|الشهر (?:اللي فات|الماضي|السابق)').hasMatch(value) => SpendingPeriod.previousMonth,
        final value when RegExp(r'\blast week\b|الأسبوع (?:اللي فات|الماضي|السابق)').hasMatch(value) => SpendingPeriod.previousWeek,
        final value when RegExp(r'\bthis week\b|هذا الأسبوع|الأسبوع ده').hasMatch(value) => SpendingPeriod.currentWeek,
        final value when RegExp(r'\bthis year\b|هذه السنة|السنة دي|هذا العام').hasMatch(value) => SpendingPeriod.currentYear,
        _ => SpendingPeriod.currentMonth,
      },
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
