import 'dart:collection';
import 'dart:math' as math;

enum InvestmentCostBasis { weightedAverage, fifo }

typedef InvestmentLot = ({DateTime date, double units, double cost});

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
    this.openLots = const [],
    this.realizedBySale = const {},
  });

  final double units;
  final double cost;
  final double realized;
  final List<InvestmentLot> openLots;
  final Map<String, double> realizedBySale;

  /// Replays trades in ledger order, including the insertion order on a date.
  factory InvestmentBalance.fromTrades(
    Iterable<InvestmentTrade> trades, {
    InvestmentCostBasis method = InvestmentCostBasis.weightedAverage,
    bool includeBreakdown = false,
  }) {
    var units = 0.0;
    var cost = 0.0;
    var realized = 0.0;
    final lots = method == InvestmentCostBasis.fifo
        ? Queue<InvestmentLot>()
        : null;
    final saleResults = <String, double>{};
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
        lots?.addLast((date: trade.date, units: trade.units, cost: purchaseCost));
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
        final gain = sold * trade.price - trade.fees - basis;
        realized += gain;
        if (includeBreakdown) saleResults[trade.id] = gain;
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
    return InvestmentBalance(
      units: units,
      cost: cost,
      realized: realized,
      openLots: includeBreakdown && lots != null ? List.unmodifiable(lots) : const [],
      realizedBySale: Map.unmodifiable(saleResults),
    );
  }

  static double _consumeOldestLots(
    Queue<InvestmentLot> lots,
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
        lots.addFirst((
          date: lot.date,
          units: lot.units - consumed,
          cost: lot.cost - lotBasis,
        ));
      }
    }
    return basis;
  }
}
