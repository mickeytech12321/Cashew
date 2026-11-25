part of 'tables.dart';

typedef _TransferPair = (String, String);

bool _isTransferLeg(Transaction row) =>
    row.categoryFk == '0' && row.pairedTransactionFk != null;

_TransferPair _transferPair(String first, String second) =>
    first.compareTo(second) <= 0 ? (first, second) : (second, first);

DateTime _syncDate(SyncLog log) =>
    log.transactionDateTime ?? DateTime.fromMillisecondsSinceEpoch(0);

bool _sameTransaction(Transaction local, Transaction remote) =>
    jsonEncode(local.toJson()) ==
    jsonEncode(
      remote.copyWith(dateTimeModified: Value(local.dateTimeModified)).toJson(),
    );

extension TransferSync on FinanceDatabase {
  Future<Map<String, String>> getJournaledTransferPeers(
      List<String> ids) async {
    final peers = <String, String>{};
    for (var offset = 0; offset < ids.length; offset += 400) {
      final page = ids.skip(offset).take(400).toList();
      final rows = await customSelect(
        'SELECT c.entity_pk AS leg, p.entity_pk AS peer '
        'FROM financial_action_changes c JOIN financial_actions a ON a.action_pk = c.action_fk '
        'JOIN financial_action_changes p ON p.action_fk = c.action_fk AND p.entity_pk != c.entity_pk '
        "WHERE a.action_type = 'transfer' AND c.entity_type = 'transaction' "
        "AND p.entity_type = 'transaction' AND c.change_pk IN (${page.map((_) => '?').join(',')})",
        variables: [for (final id in page) Variable<String>(id)],
      ).get();
      for (final row in rows) {
        peers[row.read<String>('leg')] = row.read<String>('peer');
      }
    }
    return peers;
  }

  Future<Set<_TransferPair>> _getTransferSyncPairs(
    List<SyncLog> logs,
    Map<String, Transaction> current,
  ) async {
    final pairs = <_TransferPair>{
      for (final row in current.values)
        if (_isTransferLeg(row))
          _transferPair(row.transactionPk, row.pairedTransactionFk!),
    };
    final ids = logs
        .where((log) => log.isTransaction)
        .map((log) => log.pk)
        .toSet()
        .toList();
    final journaled = await getJournaledTransferPeers(ids);
    for (var offset = 0; offset < ids.length; offset += 400) {
      // Catch a damaged local pair even when the changed leg is absent or unlinked.
      final reverseLinks = await (select(transactions)
            ..where((row) =>
                row.categoryFk.equals('0') &
                row.pairedTransactionFk.isIn(ids.skip(offset).take(400))))
          .get();
      for (final row in reverseLinks) {
        pairs.add(_transferPair(row.transactionPk, row.pairedTransactionFk!));
      }
    }
    for (final log in logs.where((log) => log.isTransaction)) {
      final remote = log.itemToUpdate;
      if (remote is Transaction && remote.transactionPk != log.pk) {
        throw ArgumentError('Transaction sync identifier mismatch');
      }
      if (remote is Transaction && _isTransferLeg(remote)) {
        pairs.add(_transferPair(log.pk, remote.pairedTransactionFk!));
      }
      for (final peer in [log.transferPeer, journaled[log.pk]].nonNulls) {
        pairs.add(_transferPair(log.pk, peer));
      }
    }
    return pairs;
  }

  Future<List<Transaction>> _readTransferRows(_TransferPair pair) =>
      (select(transactions)
            ..where((row) => row.transactionPk.isIn([pair.$1, pair.$2]))
            ..orderBy([(row) => OrderingTerm.asc(row.transactionPk)]))
          .get();

  Future<Map<String, DateTime>> _readTransferTombstones(
      _TransferPair pair) async {
    final logs = await (_supportedDeleteLogs()
          ..where((row) =>
              row.entryPk.isIn([pair.$1, pair.$2]) &
              row.type.equalsValue(DeleteLogType.Transaction)))
        .get();
    final newest = <String, DateTime>{};
    for (final log in logs) {
      final previous = newest[log.entryPk];
      if (previous == null || log.dateTimeModified.isAfter(previous)) {
        newest[log.entryPk] = log.dateTimeModified;
      }
    }
    return newest;
  }

  String _transferSnapshot(
          List<Transaction> rows, Map<String, DateTime> deleted) =>
      jsonEncode({
        'rows': rows.map((row) => row.toJson()).toList(),
        'deleted': {
          for (final key in (deleted.keys.toList()..sort()))
            key: deleted[key]!.millisecondsSinceEpoch
        },
      });

  Future<bool> _validTransferRows(
      _TransferPair pair, List<Transaction> rows) async {
    if (pair.$1 == pair.$2 || rows.length != 2) return false;
    final [first, second] = rows;
    if (first.transactionPk != pair.$1 ||
        second.transactionPk != pair.$2 ||
        first.pairedTransactionFk != pair.$2 ||
        second.pairedTransactionFk != pair.$1 ||
        first.walletFk == second.walletFk ||
        first.income == second.income ||
        rows.any((row) =>
            !_isTransferLeg(row) ||
            !row.amount.isFinite ||
            row.amount == 0 ||
            row.amount.abs() > 999999999999 ||
            row.income != (row.amount > 0) ||
            !row.paid ||
            row.skipPaid ||
            row.type != null ||
            row.sharedKey != null ||
            row.sharedReferenceBudgetPk != null ||
            row.objectiveFk != null ||
            row.objectiveLoanFk != null)) return false;
    final firstWallet = await getWalletInstanceOrNull(first.walletFk);
    final secondWallet = await getWalletInstanceOrNull(second.walletFk);
    if (firstWallet == null ||
        secondWallet == null ||
        await getCategoryInstanceOrNull('0') == null) return false;
    return firstWallet.currency?.toLowerCase() !=
            secondWallet.currency?.toLowerCase() ||
        (first.amount + second.amount).abs() <= 0.00000001;
  }

  Future<bool> _hasExternalTransferLinks(_TransferPair pair) async {
    final ids = [pair.$1, pair.$2];
    final link = await (select(transactions)
          ..where((row) =>
              row.pairedTransactionFk.isIn(ids) &
              row.transactionPk.isNotIn(ids))
          ..limit(1))
        .getSingleOrNull();
    return link != null;
  }

  Future<void> _processTransferSyncPairs(
    Set<_TransferPair> pairs,
    List<SyncLog> logs,
  ) async {
    if (pairs.isEmpty) return;
    final counts = <String, int>{};
    for (final pair in pairs) {
      counts.update(pair.$1, (count) => count + 1, ifAbsent: () => 1);
      counts.update(pair.$2, (count) => count + 1, ifAbsent: () => 1);
    }
    final byId = <String, List<SyncLog>>{};
    for (final log in logs
        .where((log) => log.isTransaction && counts.containsKey(log.pk))) {
      (byId[log.pk] ??= []).add(log);
    }
    for (final pair in pairs) {
      final bySnapshot = <String?, Map<String, SyncLog>>{};
      for (final log in [...?byId[pair.$1], ...?byId[pair.$2]]) {
        final revisions = bySnapshot[log.sourceSnapshot] ??= {};
        final previous = revisions[log.pk];
        if (previous == null ||
            _syncDate(log).isAfter(_syncDate(previous)) ||
            (_syncDate(log) == _syncDate(previous) &&
                log.deleteLogType != null)) {
          revisions[log.pk] = log;
        }
      }
      DateTime newest(Map<String, SyncLog> versions) =>
          versions.values.map(_syncDate).reduce((a, b) => a.isAfter(b) ? a : b);
      final snapshots = bySnapshot.values.toList()
        ..sort((a, b) => newest(a).compareTo(newest(b)));
      for (final versions in snapshots) {
        await _applyTransferSyncPair(
          pair,
          versions,
          newest(versions),
          overlaps: counts[pair.$1] != 1 || counts[pair.$2] != 1,
        );
      }
    }
  }

  Future<void> _applyTransferSyncPair(
    _TransferPair pair,
    Map<String, SyncLog> versions,
    DateTime newest, {
    required bool overlaps,
  }) async {
    final local = await _readTransferRows(pair);
    final tombstones = await _readTransferTombstones(pair);
    final ordered = [
      for (final id in [pair.$1, pair.$2])
        if (versions[id] != null) versions[id]!
    ];
    final remote = [
      for (final log in ordered)
        if (log.itemToUpdate is Transaction)
          (log.itemToUpdate as Transaction)
              .copyWith(dateTimeModified: Value(_syncDate(log))),
    ];
    final deletion = ordered.length == 2 &&
        ordered.every((log) => log.deleteLogType == DeleteLogType.Transaction);
    final localShape = local.every((row) =>
        _isTransferLeg(row) &&
        row.pairedTransactionFk ==
            (row.transactionPk == pair.$1 ? pair.$2 : pair.$1));
    final complete = !overlaps &&
        localShape &&
        (deletion || await _validTransferRows(pair, remote)) &&
        !await _hasExternalTransferLinks(pair);

    if (complete) {
      if (deletion &&
          local.isEmpty &&
          ordered.every(
              (log) => !(tombstones[log.pk]?.isBefore(_syncDate(log)) ?? true)))
        return;
      if (!deletion &&
          remote.any((row) => !(tombstones[row.transactionPk]
                  ?.isBefore(row.dateTimeModified!) ??
              true))) return;
      final stale = local.any((row) {
        final log = versions[row.transactionPk]!;
        final modified = row.dateTimeModified;
        if (modified == null) return false;
        if (deletion) return modified.isAfter(_syncDate(log));
        final incoming = remote
            .firstWhere((item) => item.transactionPk == row.transactionPk);
        return !_syncDate(log).isAfter(modified) &&
            !_sameTransaction(row, incoming);
      });
      if (!stale) {
        if (deletion) {
          await _deleteTransferPair(
              pair,
              {
                for (final log in ordered) log.pk: _syncDate(log),
              },
              tombstones);
        } else {
          await _writeSyncedTransferRows(remote, local);
        }
        return;
      }
    }

    final before = _transferSnapshot(local, tombstones);
    final incoming = jsonEncode({
      'ids': [pair.$1, pair.$2],
      'rows': remote.map((row) => row.toJson()).toList(),
      'deletion': deletion,
      'complete': complete,
      'revision': newest.millisecondsSinceEpoch,
    });
    final id = jsonEncode([pair.$1, pair.$2]);
    await recordSyncConflict(
      conflictPk: financialImportFingerprint(
        sourceType: 'sync-transfer',
        sender: id,
        rawText: jsonEncode([before, incoming]),
        occurredAt: newest,
      ),
      entityType: 'transfer',
      entityPk: id,
      localJson: before,
      remoteJson: incoming,
    );
  }

  Future<void> _writeSyncedTransferRows(
      List<Transaction> remote, List<Transaction> local) async {
    final existing = {for (final row in local) row.transactionPk: row};
    for (final row in remote) {
      final current = existing[row.transactionPk];
      if (current == null) {
        await into(transactions).insert(row.toCompanion(false));
      } else if (current.dateTimeModified?.isBefore(row.dateTimeModified!) ??
          true) {
        await (update(transactions)
              ..where((t) => t.transactionPk.equals(row.transactionPk)))
            .write(row.toCompanion(false));
      }
    }
  }

  Future<void> _deleteTransferPair(
    _TransferPair pair,
    Map<String, DateTime> revisions,
    Map<String, DateTime> tombstones,
  ) async {
    await (delete(transactions)
          ..where((row) => row.transactionPk.isIn([pair.$1, pair.$2])))
        .go();
    for (final entry in revisions.entries) {
      if (tombstones[entry.key]?.isBefore(entry.value) ?? true) {
        await into(deleteLogs).insert(DeleteLogsCompanion.insert(
          entryPk: entry.key,
          type: DeleteLogType.Transaction,
          dateTimeModified: Value(entry.value),
        ));
      }
    }
  }

  Future<bool> resolveTransferSyncConflict(String conflictPk,
          {required bool useRemote}) =>
      transaction(() async {
        final conflict = await customSelect(
          "SELECT * FROM sync_conflicts WHERE conflict_pk = ? AND entity_type = 'transfer' "
          'AND resolved_at IS NULL',
          variables: [Variable<String>(conflictPk)],
        ).getSingleOrNull();
        if (conflict == null) return false;
        final now = DateTime.now();
        if (useRemote) {
          final payload = jsonDecode(conflict.read<String>('remote_json'))
              as Map<String, dynamic>;
          final ids = (payload['ids'] as List).cast<String>();
          final pair = (ids[0], ids[1]);
          final local = await _readTransferRows(pair);
          final tombstones = await _readTransferTombstones(pair);
          if (payload['complete'] != true ||
              await _hasExternalTransferLinks(pair) ||
              _transferSnapshot(local, tombstones) !=
                  conflict.read<String>('local_json')) {
            throw StateError('Transfer changed or incoming pair is incomplete');
          }
          var revision =
              DateTime.fromMillisecondsSinceEpoch(payload['revision'] as int);
          for (final date in [
            ...local.map((row) => row.dateTimeModified).nonNulls,
            ...tombstones.values,
            now
          ]) {
            if (date.isAfter(revision)) revision = date;
          }
          revision = revision.add(const Duration(seconds: 1));
          if (payload['deletion'] == true) {
            await _deleteTransferPair(
                pair, {pair.$1: revision, pair.$2: revision}, tombstones);
          } else {
            final remote = [
              for (final row in payload['rows'] as List)
                Transaction.fromJson(row as Map<String, dynamic>)
                    .copyWith(dateTimeModified: Value(revision)),
            ];
            if (!await _validTransferRows(pair, remote)) {
              throw StateError('Incoming transfer cannot be applied safely');
            }
            await _writeSyncedTransferRows(remote, local);
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
