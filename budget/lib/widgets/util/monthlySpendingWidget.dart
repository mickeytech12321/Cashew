import 'dart:async';
import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

const _enabledKey = 'showMonthlySpendingOnLauncher';
const _snapshotKey = 'monthlySpendingSnapshot';
final monthlySpendingWidgetEnabled = ValueNotifier<bool>(false);

Future<void> _launcherWrites = Future.value();

Future<void> _publishSpending(String? snapshot, {bool Function()? isCurrent}) {
  final write = _launcherWrites.then((_) async {
    if (isCurrent?.call() == false) return;
    await HomeWidget.saveWidgetData<String>(_snapshotKey, snapshot);
    await HomeWidget.updateWidget(name: 'MonthlySpendingWidgetProvider');
  });
  // A launcher failure should not block any later update or revocation.
  _launcherWrites = write.catchError((Object _) {});
  return write;
}

bool get supportsMonthlySpendingWidget =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> setMonthlySpendingVisibility(bool enabled) async {
  if (!await sharedPreferences.setBool(_enabledKey, enabled)) {
    throw StateError('Widget preference could not be saved');
  }
  monthlySpendingWidgetEnabled.value = enabled;
  if (!enabled) {
    await _publishSpending(null);
  }
}

class MonthlySpendingWidgetPublisher extends StatefulWidget {
  const MonthlySpendingWidgetPublisher({required this.wallet, super.key});
  final TransactionWallet? wallet;

  @override
  State<MonthlySpendingWidgetPublisher> createState() => _PublisherState();
}

class _PublisherState extends State<MonthlySpendingWidgetPublisher>
    with WidgetsBindingObserver {
  StreamSubscription<double>? _subscription;
  Timer? _rollover;
  int _version = 0;

  @override
  void initState() {
    super.initState();
    monthlySpendingWidgetEnabled.value =
        sharedPreferences.getBool(_enabledKey) ?? false;
    monthlySpendingWidgetEnabled.addListener(_refresh);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant MonthlySpendingWidgetPublisher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wallet?.walletPk != widget.wallet?.walletPk ||
        oldWidget.wallet?.currency != widget.wallet?.currency ||
        oldWidget.wallet?.decimals != widget.wallet?.decimals) _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _version++;
    _subscription?.cancel();
    _rollover?.cancel();
    monthlySpendingWidgetEnabled.removeListener(_refresh);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refresh() {
    final version = ++_version;
    _subscription?.cancel();
    _rollover?.cancel();
    final wallet = widget.wallet;
    final currency = wallet?.currency;
    if (!monthlySpendingWidgetEnabled.value ||
        wallet == null ||
        currency == null ||
        currency.isEmpty) {
      _save(version, null);
      return;
    }

    final date = DateTime.now();
    final midnight = DateTime(date.year, date.month, date.day + 1);
    _rollover = Timer(midnight.difference(date), _refresh);
    final month = '${date.year}-${date.month.toString().padLeft(2, '0')}';
    final digits = wallet.decimals.clamp(0, 12);
    _subscription = database
        .watchMonthlySpendingInCurrency(currency, date,
            walletPk: wallet.walletPk)
        .listen(
          (amount) => _save(
              version,
              jsonEncode({
                'month': month,
                'amount':
                    '${amount.toStringAsFixed(digits)} ${currency.toUpperCase()}',
              })),
          onError: (Object _) => _save(version, null),
        );
  }

  void _save(int version, String? snapshot) {
    unawaited(_publishSpending(
      snapshot,
      isCurrent: () =>
          mounted &&
          version == _version &&
          (snapshot == null || monthlySpendingWidgetEnabled.value),
    ).catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
