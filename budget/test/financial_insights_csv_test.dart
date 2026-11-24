import 'package:budget/struct/financialInsightsCsv.dart';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CSV retains account, period, Arabic category and cash-flow amounts',
      () {
    final csv = exportFinancialInsightsCsv(
      month: DateTime(2026, 2),
      account: 'wallet',
      rows: [
        (currency: 'egp', category: 'أكل, وشرب', income: 125, expenses: 25)
      ],
    );
    final decoded =
        const CsvToListConverter(shouldParseNumbers: false).convert(csv);
    expect(decoded.last,
        ['2026-02', 'wallet', 'EGP', 'أكل, وشرب', '125.0', '25.0', '100.0']);
  });

  test('CSV escapes formula cells while keeping negative cash flow numeric',
      () {
    final csv = exportFinancialInsightsCsv(
      month: DateTime(2026, 11),
      account: '=A1',
      rows: [(currency: 'egp', category: '  +1', income: 1, expenses: 2)],
    );
    final decoded = const CsvToListConverter().convert(csv);
    expect(decoded.last, ['2026-11', "'=A1", 'EGP', "'  +1", 1.0, 2.0, -1.0]);
  });
}
