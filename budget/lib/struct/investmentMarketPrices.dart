import 'dart:convert';

import 'package:http/http.dart' as http;

import 'investmentQuoteCsv.dart';

enum InvestmentPriceProvider { coinbase, twelveData }

typedef InvestmentMarketSource = ({
  String symbol,
  String revision,
  InvestmentPriceProvider provider,
  String? mic,
});

class StockMarketListing {
  factory StockMarketListing(String symbol, String mic, String currency) {
    final ticker = symbol.trim().toUpperCase();
    final venue = mic.trim().toUpperCase();
    final code = currency.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9][A-Z0-9.-]{0,19}$').hasMatch(ticker) ||
        !RegExp(r'^[A-Z0-9]{4}$').hasMatch(venue) ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
      throw const FormatException('Invalid market listing');
    }
    return StockMarketListing._(ticker, venue, code);
  }

  const StockMarketListing._(this.symbol, this.mic, this.currency);
  final String symbol;
  final String mic;
  final String currency;
}

bool isMarketApiKey(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{4,300}$').hasMatch(value);

Future<Map<String, dynamic>> _marketPayload(
    http.Client client, http.Request request) async {
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
  if (data is! Map<String, dynamic> || data['status'] == 'error') {
    throw const FormatException('Invalid market response');
  }
  return data;
}

class TwelveDataMarketPrices {
  const TwelveDataMarketPrices(this.client);

  final http.Client client;

  Future<InvestmentQuote> fetch(
      StockMarketListing listing, String key, DateTime now) async {
    if (!isMarketApiKey(key))
      throw const FormatException('Invalid market API key');
    // The public demo works through its documented query parameter.
    // Personal credentials are sent only in an authorization header.
    final demo = key == 'demo';
    final request = http.Request(
        'GET',
        Uri.https('api.twelvedata.com', '/quote', {
          'symbol': listing.symbol,
          'interval': '1day',
          if (demo) 'apikey': 'demo' else 'mic_code': listing.mic,
        }))
      ..followRedirects = false;
    if (!demo) request.headers['Authorization'] = 'apikey $key';
    final data = await _marketPayload(client, request);
    if (data['symbol'] != listing.symbol ||
        data['mic_code'] != listing.mic ||
        data['currency'] != listing.currency ||
        data['close'] is! String) {
      throw const FormatException('Market listing or currency mismatch');
    }
    final quoteAt = data['last_quote_at'] ?? data['timestamp'];
    final price = double.tryParse(data['close'] as String);
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    // Allow non-trading days. Delisted or badly dated responses must never become current.
    if (quoteAt is! int ||
        quoteAt < nowSeconds - const Duration(days: 10).inSeconds ||
        quoteAt > nowSeconds + 120 ||
        price == null ||
        !price.isFinite ||
        price <= 0 ||
        price > 999999999999) {
      throw const FormatException('Invalid or stale market price');
    }
    return (
      date: DateTime.fromMillisecondsSinceEpoch(quoteAt * 1000, isUtc: true),
      price: price
    );
  }
}

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
    final data = await _marketPayload(client, request);
    if (data['price'] is! String || data['time'] is! String) {
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
