class ParsedFinancialMessage {
  final double? amount;
  final String? currency;
  final String? direction;
  final String? merchant;
  final String? lastFour;
  final double confidence;
  const ParsedFinancialMessage({
    this.amount, this.currency, this.direction, this.merchant,
    this.lastFour, required this.confidence,
  });
}

class FinancialMessageParser {
  static ParsedFinancialMessage parse(String raw) {
    final text = raw.replaceAll(RegExp(r'\\s+'), ' ').trim();
    if (text.isEmpty) return const ParsedFinancialMessage(confidence: 0);
    final lower = text.toLowerCase();
    final amountMatch = RegExp(
      r'(?:egp|ج(?:\\.?م)?|جنيه|usd|دولار)\\s*([0-9][0-9,]*(?:\\.[0-9]{1,2})?)|'
      r'([0-9][0-9,]*(?:\\.[0-9]{1,2})?)\\s*(egp|ج(?:\\.?م)?|جنيه|usd|دولار)',
      caseSensitive: false,
    ).firstMatch(text);
    double? amount;
    String? currency;
    if (amountMatch != null) {
      final number = amountMatch.group(1) ?? amountMatch.group(2);
      amount = double.tryParse(number?.replaceAll(',', '') ?? '');
      final token = (amountMatch.group(3) ?? amountMatch.group(0) ?? '').toLowerCase();
      currency = token.contains('usd') || token.contains('دولار') ? 'usd' : 'egp';
    }
    String? direction;
    if (RegExp(r'purchase|purchased|paid|payment|withdraw|خصم|شراء|سحب|دفعت',
            caseSensitive: false).hasMatch(lower)) {
      direction = 'debit';
    } else if (RegExp(r'received|credited|deposit|refund|استلام|ايداع|إيداع|رد',
            caseSensitive: false).hasMatch(lower)) {
      direction = 'credit';
    }
    final last4 = RegExp(
      r'(?:ending|ends|card|بطاق(?:ة|تك)|كارت)\\D{0,12}(\\d{4})(?!\\d)',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    String? merchant;
    final merchantMatch = RegExp(
      r'(?:at| لدى | عند |merchant[: ]+)\\s*([^,.;]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (merchantMatch != null) merchant = merchantMatch.group(1)?.trim();
    var confidence = 0.0;
    if (amount != null) confidence += .45;
    if (direction != null) confidence += .25;
    if (last4 != null) confidence += .2;
    if (merchant != null && merchant!.isNotEmpty) confidence += .1;
    return ParsedFinancialMessage(
      amount: amount, currency: currency, direction: direction,
      merchant: merchant, lastFour: last4,
      confidence: confidence.clamp(0.0, 1.0),
    );
  }
}
