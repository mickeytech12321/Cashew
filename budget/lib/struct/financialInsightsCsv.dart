import 'package:csv/csv.dart';

String _csvText(String value) =>
    RegExp(r'^[\s\x00-\x1f]*[=+@-]|^[\t\r\n]').hasMatch(value)
        ? "'$value"
        : value;

String exportFinancialInsightsCsv({
  required DateTime month,
  required String? account,
  required List<
          ({String currency, String? category, double income, double expenses})>
      rows,
}) {
  final period = '${month.year}-${month.month.toString().padLeft(2, '0')}';
  return const ListToCsvConverter().convert(<List<dynamic>>[
    [
      'month',
      'account_id',
      'currency',
      'category',
      'income',
      'expenses',
      'net'
    ],
    for (final row in rows)
      [
        period,
        _csvText(account ?? ''),
        _csvText(row.currency.toUpperCase()),
        _csvText(row.category ?? ''),
        row.income,
        row.expenses,
        row.income - row.expenses,
      ],
  ]);
}
