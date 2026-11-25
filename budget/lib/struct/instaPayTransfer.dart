bool isInstaPayCurrency(String? currency) => currency?.toLowerCase() == 'egp';

/// The fee is rounded to the nearest piastre, with ties rounded up.
double? instaPayTransferFee(double principal) {
  if (!principal.isFinite || principal <= 0 || principal > 999999999999) {
    return null;
  }
  final piastres = (principal * 100).round();
  if (piastres == 0 || (piastres / 100 - principal).abs() > 0.000000001) {
    return null;
  }
  return ((piastres + 500) ~/ 1000).clamp(50, 2000) / 100;
}
