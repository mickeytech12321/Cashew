import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/financialMessageParser.dart';

void main() {
  group('FinancialMessageParser', () {
    test('parses English EGP debit', () {
      final p = FinancialMessageParser.parse(
        'Purchase EGP 1,250.50 at Carrefour card ending 1234',
      );
      expect(p.amount, 1250.50);
      expect(p.currency, 'egp');
      expect(p.direction, 'debit');
      expect(p.lastFour, '1234');
      expect(p.confidence, greaterThanOrEqualTo(.8));
    });
    test('parses Arabic debit', () {
      final p = FinancialMessageParser.parse(
        'تم خصم 250 جنيه من بطاقتك 4321 عند AMAZON',
      );
      expect(p.amount, 250);
      expect(p.currency, 'egp');
      expect(p.direction, 'debit');
      expect(p.lastFour, '4321');
    });
    test('reads Arabic-Indic currency and card digits', () {
      final p = FinancialMessageParser.parse(
        'تم خصم ١٬٢٥٠٫٥٠ ج.م. من بطاقتك ٤٣٢١',
      );
      expect(p.amount, 1250.50);
      expect(p.currency, 'egp');
      expect(p.lastFour, '4321');
    });
    test(
      'leaves ambiguous amounts and verification messages for manual entry',
      () {
        expect(
          FinancialMessageParser.parse('Purchase EGP 300 plus a fee of EGP 5.')
              .amount,
          isNull,
        );
        expect(
          FinancialMessageParser.parse('OTP 123456 for purchase EGP 300')
              .confidence,
          0,
        );
        expect(
          FinancialMessageParser.parse('Purchase declined for EGP 300')
              .confidence,
          0,
        );
      },
    );
    test('excludes explicitly labelled trailing balances', () {
      final english = FinancialMessageParser.parse(
        'Purchase EGP 300 at Shop. Available balance EGP 900.',
      );
      expect(english.amount, 300);
      expect(english.direction, 'debit');
      expect(english.merchant, 'Shop');
      final arabic = FinancialMessageParser.parse(
        'تم خصم ٢٥٠ جنيه، الرصيد المتاح ٤٠٠٠ جنيه',
      );
      expect(arabic.amount, 250);
      expect(arabic.direction, 'debit');
      expect(FinancialMessageParser.parse('Available balance EGP 900.').amount,
          isNull);
    });
    test('unknown text stays low confidence', () {
      final p = FinancialMessageParser.parse('Welcome to our service');
      expect(p.amount, isNull);
      expect(p.confidence, 0);
    });
  });
}
