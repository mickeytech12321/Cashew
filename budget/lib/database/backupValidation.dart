import 'dart:typed_data';

import 'package:budget/database/tables.dart';
import 'package:drift/drift.dart';

const _upstreamTagsVersion = 48;

class CashewBackupVersionException extends FormatException {
  CashewBackupVersionException(this.foundVersion, this.supportedVersion)
      : super(foundVersion == 0
            ? 'The backup has no recognizable Cashew schema version.'
            : 'The backup uses Cashew schema $foundVersion. '
                'This build supports up to $supportedVersion.');

  final int foundVersion;
  final int supportedVersion;
}

class CashewBackupUnsupportedData extends FormatException {
  const CashewBackupUnsupportedData()
      : super('This backup uses fields or tags this version cannot restore.');
}

void validateCashewBackupHeader(
  Uint8List bytes, {
  bool allowCompatibleRestore = false,
}) {
  const header = 'SQLite format 3\u0000';
  if (bytes.length < 100 || String.fromCharCodes(bytes.take(16)) != header) {
    throw const FormatException('The selected file is not a SQLite backup.');
  }
  final version = ByteData.sublistView(bytes).getUint32(60, Endian.big);
  if (allowCompatibleRestore && version == _upstreamTagsVersion) return;
  if (version == 0 || version > schemaVersionGlobal) {
    throw CashewBackupVersionException(version, schemaVersionGlobal);
  }
}

/// Open only an isolated copy selected for a full restore.
class CashewRestoreCandidate extends FinanceDatabase {
  CashewRestoreCandidate(super.executor);
  FormatException? _compatibilityError;

  Future<void> validate() async {
    try {
      await validateCashewBackupDatabase(this);
    } catch (_) {
      // The background executor serializes errors from migration callbacks.
      if (_compatibilityError case final error?) throw error;
      rethrow;
    }
  }

  @override
  MigrationStrategy get migration {
    final regular = super.migration;
    return MigrationStrategy(
      onCreate: (_) =>
          throw CashewBackupVersionException(0, schemaVersionGlobal),
      onUpgrade: (migrator, from, to) async {
        if (from == _upstreamTagsVersion && from > to) {
          try {
            await _validateCompatibleBackup(from);
          } on FormatException catch (error) {
            _compatibilityError = error;
            rethrow;
          }
          return;
        }
        await regular.onUpgrade(migrator, from, to);
      },
      beforeOpen: regular.beforeOpen,
    );
  }

  Future<void> _validateCompatibleBackup(int version) async {
    final check = await customSelect('PRAGMA quick_check(1)').get();
    if (check.length != 1 || check.single.data.values.single != 'ok') {
      throw const FormatException('The selected backup is corrupted.');
    }

    const tagTables = ['tags', 'transaction_to_tag_links'];
    const extraColumns = <String, Map<String, (String, bool)>>{
      'wallets': {
        'archived': ('INTEGER', false),
        'emoji_icon_name': ('TEXT', true)
      },
      'categories': {'archived': ('INTEGER', false)},
      'associated_titles': {'archived': ('INTEGER', false)},
      'scanner_templates': {'default_title': ('TEXT', true)},
    };
    final stored = await customSelect(
      "SELECT name, type FROM sqlite_master WHERE name NOT GLOB 'sqlite_*' "
      "AND type IN ('table', 'view', 'trigger')",
    ).get();
    final tables = {
      for (final row in stored)
        row.read<String>('name'): row.read<String>('type'),
    };
    final expected = {
      for (final table in allTables) table.actualTableName,
      ...tagTables,
    };
    if (tables.length != expected.length ||
        expected.any((table) => tables[table] != 'table')) {
      throw CashewBackupVersionException(version, schemaVersionGlobal);
    }

    final sqlContext = GenerationContext.fromDb(this);
    var hasArchivedWalletColumn = false;
    for (final table in allTables) {
      final name = table.actualTableName;
      final columns = await customSelect('PRAGMA table_xinfo("$name")').get();
      final actual = {for (final row in columns) row.read<String>('name'): row};
      final primaryKey = table.$primaryKey.map((c) => c.$name).toSet();
      final extras = extraColumns[name] ?? const <String, (String, bool)>{};
      for (final entry in extras.entries) {
        final row = actual.remove(entry.key);
        if (row != null &&
            (row.read<int>('hidden') != 0 ||
                row.read<String>('type').toUpperCase() != entry.value.$1 ||
                (row.read<int>('notnull') == 0) != entry.value.$2 ||
                row.read<int>('pk') != 0)) {
          throw CashewBackupVersionException(version, schemaVersionGlobal);
        }
        if (row == null) continue;
        if (name == 'wallets' && entry.key == 'archived') {
          hasArchivedWalletColumn = true;
        } else {
          final predicate = entry.key == 'archived' ? '!= 0' : 'IS NOT NULL';
          final populated = await customSelect(
            'SELECT 1 FROM "$name" WHERE "${entry.key}" $predicate LIMIT 1',
          ).getSingleOrNull();
          if (populated != null) throw const CashewBackupUnsupportedData();
        }
      }
      final nullableDeleteStamp = name == 'delete_logs' &&
          actual['date_time_modified']?.read<int>('notnull') == 0;
      if (actual.length != table.$columns.length ||
          table.$columns.any((column) {
            final row = actual[column.$name];
            return row == null ||
                row.read<int>('hidden') != 0 ||
                row.read<String>('type').toUpperCase() !=
                    column.type.sqlTypeName(sqlContext).toUpperCase() ||
                ((row.read<int>('notnull') == 0) != column.$nullable &&
                    !(nullableDeleteStamp &&
                        column.$name == 'date_time_modified')) ||
                (row.read<int>('pk') > 0) != primaryKey.contains(column.$name);
          })) {
        throw CashewBackupVersionException(version, schemaVersionGlobal);
      }
      if (nullableDeleteStamp &&
          await customSelect(
                'SELECT 1 FROM delete_logs WHERE date_time_modified IS NULL LIMIT 1',
              ).getSingleOrNull() !=
              null) {
        throw const CashewBackupUnsupportedData();
      }
    }
    final newTombstones = await customSelect(
      'SELECT 1 FROM delete_logs WHERE type < 0 OR type >= ? LIMIT 1',
      variables: [Variable<int>(DeleteLogType.values.length)],
    ).getSingleOrNull();
    if (newTombstones != null) {
      throw CashewBackupVersionException(version, schemaVersionGlobal);
    }
    for (final table in tagTables) {
      if (await customSelect('SELECT 1 FROM "$table" LIMIT 1')
              .getSingleOrNull() !=
          null) {
        throw const CashewBackupUnsupportedData();
      }
    }

    if (hasArchivedWalletColumn) {
      final malformed = await customSelect(
        'SELECT 1 FROM wallets WHERE archived NOT IN (0, 1) LIMIT 1',
      ).getSingleOrNull();
      if (malformed != null) throw const CashewBackupUnsupportedData();
      await transaction(() async {
        await createLocalFinancialSchema47();
        await customStatement(
          "INSERT INTO account_details(wallet_fk, account_type, archived) "
          "SELECT wallet_pk, 'unspecified', 1 FROM wallets WHERE archived = 1",
        );
      });
    }
    // Drift stamps the isolated copy after validation.
    // The regular beforeOpen provisions the local extension tables.
  }
}

Future<void> validateCashewBackupDatabase(FinanceDatabase candidate) async {
  final check = await candidate.customSelect('PRAGMA quick_check(1)').get();
  if (check.length != 1 || check.single.data.values.single != 'ok') {
    throw const FormatException('The selected backup is corrupted.');
  }
  final tables = await candidate
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )
      .get();
  final tableNames = tables.map((row) => row.read<String>('name')).toSet();
  for (final table in candidate.allTables) {
    if (!tableNames.contains(table.actualTableName)) {
      throw const FormatException(
          'The selected database is missing Cashew data tables.');
    }
    final columns = await candidate
        .customSelect('PRAGMA table_info("${table.actualTableName}")')
        .get();
    final columnNames = columns.map((row) => row.read<String>('name')).toSet();
    if (!table.$columns.every((column) => columnNames.contains(column.$name))) {
      throw const FormatException(
          'The selected database is missing Cashew data columns.');
    }
  }
}
