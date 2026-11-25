import 'dart:typed_data';

import 'package:budget/database/tables.dart';
import 'package:drift/drift.dart';

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
      : super('This backup has an unsupported SQLite table layout.');
}

void validateCashewBackupHeader(Uint8List bytes) {
  const header = 'SQLite format 3\u0000';
  if (bytes.length < 100 || String.fromCharCodes(bytes.take(16)) != header) {
    throw const FormatException('The selected file is not a SQLite backup.');
  }
  final version = ByteData.sublistView(bytes).getUint32(60, Endian.big);
  if (version == 0 || version > schemaVersionGlobal) {
    throw CashewBackupVersionException(version, schemaVersionGlobal);
  }
}

/// Open only an isolated copy selected for a full restore.
class CashewRestoreCandidate extends FinanceDatabase {
  CashewRestoreCandidate(super.executor);
  FormatException? _validationError;

  Future<void> validate() async {
    try {
      await validateCashewBackupDatabase(this);
    } catch (_) {
      // The background SQLite executor serializes migration callback errors.
      if (_validationError case final error?) throw error;
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
        try {
          await _validateSourceTables();
        } on FormatException catch (error) {
          _validationError = error;
          rethrow;
        }
        await regular.onUpgrade(migrator, from, to);
      },
      beforeOpen: (details) async {
        if (!details.hadUpgrade) {
          try {
            await _validateCurrentLayout();
          } on FormatException catch (error) {
            _validationError = error;
            rethrow;
          }
        }
        await regular.beforeOpen?.call(details);
      },
    );
  }

  Future<void> _validateSourceTables() async {
    final stored = await customSelect(
      "SELECT name, type FROM sqlite_master "
      "WHERE type IN ('table', 'trigger', 'view')",
    ).get();
    if (stored.any((row) => row.read<String>('type') != 'table')) {
      throw const CashewBackupUnsupportedData();
    }
    final names = stored.map((row) => row.read<String>('name')).toSet();
    if (!names.containsAll(['wallets', 'transactions'])) {
      throw const FormatException(
          'The selected database is missing Cashew data tables.');
    }
  }

  Future<void> _validateCurrentLayout() async {
    const extraColumns = <String, Map<String, (String, bool)>>{
      'wallets': {
        'archived': ('INTEGER', false),
        'emoji_icon_name': ('TEXT', true),
      },
      'categories': {'archived': ('INTEGER', false)},
      'associated_titles': {'archived': ('INTEGER', false)},
      'scanner_templates': {'default_title': ('TEXT', true)},
    };
    await _validateSourceTables();
    final sqlContext = GenerationContext.fromDb(this);
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
          throw const CashewBackupUnsupportedData();
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
        throw const CashewBackupUnsupportedData();
      }
    }
    const tableLayouts = {
      'tags': {
        'date_created',
        'date_time_modified',
        'order',
        'archived',
        'name',
        'colour',
        'icon_name',
        'emoji_icon_name',
        'tag_pk',
      },
      'transaction_to_tag_links': {'transaction_pk', 'tag_pk'},
    };
    for (final table in tableLayouts.entries) {
      final columns =
          await customSelect('PRAGMA table_xinfo("${table.key}")').get();
      if (columns.isNotEmpty &&
          (columns.length != table.value.length ||
              columns.any((column) =>
                  column.read<int>('hidden') != 0 ||
                  !table.value.contains(column.read<String>('name'))))) {
        throw const CashewBackupUnsupportedData();
      }
    }
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
