import 'dart:async';

import 'package:budget/database/tables.dart'
    show FinanceDatabase, constructHouseholdDb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import 'sharedHousehold.dart';

const _project = String.fromEnvironment('CASHEW_HOUSEHOLD_PROJECT_ID');
const _appId = String.fromEnvironment('CASHEW_HOUSEHOLD_APP_ID');
const _apiKey = String.fromEnvironment('CASHEW_HOUSEHOLD_API_KEY');
const _sender = String.fromEnvironment('CASHEW_HOUSEHOLD_SENDER_ID');
const _firebaseApp = 'cashew-household';
const _serverOnly = GetOptions(source: Source.server);
const _networkWait = Duration(seconds: 8);

bool get householdFirebaseConfigured =>
    [_project, _appId, _apiKey, _sender].every((value) => value.isNotEmpty);

class HouseholdFirebase {
  HouseholdFirebase._(this.auth, this.firestore, this.local);

  final FirebaseAuth auth;
  final FirebaseFirestore firestore;
  final FinanceDatabase local;
  static Future<HouseholdFirebase>? _instance;

  static Future<HouseholdFirebase> open() =>
      _instance ??= _initialize().onError(
        (Object error, StackTrace stack) {
          _instance = null;
          Error.throwWithStackTrace(error, stack);
        },
      );

  static Future<HouseholdFirebase> _initialize() async {
    if (!householdFirebaseConfigured)
      throw StateError('Household service is not configured');
    // Separate project and SDK session from Cashew's legacy sharing integration.
    final app =
        Firebase.apps.where((app) => app.name == _firebaseApp).firstOrNull ??
            await Firebase.initializeApp(
              name: _firebaseApp,
              options: const FirebaseOptions(
                apiKey: _apiKey,
                appId: _appId,
                messagingSenderId: _sender,
                projectId: _project,
                authDomain: '$_project.firebaseapp.com',
              ),
            );
    final local = await constructHouseholdDb();
    try {
      await HouseholdLocalStore.initialize(local);
      final firestore = FirebaseFirestore.instanceFor(app: app)
        ..settings = const Settings(persistenceEnabled: false);
      return HouseholdFirebase._(
          FirebaseAuth.instanceFor(app: app), firestore, local);
    } catch (_) {
      await local.close();
      rethrow;
    }
  }

  HouseholdFirebaseSession session(User user) {
    if (!user.emailVerified || auth.currentUser?.uid != user.uid) {
      throw StateError('Verify the current household email first');
    }
    return HouseholdFirebaseSession._(this, user.uid);
  }
}

typedef SharedMember = ({
  String id,
  String email,
  String generation,
  bool active
});
typedef SharedInvite = ({
  String id,
  String email,
  DateTime expires,
  String state
});

class HouseholdFirebaseSession {
  HouseholdFirebaseSession._(this._service, this.uid)
      : store = HouseholdLocalStore(_service.local, '$_project/$uid') {
    outbox = HouseholdOutbox(store, _send);
  }

  final HouseholdFirebase _service;
  final String uid;
  final HouseholdLocalStore store;
  late final HouseholdOutbox outbox;

  DocumentReference<Map<String, dynamic>> _space(String id) =>
      _service.firestore.collection('households').doc(id);

  DocumentReference<Map<String, dynamic>> _link(String id) => _service.firestore
      .collection('householdUsers')
      .doc(uid)
      .collection('links')
      .doc(id);

  void _checkSession() {
    final user = _service.auth.currentUser;
    if (user?.uid != uid || user?.emailVerified != true)
      throw StateError('Household session changed');
  }

  void _checkId(String id) {
    if (!isHouseholdId(id)) throw const FormatException('Invalid household ID');
  }

  Future<T> _online<T>(Future<T> work) => work.timeout(_networkWait);

  bool _denied(FirebaseException error) =>
      error.code == 'permission-denied' || error.code == 'unauthenticated';

  Future<HouseholdRead<T>> _read<T>(
    String key,
    T Function(Map<String, dynamic>) decode,
    Map<String, dynamic> Function(T) encode,
    Future<List<T>> Function() fetch,
  ) async {
    _checkSession();
    try {
      final rows = await _online(fetch());
      _checkSession();
      await store.cache(key, rows.map(encode));
      return (items: rows, offline: false);
    } on FirebaseException catch (error) {
      if (_denied(error)) {
        await store.eraseCache(key);
        rethrow;
      }
      if (!const {
        'deadline-exceeded',
        'unavailable',
        'network-request-failed',
        'cancelled'
      }.contains(error.code)) rethrow;
    } on TimeoutException {
      // The identity-scoped local snapshot is available while the server is unreachable.
    }
    _checkSession();
    return (items: await store.read(key, decode) ?? <T>[], offline: true);
  }

  Future<HouseholdRead<SharedHousehold>> households() => _read(
        'workspaces',
        SharedHousehold.fromJson,
        (row) => row.toJson(),
        () async {
          final links = await _online(_service.firestore
              .collection('householdUsers')
              .doc(uid)
              .collection('links')
              .get(_serverOnly));
          final workspaces = await Future.wait(links.docs.map((link) async {
            try {
              final document = await _online(_space(link.id).get(_serverOnly));
              final data = document.data();
              if (data != null)
                return SharedHousehold(link.id, data['name'] as String,
                    isOwner: data['owner'] == uid);
            } on FirebaseException catch (error) {
              if (!_denied(error)) rethrow;
            }
            await store.eraseCache('space/${link.id}/', prefix: true);
            return null;
          }));
          return workspaces.nonNulls.toList()
            ..sort((a, b) => a.name.compareTo(b.name));
        },
      );

  Future<HouseholdRead<SharedHouseholdAccount>> accounts(
          SharedHousehold space) =>
      _read(
        'space/${space.id}/accounts',
        SharedHouseholdAccount.fromJson,
        (row) => row.toJson(),
        () async {
          final root = _space(space.id);
          final collection = root.collection('accounts');
          List<SharedHouseholdAccount> accounts;
          if (space.isOwner) {
            final all = await _online(collection.get(_serverOnly));
            accounts = [
              for (final doc in all.docs)
                _account(doc, SharedHouseholdRole.owner)
            ];
          } else {
            final member = root.collection('members').doc(uid);
            final membership = (await _online(member.get(_serverOnly))).data();
            if (membership?['active'] != true) {
              await store.eraseCache('space/${space.id}/', prefix: true);
              return [];
            }
            final grants = await _online(member
                .collection('access')
                .where('generation', isEqualTo: membership?['generation'])
                .get(_serverOnly));
            accounts = (await Future.wait(grants.docs.map((grant) async {
              try {
                final document =
                    await _online(collection.doc(grant.id).get(_serverOnly));
                if (document.exists) {
                  return _account(
                      document,
                      SharedHouseholdRole.values
                          .byName(grant.data()['role'] as String),
                      generation: grant.data()['generation'] as String);
                }
              } on FirebaseException catch (error) {
                if (!_denied(error)) rethrow;
              }
              return null;
            })))
                .nonNulls
                .toList();
          }
          final previous = await store.read(
              'space/${space.id}/accounts', SharedHouseholdAccount.fromJson);
          final available = accounts.map((account) => account.id).toSet();
          for (final account in previous ?? <SharedHouseholdAccount>[]) {
            if (!available.contains(account.id)) {
              await store.eraseCache(_ledgerKey(space.id, account.id));
            }
          }
          return accounts..sort((a, b) => a.name.compareTo(b.name));
        },
      );

  SharedHouseholdAccount _account(
          DocumentSnapshot<Map<String, dynamic>> doc, SharedHouseholdRole role,
          {String generation = 'owner'}) =>
      SharedHouseholdAccount.fromJson({
        ...doc.data()!,
        'id': doc.id,
        'role': role.name,
        'generation': generation,
      });

  String _ledgerKey(String space, String account) =>
      'space/$space/ledger/$account';

  Query<Map<String, dynamic>> _entriesQuery(String space, String account) =>
      _space(space)
          .collection('accounts')
          .doc(account)
          .collection('entries')
          .where('deleted', isEqualTo: false);

  List<SharedHouseholdEntry> _decodeEntries(
          QuerySnapshot<Map<String, dynamic>> snapshot) =>
      [
        for (final doc in snapshot.docs)
          SharedHouseholdEntry.fromJson({...doc.data(), 'id': doc.id}),
      ]..sort((a, b) {
          final byDay = b.day.compareTo(a.day);
          return byDay == 0 ? a.id.compareTo(b.id) : byDay;
        });

  Future<HouseholdRead<SharedHouseholdEntry>> entries(
          String space, String account) =>
      _read(
        _ledgerKey(space, account),
        SharedHouseholdEntry.fromJson,
        (row) => row.toJson(),
        () async => _decodeEntries(
            await _online(_entriesQuery(space, account).get(_serverOnly))),
      );

  /// Conflicts are reviewed against the server under the original access grant.
  Future<SharedHouseholdEntry?> latestConflictEntry(
    SharedHousehold space,
    HouseholdMutation draft,
  ) async {
    if (space.id != draft.space) throw StateError('Household changed');
    final available = await accounts(space);
    if (available.offline) throw TimeoutException('Household is offline');
    final account = available.items
        .where((item) => item.id == draft.account)
        .firstOrNull;
    if (account == null ||
        !account.role.canEdit ||
        account.generation != draft.generation) {
      throw StateError('Household edit access changed');
    }
    _checkSession();
    final doc = await _online(_entryRef(draft).get(_serverOnly));
    _checkSession();
    final data = doc.data();
    if (data == null || data['deleted'] == true) return null;
    return SharedHouseholdEntry.fromJson({...data, 'id': doc.id});
  }

  Stream<HouseholdRead<SharedHouseholdEntry>> liveEntries(
      String space, String account) async* {
    _checkSession();
    final key = _ledgerKey(space, account);
    try {
      await for (final snapshot in _entriesQuery(space, account).snapshots(
        includeMetadataChanges: true,
      )) {
        _checkSession();
        if (snapshot.metadata.isFromCache || snapshot.metadata.hasPendingWrites)
          continue;
        final rows = _decodeEntries(snapshot);
        await store.cache(key, rows.map((row) => row.toJson()));
        _checkSession();
        yield (items: rows, offline: false);
      }
    } on FirebaseException catch (error) {
      if (_denied(error)) await store.eraseCache(key);
      rethrow;
    }
  }

  Future<void> _write(void Function(Transaction) write) async {
    _checkSession();
    await _service.firestore.runTransaction((transaction) async {
      _checkSession();
      write(transaction);
    }, timeout: _networkWait, maxAttempts: 3);
  }

  Future<void> createHousehold(String id, String name) {
    _checkId(id);
    return _write((transaction) {
      transaction.set(_space(id), {
        'owner': uid,
        'name': name,
        'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.set(_link(id), {'linkedAt': FieldValue.serverTimestamp()});
    });
  }

  Future<void> createAccount(String space, SharedHouseholdAccount account) {
    _checkId(account.id);
    return _write((transaction) {
      transaction.set(_space(space).collection('accounts').doc(account.id), {
        'name': account.name,
        'currency': account.currency,
        'decimals': account.decimals,
        'opening': account.opening,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> createInvite(String space, String id, String email) {
    _checkId(id);
    final expires =
        Timestamp.fromDate(DateTime.now().add(const Duration(days: 2)));
    return _write((transaction) {
      transaction.set(_space(space).collection('invites').doc(id), {
        'email': email.trim().toLowerCase(),
        'state': 'open',
        'expiresAt': expires,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> acceptInvite(String input) async {
    _checkSession();
    final parts = input.trim().split('/');
    if (parts.length != 2 || !parts.every(isHouseholdId)) {
      throw const FormatException('Invalid invitation');
    }
    final [space, code] = parts;
    final root = _space(space);
    final email = _service.auth.currentUser!.email!.toLowerCase();
    await _service.firestore.runTransaction((transaction) async {
      final member = root.collection('members').doc(uid);
      final alreadyJoined = (await transaction.get(member)).data();
      if (alreadyJoined?['active'] == true &&
          alreadyJoined?['generation'] == code) return;
      transaction.update(root.collection('invites').doc(code), {
        'state': 'accepted',
        'acceptedBy': uid,
      });
      transaction.set(member, {
        'email': email,
        'active': true,
        'generation': code,
        'joinedAt': FieldValue.serverTimestamp(),
      });
      transaction.set(_link(space), {'linkedAt': FieldValue.serverTimestamp()});
    }, timeout: _networkWait, maxAttempts: 3);
  }

  Future<List<SharedMember>> members(String space) async {
    _checkSession();
    final result =
        await _online(_space(space).collection('members').get(_serverOnly));
    return [
      for (final row in result.docs)
        (
          id: row.id,
          email: row['email'] as String,
          generation: row['generation'] as String,
          active: row['active'] as bool
        ),
    ]..sort((a, b) => a.email.compareTo(b.email));
  }

  Future<List<SharedInvite>> openInvites(String space) async {
    _checkSession();
    final result = await _online(
      _space(space)
          .collection('invites')
          .where('state', isEqualTo: 'open')
          .get(_serverOnly),
    );
    return [
      for (final row in result.docs)
        (
          id: row.id,
          email: row['email'] as String,
          expires: (row['expiresAt'] as Timestamp).toDate(),
          state: row['state'] as String
        ),
    ]..sort((a, b) => b.expires.compareTo(a.expires));
  }

  Future<void> revokeInvite(String space, String id) => _write((transaction) {
        transaction.update(
            _space(space).collection('invites').doc(id), {'state': 'revoked'});
      });

  Future<void> revokeMember(String space, String member) =>
      _write((transaction) {
        transaction.update(
            _space(space).collection('members').doc(member), {'active': false});
      });

  Future<Map<String, SharedHouseholdRole>> grants(
    String space,
    String account,
    Iterable<SharedMember> people,
  ) async {
    _checkSession();
    final documents = await Future.wait(people.map((member) async {
      final grant = await _online(_space(space)
          .collection('members')
          .doc(member.id)
          .collection('access')
          .doc(account)
          .get(_serverOnly));
      final data = grant.data();
      return data == null || data['generation'] != member.generation
          ? null
          : MapEntry(member.id,
              SharedHouseholdRole.values.byName(data['role'] as String));
    }));
    return Map.fromEntries(documents.nonNulls);
  }

  Future<void> setGrant(String space, String account, SharedMember member,
      SharedHouseholdRole? role) {
    final reference = _space(space)
        .collection('members')
        .doc(member.id)
        .collection('access')
        .doc(account);
    return _write((transaction) {
      if (role == null) {
        transaction.delete(reference);
      } else {
        transaction.set(
            reference, {'role': role.name, 'generation': member.generation});
      }
    });
  }

  DocumentReference<Map<String, dynamic>> _entryRef(HouseholdMutation change) =>
      _space(change.space)
        .collection('accounts')
        .doc(change.account)
        .collection('entries')
        .doc(change.entry.id);

  Future<HouseholdSendResult> _send(HouseholdMutation change) async {
    _checkSession();
    final reference = _entryRef(change);
    try {
      return await _service.firestore.runTransaction((transaction) async {
        _checkSession();
        final current = (await transaction.get(reference)).data();
        if (current?['mutation'] == change.id)
          return HouseholdSendResult.applied;
        if ((current?['revision'] ?? 0) != change.entry.revision ||
            current?['deleted'] == true) {
          return HouseholdSendResult.conflict;
        }
        final updated = {
          'title': change.entry.title,
          'minor': change.entry.minor,
          'day': change.entry.day,
          'deleted': change.deleted,
          'revision': change.entry.revision + 1,
          'updatedBy': uid,
          'generation': change.generation,
          'mutation': change.id,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        if (current == null) {
          transaction.set(reference, {
            ...updated,
            'author': uid,
            'createdAt': FieldValue.serverTimestamp()
          });
        } else {
          transaction.update(reference, updated);
        }
        return HouseholdSendResult.applied;
      }, timeout: _networkWait, maxAttempts: 3);
    } on FirebaseException catch (error) {
      if (_denied(error)) {
        await store.eraseCache(_ledgerKey(change.space, change.account));
        return HouseholdSendResult.denied;
      }
      if (const {
        'aborted',
        'deadline-exceeded',
        'unavailable',
        'cancelled',
        'failed-precondition'
      }.contains(error.code)) return HouseholdSendResult.retry;
      rethrow;
    } on TimeoutException {
      return HouseholdSendResult.retry;
    }
  }
}
