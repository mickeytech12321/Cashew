import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/financialMessageParser.dart';

void main() {
  group('FinancialMessageParser', () {
    test('recognizes foreign card amounts and refuses ambiguous currencies',
        () {
      final euro = FinancialMessageParser.parse('Purchase EUR 25.70 at Shop');
      expect((euro.amount, euro.currency, euro.direction),
          (25.70, 'eur', 'debit'));
      final dinar = FinancialMessageParser.parse('تم خصم ١٢٫٣٤٥ KWD');
      expect((dinar.amount, dinar.currency), (12.345, 'kwd'));
      expect(FinancialMessageParser.parse('Paid EGP 12.345').amount, isNull);
      expect(FinancialMessageParser.parse('Purchase AED 25 or EGP 300').amount,
          isNull);
    });
    test('reads wallet cash movements and ignores incomplete transfers', () {
      final cashIn = FinancialMessageParser.parse(
          'Cash in EGP 300. Available bal: EGP 900');
      expect((cashIn.amount, cashIn.direction), (300.0, 'credit'));
      final cashOut = FinancialMessageParser.parse('Cash out EGP 40');
      expect((cashOut.amount, cashOut.direction), (40.0, 'debit'));
      expect(
          FinancialMessageParser.parse('لم يكتمل التحويل ٣٠٠ جنيه').confidence,
          0);
    });
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
    test('recognizes explicit Egyptian wallet transfers in English and Arabic',
        () {
      final sent =
          FinancialMessageParser.parse('You sent LE 200.00 to a wallet');
      expect((sent.amount, sent.currency, sent.direction),
          (200.0, 'egp', 'debit'));
      final received =
          FinancialMessageParser.parse('تم استلام ٢٠٠ جنيه من محفظة');
      expect((received.amount, received.currency, received.direction),
          (200.0, 'egp', 'credit'));
      final unknown = FinancialMessageParser.parse('Transfer EGP 200');
      expect(unknown.direction, isNull);
    });
    test('unknown text stays low confidence', () {
      final p = FinancialMessageParser.parse('Welcome to our service');
      expect(p.amount, isNull);
      expect(p.confidence, 0);
    });
    test('reads compact card alerts with an unpunctuated balance', () {
      final parsed = FinancialMessageParser.parse(
        'Purchase L.E. 650.50 at Shop card ending 9932 avail. balance LE 900',
      );
      expect(
          (parsed.amount, parsed.currency, parsed.direction, parsed.lastFour),
          (650.50, 'egp', 'debit', '9932'));
    });
    test('reads wallet alerts with bidi marks and Eastern Arabic digits', () {
      final parsed = FinancialMessageParser.parse(
        'تم تحويل \u200f۲۵۰٫۵۰ جنيه إلى محفظتك من رقم آخر رصيدك الآن ۳۰۰ جنيه',
      );
      expect((parsed.amount, parsed.currency, parsed.direction),
          (250.50, 'egp', 'credit'));
      final sent = FinancialMessageParser.parse('تم تحويل ٢٥٠ جنيه لرقم آخر');
      expect((sent.amount, sent.direction), (250.0, 'debit'));
    });
    test(
        'reads a Vodafone Cash style receipt with a separately labelled balance',
        () {
      final received = FinancialMessageParser.parse(
          'تم استلام مبلغ ٥٠٠٫٠٠ جنيه من رقم مثال. رصيد محفظتك الحالي هو ٦٥٠٠٫٥٠ جنيه. رقم العملية: EXAMPLE');
      expect((received.amount, received.currency, received.direction),
          (500.0, 'egp', 'credit'));
      final balanceFirst = FinancialMessageParser.parse(
          'Current balance EGP 900. Purchase EGP 30 at Shop');
      expect((balanceFirst.amount, balanceFirst.direction), (30.0, 'debit'));
    });
    test(
        'accepts a debit with an explicit, matching total and rejects mismatches',
        () {
      final receipt = FinancialMessageParser.parse(
          'تم تحويل ٢٠٠ جنيه لرقم مثال. رسوم التحويل: ١ جنيه. إجمالي المبلغ: ٢٠١ جنيه. الرصيد المتاح: ٨٠٠ جنيه');
      expect((receipt.amount, receipt.currency, receipt.direction),
          (201.0, 'egp', 'debit'));
      for (final text in [
        'You sent EGP 200. Transfer fee: EGP 1. Total debited: EGP 209',
        'You sent EGP 200. Transfer fee: USD 1. Total debited: EGP 201',
        'You sent EGP 200. Transfer fee: EGP 1',
      ]) {
        expect(FinancialMessageParser.parse(text).amount, isNull);
      }
    });
    test('reads card purchase phrasing and explicit foreign billing amounts',
        () {
      final cib = FinancialMessageParser.parse(
        'Purchase of EGP 450.00 at Example Market with card ending 4571',
      );
      expect((cib.amount, cib.lastFour, cib.merchant, cib.direction),
          (450.0, '4571', 'Example Market', 'debit'));
      final billing = FinancialMessageParser.parse(
        'Card ending 1234 was charged. Transaction amount: USD 25. Billing amount: EGP 1259.50',
      );
      expect((
        billing.amount,
        billing.currency,
        billing.lastFour,
        billing.direction
      ), (
        1259.5,
        'egp',
        '1234',
        'debit'
      ));
      final ambiguous = FinancialMessageParser.parse(
        'Card ending 1234 was charged. Transaction amount: EGP 25. Billing amount: EGP 30',
      );
      expect(ambiguous.amount, isNull);
    });
    test('rejects Arabic activation codes and unsuccessful transfers', () {
      for (final message in [
        'كود التفعيل 123456 لشراء 250 جنيه',
        'لم يتم تنفيذ تحويل 250 جنيه لرقم آخر',
        'فشلت العملية: خصم 250 جنيه',
      ]) {
        expect(FinancialMessageParser.parse(message).confidence, 0);
      }
    });
  });
}
