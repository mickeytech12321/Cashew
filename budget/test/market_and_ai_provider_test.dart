import 'dart:convert';

import 'package:budget/struct/financialAssistant.dart';
import 'package:budget/struct/investmentMarketPrices.dart';
import 'package:budget/struct/geminiFinancialAssistant.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final now = DateTime.utc(2026, 11, 25, 12);

  test(
      'Coinbase fetch requests only the selected trading pair and uses trade time',
      () async {
    final client = MockClient((request) async {
      expect(request.url.toString(),
          'https://api.exchange.coinbase.com/products/BTC-USD/ticker');
      expect(request.method, 'GET');
      expect(request.followRedirects, isFalse);
      expect(request.body, isEmpty);
      return http.Response(
          '{"price":"82150.12","time":"2026-11-25T11:59:56.123Z"}', 200);
    });
    addTearDown(client.close);
    final quote = await CoinbaseMarketPrices(client)
        .fetch(CoinbaseMarketPair('btc', 'usd'), now);
    expect(quote.price, 82150.12);
    expect(quote.date, DateTime.utc(2026, 11, 25, 11, 59, 56, 123));
    expect(() => CoinbaseMarketPair('btc-usd', 'egp'), throwsFormatException);
  });

  test(
      'Coinbase rejects failures, missing or bad prices and stale or future times',
      () async {
    for (final (body, status) in [
      ('{}', 404),
      ('{}', 200),
      ('{"price":"Infinity","time":"2026-11-25T11:59:56Z"}', 200),
      ('{"price":"0","time":"2026-11-25T11:59:56Z"}', 200),
      ('{"price":"123","time":"2026-11-25T11:59:56"}', 200),
      ('{"price":"123","time":"2026-11-24T11:59:56Z"}', 200),
      ('{"price":"123","time":"2026-11-25T12:03:00Z"}', 200),
    ]) {
      final client = MockClient((_) async => http.Response(body, status));
      addTearDown(client.close);
      await expectLater(
        CoinbaseMarketPrices(client)
            .fetch(CoinbaseMarketPair('btc', 'eur'), now),
        throwsFormatException,
      );
    }
  });

  String response(Map<String, dynamic> suggestion) => jsonEncode({
        'candidates': [
          {
            'finishReason': 'STOP',
            'content': {
              'role': 'model',
              'parts': [
                {'text': jsonEncode(suggestion)}
              ]
            },
          },
        ],
      });

  test(
      'Gemini sends one explicit command and returns a confirmation-required draft',
      () async {
    final client = MockClient((request) async {
      expect(
          request.url.toString(),
          'https://generativelanguage.googleapis.com/'
          'v1beta/models/${GeminiFinancialAssistant.model}:generateContent');
      expect(request.method, 'POST');
      expect(request.followRedirects, isFalse);
      expect(request.headers['x-goog-api-key'], 'fixture-key');
      final sent = jsonDecode(request.body);
      expect(sent['contents'], [
        {
          'role': 'user',
          'parts': [
            {'text': 'دفعت ٢٥ جنيه'}
          ]
        }
      ]);
      expect(sent['generationConfig']['responseMimeType'], 'application/json');
      expect(sent.containsKey('tools'), isFalse);
      return http.Response(
          response({
            'type': 'addExpense',
            'amount': 25,
            'currency': 'EGP',
            'title': 'مصاريف',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    addTearDown(client.close);
    final draft = await GeminiFinancialAssistant(client, 'fixture-key')
        .interpret('دفعت ٢٥ جنيه');
    expect(draft.type, FinancialAssistantIntentType.addExpense);
    expect(draft.amount, 25);
    expect(draft.currency, 'egp');
    expect(draft.merchantOrTitle, 'مصاريف');
    expect(draft.requiresConfirmation, isTrue);
  });

  test('Gemini can suggest the existing bank certificate form', () async {
    final client = MockClient((_) async => http.Response(
        response({
          'type': 'openFeature',
          'feature': 'addCertificate',
          'amount': 1,
        }),
        200));
    addTearDown(client.close);
    final intent = await GeminiFinancialAssistant(client, 'fixture-key')
        .interpret('عايز أضيف شهادة');
    expect(intent.feature, FinancialAssistantFeature.addCertificate);
    expect(intent.amount, isNull);
  });

  test('Gemini rejects malformed, incomplete and unsupported suggestions',
      () async {
    for (final (body, status) in [
      ('{}', 429),
      ('{"candidates":[{"finishReason":"MAX_TOKENS"}]}', 200),
      (response({'type': 'eraseAccount'}), 200),
      (response({'type': 'openFeature', 'feature': 'factoryReset'}), 200),
      (
        response(
            {'type': 'addIncome', 'amount': 10, 'currency': 'not currency'}),
        200
      ),
      (response({'type': 'transfer', 'amount': -3, 'currency': 'USD'}), 200),
      (response({'type': 'addExpense', 'amount': '3', 'currency': 'EGP'}), 200),
    ]) {
      final client = MockClient((_) async => http.Response(body, status));
      addTearDown(client.close);
      await expectLater(
        GeminiFinancialAssistant(client, 'fixture-key').interpret('A command'),
        throwsFormatException,
      );
    }
    expect(const FinancialAssistant().parse('Paid 5 EGP').amount, 5);
  });
}
