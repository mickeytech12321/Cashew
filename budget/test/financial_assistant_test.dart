import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/financialAssistant.dart';

void main() {

  test('distinguishes transfer commands from expense descriptions', () {
    const assistant = FinancialAssistant();
    expect(assistant.parse('Please transfer EGP 20').type,
        FinancialAssistantIntentType.transfer);
    expect(assistant.parse('حولت ٢٠ جنيه').type,
        FinancialAssistantIntentType.transfer);
    expect(assistant.parse('I paid EGP 20 for an airport transfer').type,
        FinancialAssistantIntentType.addExpense);
    expect(assistant.parse('حولين المحطة').type,
        FinancialAssistantIntentType.unknown);
  });

  test('understands spending periods in Arabic and English', () {
    const assistant = FinancialAssistant();
    final arabic = assistant.parse('صرفت كام الشهر اللي فات؟');
    expect(arabic.type, FinancialAssistantIntentType.querySpending);
    expect(arabic.spendingPeriod, SpendingPeriod.previousMonth);
    expect(arabic.requiresConfirmation, isFalse);
    final english = assistant.parse('How much did I spend last week?');
    expect(english.type, FinancialAssistantIntentType.querySpending);
    expect(english.spendingPeriod, SpendingPeriod.previousWeek);
    expect(assistant.parse('I spent EGP 20').type,
        FinancialAssistantIntentType.addExpense);
  });

  test('spending periods respect calendar and year boundaries', () {
    final now = DateTime(2027, 1, 3, 20);
    expect(SpendingPeriod.previousMonth.range(now),
        (start: DateTime(2026, 12), end: DateTime(2027, 1)));
    expect(SpendingPeriod.previousWeek.range(now),
        (start: DateTime(2026, 12, 21), end: DateTime(2026, 12, 28)));
    expect(SpendingPeriod.currentWeek.range(now),
        (start: DateTime(2026, 12, 28), end: null));
  });

  const assistant = FinancialAssistant();
  test('Arabic expense requires confirmation', () {
    final i = assistant.parse('دفعت 250 جنيه');
    expect(i.type, FinancialAssistantIntentType.addExpense);
    expect(i.amount, 250);
    expect(i.currency, 'egp');
    expect(i.requiresConfirmation, isTrue);
  });
  test('balance query is read only', () {
    final i = assistant.parse('كام الرصيد؟');
    expect(i.type, FinancialAssistantIntentType.queryBalance);
    expect(i.requiresConfirmation, isFalse);
  });
  test('Arabic spending question is read only', () {
    final result = assistant.parse('صرفنا كام الشهر ده؟');
    expect(result.type, FinancialAssistantIntentType.querySpending);
    expect(result.requiresConfirmation, isFalse);
  });
  test('transfer requires confirmation', () {
    final i = assistant.parse('transfer 100 EGP');
    expect(i.type, FinancialAssistantIntentType.transfer);
    expect(i.requiresConfirmation, isTrue);
  });
}
