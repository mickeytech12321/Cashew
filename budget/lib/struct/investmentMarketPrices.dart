import 'dart:convert';

import 'package:http/http.dart' as http;

import 'investmentQuoteCsv.dart';

class CoinbaseMarketPair {
  factory CoinbaseMarketPair(String base, String currency) {
    final symbol = base.trim().toUpperCase();
    final quote = currency.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{2,12}$').hasMatch(symbol) ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(quote) ||
        symbol == quote) {
      throw const FormatException('Invalid Coinbase trading pair');
    }
    return CoinbaseMarketPair._(symbol, quote);
  }

  const CoinbaseMarketPair._(this.symbol, this.currency);

  final String symbol;
  final String currency;

  String get product => '$symbol-$currency';
}

class CoinbaseMarketPrices {
  const CoinbaseMarketPrices(this.client);
  final http.Client client;

  Future<InvestmentQuote> fetch(CoinbaseMarketPair pair, DateTime now) async {
    final request = http.Request(
      'GET',
      Uri.https(
          'api.exchange.coinbase.com', '/products/${pair.product}/ticker'),
    )..followRedirects = false;
    final response =
        await client.send(request).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw const FormatException('Market price unavailable');
    }

    final body = <int>[];
    await for (final chunk
        in response.stream.timeout(const Duration(seconds: 8))) {
      if (body.length + chunk.length > 16384) {
        throw const FormatException('Market response too large');
      }
      body.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(body));
    if (data is! Map<String, dynamic> ||
        data['price'] is! String ||
        data['time'] is! String) {
      throw const FormatException('Invalid market response');
    }
    final price = double.tryParse(data['price'] as String);
    final timestamp = data['time'] as String;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$')
        .hasMatch(timestamp)) {
      throw const FormatException('Invalid market price timestamp');
    }
    final date = DateTime.tryParse(timestamp);
    if (price == null ||
        !price.isFinite ||
        price <= 0 ||
        price > 999999999999 ||
        date == null ||
        !date.toIso8601String().startsWith(timestamp.substring(0, 19)) ||
        date.isAfter(now.add(const Duration(minutes: 2))) ||
        date.isBefore(now.subtract(const Duration(days: 1)))) {
      throw const FormatException('Invalid or stale market price');
    }
    return (date: date, price: price);
  }
}
