part of 'tables.dart';

typedef _MetadataKey = (DeleteLogType, String);
typedef _MetadataRow = ({
  _MetadataKey key,
  DateTime? revision,
  Map<String, dynamic> fields,
});

_MetadataRow _metadataRow(DataClass row) {
  final (type, id, revision) = switch (row) {
    TransactionWallet row => (
        DeleteLogType.TransactionWallet,
        row.walletPk,
        row.dateTimeModified
      ),
    TransactionCategory row => (
        DeleteLogType.TransactionCategory,
        row.categoryPk,
        row.dateTimeModified
      ),
    Budget row => (DeleteLogType.Budget, row.budgetPk, row.dateTimeModified),
    CategoryBudgetLimit row => (
        DeleteLogType.CategoryBudgetLimit,
        row.categoryLimitPk,
        row.dateTimeModified
      ),
    TransactionAssociatedTitle row => (
        DeleteLogType.TransactionAssociatedTitle,
        row.associatedTitlePk,
        row.dateTimeModified
      ),
    ScannerTemplate row => (
        DeleteLogType.ScannerTemplate,
        row.scannerTemplatePk,
        row.dateTimeModified
      ),
    Objective row => (
        DeleteLogType.Objective,
        row.objectivePk,
        row.dateTimeModified
      ),
    _ => throw ArgumentError('Unexpected sync metadata'),
  };
  return (key: (type, id), revision: revision, fields: row.toJson());
}

DataClass _decodeSyncMetadata(DeleteLogType type, Map<String, dynamic> json) =>
    switch (type) {
      DeleteLogType.TransactionWallet => TransactionWallet.fromJson(json),
      DeleteLogType.TransactionCategory => TransactionCategory.fromJson(json),
      DeleteLogType.Budget => Budget.fromJson(json),
      DeleteLogType.CategoryBudgetLimit => CategoryBudgetLimit.fromJson(json),
      DeleteLogType.TransactionAssociatedTitle =>
        TransactionAssociatedTitle.fromJson(json),
      DeleteLogType.ScannerTemplate => ScannerTemplate.fromJson(json),
      DeleteLogType.Objective => Objective.fromJson(json),
      _ => throw ArgumentError('Unexpected sync metadata type'),
    };

extension MetadataSync on FinanceDatabase {
  Future<List<DataClass>> _metadataRows(
          DeleteLogType type, Iterable<String> ids) =>
      switch (type) {
        DeleteLogType.TransactionWallet =>
          (select(wallets)..where((row) => row.walletPk.isIn(ids))).get(),
        DeleteLogType.TransactionCategory =>
          (select(categories)..where((row) => row.categoryPk.isIn(ids))).get(),
        DeleteLogType.Budget =>
          (select(budgets)..where((row) => row.budgetPk.isIn(ids))).get(),
        DeleteLogType.CategoryBudgetLimit => (select(categoryBudgetLimits)
              ..where((row) => row.categoryLimitPk.isIn(ids)))
            .get(),
        DeleteLogType.TransactionAssociatedTitle => (select(associatedTitles)
              ..where((row) => row.associatedTitlePk.isIn(ids)))
            .get(),
        DeleteLogType.ScannerTemplate => (select(scannerTemplates)
              ..where((row) => row.scannerTemplatePk.isIn(ids)))
            .get(),
        DeleteLogType.Objective =>
          (select(objectives)..where((row) => row.objectivePk.isIn(ids))).get(),
        _ => throw ArgumentError('Unexpected sync metadata type'),
      };

  Future<Map<_MetadataKey, _MetadataRow>> _readMetadataVersions(
      List<SyncLog> logs) async {
    final targets = <DeleteLogType, Set<String>>{};
    for (final log in logs) {
      final type = _metadataSyncType(log);
      if (type != null) (targets[type] ??= {}).add(log.pk);
    }
    final rows = <_MetadataKey, _MetadataRow>{};
    for (final item in targets.entries) {
      final ids = item.value.toList();
      for (var offset = 0; offset < ids.length; offset += 400) {
        for (final row
            in await _metadataRows(item.key, ids.skip(offset).take(400))) {
          final metadata = _metadataRow(row);
          rows[metadata.key] = metadata;
        }
      }
    }
    return rows;
  }

  Future<_MetadataRow?> _readMetadataVersion(_MetadataKey key) async {
    final row = (await _metadataRows(key.$1, [key.$2])).singleOrNull;
    return row == null ? null : _metadataRow(row);
  }

  Future<void> _recordMetadataConflict(
    _MetadataRow local,
    Map<String, dynamic>? remote,
    DateTime date,
    DateTime? tombstone,
  ) async {
    final type = local.key.$1.name;
    final id = local.key.$2;
    final before = jsonEncode({
      'type': type,
      'fields': local.fields,
      'removedAt': tombstone?.millisecondsSinceEpoch,
    });
    final after =
        jsonEncode({'fields': remote, 'revision': date.millisecondsSinceEpoch});
    await recordSyncConflict(
      conflictPk: financialImportFingerprint(
          sourceType: 'sync-metadata',
          sender: '$type:$id',
          rawText: jsonEncode([before, after]),
          occurredAt: date),
      entityType: 'metadata',
      entityPk: id,
      localJson: before,
      remoteJson: after,
    );
  }

  bool _matchesMetadataIgnoringRevision(_MetadataRow a, _MetadataRow b) =>
      jsonEncode(a.fields) ==
      jsonEncode(
          {...b.fields, 'dateTimeModified': a.fields['dateTimeModified']});

  Future<bool> _hasMetadataReference(String query, String id) async {
    final row =
        await customSelect('$query LIMIT 1', variables: [Variable<String>(id)])
            .getSingleOrNull();
    return row != null;
  }

  Future<bool> _canDeleteSyncMetadata(_MetadataRow row) async {
    final (type, id) = row.key;
    final references = switch (type) {
      DeleteLogType.TransactionWallet => const [
          'SELECT 1 FROM transactions WHERE wallet_fk = ?',
          'SELECT 1 FROM budgets WHERE wallet_fk = ?',
          'SELECT 1 FROM category_budget_limits WHERE wallet_fk = ?',
          'SELECT 1 FROM scanner_templates WHERE wallet_fk = ?',
          'SELECT 1 FROM objectives WHERE wallet_fk = ?',
          'SELECT 1 FROM credit_card_details WHERE wallet_fk = ?1 OR linked_bank_wallet_fk = ?1',
          'SELECT 1 FROM credit_card_statements WHERE wallet_fk = ?',
        ],
      DeleteLogType.TransactionCategory => const [
          'SELECT 1 FROM transactions WHERE category_fk = ?1 OR sub_category_fk = ?1',
          'SELECT 1 FROM categories WHERE main_category_pk = ?',
          'SELECT 1 FROM category_budget_limits WHERE category_fk = ?',
          'SELECT 1 FROM associated_titles WHERE category_fk = ?',
          'SELECT 1 FROM scanner_templates WHERE default_category_fk = ?',
        ],
      DeleteLogType.Budget => const [
          'SELECT 1 FROM transactions WHERE shared_reference_budget_pk = ?',
          'SELECT 1 FROM category_budget_limits WHERE budget_fk = ?',
        ],
      DeleteLogType.Objective => const [
          'SELECT 1 FROM transactions WHERE objective_fk = ?1 OR objective_loan_fk = ?1',
          'SELECT 1 FROM planning_scenario_goals WHERE goal_fk = ?',
        ],
      _ => const <String>[],
    };
    if (id == '0' &&
        (type == DeleteLogType.TransactionWallet ||
            type == DeleteLogType.TransactionCategory)) return false;
    if (type == DeleteLogType.Budget && row.fields['sharedKey'] != null)
      return false;
    for (final reference in references) {
      if (await _hasMetadataReference(reference, id)) return false;
    }
    if (type == DeleteLogType.TransactionWallet) {
      return !await _hasMetadataReference(
          'SELECT 1 FROM budgets WHERE instr(wallet_fks, ?) > 0',
          jsonEncode(id));
    }
    if (type == DeleteLogType.TransactionCategory) {
      return !await _hasMetadataReference(
        'SELECT 1 FROM budgets WHERE instr(category_fks, ?1) > 0 '
        'OR instr(category_fks_exclude, ?1) > 0',
        jsonEncode(id),
      );
    }
    return true;
  }

  Future<int> _deleteSyncMetadata(_MetadataKey key) => switch (key.$1) {
        DeleteLogType.TransactionWallet =>
          (delete(wallets)..where((row) => row.walletPk.equals(key.$2))).go(),
        DeleteLogType.TransactionCategory => (delete(categories)
              ..where((row) => row.categoryPk.equals(key.$2)))
            .go(),
        DeleteLogType.Budget =>
          (delete(budgets)..where((row) => row.budgetPk.equals(key.$2))).go(),
        DeleteLogType.CategoryBudgetLimit => (delete(categoryBudgetLimits)
              ..where((row) => row.categoryLimitPk.equals(key.$2)))
            .go(),
        DeleteLogType.TransactionAssociatedTitle => (delete(associatedTitles)
              ..where((row) => row.associatedTitlePk.equals(key.$2)))
            .go(),
        DeleteLogType.ScannerTemplate => (delete(scannerTemplates)
              ..where((row) => row.scannerTemplatePk.equals(key.$2)))
            .go(),
        DeleteLogType.Objective => (delete(objectives)
              ..where((row) => row.objectivePk.equals(key.$2)))
            .go(),
        _ => throw ArgumentError('Unexpected sync metadata type'),
      };

  Future<void> _finishMetadataDeletes(
    Map<_MetadataKey, DateTime> requests,
    Map<_MetadataKey, DateTime> tombstones,
  ) async {
    // Remove dependent records first. Linked transfers have already been handled.
    final categoryIds = [
      for (final key in requests.keys)
        if (key.$1 == DeleteLogType.TransactionCategory) key.$2,
    ];
    final subcategories = <String>{};
    for (var offset = 0; offset < categoryIds.length; offset += 400) {
      final rows = await (select(categories)
            ..where((row) =>
                row.categoryPk.isIn(categoryIds.skip(offset).take(400)) &
                row.mainCategoryPk.isNotNull()))
          .get();
      subcategories.addAll(rows.map((row) => row.categoryPk));
    }
    final ordered = requests.entries.toList()
      ..sort((a, b) {
        final byType = b.key.$1.index.compareTo(a.key.$1.index);
        if (byType != 0 || a.key.$1 != DeleteLogType.TransactionCategory)
          return byType;
        final aChild = subcategories.contains(a.key.$2);
        final bChild = subcategories.contains(b.key.$2);
        return aChild == bChild
            ? 0
            : aChild
                ? -1
                : 1;
      });
    for (final request in ordered) {
      final key = request.key;
      final date = request.value;
      final prior = tombstones[key];
      if (!(prior?.isBefore(date) ?? true)) continue;
      final local = await _readMetadataVersion(key);
      if (local != null) {
        if ((local.revision != null && !local.revision!.isBefore(date)) ||
            !await _canDeleteSyncMetadata(local)) {
          await _recordMetadataConflict(local, null, date, prior);
          continue;
        }
        await _deleteSyncMetadata(key);
      }
      await into(deleteLogs).insert(DeleteLogsCompanion.insert(
        type: key.$1,
        entryPk: key.$2,
        dateTimeModified: Value(date),
      ));
    }
  }

  Future<DateTime?> _latestMetadataRemoval(_MetadataKey key) async {
    final log = await (select(deleteLogs)
          ..where((row) =>
              row.entryPk.equals(key.$2) & row.type.equalsValue(key.$1))
          ..orderBy([(row) => OrderingTerm.desc(row.dateTimeModified)])
          ..limit(1))
        .getSingleOrNull();
    return log?.dateTimeModified;
  }

  Future<bool> _canEditSyncMetadata(
      _MetadataRow local, DataClass remote) async {
    Future<bool> wallet(String key) async =>
        await getWalletInstanceOrNull(key) != null;
    Future<bool> category(String key) async =>
        await getCategoryInstanceOrNull(key) != null;
    switch (remote) {
      case TransactionWallet row:
        return row.name.trim().isNotEmpty &&
            row.decimals >= 0 &&
            row.decimals <= 12 &&
            (row.currency == local.fields['currency'] ||
                !await _hasMetadataReference(
                    'SELECT 1 FROM transactions WHERE wallet_fk = ?',
                    row.walletPk));
      case TransactionCategory row:
        final parent = row.mainCategoryPk;
        if (row.name.trim().isEmpty || parent == row.categoryPk) return false;
        if (parent == null || parent == local.fields['mainCategoryPk'])
          return true;
        final target = await getCategoryInstanceOrNull(parent);
        return target != null &&
            target.mainCategoryPk == null &&
            !await _hasMetadataReference(
                'SELECT 1 FROM categories WHERE main_category_pk = ?',
                row.categoryPk);
      case Budget row:
        if (row.sharedKey != null ||
            local.fields['sharedKey'] != null ||
            !row.amount.isFinite ||
            !await wallet(row.walletFk)) return false;
        for (final key in row.walletFks ?? const <String>[]) {
          if (!await wallet(key)) return false;
        }
        for (final key in [...?row.categoryFks, ...?row.categoryFksExclude]) {
          if (!await category(key)) return false;
        }
        return true;
      case CategoryBudgetLimit row:
        return row.amount.isFinite &&
            await wallet(row.walletFk) &&
            await category(row.categoryFk) &&
            (await _metadataRows(DeleteLogType.Budget, [row.budgetFk]))
                .isNotEmpty;
      case TransactionAssociatedTitle row:
        return row.title.trim().isNotEmpty && await category(row.categoryFk);
      case ScannerTemplate row:
        return row.templateName.trim().isNotEmpty &&
            await wallet(row.walletFk) &&
            await category(row.defaultCategoryFk);
      case Objective row:
        return row.name.trim().isNotEmpty &&
            row.amount.isFinite &&
            await wallet(row.walletFk);
      default:
        return false;
    }
  }

  Future<int> _writeMetadataResolution(DataClass remote, DateTime revision) {
    final date = Value(revision);
    return switch (remote) {
      TransactionWallet row => (update(wallets)
            ..where((entry) => entry.walletPk.equals(row.walletPk)))
          .write(row.copyWith(dateTimeModified: date).toCompanion(false)),
      TransactionCategory row => (update(categories)
            ..where((entry) => entry.categoryPk.equals(row.categoryPk)))
          .write(row.copyWith(dateTimeModified: date).toCompanion(false)),
      Budget row => (update(budgets)
            ..where((entry) => entry.budgetPk.equals(row.budgetPk)))
          .write(row.copyWith(dateTimeModified: date).toCompanion(false)),
      CategoryBudgetLimit row => (update(categoryBudgetLimits)
            ..where(
                (entry) => entry.categoryLimitPk.equals(row.categoryLimitPk)))
          .write(row.copyWith(dateTimeModified: date).toCompanion(false)),
      TransactionAssociatedTitle row => (update(associatedTitles)
            ..where((entry) =>
                entry.associatedTitlePk.equals(row.associatedTitlePk)))
          .write(row.copyWith(dateTimeModified: date).toCompanion(false)),
      ScannerTemplate row => (update(scannerTemplates)
            ..where((entry) =>
                entry.scannerTemplatePk.equals(row.scannerTemplatePk)))
          .write(row.copyWith(dateTimeModified: date).toCompanion(false)),
      Objective row => (update(objectives)
            ..where((entry) => entry.objectivePk.equals(row.objectivePk)))
          .write(row.copyWith(dateTimeModified: date).toCompanion(false)),
      _ => throw ArgumentError('Unexpected sync metadata'),
    };
  }

  Future<bool> resolveMetadataSyncConflict(String conflictPk,
          {required bool useRemote}) =>
      transaction(() async {
        final conflict = await customSelect(
          "SELECT * FROM sync_conflicts WHERE conflict_pk = ? AND entity_type = 'metadata' "
          'AND resolved_at IS NULL',
          variables: [Variable<String>(conflictPk)],
        ).getSingleOrNull();
        if (conflict == null) return false;
        final now = DateTime.now();
        if (useRemote) {
          final before = jsonDecode(conflict.read<String>('local_json'))
              as Map<String, dynamic>;
          final after = jsonDecode(conflict.read<String>('remote_json'))
              as Map<String, dynamic>;
          final type = DeleteLogType.values.byName(before['type'] as String);
          final key = (type, conflict.read<String>('entity_pk'));
          final local = await _readMetadataVersion(key);
          final tombstone = await _latestMetadataRemoval(key);
          if (local == null ||
              jsonEncode(local.fields) != jsonEncode(before['fields']) ||
              tombstone?.millisecondsSinceEpoch != before['removedAt']) {
            throw StateError('Metadata changed since conflict detection');
          }
          var revision = [
            now,
            DateTime.fromMillisecondsSinceEpoch(after['revision'] as int),
            if (local.revision != null) local.revision!,
            if (tombstone != null) tombstone,
          ].reduce((a, b) => a.isAfter(b) ? a : b);
          revision = revision.add(const Duration(seconds: 1));
          if (after['fields'] == null) {
            if (!await _canDeleteSyncMetadata(local) ||
                await _deleteSyncMetadata(key) != 1) {
              throw StateError('Other records still reference this entry');
            }
            await into(deleteLogs).insert(DeleteLogsCompanion.insert(
              type: type,
              entryPk: key.$2,
              dateTimeModified: Value(revision),
            ));
          } else {
            final remote = _decodeSyncMetadata(
                type, after['fields'] as Map<String, dynamic>);
            if (_metadataRow(remote).key != key ||
                !await _canEditSyncMetadata(local, remote) ||
                await _writeMetadataResolution(remote, revision) != 1) {
              throw StateError('Incoming metadata cannot be applied safely');
            }
          }
        }
        await customStatement(
          'UPDATE sync_conflicts SET resolved_at = ?, resolution = ? WHERE conflict_pk = ?',
          [
            now.millisecondsSinceEpoch,
            useRemote ? 'remote' : 'local',
            conflictPk
          ],
        );
        return true;
      });
}
