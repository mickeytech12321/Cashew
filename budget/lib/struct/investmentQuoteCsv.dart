import 'package:budget/struct/financialMessageParser.dart';
import 'package:csv/csv.dart';

typedef InvestmentQuote = ({DateTime date, double price});

List<InvestmentQuote> parseInvestmentQuoteCsv(String text, DateTime today) {
  if (text.length > 65536) throw const FormatException('CSV is too large');
  final input = text.replaceFirst(RegExp(r'^\uFEFF'), '').trim();
  final rows = CsvToListConverter(
    shouldParseNumbers: false,
    allowInvalid: false,
    eol: input.contains('\r\n') ? '\r\n' : '\n',
  ).convert(input);
  if (rows.length < 2 || rows.length > 366 ||
      rows.first.map((cell) => cell.toString().trim().toLowerCase()).join(',') !=
          'date,price') {
    throw const FormatException('Expected date,price and 1–365 quotes');
  }
  final end = DateTime(today.year, today.month, today.day + 1);
  final quotes = <InvestmentQuote>[];
  final seen = <DateTime>{};
  for (var i = 1; i < rows.length; i++) {
    final cells = rows[i].map((cell) =>
        FinancialMessageParser.normalize(cell.toString().trim())).toList();
    if (cells.length != 2) throw FormatException('Invalid row ${i + 1}');
    final date = DateTime.tryParse(cells[0]);
    final price = double.tryParse(cells[1]);
    if (date == null || !date.toIso8601String().startsWith('${cells[0]}T') ||
        !date.isBefore(end) || price == null || !price.isFinite ||
        price < 0 || !seen.add(date)) {
      throw FormatException('Invalid or duplicate quote on row ${i + 1}');
    }
    quotes.add((date: date, price: price));
  }
  return quotes;
}

/// The most recent quote wins if several entries share a calendar day.
String exportInvestmentQuoteCsv(Iterable<InvestmentQuote> quotes) {
  final ordered = quotes.toList()
    ..sort((a, b) => b.date.compareTo(a.date));
  final daily = <String, double>{};
  for (final quote in ordered) {
    final date = quote.date.toIso8601String().split('T').first;
    daily.putIfAbsent(date, () => quote.price);
  }
  return const ListToCsvConverter().convert([
    ['date', 'price'],
    for (final quote in daily.entries) [quote.key, quote.value],
  ]);
}
