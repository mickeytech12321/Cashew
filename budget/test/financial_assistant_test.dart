import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/financialAssistant.dart';

void main() {
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
  test('transfer requires confirmation', () {
    final i = assistant.parse('transfer 100 EGP');
    expect(i.type, FinancialAssistantIntentType.transfer);
    expect(i.requiresConfirmation, isTrue);
  });
}
