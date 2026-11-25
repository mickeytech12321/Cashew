import 'financialMessageParser.dart';

typedef BankMessageLine = ({
  int line,
  String raw,
  ParsedFinancialMessage parsed,
});

const maxBankMessageLength = 2000;
const maxBankBatchLength = 12000;

List<BankMessageLine> parseBankMessageBatch(String input) {
  if (input.length > maxBankBatchLength) {
    throw const FormatException('Batch text is too long');
  }
  final lines = input.split(RegExp(r'\r?\n'));
  final rows = [
    for (final (index, line) in lines.indexed)
      if (line.trim().isNotEmpty)
        (
          line: index + 1,
          raw: line.trim(),
          parsed: line.trim().length > maxBankMessageLength
              ? const ParsedFinancialMessage(confidence: 0)
              : FinancialMessageParser.parse(line.trim()),
        ),
  ];
  if (rows.isEmpty || rows.length > 25) {
    throw const FormatException('Expected 1–25 bank messages');
  }
  return rows;
}

bool canStageBankMessage(ParsedFinancialMessage parsed) {
  final amount = parsed.amount;
  return amount != null &&
      amount.isFinite &&
      amount > 0 &&
      amount <= 999999999999 &&
      parsed.currency != null &&
      (parsed.direction == 'debit' || parsed.direction == 'credit');
}
