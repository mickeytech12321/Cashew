import 'dart:async';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/sharedHousehold.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const space = '00000000-0000-4000-8000-000000000001';
const account = '00000000-0000-4000-8000-000000000002';
const generation = '00000000-0000-4000-8000-000000000003';
String changeId(int suffix) =>
    '00000000-0000-4000-8000-${suffix.toString().padLeft(12, '0')}';

HouseholdMutation change(int suffix,
    {String? target, int revision = 0, String title = 'Food'}) {
  final id = changeId(suffix);
  return HouseholdMutation(
    id: id,
    space: space,
    account: account,
    generation: generation,
    deleted: false,
    entry: SharedHouseholdEntry(
        id: target ?? id,
        title: title,
        minor: -250,
        day: '2026-11-25',
        revision: revision),
  );
}

void main() {
  test(
      'minor units handle Arabic input and reject invalid dates, fractions and bounds',
      () {
    expect(parseHouseholdMinor('-١٢٣٫٤٥', 2), -12345);
    expect(parseHouseholdMinor('1.5', 3), 1500);
    expect(parseHouseholdMinor('1.500', 2), isNull);
    expect(parseHouseholdMinor('1e7', 2), isNull);
    expect(parseHouseholdMinor('1000000000000', 0), isNull);
    expect(displayHouseholdMinor(-5, 2), '-0.05');
    expect(displayHouseholdMinor(120, 0), '120');
    expect(isHouseholdDay('2028-02-29'), isTrue);
    expect(isHouseholdDay('2026-02-29'), isFalse);
    expect(() => change(4, target: changeId(5)), throwsFormatException);
  });

  test(
      'saved snapshots and drafts reopen only for the same project and identity',
      () async {
    final folder = await Directory.systemTemp.createTemp('cashew-household');
    addTearDown(() => folder.delete(recursive: true));
    final path = File('${folder.path}/sharing.sqlite');
    final old = FinanceDatabase(NativeDatabase(path));
    await HouseholdLocalStore.initialize(old);
    final first = HouseholdLocalStore(old, 'project/first');
    await first.cache('ledger', [
      {'minor': 501}
    ]);
    await first.stage(change(11));
    await first.stage(change(11));
    await expectLater(
        first.stage(change(11, title: 'Different')), throwsStateError);
    await old.close();

    final recovered = FinanceDatabase(NativeDatabase(path));
    addTearDown(recovered.close);
    await HouseholdLocalStore.initialize(recovered);
    final restored = HouseholdLocalStore(recovered, 'project/first');
    expect(await restored.read('ledger', (row) => row['minor']), [501]);
    expect((await restored.outbox()).single.change.generation, generation);
    expect(await HouseholdLocalStore(recovered, 'project/second').outbox(),
        isEmpty);
    expect(
        await HouseholdLocalStore(recovered, 'different/first')
            .read('ledger', (row) => row),
        isNull);
    await restored.clearCache();
    expect(await restored.read('ledger', (row) => row), isNull);
    expect(await restored.outbox(), hasLength(1));
  });

  test(
      'outbox keeps edits on network failure and marks conflicts and revoked access',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await HouseholdLocalStore.initialize(db);
    final store = HouseholdLocalStore(db, 'project/first');
    for (var id = 21; id < 24; id++) {
      await store.stage(change(id));
    }
    var offline = true;
    final attempts = <String>[];
    final outbox = HouseholdOutbox(store, (mutation) async {
      attempts.add(mutation.id);
      if (offline) return HouseholdSendResult.retry;
      if (mutation.id == changeId(22)) return HouseholdSendResult.conflict;
      if (mutation.id == changeId(23)) return HouseholdSendResult.denied;
      return HouseholdSendResult.applied;
    });
    await outbox.sync();
    expect(await store.outbox(), hasLength(3));
    offline = false;
    await outbox.sync();
    final rejected = await store.outbox();
    expect(rejected.map((row) => row.delivery),
        [HouseholdDelivery.conflict, HouseholdDelivery.denied]);
    await outbox.sync();
    expect(attempts, [changeId(21), changeId(21), changeId(22), changeId(23)]);
  });

  test(
      'concurrent sync callers share a session and pick up a draft queued during delivery',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await HouseholdLocalStore.initialize(db);
    final store = HouseholdLocalStore(db, 'project/first');
    await store.stage(change(31));
    final waiting = Completer<void>();
    final release = Completer<void>();
    final sent = <String>[];
    final sync = HouseholdOutbox(store, (mutation) async {
      sent.add(mutation.id);
      if (sent.length == 1) {
        waiting.complete();
        await release.future;
      }
      return HouseholdSendResult.applied;
    });
    final first = sync.sync();
    await waiting.future;
    expect(identical(first, sync.sync()), isTrue);
    await store.stage(change(32));
    release.complete();
    await first;
    expect(sent, [changeId(31), changeId(32)]);
    expect(await store.outbox(), isEmpty);
  });

  test('a private wallet can supply only a settled opening balance for review',
      () async {
    final db = FinanceDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.wallets).insert(WalletsCompanion.insert(
          walletPk: const Value('local'),
          name: 'Local',
          order: 0,
          currency: const Value('egp'),
          decimals: const Value(2),
        ));
    final now = DateTime(2026, 11, 25);
    for (final (id, amount, paid, skipped, date) in [
      ('settled', 500.0, true, false, now),
      ('unpaid', -200.0, false, false, now),
      ('skipped', 100.0, true, true, now),
      ('future', 990.0, true, false, now.add(const Duration(days: 1))),
    ]) {
      await db.into(db.transactions).insert(Transaction(
            transactionPk: id,
            name: id,
            amount: amount,
            note: 'personal',
            categoryFk: '0',
            walletFk: 'local',
            dateCreated: date,
            income: amount > 0,
            paid: paid,
            skipPaid: skipped,
          ));
    }
    expect(await db.previewHouseholdWalletOpening('local', now),
        (name: 'Local', currency: 'EGP', decimals: 2, balance: 500.0));
    await db.saveAccountDetails(
        walletPk: 'local', accountType: 'cash', archived: true);
    expect(await db.previewHouseholdWalletOpening('local', now), isNull);
  });
}
