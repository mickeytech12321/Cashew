import 'dart:async';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BankNotification {
  const BankNotification(
      {this.id,
      this.packageName,
      this.title,
      this.content,
      this.postedAt,
      this.receipt,
      this.signature});

  final String? id;
  final String? packageName;
  final String? title;
  final String? content;
  final DateTime? postedAt;
  final String? receipt;
  final String? signature;
}

const _access = MethodChannel('cashew/bank_notifications/settings');
const _events = EventChannel('cashew/bank_notifications/events');
const _packagesKey = 'bankNotificationAllowedPackages';
const _captureSinceKey = 'bankNotificationCaptureSince';
const _enabledKey = 'bankNotificationImportEnabled';
const _backgroundKey = 'bankNotificationBackgroundEnabled';
final bankNotificationInbox = BankNotificationInbox();

class BankNotificationInbox {
  StreamSubscription<dynamic>? _subscription;
  final revision = ValueNotifier<int>(0);
  int _configuration = 0;
  Future<void> _deliveries = Future.value();

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get enabled => sharedPreferences.getBool(_enabledKey) ?? false;
  bool get backgroundEnabled =>
      sharedPreferences.getBool(_backgroundKey) ?? false;
  List<String> get packages =>
      sharedPreferences.getStringList(_packagesKey) ?? const [];

  static List<String> parsePackages(String input) {
    final values = input
        .split(RegExp(r'[\s,]+'))
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (values.length > 20 ||
        values.any((value) =>
            value.length > 255 ||
            !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*)+$')
                .hasMatch(value))) {
      throw const FormatException('Invalid Android package list');
    }
    return values;
  }

  Future<bool> hasAccess() async =>
      supported && (await _access.invokeMethod<bool>('hasAccess') ?? false);

  Future<List<({String package, String label})>> listApps() async {
    final apps =
        await _access.invokeListMethod<Map<Object?, Object?>>('listApps');
    final result = [
      for (final app in apps ?? const <Map<Object?, Object?>>[])
        if (app['package'] is String && app['label'] is String)
          (package: app['package'] as String, label: app['label'] as String),
    ];
    result
        .sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return result;
  }

  Future<void> openAccessSettings() =>
      _access.invokeMethod<void>('openAccessSettings');

  Future<void> configure(
      {required bool enabled,
      required List<String> packages,
      bool background = false}) async {
    final validated = parsePackages(packages.join(' '));
    if (enabled && validated.isEmpty)
      throw const FormatException('Select an app');
    final changed = this.enabled != enabled ||
        backgroundEnabled != (enabled && background) ||
        !listEquals(this.packages, validated);
    if (changed &&
        !await sharedPreferences.setInt(
            _captureSinceKey, DateTime.now().millisecondsSinceEpoch)) {
      throw StateError('Could not save notification capture start');
    }
    if (!await sharedPreferences.setStringList(_packagesKey, validated) ||
        !await sharedPreferences.setBool(_enabledKey, enabled) ||
        !await sharedPreferences.setBool(
            _backgroundKey, enabled && background)) {
      throw StateError('Could not save notification settings');
    }
    await refresh(throwOnError: true);
  }

  Future<void> refresh({bool throwOnError = false}) async {
    final configuration = ++_configuration;
    final previous = _subscription;
    _subscription = null;
    await previous?.cancel();
    if (!supported || configuration != _configuration) return;
    final allowed = enabled ? packages.toSet() : <String>{};
    try {
      final permitted = await hasAccess();
      if (configuration != _configuration) return;
      final now = DateTime.now();
      final cutoff =
          now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
      var since = sharedPreferences.getInt(_captureSinceKey);
      if (since == null && permitted && allowed.isNotEmpty) {
        since = now.millisecondsSinceEpoch;
        if (!await sharedPreferences.setInt(_captureSinceKey, since)) return;
        if (configuration != _configuration) return;
      }
      await _access.invokeMethod<void>('configureRetention', {
        'packages':
            permitted && backgroundEnabled ? allowed.toList() : <String>[],
        'since': permitted && backgroundEnabled ? since ?? 0 : 0,
      });
      if (!permitted ||
          allowed.isEmpty ||
          since == null ||
          configuration != _configuration) return;
      _subscription = _events.receiveBroadcastStream({
        'packages': allowed.toList(),
        'since': since < cutoff ? cutoff : since,
      }).listen(
        (data) {
          if (data is! Map) return;
          final timestamp = data['postedAt'];
          final event = BankNotification(
            id: data['id'] as String?,
            packageName: data['packageName'] as String?,
            title: data['title'] as String?,
            content: data['content'] as String?,
            receipt: data['receipt'] as String?,
            signature: data['signature'] as String?,
            postedAt: timestamp is int && timestamp > 0
                ? DateTime.fromMillisecondsSinceEpoch(timestamp)
                : null,
          );
          _deliveries =
              _deliveries.then((_) => _receive(event, allowed, configuration));
        },
        onError: (Object _) {},
      );
    } on PlatformException {
      if (throwOnError) rethrow;
    } on MissingPluginException {
      if (throwOnError) rethrow;
    }
  }

  Future<void> _receive(
    BankNotification event,
    Set<String> allowed,
    int configuration,
  ) async {
    if (configuration != _configuration) return;
    try {
      if (await stageNotification(database, event, allowed, DateTime.now())) {
        revision.value++;
      }
      if (event.receipt != null && configuration == _configuration) {
        await _access.invokeMethod<void>('acknowledge', event.receipt);
      }
    } catch (_) {
      // Notification content must never be included in diagnostics.
    }
  }

  Future<bool> stageNotification(
    FinanceDatabase db,
    BankNotification event,
    Set<String> allowedPackages,
    DateTime receivedAt,
  ) async {
    final package = event.packageName;
    if (package == null || !allowedPackages.contains(package)) {
      return false;
    }
    final message =
        [event.title, event.content].whereType<String>().join(' ').trim();
    if (message.isEmpty || message.length > 2000) return false;
    final parsed = FinancialMessageParser.parse(message);
    final amount = parsed.amount;
    final currency = parsed.currency;
    final direction = parsed.direction;
    if (amount == null ||
        amount > 999999999999 ||
        currency == null ||
        direction == null) {
      return false;
    }

    return db.stageBankNotificationEvent(
      eventPk: uuid.v4(),
      package: package,
      notificationId: event.id ?? '',
      deliverySignature: event.signature,
      occurredAt: event.postedAt ?? receivedAt,
      receivedAt: receivedAt,
      amount: amount,
      currency: currency,
      direction: direction,
      lastFour: parsed.lastFour,
      confidence: parsed.confidence,
    );
  }
}
