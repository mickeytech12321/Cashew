import 'package:budget/struct/googleServiceConfiguration.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/accountAndBackup.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/util/debouncer.dart';
import 'package:budget/widgets/walletEntry.dart';
// import 'package:drift/web.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
import 'package:googleapis/drive/v3.dart' as drive;

String? syncBackupClientId(String? name) {
  if (name == null || !name.startsWith('sync-') || !name.endsWith('.sqlite')) return null;
  final id = name.substring(5, name.length - 7);
  if (id.isEmpty || id.contains('/') || id.contains('\\') || id.trim() != id) return null;
  return id;
}

bool isSyncBackupFile(String? name) => syncBackupClientId(name) != null;

bool isCurrentDeviceSyncBackupFile(String? backupFileName) {
  if (backupFileName == null) return false;
  return backupFileName == getCurrentDeviceSyncBackupFileName();
}

String getCurrentDeviceSyncBackupFileName({String? clientIDForSync}) {
  if (clientIDForSync == null) clientIDForSync = clientID;
  return "sync-" + clientIDForSync + ".sqlite";
}

String getDeviceFromSyncBackupFileName(String? backupFileName) {
  return syncBackupClientId(backupFileName)?.split('-').first ?? '';
}

String getCurrentDeviceName() {
  return (clientID).split("-")[0];
}

Map<String, DateTime> readSyncCursors(String? raw) {
  if (raw == null) return {};
  try {
    final settings = jsonDecode(raw);
    if (settings is! Map<String, dynamic>) return {};
    return {
      for (final entry in settings.entries)
        if (entry.value is String)
          if (DateTime.tryParse(entry.value as String) case final time?)
            entry.key: time,
    };
  } on FormatException {
    return {};
  }
}

Map<String, DateTime> advanceSyncCursors(
  Map<String, DateTime> cursors, Map<String, DateTime> received,
) {
  final updated = {...cursors};
  for (final entry in received.entries) {
    final previous = updated[entry.key];
    if (previous == null || entry.value.isAfter(previous)) {
      updated[entry.key] = entry.value;
    }
  }
  return updated;
}

Future<List<drive.File>> _listSyncFiles(drive.DriveApi api) async {
  final files = <drive.File>[];
  String? token;
  do {
    final page = await api.files.list(
      spaces: 'appDataFolder', pageToken: token,
      $fields: 'nextPageToken, files(id, name, modifiedTime)',
    );
    files.addAll((page.files ?? <drive.File>[])
      .where((file) => isSyncBackupFile(file.name)));
    token = page.nextPageToken;
  } while (token != null && token.isNotEmpty);
  return files;
}

// if changeMadeSync show loading and check if syncEveryChange is turned on
Timer? syncTimeoutTimer;
Debouncer backupDebounce = Debouncer(milliseconds: 5000);
Future<bool> createSyncBackup(
    {bool changeMadeSync = false,
    bool changeMadeSyncWaitForDebounce = true}) async {
  if (appStateSettings["hasSignedIn"] == false) return false;
  if (errorSigningInDuringCloud == true) return false;
  if (appStateSettings["backupSync"] == false) return false;
  if (changeMadeSync == true && appStateSettings["syncEveryChange"] == false)
    return false;
  // create the auto syncs after 10 seconds of no changes
  if (changeMadeSync == true &&
      (appStateSettings["syncEveryChange"] == true && kIsWeb) &&
      changeMadeSyncWaitForDebounce == true) {
    print("Running sync debouncer");
    backupDebounce.run(() {
      createSyncBackup(
          changeMadeSync: true, changeMadeSyncWaitForDebounce: false);
    });
  }

  print("Creating sync backup");
  if (changeMadeSync)
    loadingIndeterminateKey.currentState?.setVisibility(true, opacity: 0.4);
  if (syncTimeoutTimer?.isActive == true) {
    // openSnackbar(SnackbarMessage(title: "Please wait..."));
    if (changeMadeSync)
      loadingIndeterminateKey.currentState?.setVisibility(false);
    return false;
  } else {
    syncTimeoutTimer = Timer(Duration(milliseconds: 5000), () {
      syncTimeoutTimer!.cancel();
    });
  }

  bool hasSignedIn = false;
  if (googleUser == null) {
    hasSignedIn = await signInGoogle(
      gMailPermissions: false,
      waitForCompletion: false,
      silentSignIn: true,
    );
  } else {
    hasSignedIn = true;
  }
  if (hasSignedIn == false) {
    if (changeMadeSync)
      loadingIndeterminateKey.currentState?.setVisibility(false);
    return false;
  }

  final authenticateClient = await getGoogleAuthorizedClient(googleBackupScopes);
  drive.DriveApi driveApi = drive.DriveApi(authenticateClient);

  final files = await _listSyncFiles(driveApi);

  final createdId = await createBackup(null,
      silentBackup: true, clientIDForSync: clientID);
  if (createdId != null) {
    for (final file in files) {
      final id = file.id;
      if (id != null && id != createdId && isCurrentDeviceSyncBackupFile(file.name)) {
        await deleteBackup(driveApi, id);
      }
    }
  }
  if (changeMadeSync)
    loadingIndeterminateKey.currentState?.setVisibility(false);
  return createdId != null;
}

class SyncLog {
  SyncLog({
    this.deleteLogType,
    this.updateLogType,
    required this.transactionDateTime,
    required this.pk,
    this.itemToUpdate,
    this.sourceSnapshot,
    this.transferPeer,
  });

  DeleteLogType? deleteLogType;
  UpdateLogType? updateLogType;
  DateTime? transactionDateTime;
  String pk;
  dynamic itemToUpdate;
  final String? sourceSnapshot;
  final String? transferPeer;

  bool get isTransaction => updateLogType == UpdateLogType.Transaction ||
      deleteLogType == DeleteLogType.Transaction;

  @override
  String toString() {
    return "SyncLog(deleteLogType: $deleteLogType, updateLogType: $updateLogType, transactionDateTime: $transactionDateTime, pk: $pk, entry present: ${itemToUpdate != null})";
  }
}

// Only allow one sync at a time
bool canSyncData = true;

bool requestSyncDataCancel = false;

Future<bool>? _runningSync;

Future<void> cancelAndPreventSyncOperation() async {
  final pending = _runningSync;
  if (pending == null) return;
  requestSyncDataCancel = true;
  await pending;
}

Future<bool> runForceSignIn(BuildContext context) async {
  if (appStateSettings["forceAutoLogin"] == false) return false;
  if (appStateSettings["hasSignedIn"] == false) return false;
  return await signInGoogle(
    gMailPermissions: false,
    waitForCompletion: false,
    silentSignIn: true,
    context: context,
  );
}

Future<bool> syncData(BuildContext context) {
  final current = _runningSync;
  if (current != null) return current;
  final run = _syncData(context).catchError((Object _) {
    if (context.mounted && !requestSyncDataCancel) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text("syncing-failed".tr())));
    }
    return false;
  }).whenComplete(() {
    loadingProgressKey.currentState?.setProgressPercentage(1);
    loadingIndeterminateKey.currentState?.setVisibility(false);
    requestSyncDataCancel = false;
    canSyncData = true;
    _runningSync = null;
  });
  _runningSync = run;
  return run;
}

// load the latest backup and import any newly modified data into the db
Future<bool> _syncData(BuildContext context) async {
  if (canSyncData == false) return false;
  // Syncing data seems to fail on iOS debug mode (at least on iPad).
  // When actually creating the entries, it seems the device disconnects.
  // It works on release though.

  if (appStateSettings["backupSync"] == false) return false;
  if (appStateSettings["hasSignedIn"] == false) return false;
  if (errorSigningInDuringCloud == true) return false;

  // We only want to prevent this if silent sign in, otherwise we can show the user the google login popup every time on web?
  // Prevent sign-in on web - background sign-in cannot access Google Drive etc.
  if (kIsWeb &&
      !entireAppLoaded &&
      appStateSettings["webForceLoginPopupOnLaunch"] != true) return false;

  canSyncData = false;

  bool hasSignedIn = false;
  if (googleUser == null) {
    hasSignedIn = await signInGoogle(
      gMailPermissions: false,
      waitForCompletion: false,
      silentSignIn: true,
    );
  } else {
    hasSignedIn = true;
  }
  if (hasSignedIn == false) {
    canSyncData = true;
    return false;
  }

  final authenticateClient = await getGoogleAuthorizedClient(googleBackupScopes);
  drive.DriveApi driveApi = drive.DriveApi(authenticateClient);

  await createSyncBackup();

  final filesToDownloadSyncChanges = await _listSyncFiles(driveApi);
  final syncStarted = DateTime.now();
  final cursors = readSyncCursors(sharedPreferences.getString('dateOfLastSyncedWithClient'));
  final processed = <String, DateTime>{};
  final syncLogs = <SyncLog>[];

  int currentFileIndex = 0;
  loadingProgressKey.currentState?.setProgressPercentage(0);
  for (drive.File file in filesToDownloadSyncChanges) {
    if (requestSyncDataCancel == true) {
      loadingProgressKey.currentState?.setProgressPercentage(0);
      loadingIndeterminateKey.currentState?.setVisibility(false);
      print("Cancelling sync!");
      requestSyncDataCancel = false;
      return false;
    }

    loadingIndeterminateKey.currentState?.setVisibility(true);

    // we don't want to restore this clients backup
    if (isCurrentDeviceSyncBackupFile(file.name)) continue;

    final deviceId = syncBackupClientId(file.name);
    final revision = file.modifiedTime;
    final fileId = file.id;
    if (deviceId == null || revision == null || fileId == null) continue;
    final lastSynced = cursors[deviceId] ?? DateTime(0);
    if (!revision.isAfter(lastSynced)) continue;

    try {
      final media = await driveApi.files.get(fileId,
        downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in media.stream) {
        if (requestSyncDataCancel) return false;
        chunks.add(chunk);
      }
      if (requestSyncDataCancel) return false;
      await readCashewSyncSnapshot(chunks.takeBytes(), (databaseSync) async {
        List<TransactionWallet> newWallets =
            await databaseSync.getAllNewWallets(lastSynced);
        for (TransactionWallet newEntry in newWallets) {
          syncLogs.add(SyncLog(
            deleteLogType: null,
            updateLogType: UpdateLogType.TransactionWallet,
            pk: newEntry.walletPk,
            itemToUpdate: newEntry,
            transactionDateTime: newEntry.dateTimeModified,
          ));
        }

        List<TransactionCategory> newCategories =
            await databaseSync.getAllNewCategories(lastSynced);
        for (TransactionCategory newEntry in newCategories) {
          syncLogs.add(SyncLog(
            deleteLogType: null,
            updateLogType: UpdateLogType.TransactionCategory,
            pk: newEntry.categoryPk,
            itemToUpdate: newEntry,
            transactionDateTime: newEntry.dateTimeModified,
          ));
        }

        List<Budget> newBudgets = await databaseSync.getAllNewBudgets(lastSynced);
        for (Budget newEntry in newBudgets) {
          syncLogs.add(SyncLog(
            deleteLogType: null,
            updateLogType: UpdateLogType.Budget,
            pk: newEntry.budgetPk,
            itemToUpdate: newEntry,
            transactionDateTime: newEntry.dateTimeModified,
          ));
        }

        List<CategoryBudgetLimit> newCategoryBudgetLimits =
            await databaseSync.getAllNewCategoryBudgetLimits(lastSynced);
        for (CategoryBudgetLimit newEntry in newCategoryBudgetLimits) {
          syncLogs.add(SyncLog(
            deleteLogType: null,
            updateLogType: UpdateLogType.CategoryBudgetLimit,
            pk: newEntry.categoryLimitPk,
            itemToUpdate: newEntry,
            transactionDateTime: newEntry.dateTimeModified,
          ));
        }

        List<Transaction> newTransactions =
            await databaseSync.getAllNewTransactions(lastSynced);
        for (Transaction newEntry in newTransactions) {
          syncLogs.add(SyncLog(
            deleteLogType: null,
            updateLogType: UpdateLogType.Transaction,
            pk: newEntry.transactionPk,
            itemToUpdate: newEntry,
            transactionDateTime: newEntry.dateTimeModified,
            sourceSnapshot: fileId,
          ));
        }

        List<TransactionAssociatedTitle> newTitles =
            await databaseSync.getAllNewAssociatedTitles(lastSynced);
        for (TransactionAssociatedTitle newEntry in newTitles) {
          syncLogs.add(SyncLog(
            deleteLogType: null,
            updateLogType: UpdateLogType.TransactionAssociatedTitle,
            pk: newEntry.associatedTitlePk,
            itemToUpdate: newEntry,
            transactionDateTime: newEntry.dateTimeModified,
          ));
        }

        for (ScannerTemplate newEntry
            in (await databaseSync.getAllNewScannerTemplates(lastSynced))) {
          syncLogs.add(SyncLog(
            deleteLogType: null,
            updateLogType: UpdateLogType.ScannerTemplate,
            pk: newEntry.scannerTemplatePk,
            itemToUpdate: newEntry,
            transactionDateTime: newEntry.dateTimeModified,
          ));
        }

        List<Objective> newObjectives =
            await databaseSync.getAllNewObjectives(lastSynced);
        for (Objective newEntry in newObjectives) {
          syncLogs.add(SyncLog(
            deleteLogType: null,
            updateLogType: UpdateLogType.Objective,
            pk: newEntry.objectivePk,
            itemToUpdate: newEntry,
            transactionDateTime: newEntry.dateTimeModified,
          ));
        }

        List<DeleteLog> deleteLogs =
            await databaseSync.getAllNewDeleteLogs(lastSynced);

        final transferPeers = await databaseSync.getJournaledTransferPeers(
          [for (final log in deleteLogs)
            if (log.type == DeleteLogType.Transaction) log.entryPk],
        );
        for (DeleteLog deleteLog in deleteLogs) {
          syncLogs.add(SyncLog(
            deleteLogType: deleteLog.type,
            updateLogType: null,
            pk: deleteLog.entryPk,
            transactionDateTime: deleteLog.dateTimeModified,
            sourceSnapshot: fileId,
            transferPeer: transferPeers[deleteLog.entryPk],
          ));
        }
      });
      if (processed[deviceId]?.isBefore(revision) ?? true) {
        processed[deviceId] = revision;
      }
    } catch (e) {
      print("Sync failed: ${e.runtimeType}");
      loadingProgressKey.currentState?.setProgressPercentage(1);
      canSyncData = true;
      await openPopup(
        context,
        title: "syncing-failed".tr(),
        description: "sync-fail-reason".tr() + "\n\n" + file.name.toString(),
        descriptionWidget: Padding(
          padding: const EdgeInsetsDirectional.only(top: 8, bottom: 12),
          child: CodeBlock(text: e.toString()),
        ),
        icon: appStateSettings["outlinedIcons"]
            ? Icons.sync_problem_outlined
            : Icons.sync_problem_rounded,
        onCancel: () {
          popRoute(context);
        },
        onCancelLabel: "close".tr(),
        onSubmit: () {
          chooseBackup(context, isManaging: true, isClientSync: true);
        },
        onSubmitLabel: "manage".tr(),
      );
      // By returning we do not update the time last synced!
      return false;
    }

    currentFileIndex = currentFileIndex + 1;
    loadingProgressKey.currentState?.setProgressPercentage(
        currentFileIndex / filesToDownloadSyncChanges.length);
  }

  if (requestSyncDataCancel) return false;
  await database.processSyncLogs(syncLogs);
  if (processed.isNotEmpty) {
    final updated = advanceSyncCursors(cursors, processed);
    final saved = await sharedPreferences.setString('dateOfLastSyncedWithClient',
      jsonEncode(updated.map((key, value) => MapEntry(key, value.toUtc().toIso8601String()))));
    if (!saved) throw StateError('Could not persist device sync cursors');
  }

  try {
    print("UPDATED WALLET CURRENCY");
    await database.getWalletInstance(appStateSettings["selectedWalletPk"]);
  } catch (_) {
    final firstWallet = (await database.getAllWallets(limit: 1)).firstOrNull;
    if (firstWallet != null) await setPrimaryWallet(firstWallet.walletPk);
  }

  updateSettings(
    "lastSynced",
    syncStarted.toString(),
    pagesNeedingRefresh: [],
    updateGlobalState: getIsFullScreen(context) ? true : false,
  );

  loadingProgressKey.currentState?.setProgressPercentage(0.999);

  Future.delayed(Duration(milliseconds: 300), () {
    loadingProgressKey.currentState?.setProgressPercentage(1);
  });

  canSyncData = true;

  print("DONE SYNCING");
  return true;
}
