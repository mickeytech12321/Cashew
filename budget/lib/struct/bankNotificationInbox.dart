import 'dart:async';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BankNotification {
  const BankNotification(
      {this.id, this.packageName, this.title, this.content, this.postedAt});

  final String? id;
  final String? packageName;
  final String? title;
  final String? content;
  final DateTime? postedAt;
}

const _access = MethodChannel('cashew/bank_notifications/settings');
const _events = EventChannel('cashew/bank_notifications/events');
const _packagesKey = 'bankNotificationAllowedPackages';
const _captureSinceKey = 'bankNotificationCaptureSince';
const _enabledKey = 'bankNotificationImportEnabled';
final bankNotificationInbox = BankNotificationInbox();

class BankNotificationInbox {
  StreamSubscription<dynamic>? _subscription;
  final _recent = <String, DateTime>{};
  final revision = ValueNotifier<int>(0);
  int _configuration = 0;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get enabled => sharedPreferences.getBool(_enabledKey) ?? false;
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
      {required bool enabled, required List<String> packages}) async {
    final validated = parsePackages(packages.join(' '));
    if (enabled && validated.isEmpty)
      throw const FormatException('Select an app');
    final changed = this.enabled != enabled ||
        !listEquals(this.packages, validated);
    if (changed &&
        !await sharedPreferences.setInt(
            _captureSinceKey, DateTime.now().millisecondsSinceEpoch)) {
      throw StateError('Could not save notification capture start');
    }
    if (!await sharedPreferences.setStringList(_packagesKey, validated) ||
        !await sharedPreferences.setBool(_enabledKey, enabled)) {
      throw StateError('Could not save notification settings');
    }
    await refresh();
  }

  Future<void> refresh() async {
    final configuration = ++_configuration;
    final previous = _subscription;
    _subscription = null;
    await previous?.cancel();
    if (configuration != _configuration ||
        !supported ||
        !enabled ||
        packages.isEmpty) return;
    final allowed = packages.toSet();
    try {
      final permitted = await hasAccess();
      if (!permitted || configuration != _configuration) return;
      final now = DateTime.now();
      final cutoff = now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
      var since = sharedPreferences.getInt(_captureSinceKey);
      if (since == null) {
        // Existing opt-ins start recovery from their first launch with this version.
        since = now.millisecondsSinceEpoch;
        if (!await sharedPreferences.setInt(_captureSinceKey, since)) return;
        if (configuration != _configuration) return;
      }
      _subscription = _events.receiveBroadcastStream({
        'packages': allowed.toList(),
        'since': since < cutoff ? cutoff : since,
      }).listen(
        (data) {
          if (data is! Map) return;
          final timestamp = data['postedAt'];
          unawaited(_receive(
            BankNotification(
              id: data['id'] as String?,
              packageName: data['packageName'] as String?,
              title: data['title'] as String?,
              content: data['content'] as String?,
              postedAt: timestamp is int && timestamp > 0
                  ? DateTime.fromMillisecondsSinceEpoch(timestamp)
                  : null,
            ),
            allowed,
            configuration,
          ));
        },
        onError: (Object _) {},
      );
    } on PlatformException {
      // Notification access can change independently in Android settings.
    } on MissingPluginException {
      // The app can still use manual imports on unsupported builds.
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

    // Android may update the same notification repeatedly. Keep only hashes
    // in a bounded, short-lived cache so reused notification IDs work later.
    final key = db.financialImportFingerprint(
      sourceType: 'notification',
      sender: '$package:${event.id ?? ''}',
      rawText: message,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    _recent.removeWhere(
        (_, time) => receivedAt.difference(time) > const Duration(minutes: 2));
    if (_recent.containsKey(key)) return false;
    if (_recent.length >= 100) _recent.remove(_recent.keys.first);
    _recent[key] = receivedAt;
    try {
      return await db.stageImportedFinancialEvent(
        eventPk: uuid.v4(),
        sourceType: 'notification',
        sourceSender: package,
        // Keep the parsed direction, amount and card suffix separately. Do
        // not retain the original notification body or merchant string.
        rawText: package,
        occurredAt: event.postedAt ?? receivedAt,
        amount: amount,
        currency: currency,
        direction: direction,
        identifierLast4: parsed.lastFour,
        confidence: parsed.confidence,
      );
    } catch (_) {
      if (_recent[key] == receivedAt) _recent.remove(key);
      rethrow;
    }
  }
}
