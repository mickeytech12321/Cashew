import 'package:budget/struct/financialMessageParser.dart';
import 'package:csv/csv.dart';

typedef BankStatementLine = ({
  DateTime closed,
  DateTime due,
  double balance,
  double minimum,
});

const creditStatementCsvHeader =
    'closing_date,due_date,statement_balance,minimum_due';

List<BankStatementLine> parseCreditStatementCsv(String content) {
  final input = content.replaceFirst('\uFEFF', '').trim();
  if (input.length > 65536)
    throw const FormatException('Statement file is too large');
  final rows = CsvToListConverter(
    shouldParseNumbers: false,
    allowInvalid: false,
    eol: input.contains('\r\n') ? '\r\n' : '\n',
  ).convert(input);
  if (rows.isEmpty ||
      rows.first
              .map((value) => value.toString().trim().toLowerCase())
              .join(',') !=
          creditStatementCsvHeader ||
      rows.length < 2 ||
      rows.length > 37) {
    throw const FormatException('Invalid statement header or row count');
  }

  DateTime? date(String cell) {
    if (!RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(cell)) return null;
    final result = DateTime.tryParse(cell);
    if (result == null || !result.toIso8601String().startsWith('${cell}T')) {
      return null;
    }
    return result;
  }

  double? amount(String cell) {
    if (!RegExp(r'^[0-9]+(?:\.[0-9]{1,6})?$').hasMatch(cell)) return null;
    final value = double.tryParse(cell);
    return value != null && value.isFinite && value <= 999999999999
        ? value
        : null;
  }

  final statements = <BankStatementLine>[];
  final seen = <DateTime>{};
  for (var i = 1; i < rows.length; i++) {
    final cells = rows[i]
        .map((cell) => FinancialMessageParser.normalize(cell.toString().trim()))
        .toList();
    if (cells.length != 4)
      throw FormatException('Invalid statement row ${i + 1}');
    final closed = date(cells[0]);
    final due = date(cells[1]);
    final balance = amount(cells[2]);
    final minimum = amount(cells[3]);
    if (closed == null ||
        due == null ||
        !due.isAfter(closed) ||
        balance == null ||
        minimum == null ||
        minimum > balance ||
        !seen.add(closed)) {
      throw FormatException('Invalid or duplicate statement row ${i + 1}');
    }
    statements
        .add((closed: closed, due: due, balance: balance, minimum: minimum));
  }
  return statements;
}
