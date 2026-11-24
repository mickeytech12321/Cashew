class ParsedFinancialMessage {
  final double? amount;
  final String? currency;
  final String? direction;
  final String? merchant;
  final String? lastFour;
  final double confidence;
  const ParsedFinancialMessage({
    this.amount,
    this.currency,
    this.direction,
    this.merchant,
    this.lastFour,
    required this.confidence,
  });
}

class FinancialMessageParser {
  static String normalize(String raw) {
    const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
    const easternArabicIndic = '۰۱۲۳۴۵۶۷۸۹';
    return raw.replaceAllMapped(RegExp(r'[٠-٩۰-۹٬٫]'), (match) {
      final character = match[0]!;
      if (character == '٬') return ',';
      if (character == '٫') return '.';
      final index = arabicIndic.indexOf(character);
      return (index >= 0 ? index : easternArabicIndic.indexOf(character))
          .toString();
    });
  }

  static ParsedFinancialMessage parse(String raw) {
    final message = normalize(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (message.isEmpty) return const ParsedFinancialMessage(confidence: 0);
    if (RegExp(
      r'\b(?:otp|declined|unsuccessful|failed|verification code|one[- ]time password)\b|رمز التحقق|رمز التأكيد|تم رفض|لم تتم',
    ).hasMatch(message.toLowerCase())) {
      return const ParsedFinancialMessage(confidence: 0);
    }
    // A separately labelled trailing balance is not a transaction amount.
    final balance = RegExp(
      r'(?:^|[.;،|]\s*)(?:(?:new|available|remaining|current)\s+balance\b|(?:الرصيد|رصيدك)\s+(?:المتاح|الحالي|الجديد|المتبقي))',
      caseSensitive: false,
    ).firstMatch(message);
    final text =
        balance == null ? message : message.substring(0, balance.start);
    final lower = text.toLowerCase();
    const currencyPattern =
        r'(?:\b(?:egp|le)\b|e£|جنيه(?:ًا|ا)?|ج\.?\s*م\.?|\busd\b|دولار)';
    const numberPattern =
        r'(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,2})?';
    final amountPattern = RegExp(
      '($currencyPattern)\\s*($numberPattern)(?![0-9]|[.,][0-9])|'
      '(?<![0-9.,+−-])($numberPattern)\\s*($currencyPattern)',
      caseSensitive: false,
    );
    final matches = amountPattern.allMatches(text).toList();
    double? amount;
    String? currency;
    if (matches.length == 1) {
      final match = matches.single;
      final number = match[2] ?? match[3]!;
      final token = (match[1] ?? match[4]!).toLowerCase();
      amount = double.tryParse(number.replaceAll(',', ''));
      if (amount != null && amount.isFinite && amount > 0) {
        currency = token == 'usd' || token == 'دولار' ? 'usd' : 'egp';
      } else {
        amount = null;
      }
    }
    final debit = RegExp(
      r'\b(?:purchase[ds]?|paid|withdraw(?:al|n)?|debited|sent|outgoing transfer)\b|خصم|شراء|سحب|دفعت|تم إرسال|تم تحويل.+(?:إلى|الى)',
    ).hasMatch(lower);
    final credit = RegExp(
      r'\b(?:received|credited|deposit(?:ed)?|refund(?:ed)?|incoming transfer)\b|استلام|استلمت|[إا]يداع|رد مبلغ|تم إضافة',
    ).hasMatch(lower);
    final direction = debit == credit ? null : (debit ? 'debit' : 'credit');
    final last4 = RegExp(
      r'(?:ending|ends|card|بطاق(?:ة|تك)|كارت)\D{0,12}(\d{4})(?!\d)',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    String? merchant;
    final merchantMatch = RegExp(
      r'(?:\bat\b|لدى|عند|\bmerchant[: ]+)\s+(.+?)(?=\s+(?:card\b|ending\b|من بطاق|كارت)|[,.;]|$)',
      caseSensitive: false,
    ).firstMatch(text);
    if (merchantMatch != null) merchant = merchantMatch.group(1)?.trim();
    var confidence = 0.0;
    if (amount != null) confidence += .45;
    if (direction != null) confidence += .25;
    if (last4 != null) confidence += .2;
    if (merchant != null && merchant.isNotEmpty) confidence += .1;
    return ParsedFinancialMessage(
      amount: amount,
      currency: currency,
      direction: direction,
      merchant: merchant,
      lastFour: last4,
      confidence: confidence.clamp(0.0, 1.0),
    );
  }
}
