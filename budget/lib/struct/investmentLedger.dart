class InvestmentTrade {
  const InvestmentTrade({
    required this.id,
    required this.date,
    required this.buy,
    required this.units,
    required this.price,
    required this.fees,
  });

  final String id;
  final DateTime date;
  final bool buy;
  final double units;
  final double price;
  final double fees;
}

class InvestmentBalance {
  const InvestmentBalance({
    required this.units,
    required this.cost,
    required this.realized,
  });

  final double units;
  final double cost;
  final double realized;

  factory InvestmentBalance.fromTrades(Iterable<InvestmentTrade> trades) {
    var units = 0.0;
    var cost = 0.0;
    var realized = 0.0;
    for (final trade in trades) {
      final gross = trade.units * trade.price;
      if (!trade.units.isFinite ||
          trade.units <= 0 ||
          !trade.price.isFinite ||
          trade.price <= 0 ||
          !trade.fees.isFinite ||
          trade.fees < 0 ||
          !gross.isFinite ||
          (!trade.buy && trade.fees > gross)) {
        throw ArgumentError('Invalid investment trade');
      }
      if (trade.buy) {
        units += trade.units;
        cost += gross + trade.fees;
      } else {
        // Allow only rounding noise when liquidating a fractional holding.
        final tolerance = units.abs() * 1e-12;
        if (units <= 0 || trade.units - units > tolerance) {
          throw StateError('Sale exceeds units held on the trade date');
        }
        final sold = trade.units > units ? units : trade.units;
        final basis = cost * (sold / units);
        realized += sold * trade.price - trade.fees - basis;
        units -= sold;
        cost = units <= tolerance ? 0 : cost - basis;
        if (units <= tolerance) units = 0;
      }
      if (!units.isFinite || !cost.isFinite || !realized.isFinite) {
        throw StateError('Investment balance is outside the supported range');
      }
    }
    return InvestmentBalance(units: units, cost: cost, realized: realized);
  }
}
