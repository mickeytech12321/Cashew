import 'dart:convert';

import 'package:http/http.dart' as http;

import 'financialAssistant.dart';

class OpenAiFinancialAssistant implements OptionalFinancialAiProvider {
  const OpenAiFinancialAssistant(this.client, this.apiKey);

  final http.Client client;
  final String apiKey;

  @override
  String get providerId => 'OpenAI';

  @override
  Future<FinancialAssistantIntent> interpret(String input) async {
    final command = input.trim();
    if (command.isEmpty || command.runes.length > 250) {
      throw const FormatException('Invalid assistant input');
    }
    final request =
        http.Request('POST', Uri.https('api.openai.com', '/v1/responses'))
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          })
          ..body = jsonEncode({
            'model': 'gpt-4.1-mini',
            'store': false,
            'max_output_tokens': 220,
            'text': {
              'format': {'type': 'json_object'}
            },
            'instructions': 'Classify a single English or Arabic finance command. '
                'Return JSON with type, amount, currency, title and period. '
                'Do not guess amounts or currencies. Use null for missing values. '
                'Currency must be the explicit three-letter currency code. '
                'Type is addExpense, addIncome, transfer, queryBalance, querySpending or unknown. '
                'Period is currentMonth, previousMonth, currentWeek, previousWeek or currentYear. '
                'Title is a short optional description taken from the command.',
            'input': command,
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
    if (body is! Map ||
        body['status'] != 'completed' ||
        body['output'] is! List) {
      throw const FormatException('Invalid assistant response');
    }
    final messages = [
      for (final item in body['output'] as List)
        if (item is Map &&
            item['type'] == 'message' &&
            item['role'] == 'assistant' &&
            item['content'] is List)
          for (final part in item['content'] as List)
            if (part is Map &&
                part['type'] == 'output_text' &&
                part['text'] is String)
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
    if (type == null || type == FinancialAssistantIntentType.unknown) {
      throw const FormatException('Unsupported suggestion');
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
    );
  }
}
