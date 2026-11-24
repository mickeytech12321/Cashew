# Android Google sign-in and Drive backup

This branch uses a Google Cloud OAuth project owned by the app publisher. Basic Drive backup and device sync use the Google Drive API app data folder. Firebase and Gmail are separate services.

## Current project setup

The [Cashew Free Edition project](https://console.cloud.google.com/auth/overview?project=cashew-free-edition) has the Drive API enabled. The OAuth consent screen uses External / Testing, the project owner's account is on the test-user list, and Data Access declares `drive.appdata`. The Web OAuth client is registered and its client ID is configured in the GitHub Actions repository variable `CASHEW_GOOGLE_WEB_CLIENT_ID`.

Android OAuth registration is pending the certificate SHA-1 for the intended test or release signer. Complete that registration before verifying Google sign-in and the Drive backup and restore flows on a device. Keep the app in Testing until those checks pass.

## Configure Google Cloud

1. Create or select a project in [Google Cloud Console](https://console.cloud.google.com/).
2. Enable [Google Drive API](https://console.cloud.google.com/apis/library/drive.googleapis.com) in that project.
3. In [Google Auth Platform](https://console.cloud.google.com/auth/overview), configure Branding and Audience. For external testing, add the Google accounts that will test the app. Under Data Access, add `https://www.googleapis.com/auth/drive.appdata`.
4. Under Clients, create **Android** OAuth credentials for package `com.mickey.cashew`. Register the SHA‑1 of each certificate that signs an APK you plan to install.
5. In the same project, create a **Web application** OAuth client. Copy only its client ID ending in `.apps.googleusercontent.com`. The Android plugin uses this ID as its server client ID. The native Android client ID and Web client secret are unused by the build.

For a local debug signer on Windows PowerShell:

```powershell
keytool -list -v -alias androiddebugkey -keystore "$env:USERPROFILE\.android\debug.keystore" -storepass android
```

Use the SHA1 line. If the debug keystore does not exist, use the signing report from your configured Android development build once it has created the default debug key. For a directly distributed release, use the SHA‑1 of the release certificate that signs the distributable APK. For Google Play, use the **app signing certificate** on Play Console → App integrity.

If you already have the APK you will install, read its actual signing certificate with the Android SDK Build Tools command below. Use the SHA-1 it prints rather than the fingerprint from a different build.

```text
apksigner verify --print-certs path/to/cashew.apk
```

## Give the ID to the build

Set the GitHub Actions repository **variable** `CASHEW_GOOGLE_WEB_CLIENT_ID` to the Web client ID. The configured workflow forwards it to Dart for Android builds. A local build can pass the same setting as:

```text
--dart-define=CASHEW_GOOGLE_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
```

Run this only as part of an Android build you intend to create. GitHub-hosted debug keys can differ from a local debug key. OAuth will work only for the SHA‑1 of the APK actually installed. For repeatable testing, consistently use a registered signer. Keep signing keys, passwords, OAuth client secrets, service account keys, and access tokens out of repository variables, commits and chat.

## Verify a configured build

- Sign in from **Accounts** with an authorized Google account and grant the Cashew Drive backup permission.
- Create a backup, confirm it appears in **Manage backups**, then verify that it restores into a test installation on restart.
- Try a canceled sign-in and a denied Drive grant. Local finance features should remain usable.
- For device sync, confirm both installations use the same OAuth project and Google account. Drive's app data is app-scoped. Export and import a SQLite backup when migrating from old credentials if the old files do not appear.

## Credentials for later services

| Service | Configuration to collect |
| --- | --- |
| Drive attachments | Same Android OAuth project and clients, plus the optional `drive.file` scope. |
| Gmail scanning | Gmail API enabled in the same project, plus the Gmail scope and any applicable verification. Keep it separate from backup consent. |
| Firebase Auth and household sharing | A dedicated Firebase project owned by the publisher, a registered Android app for `com.mickey.cashew`, its client configuration, enabled auth providers and tested per-member Firestore security rules. It remains disabled in this branch. |
| Browser builds | A Web OAuth client restricted to the real JavaScript origins, plus integration of the provider-rendered Google sign-in button. The Android build variable does not enable browser sign-in. |
| iOS | A separately registered iOS OAuth client and the matching native bundle and URL scheme configuration. |

Official setup references: [Google Android signing certificates](https://developers.google.com/android/guides/client-auth), [Flutter Android Google sign-in configuration](https://pub.dev/documentation/google_sign_in_android/latest/), and [Drive application data scope](https://developers.google.com/workspace/drive/api/guides/appdata).
