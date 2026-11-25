import 'dart:convert';

import 'package:http/http.dart' as http;

import 'financialAssistant.dart';

class GeminiFinancialAssistant implements OptionalFinancialAiProvider {
  const GeminiFinancialAssistant(this.client, this.apiKey);

  final http.Client client;
  final String apiKey;

  @override
  String get providerId => 'Gemini';

  static const model = 'gemini-3.5-flash-lite';

  static const _instructions = '''
You route one user command in CashU, an offline-first personal finance tracker.
Understand English, Egyptian Arabic and Arabic digits. Return one JSON object with type, amount, currency, title, period and feature.
Allowed types: addExpense, addIncome, transfer, queryBalance, querySpending, openFeature, unknown.
Use addExpense, addIncome or transfer only when both amount and a currency are explicit (including common names such as جنيه for EGP). Return a positive number and an ISO 4217 currency code. Do not guess. A transfer is a draft between the user's own accounts. To record sending money to another person with InstaPay, open transactions or draft an expense. The app never sends money.
queryBalance and querySpending run locally. Periods: currentMonth, previousMonth, currentWeek, previousWeek, currentYear.
For openFeature, choose exactly one destination from this catalog. Users finalize their actions in the normal screen:
accounts (manage balances), addAccount (choose a new account or card), cards (credit card details, statements and repayment), certificates (existing bank certificates and payouts), addCertificate (new certificate terms and payout account), bankMessages (review SMS, notifications and account/card links), transactions (search, edit, and track payments), transfer (including InstaPay fees), transferHistory (linked entries and undo), budgets, categories, subscriptions, scheduled (upcoming transactions and bills), goals, loans (credit/debt), reports (monthly analytics), planning (cash flow scenarios), wealth (net worth and assets), investments (holdings and market prices), household (profiles and sharing), backup (Google Drive), settings, appearance, notifications (reminders), activity (ledger history), billSplitter.
Do not claim an action was taken, output URLs, ask for credentials or authorize any change. For unsupported commands return unknown. A title may only describe the explicit transaction in the user's own words.''';

  @override
  Future<FinancialAssistantIntent> interpret(String input) async {
    final command = input.trim();
    if (command.isEmpty || command.runes.length > 250) {
      throw const FormatException('Invalid assistant input');
    }
    final request = http.Request(
        'POST',
        Uri.https('generativelanguage.googleapis.com',
            '/v1beta/models/$model:generateContent'))
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      })
      ..body = jsonEncode({
        'systemInstruction': {
          'parts': [
            {'text': _instructions}
          ]
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': command}
            ]
          }
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'maxOutputTokens': 512,
        },
      });

    final response =
        await client.send(request).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw const FormatException('Assistant service unavailable');
    }
    final bytes = <int>[];
    await for (final chunk
        in response.stream.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > 32768) {
        throw const FormatException('Assistant response too large');
      }
      bytes.addAll(chunk);
    }
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map || body['candidates'] is! List) {
      throw const FormatException('Invalid assistant response');
    }
    final candidates = body['candidates'] as List;
    final candidate = candidates.length == 1 ? candidates.single : null;
    final content = candidate is Map && candidate['finishReason'] == 'STOP'
        ? candidate['content']
        : null;
    if (content is! Map ||
        content['role'] != 'model' ||
        content['parts'] is! List) {
      throw const FormatException('Invalid assistant candidate');
    }
    final messages = [
      for (final part in content['parts'] as List)
        if (part is Map && part['thought'] != true && part['text'] is String)
          part['text'] as String,
    ];
    if (messages.length != 1)
      throw const FormatException('Expected one suggestion');
    final data = jsonDecode(messages.single);
    if (data is! Map) throw const FormatException('Invalid suggestion');
    final type = FinancialAssistantIntentType.values
        .where((value) => value.name == data['type'])
        .firstOrNull;
    final period = SpendingPeriod.values
        .where((value) => value.name == data['period'])
        .firstOrNull;
    final feature = FinancialAssistantFeature.values
        .where((value) => value.name == data['feature'])
        .firstOrNull;
    if (type == null || type == FinancialAssistantIntentType.unknown) {
      throw const FormatException('Unsupported suggestion');
    }
    if (type == FinancialAssistantIntentType.openFeature && feature == null) {
      throw const FormatException('Unsupported destination');
    }

    final write = type == FinancialAssistantIntentType.addIncome ||
        type == FinancialAssistantIntentType.addExpense ||
        type == FinancialAssistantIntentType.transfer;
    final amount = data['amount'];
    final currency = data['currency'];
    final title = data['title'];
    if (write &&
        (amount is! num ||
            !amount.isFinite ||
            amount <= 0 ||
            amount > 999999999999 ||
            currency is! String ||
            !RegExp(r'^[A-Za-z]{3}$').hasMatch(currency))) {
      throw const FormatException('Invalid financial suggestion');
    }
    return FinancialAssistantIntent(
      type: type,
      rawText: command,
      amount: write ? (amount as num).toDouble() : null,
      currency: write ? (currency as String).toLowerCase() : null,
      merchantOrTitle: title is String &&
              title.trim().isNotEmpty &&
              title.length <= 100 &&
              !RegExp(r'[\x00-\x1f\u202a-\u202e\u2066-\u2069]').hasMatch(title)
          ? title.trim()
          : null,
      requiresConfirmation: write,
      spendingPeriod: period ?? SpendingPeriod.currentMonth,
      feature:
          type == FinancialAssistantIntentType.openFeature ? feature : null,
    );
  }
}
