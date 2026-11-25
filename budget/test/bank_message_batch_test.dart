import 'package:budget/struct/bankMessageBatch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves line numbers and accepts mixed Arabic and English messages',
      () {
    final messages = parseBankMessageBatch(
      'Purchase EGP 250\r\n\r\nتم استلام ١٢٠ جنيه\nOTP 1200',
    );
    expect(messages.map((row) => row.line), [1, 3, 4]);
    expect(messages.map((row) => canStageBankMessage(row.parsed)),
        [true, true, false]);
    expect(messages[1].parsed.amount, 120);
  });

  test('rejects oversized batches and skips oversized individual messages', () {
    expect(() => parseBankMessageBatch(List.filled(26, 'msg').join('\n')),
        throwsFormatException);
    expect(() => parseBankMessageBatch(' '), throwsFormatException);
    final messages = parseBankMessageBatch(
      'Paid EGP 10 ${'x' * maxBankMessageLength}\nPaid EGP 20',
    );
    expect(
        messages.map((row) => canStageBankMessage(row.parsed)), [false, true]);
  });
}
