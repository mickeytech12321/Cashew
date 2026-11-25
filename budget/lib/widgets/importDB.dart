import 'package:budget/database/backupValidation.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/syncClient.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';

Future<String?> importDBFileFromDevice(BuildContext context) async {
  // Avoid using a file filter: PlatformException(FilePicker, Unsupported filter....
  FilePickerResult? result = await FilePicker.platform.pickFiles();
  if (result == null) {
    openSnackbar(SnackbarMessage(
      title: "error-importing".tr(),
      description: "no-file-selected".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.warning_outlined
          : Icons.warning_rounded,
    ));
    return null;
  }

  String fileName = result.files.single.name;
  if (fileName.endsWith('.sql') == false &&
      fileName.endsWith('.sqlite') == false) {
    openSnackbar(SnackbarMessage(
      title: "import-warning".tr(),
      description: "import-warning-description".tr(),
      icon: appStateSettings["outlinedIcons"]
          ? Icons.warning_outlined
          : Icons.warning_rounded,
    ));
  }

  await cancelAndPreventSyncOperation();

  if (kIsWeb) {
    Uint8List fileBytes = result.files.single.bytes!;
    await overwriteDefaultDB(fileBytes);
  } else {
    File file = File(result.files.single.path ?? "");
    Uint8List fileBytes = await file.readAsBytes();
    await overwriteDefaultDB(fileBytes);
  }
  if (kIsWeb && context.mounted) {
    await resetLanguageToSystem(context);
    await updateSettings("databaseJustImported", true,
        pagesNeedingRefresh: [], updateGlobalState: false);
  }
  return result.files.single.name;
}

Future importDB(BuildContext context, {ignoreOverwriteWarning = false}) async {
  dynamic result = ignoreOverwriteWarning == true
      ? true
      : await openPopup(
          context,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.warning_outlined
              : Icons.warning_rounded,
          title: "data-overwrite-warning".tr(),
          description: "data-overwrite-warning-description".tr(),
          onCancel: () {
            popRoute(context, false);
          },
          onCancelLabel: "cancel".tr(),
          onSubmit: () {
            popRoute(context, true);
          },
          onSubmitLabel: "ok".tr(),
        );
  if (result == true) {
    await openPopup(
      context,
      icon: appStateSettings["outlinedIcons"]
          ? Icons.file_open_outlined
          : Icons.file_open_rounded,
      title: "select-backup-file".tr(),
      description: "select-backup-file-description".tr(),
      onSubmit: () {
        popRoute(context);
      },
      onSubmitLabel: "ok".tr(),
    );
    await openLoadingPopupTryCatch(
      () async {
        return await importDBFileFromDevice(context);
      },
      onError: (error) {
        if (context.mounted) showCashewBackupImportError(context, error);
      },
      onSuccess: (result) {
        if (result != null)
          restartAppPopup(
            context,
            description: kIsWeb
                ? "refresh-required-to-load-backup".tr()
                : "restart-required-to-load-backup".tr(),
            // codeBlock: result.toString(),
          );
      },
    );
  }
}

void showCashewBackupImportError(BuildContext context, Object error) {
  final ar = Localizations.localeOf(context).languageCode == 'ar';
  final description = switch (error) {
    CashewBackupVersionException(:final foundVersion, :final supportedVersion)
        when foundVersion > 0 =>
      ar
          ? 'الملف يستخدم db-v$foundVersion. هذه النسخة تدعم لحد db-v$supportedVersion والنسخ المتوافقة فقط.'
          : 'The file uses db-v$foundVersion. This build supports up to db-v$supportedVersion and compatible backups.',
    CashewBackupVersionException() => ar
        ? 'تعذّر تحديد إصدار النسخة الاحتياطية. جرّب تصديرها مرة أخرى من Cashew.'
        : 'The backup has no schema version. Try exporting it again from Cashew.',
    CashewBackupUnsupportedData() => ar
        ? 'تركيب جداول هذه النسخة الاحتياطية غير مدعوم.'
        : 'This backup uses an unsupported database layout.',
    _ => error.toString(),
  };
  openSnackbar(SnackbarMessage(
    title: 'error-importing'.tr(),
    description: description,
    icon: Icons.warning_amber,
  ));
}

class ImportDB extends StatefulWidget {
  const ImportDB({super.key});

  @override
  State<ImportDB> createState() => _ImportDBState();
}

class _ImportDBState extends State<ImportDB> {
  late var _recovery = databaseRestoreStatus();

  String _label(String en, String ar) =>
      Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

  String get _previousTitle => _label(
        'Restore pre-restore copy',
        'استرجاع النسخة المحفوظة قبل الاستعادة',
      );

  Future<void> _restorePrevious() async {
    final confirmed = await openPopup(
      context,
      title: _previousTitle,
      description: _label(
        'Switch back to the data saved before the last restore? This takes effect when you restart Cashew.',
        'هل تريد الرجوع للبيانات المحفوظة قبل آخر استعادة؟ تُطبَّق بعد إعادة تشغيل Cashew.',
      ),
      icon: Icons.settings_backup_restore,
      onCancel: () => popRoute(context, false),
      onCancelLabel: 'cancel'.tr(),
      onSubmit: () => popRoute(context, true),
      onSubmitLabel: 'ok'.tr(),
    );
    if (confirmed != true || !mounted) return;
    await openLoadingPopupTryCatch(
      () async {
        await cancelAndPreventSyncOperation();
        await stagePreviousDatabaseRestore();
      },
      onSuccess: (_) {
        if (!mounted) return;
        restartAppPopup(context,
            description: 'restart-required-to-load-backup'.tr());
      },
    );
  }

  Future<void> _dismissRejected() async {
    await openLoadingPopupTryCatch(dismissRejectedDatabaseRestore);
    if (mounted) setState(() => _recovery = databaseRestoreStatus());
  }

  Future<void> _deletePrevious() async {
    final confirmed = await openPopup(
      context,
      title: _label('Delete recovery copy?', 'حذف نسخة الاستعادة؟'),
      description: _label(
        'This removes the local copy saved before the last restore. Your current transactions stay available.',
        'سيتم حذف النسخة المحلية المحفوظة قبل آخر استعادة. يمكنك متابعة استخدام معاملاتك الحالية.',
      ),
      icon: Icons.delete_outline,
      onCancel: () => popRoute(context, false),
      onCancelLabel: 'cancel'.tr(),
      onSubmit: () => popRoute(context, true),
      onSubmitLabel: 'delete'.tr(),
    );
    if (confirmed != true || !mounted) return;
    await openLoadingPopupTryCatch(deletePreviousDatabaseRestore);
    if (mounted) setState(() => _recovery = databaseRestoreStatus());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SettingsContainer(
          onTap: () => importDB(context),
          title: 'import-data-file'.tr(),
          icon: appStateSettings['outlinedIcons']
              ? Icons.download_outlined
              : Icons.download_rounded,
        ),
        FutureBuilder<({bool previous, bool rejected})>(
          future: _recovery,
          builder: (context, snapshot) => Column(
            children: [
              if (snapshot.data?.rejected == true)
                ListTile(
                  leading: const Icon(Icons.warning_amber),
                  title: Text(_label(
                    'The pending backup could not be opened.',
                    'تعذّر فتح النسخة الاحتياطية المعلّقة.',
                  )),
                  trailing: IconButton(
                    tooltip: _label(
                      'Dismiss and remove failed backup',
                      'إخفاء التنبيه وحذف النسخة التي تعذّر فتحها',
                    ),
                    onPressed: _dismissRejected,
                    icon: const Icon(Icons.close),
                  ),
                ),
              if (snapshot.data?.previous == true)
                ListTile(
                  onTap: _restorePrevious,
                  leading: const Icon(Icons.settings_backup_restore),
                  title: Text(_previousTitle),
                  trailing: IconButton(
                    tooltip: _label('Delete recovery copy', 'حذف نسخة الاستعادة'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _deletePrevious,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
