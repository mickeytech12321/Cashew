import 'dart:collection';
import 'dart:math' as math;

enum InvestmentCostBasis { weightedAverage, fifo }

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

  /// Replays trades in ledger order, including the insertion order on a date.
  factory InvestmentBalance.fromTrades(
    Iterable<InvestmentTrade> trades, {
    InvestmentCostBasis method = InvestmentCostBasis.weightedAverage,
  }) {
    var units = 0.0;
    var cost = 0.0;
    var realized = 0.0;
    final lots = method == InvestmentCostBasis.fifo
        ? Queue<({double units, double cost})>()
        : null;
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
        final purchaseCost = gross + trade.fees;
        units += trade.units;
        cost += purchaseCost;
        lots?.addLast((units: trade.units, cost: purchaseCost));
      } else {
        // Allow only rounding noise when liquidating a fractional holding.
        final tolerance = units.abs() * 1e-12;
        if (units <= 0 || trade.units - units > tolerance) {
          throw StateError('Sale exceeds units held on the trade date');
        }
        final sold = trade.units > units ? units : trade.units;
        final basis = lots == null || units - sold <= tolerance
            ? cost * (sold / units)
            : _consumeOldestLots(lots, sold);
        realized += sold * trade.price - trade.fees - basis;
        units -= sold;
        cost = units <= tolerance ? 0 : cost - basis;
        if (units <= tolerance) {
          units = 0;
          lots?.clear();
        }
      }
      if (!units.isFinite || !cost.isFinite || !realized.isFinite) {
        throw StateError('Investment balance is outside the supported range');
      }
    }
    return InvestmentBalance(units: units, cost: cost, realized: realized);
  }

  static double _consumeOldestLots(
    Queue<({double units, double cost})> lots,
    double units,
  ) {
    var remaining = units;
    var basis = 0.0;
    while (remaining > 0 && lots.isNotEmpty) {
      final lot = lots.removeFirst();
      final consumed = math.min(remaining, lot.units);
      final lotBasis = lot.cost * (consumed / lot.units);
      basis += lotBasis;
      remaining -= consumed;
      if (consumed < lot.units) {
        lots.addFirst((units: lot.units - consumed, cost: lot.cost - lotBasis));
      }
    }
    return basis;
  }
}
