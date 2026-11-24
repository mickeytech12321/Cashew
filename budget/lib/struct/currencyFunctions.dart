import 'package:budget/struct/settings.dart';
import 'dart:convert';
import 'package:budget/database/tables.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

Map<String, dynamic> currenciesJSON = {};

loadCurrencyJSON() async {
  currenciesJSON = await json.decode(
      await rootBundle.loadString('assets/static/generated/currencies.json'));
}

Future<bool> getExchangeRates() async {
  print("Getting exchange rates for current wallets");
  // List<String?> uniqueCurrencies =
  //     await database.getUniqueCurrenciesFromWallets();
  Map<dynamic, dynamic> cachedCurrencyExchange =
      appStateSettings["cachedCurrencyExchange"];
  try {
    Uri url = Uri.parse(
        "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json");
    final response = await http.get(url).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return false;
    final decoded = json.decode(response.body);
    if (decoded is! Map || decoded["usd"] is! Map) return false;
    final rates = <String, double>{};
    for (final entry in (decoded["usd"] as Map).entries) {
      final value = entry.value;
      if (entry.key is String && value is num && value.isFinite && value > 0) {
        rates[entry.key as String] = value.toDouble();
      }
    }
    if (rates.isEmpty) return false;
    rates["usd"] = 1;
    cachedCurrencyExchange = rates;
  } catch (e) {
    print("Error getting currency rates: " + e.toString());
    return false;
  }
  // print(cachedCurrencyExchange);
  updateSettings(
    "cachedCurrencyExchange",
    cachedCurrencyExchange,
    updateGlobalState:
        appStateSettings["cachedCurrencyExchange"].keys.length <= 0,
  );
  return true;
}

double amountRatioToPrimaryCurrencyGivenPk(
  AllWallets allWallets,
  String walletPk, {
  Map<String, dynamic>? appStateSettingsPassed,
}) {
  if (allWallets.indexedByPk[walletPk] == null) return 1;
  return amountRatioToPrimaryCurrency(
    allWallets,
    allWallets.indexedByPk[walletPk]?.currency,
    appStateSettingsPassed: appStateSettingsPassed,
  );
}

double amountRatioToPrimaryCurrency(
  AllWallets allWallets,
  String? walletCurrency, {
  Map<String, dynamic>? appStateSettingsPassed,
}) {
  if (walletCurrency == null) {
    return 1;
  }
  if (allWallets
          .indexedByPk[
              (appStateSettingsPassed ?? appStateSettings)["selectedWalletPk"]]
          ?.currency ==
      walletCurrency) {
    return 1;
  }
  if (allWallets.indexedByPk[
          (appStateSettingsPassed ?? appStateSettings)["selectedWalletPk"]] ==
      null) {
    return 1;
  }

  double exchangeRateFromUSDToTarget = getCurrencyExchangeRate(
    allWallets
        .indexedByPk[
            (appStateSettingsPassed ?? appStateSettings)["selectedWalletPk"]]
        ?.currency,
    appStateSettingsPassed: appStateSettingsPassed,
  );
  double exchangeRateFromCurrentToUSD = 1 /
      getCurrencyExchangeRate(
        walletCurrency,
        appStateSettingsPassed: appStateSettingsPassed,
      );
  return exchangeRateFromUSDToTarget * exchangeRateFromCurrentToUSD;
}

double? amountRatioFromToCurrency(
    String walletCurrencyBefore, String walletCurrencyAfter) {
  double exchangeRateFromUSDToTarget =
      getCurrencyExchangeRate(walletCurrencyAfter);
  double exchangeRateFromCurrentToUSD =
      1 / getCurrencyExchangeRate(walletCurrencyBefore);
  return exchangeRateFromUSDToTarget * exchangeRateFromCurrentToUSD;
}

// assume selected wallets currency
String getCurrencyString(AllWallets allWallets, {String? currencyKey}) {
  String? selectedWalletCurrency =
      allWallets.indexedByPk[appStateSettings["selectedWalletPk"]]?.currency;
  return currencyKey != null
      ? (currenciesJSON[currencyKey]?["Symbol"] ?? "")
      : selectedWalletCurrency == null
          ? ""
          : (currenciesJSON[selectedWalletCurrency]?["Symbol"] ?? "");
}

double? getKnownCurrencyExchangeRate(
  String? currencyKey, {
  Map<String, dynamic>? appStateSettingsPassed,
}) {
  if (currencyKey == null || currencyKey.trim().isEmpty) return null;
  final settings = appStateSettingsPassed ?? appStateSettings;
  final key = currencyKey.trim().toLowerCase();
  if (key == "usd") return 1;
  for (final source in [settings["customCurrencyAmounts"], settings["cachedCurrencyExchange"]]) {
    if (source is! Map) continue;
    final value = source[currencyKey] ?? source[key];
    if (value is num && value.isFinite && value > 0) return value.toDouble();
  }
  return null;
}

double? strictCurrencyRatio(String? from, String? to, {
  Map<String, dynamic>? appStateSettingsPassed,
}) {
  if (from == null || to == null || from.trim().isEmpty || to.trim().isEmpty) return null;
  if (from.trim().toLowerCase() == to.trim().toLowerCase()) return 1;
  final source = getKnownCurrencyExchangeRate(from, appStateSettingsPassed: appStateSettingsPassed);
  final target = getKnownCurrencyExchangeRate(to, appStateSettingsPassed: appStateSettingsPassed);
  if (source == null || target == null) return null;
  final ratio = target / source;
  return ratio.isFinite && ratio > 0 ? ratio : null;
}

double getCurrencyExchangeRate(
  String? currencyKey, {
  Map<String, dynamic>? appStateSettingsPassed,
}) {
  // Preserve legacy display behavior. Financial writes should use strictCurrencyRatio.
  return getKnownCurrencyExchangeRate(currencyKey,
      appStateSettingsPassed: appStateSettingsPassed) ?? 1;
}

double budgetAmountToPrimaryCurrency(AllWallets allWallets, Budget budget) {
  return budget.amount *
      (amountRatioToPrimaryCurrencyGivenPk(allWallets, budget.walletFk));
}

double objectiveAmountToPrimaryCurrency(
    AllWallets allWallets, Objective objective) {
  return objective.amount *
      (amountRatioToPrimaryCurrencyGivenPk(allWallets, objective.walletFk));
}

double categoryBudgetLimitToPrimaryCurrency(
    AllWallets allWallets, CategoryBudgetLimit limit) {
  return limit.amount *
      (amountRatioToPrimaryCurrencyGivenPk(allWallets, limit.walletFk));
}

// Positive (input)
double getAmountRatioWalletTransferTo(AllWallets allWallets, String walletToPk,
    {String? enteredAmountWalletPk}) {
  return amountRatioFromToCurrency(
        allWallets
            .indexedByPk[
                enteredAmountWalletPk ?? appStateSettings["selectedWalletPk"]]!
            .currency!,
        allWallets.indexedByPk[walletToPk]!.currency!,
      ) ??
      1;
}

// Negative (output)
double getAmountRatioWalletTransferFrom(
    AllWallets allWallets, String walletFromPk,
    {String? enteredAmountWalletPk}) {
  return -1 *
      (amountRatioFromToCurrency(
            allWallets
                .indexedByPk[enteredAmountWalletPk ??
                    appStateSettings["selectedWalletPk"]]!
                .currency!,
            allWallets.indexedByPk[walletFromPk]!.currency!,
          ) ??
          1);
}
