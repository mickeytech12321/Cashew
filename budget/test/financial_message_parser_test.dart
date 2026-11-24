import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/financialMessageParser.dart';

void main() {
  group('FinancialMessageParser', () {
    test('parses English EGP debit', () {
      final p = FinancialMessageParser.parse(
          'Purchase EGP 1,250.50 at Carrefour card ending 1234');
      expect(p.amount, 1250.50);
      expect(p.currency, 'egp');
      expect(p.direction, 'debit');
      expect(p.lastFour, '1234');
      expect(p.confidence, greaterThanOrEqualTo(.8));
    });
    test('parses Arabic debit', () {
      final p = FinancialMessageParser.parse(
          'تم خصم 250 جنيه من بطاقتك 4321 عند AMAZON');
      expect(p.amount, 250);
      expect(p.currency, 'egp');
      expect(p.direction, 'debit');
      expect(p.lastFour, '4321');
    });
    test('unknown text stays low confidence', () {
      final p = FinancialMessageParser.parse('Welcome to our service');
      expect(p.amount, isNull);
      expect(p.confidence, 0);
    });
  });
}
