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
    final message = normalize(raw)
        .replaceAll(
            RegExp(r'[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (message.isEmpty) return const ParsedFinancialMessage(confidence: 0);
    if (RegExp(
      r'\b(?:otp|declined|unsuccessful|failed|verification code|one[- ]time password|security code|insufficient (?:funds|balance))\b|(?:رمز|كود) (?:التحقق|التأكيد|التفعيل|الأمان)|تم رفض|لم تتم|لم يتم تنفيذ|فشلت العملية|لم يكتمل التحويل|تعذر تنفيذ|تعذّر تنفيذ|الرصيد غير كاف',
    ).hasMatch(message.toLowerCase())) {
      return const ParsedFinancialMessage(confidence: 0);
    }
    final lower = message.toLowerCase();
    final balanceLabel = RegExp(
      r'(?:^|[\s.;،|])(?:(?:new|available|remaining|current|avail\.?)\s+balance\b|(?:available|avail\.?)\s+bal\.?\s*:|(?:الرصيد|رصيدك|رصيد (?:محفظتك|حسابك))\s+(?:المتاح|الحالي|الحالى|الجديد|المتبقي|الآن|الان))',
      caseSensitive: false,
    );
    const currencyPattern =
        r'(?:\b(?:egp|le|usd|eur|gbp|sar|aed|kwd|qar|bhd|omr|jod)\b|l\.\s*e\.|e£|جنيه(?:ًا|ا)?|ج\.?\s*م\.?|دولار)';
    const numberPattern =
        r'(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,3})?';
    final amountPattern = RegExp(
      '($currencyPattern)\\s*($numberPattern)(?![0-9]|[.,][0-9])|'
      '(?<![0-9.,+−-])($numberPattern)(?![0-9]|[.,][0-9])\\s*($currencyPattern)',
      caseSensitive: false,
    );
    final matches = amountPattern.allMatches(message).toList();
    final amounts = <({double? value, String currency, String role})>[];
    var previousEnd = 0;
    final balanceEnding = RegExp(r'^\s*(?:is\b|of\b|was\b|هو|يبلغ)?[\s:=]*$',
        caseSensitive: false);
    final walletFee = RegExp(
      r'(?:^|[.;،|]\s*)(?:رسوم (?:العملية|التحويل|السحب)|تكلفة الخدمة|(?:transfer|withdrawal|transaction) fee)\s*[:=]?\s*$',
      caseSensitive: false,
    );
    final walletTotal = RegExp(
      r'(?:^|[.;،|]\s*)(?:إجمالي (?:المبلغ|الخصم)|المبلغ الإجمالي|الإجمالي|total (?:debited|amount))\s*[:=]?\s*$',
      caseSensitive: false,
    );
    final billingAmount = RegExp(
      r'(?:^|[.;،|]\s*)(?:billing (?:amount|total)|المبلغ المفوتر)\s*[:=]?\s*$',
      caseSensitive: false,
    );
    final originalAmount = RegExp(
      r'(?:^|[.;،|]\s*)(?:original (?:transaction )?amount|transaction amount|المبلغ الأصلي|مبلغ العملية)\s*[:=]?\s*$',
      caseSensitive: false,
    );
    for (final match in matches) {
      final label = message.substring(previousEnd, match.start).trim();
      previousEnd = match.end;
      final lastBalanceLabel = balanceLabel.allMatches(label).lastOrNull;
      if (lastBalanceLabel != null &&
          balanceEnding.hasMatch(label.substring(lastBalanceLabel.end)))
        continue;
      final number = match[2] ?? match[3]!;
      final token = (match[1] ?? match[4]!).toLowerCase();
      final currency = switch (token) {
        'usd' || 'دولار' => 'usd',
        'eur' ||
        'gbp' ||
        'sar' ||
        'aed' ||
        'kwd' ||
        'qar' ||
        'bhd' ||
        'omr' ||
        'jod' =>
          token,
        _ => 'egp',
      };
      final role = switch (label) {
        _ when walletFee.hasMatch(label) => 'fee',
        _ when walletTotal.hasMatch(label) => 'total',
        _ when billingAmount.hasMatch(label) => 'billing',
        _ when originalAmount.hasMatch(label) => 'original',
        _ => 'principal',
      };
      final value = double.tryParse(number.replaceAll(',', ''));
      final validPrecision = !number.contains('.') ||
          number.split('.').last.length <= 2 ||
          const {'kwd', 'bhd', 'omr', 'jod'}.contains(currency);
      amounts.add((
        value: validPrecision &&
                value != null &&
                value.isFinite &&
                value <= 999999999999
            ? value
            : null,
        currency: currency,
        role: role
      ));
    }
    final operation = lower.replaceAll(
      RegExp(
          r'رسوم (?:العملية|التحويل|السحب)|إجمالي (?:المبلغ|الخصم)|(?:transfer|withdrawal|transaction) fee|total (?:debited|amount)'),
      '',
    );
    final debit = RegExp(
      r'\b(?:purchase[ds]?|paid|payment of|charged|withdraw(?:al|n)?|debited|sent|outgoing transfer|cash out)\b|خصم|شراء|سحب|دفعت|تم [إا]رسال|(?:تم تحويل|حولت)\s+.+?\s+(?:[إا]لى\s+(?!(?:محفظتك|حسابك) من)|لرقم)',
    ).hasMatch(operation);
    final credit = RegExp(
      r'\b(?:received|credited|deposit(?:ed)?|refund(?:ed)?|incoming transfer|cash in)\b|استلام|استلمت|تم استقبال|[إا]يداع|رد مبلغ|تم [إا]ضافة|تم استرداد|تم شحن محفظتك|تم تحويل\s+.+?\s+(?:[إا]لى (?:محفظتك|حسابك) من|لحسابك من)',
    ).hasMatch(operation);
    final direction = debit == credit ? null : (debit ? 'debit' : 'credit');
    double? amount;
    String? currency;
    if (amounts.length == 1 &&
        const {'principal', 'original', 'billing'}
            .contains(amounts.single.role)) {
      final entry = amounts.single;
      if ((entry.value ?? 0) > 0) {
        amount = entry.value;
        currency = entry.currency;
      }
    } else if (direction == 'debit' && amounts.length == 2) {
      final original =
          amounts.where((entry) => entry.role == 'original').firstOrNull;
      final billing =
          amounts.where((entry) => entry.role == 'billing').firstOrNull;
      if (original != null &&
          billing != null &&
          (original.value ?? 0) > 0 &&
          (billing.value ?? 0) > 0 &&
          original.currency != billing.currency) {
        amount = billing.value;
        currency = billing.currency;
      }
    } else if (direction == 'debit' &&
        amounts.length == 3 &&
        amounts
            .every((entry) => entry.currency == 'egp' && entry.value != null)) {
      final byRole = {
        for (final entry in amounts)
          (entry.role == 'original' ? 'principal' : entry.role): entry.value!
      };
      final principal = byRole['principal'];
      final fee = byRole['fee'];
      final total = byRole['total'];
      if (principal != null &&
          principal > 0 &&
          fee != null &&
          total != null &&
          ((principal + fee) * 100).round() == (total * 100).round()) {
        // An explicitly itemized debit changes the wallet by the displayed total.
        amount = total;
        currency = 'egp';
      }
    }
    final balance = balanceLabel.firstMatch(message);
    final text = balance != null &&
            matches.isNotEmpty &&
            balance.start > matches.first.end
        ? message.substring(0, balance.start)
        : message;
    final last4 = RegExp(
      r'(?:ending|ends|card|بطاق(?:ة|تك)|كارت)\D{0,12}(\d{4})(?!\d)',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    String? merchant;
    final merchantMatch = RegExp(
      r'(?:\bat\b|لدى|عند|\bmerchant[: ]+)\s+(.+?)(?=\s+(?:(?:(?:with|using|on)\s+)?card\b|ending\b|من بطاق|كارت)|[,.;]|$)',
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
