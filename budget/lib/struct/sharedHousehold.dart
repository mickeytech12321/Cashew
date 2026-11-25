import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/financialMessageParser.dart';
import 'package:drift/drift.dart' show Variable;

const householdMoneyLimit = 999999999999;
final _householdId = RegExp(r'^[a-z0-9_-]{20,50}$');
final _isoDay = RegExp(r'^\d{4}-\d{2}-\d{2}$');

bool isHouseholdId(String value) => _householdId.hasMatch(value);

bool isHouseholdDay(String value) {
  if (!_isoDay.hasMatch(value)) return false;
  final day = DateTime.tryParse(value);
  return day != null && day.toIso8601String().startsWith(value);
}

String householdDay(DateTime date) => date.toIso8601String().split('T').first;

int? parseHouseholdMinor(String input, int decimals) {
  if (decimals < 0 || decimals > 3) return null;
  final value = FinancialMessageParser.normalize(input.trim());
  final match =
      RegExp(r'^(-?)([0-9]{1,12})(?:\.([0-9]{1,3}))?$').firstMatch(value);
  if (match == null) return null;
  final fraction = match[3] ?? '';
  if (fraction.length > decimals) return null;
  final magnitude =
      int.tryParse('${match[2]}${fraction.padRight(decimals, '0')}');
  if (magnitude == null || magnitude > householdMoneyLimit) return null;
  return match[1] == '-' ? -magnitude : magnitude;
}

String displayHouseholdMinor(int minor, int decimals) {
  final digits = minor.abs().toString().padLeft(decimals + 1, '0');
  final prefix = minor < 0 ? '-' : '';
  if (decimals == 0) return '$prefix$digits';
  final point = digits.length - decimals;
  return '$prefix${digits.substring(0, point)}.${digits.substring(point)}';
}

enum SharedHouseholdRole {
  owner,
  editor,
  viewer;

  bool get canEdit => this != viewer;
}

class SharedHousehold {
  const SharedHousehold(this.id, this.name, {required this.isOwner});
  final String id;
  final String name;
  final bool isOwner;

  SharedHousehold.fromJson(Map<String, dynamic> json)
      : this(json['id'] as String, json['name'] as String,
            isOwner: json['owner'] as bool);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'owner': isOwner};
}

class SharedHouseholdAccount {
  const SharedHouseholdAccount({
    required this.id,
    required this.name,
    required this.currency,
    required this.decimals,
    required this.opening,
    required this.role,
    this.generation = 'owner',
  });

  final String id;
  final String name;
  final String currency;
  final int decimals;
  final int opening;
  final SharedHouseholdRole role;
  final String generation;

  SharedHouseholdAccount.fromJson(Map<String, dynamic> json)
      : this(
            id: json['id'] as String,
            name: json['name'] as String,
            currency: json['currency'] as String,
            decimals: json['decimals'] as int,
            opening: json['opening'] as int,
            role: SharedHouseholdRole.values.byName(json['role'] as String),
            generation: json['generation'] as String);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'currency': currency,
        'decimals': decimals,
        'opening': opening,
        'role': role.name,
        'generation': generation,
      };
}

class SharedHouseholdEntry {
  const SharedHouseholdEntry({
    required this.id,
    required this.title,
    required this.minor,
    required this.day,
    required this.revision,
  });

  final String id;
  final String title;
  final int minor;
  final String day;
  final int revision;

  SharedHouseholdEntry.fromJson(Map<String, dynamic> json)
      : this(
            id: json['id'] as String,
            title: json['title'] as String,
            minor: json['minor'] as int,
            day: json['day'] as String,
            revision: json['revision'] as int);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'minor': minor,
        'day': day,
        'revision': revision,
      };
}

class HouseholdMutation {
  HouseholdMutation({
    required this.id,
    required this.space,
    required this.account,
    required this.generation,
    required this.entry,
    required this.deleted,
  }) {
    if (![id, space, account, entry.id].every(isHouseholdId) ||
        (generation != 'owner' && !isHouseholdId(generation)) ||
        entry.title.trim().isEmpty ||
        entry.title.length > 100 ||
        entry.minor == 0 ||
        entry.minor.abs() > householdMoneyLimit ||
        !isHouseholdDay(entry.day) ||
        entry.revision < 0 ||
        (entry.revision == 0 && (deleted || id != entry.id))) {
      throw const FormatException('Invalid shared ledger change');
    }
  }

  final String id;
  final String space;
  final String account;
  final String generation;
  final SharedHouseholdEntry entry;
  final bool deleted;

  HouseholdMutation.fromJson(Map<String, dynamic> json)
      : this(
            id: json['id'] as String,
            space: json['space'] as String,
            account: json['account'] as String,
            generation: json['generation'] as String,
            deleted: json['deleted'] as bool,
            entry: SharedHouseholdEntry.fromJson(
                json['entry'] as Map<String, dynamic>));

  Map<String, dynamic> toJson() => {
        'id': id,
        'space': space,
        'account': account,
        'generation': generation,
        'deleted': deleted,
        'entry': entry.toJson(),
      };
}

enum HouseholdDelivery { pending, conflict, denied }

enum HouseholdSendResult { applied, conflict, denied, retry }

typedef HouseholdOutboxItem = ({
  HouseholdMutation change,
  HouseholdDelivery delivery
});
typedef HouseholdRead<T> = ({List<T> items, bool offline});

/// Storage is opened in a separate database from the personal ledger and Drive backups.
class HouseholdLocalStore {
  HouseholdLocalStore(this.database, this.scope);

  final FinanceDatabase database;
  final String scope;

  static Future<void> initialize(FinanceDatabase database) async {
    await database.customStatement('PRAGMA secure_delete = ON');
    await database.transaction(() async {
      await database.customStatement(
          '''CREATE TABLE IF NOT EXISTS shared_household_cache (
        scope TEXT NOT NULL, cache_key TEXT NOT NULL, payload TEXT NOT NULL,
        PRIMARY KEY (scope, cache_key)
      )''');
      await database.customStatement(
          '''CREATE TABLE IF NOT EXISTS shared_household_outbox (
        scope TEXT NOT NULL, mutation_id TEXT NOT NULL, workspace TEXT NOT NULL,
        account TEXT NOT NULL, entry TEXT NOT NULL, payload TEXT NOT NULL,
        delivery TEXT NOT NULL DEFAULT 'pending',
        created_at INTEGER NOT NULL,
        PRIMARY KEY (scope, mutation_id), UNIQUE (scope, workspace, account, entry)
      )''');
    });
  }

  Future<List<T>?> read<T>(
      String key, T Function(Map<String, dynamic>) decode) async {
    final row = await database.customSelect(
      'SELECT payload FROM shared_household_cache WHERE scope = ? AND cache_key = ?',
      variables: [Variable<String>(scope), Variable<String>(key)],
    ).getSingleOrNull();
    if (row == null) return null;
    return (jsonDecode(row.read<String>('payload')) as List)
        .map((item) => decode(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> cache(String key, Iterable<Map<String, dynamic>> rows) =>
      database.customStatement(
        'INSERT INTO shared_household_cache(scope,cache_key,payload) VALUES (?,?,?) '
        'ON CONFLICT(scope,cache_key) DO UPDATE SET payload=excluded.payload',
        [scope, key, jsonEncode(rows.toList())],
      );

  Future<void> eraseCache(String key, {bool prefix = false}) =>
      database.customStatement(
        'DELETE FROM shared_household_cache WHERE scope = ? AND '
        '${prefix ? "substr(cache_key,1,length(?)) = ?" : "cache_key = ?"}',
        [scope, if (prefix) key, key],
      );

  Future<void> stage(HouseholdMutation mutation) =>
      database.transaction(() async {
        final payload = jsonEncode(mutation.toJson());
        final saved = await database.customSelect(
          'SELECT payload FROM shared_household_outbox WHERE scope = ? AND mutation_id = ?',
          variables: [Variable<String>(scope), Variable<String>(mutation.id)],
        ).getSingleOrNull();
        if (saved != null) {
          if (saved.read<String>('payload') != payload)
            throw StateError('Mutation id reused');
          return;
        }
        await database.customStatement(
          'INSERT INTO shared_household_outbox '
          '(scope,mutation_id,workspace,account,entry,payload,created_at) VALUES (?,?,?,?,?,?,?)',
          [
            scope,
            mutation.id,
            mutation.space,
            mutation.account,
            mutation.entry.id,
            payload,
            DateTime.now().millisecondsSinceEpoch
          ],
        );
      });

  Future<List<HouseholdOutboxItem>> outbox() async {
    final rows = await database.customSelect(
      'SELECT payload, delivery FROM shared_household_outbox WHERE scope = ? '
      'ORDER BY created_at, mutation_id',
      variables: [Variable<String>(scope)],
    ).get();
    return [
      for (final row in rows)
        (
          change: HouseholdMutation.fromJson(
              jsonDecode(row.read<String>('payload')) as Map<String, dynamic>),
          delivery:
              HouseholdDelivery.values.byName(row.read<String>('delivery'))
        ),
    ];
  }

  Future<void> mark(String id, HouseholdDelivery state) =>
      database.customStatement(
        'UPDATE shared_household_outbox SET delivery = ? WHERE scope = ? AND mutation_id = ?',
        [state.name, scope, id],
      );

  Future<void> remove(String id) => database.customStatement(
        'DELETE FROM shared_household_outbox WHERE scope = ? AND mutation_id = ?',
        [scope, id],
      );

  Future<void> clearCache() => eraseCache('', prefix: true);
}

class HouseholdOutbox {
  HouseholdOutbox(this.store, this.send);
  final HouseholdLocalStore store;
  final Future<HouseholdSendResult> Function(HouseholdMutation) send;
  Future<void>? _active;

  Future<void> sync() {
    if (_active case final active?) return active;
    final work = _sync().whenComplete(() => _active = null);
    _active = work;
    return work;
  }

  Future<void> _sync() async {
    while (true) {
      final pending = (await store.outbox())
          .where((item) => item.delivery == HouseholdDelivery.pending);
      if (pending.isEmpty) return;
      for (final item in pending) {
        switch (await send(item.change)) {
          case HouseholdSendResult.applied:
            await store.remove(item.change.id);
          case HouseholdSendResult.conflict:
            await store.mark(item.change.id, HouseholdDelivery.conflict);
          case HouseholdSendResult.denied:
            await store.mark(item.change.id, HouseholdDelivery.denied);
          case HouseholdSendResult.retry:
            return;
        }
      }
    }
  }
}
