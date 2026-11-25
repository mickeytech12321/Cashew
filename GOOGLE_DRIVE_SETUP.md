# CashU Android Google sign-in and Drive backup

This branch uses a Google Cloud OAuth project owned by the app publisher. Basic Drive backup and device sync use the Google Drive API app data folder. Firebase and Gmail are separate services.

## Current project setup

The [Cashew Free Edition project](https://console.cloud.google.com/auth/overview?project=cashew-free-edition) has the Drive API enabled. The OAuth consent screen uses External / Testing, the project owner's account is on the test-user list, and Data Access declares `drive.appdata`. The Web OAuth client is registered and its client ID is configured in the GitHub Actions repository variable `CASHEW_GOOGLE_WEB_CLIENT_ID`.

Register a new Android OAuth client for the CashU package. The previous Android package registration does not cover this build. For the supplied ARM64 CashU test build, use package `com.cashu.mickey` and SHA-1 `09:B9:9A:4C:9E:4E:3A:95:3F:D8:8C:51:FE:FF:6D:EB:FC:DF:84:20`. Complete registration before verifying sign-in, backup and restore on a device.

## Configure Google Cloud

1. Create or select a project in [Google Cloud Console](https://console.cloud.google.com/).
2. Enable [Google Drive API](https://console.cloud.google.com/apis/library/drive.googleapis.com) in that project.
3. In [Google Auth Platform](https://console.cloud.google.com/auth/overview), configure Branding and Audience. For external testing, add the Google accounts that will test the app. Under Data Access, add `https://www.googleapis.com/auth/drive.appdata`.
4. Under Clients, create **Android** OAuth credentials for the installed package. The standard package is `com.cashu.mickey` and the isolated preview package is `com.cashu.mickey.preview`. Register the SHA‑1 of the certificate that signs that APK.
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

GitHub Actions variables are available to the workflow. For a local build with Drive enabled, explicitly pass the public Web client ID with the flag above and register the APK's actual package and certificate in Google Cloud. When building without the variable, use **Settings → Google Drive → Google Drive setup** on the test device to paste the public **Web OAuth client ID** from the same Cloud project. This saves the ID on that installation and leaves the local backup workflow available. If changing an ID after a sign-in attempt, close and reopen CashU before retrying.

## Build an Android test APK

Use Flutter 3.50.1 and Android SDK 36. The optimized test build uses the local Android debug signer and installs as `com.cashu.mickey`. Set `CASHU_TEST_KEYSTORE` to reuse an existing Android debug-format keystore that has a registered OAuth certificate. For a separately installed preview alongside CashU, also set `CASHEW_ISOLATED_PREVIEW=true` and register the resulting `com.cashu.mickey.preview` package separately.

```bash
cd budget
flutter pub get
python3 ../scripts/prepare_flutter_compat.py android
CASHEW_TEST_RELEASE=true \
  flutter build apk --release --no-pub --no-tree-shake-icons
```

The APK is at `budget/build/app/outputs/flutter-apk/app-release.apk` from the repository root. For Web compilation, apply `python3 ../scripts/prepare_flutter_compat.py web` after package resolution to use the pinned Drift and sqlite3 versions with the newer Dart toolchain.

## Verify a configured build

- Sign in from **Accounts** with an authorized Google account and grant the Cashew Drive backup permission.
- Create a backup, confirm it appears in **Manage backups**, then verify that it restores into a test installation on restart.
- Try a canceled sign-in and a denied Drive grant. Local finance features should remain usable.
- For device sync, confirm both installations use the same OAuth project and Google account. Drive's app data is app-scoped. The new Android package starts with independent app data. Use **Export Cashew Data File** in the old app, then **Import Cashew Data File** in CashU and reopen it to restore on the new package if the existing Drive files are unavailable.

## Credentials for later services

| Service | Configuration to collect |
| --- | --- |
| Drive attachments | Same Android OAuth project and clients, plus the optional `drive.file` scope. |
| Gmail scanning | Gmail API enabled in the same project, plus the Gmail scope and any applicable verification. Keep it separate from backup consent. |
| Firebase Auth and household sharing | A separate publisher-owned project, registered app, verified email/password sign-in and the isolated [household rules](budget/household/firestore.rules). See the setup below. |
| Browser builds | A Web OAuth client restricted to the real JavaScript origins, plus integration of the provider-rendered Google sign-in button. The Android build variable does not enable browser sign-in. |
| iOS | A separately registered iOS OAuth client and the matching native bundle and URL scheme configuration. |

## Configure household sharing

This optional service uses a dedicated Firebase project with a default Cloud Firestore database and Email/Password authentication. Register `com.cashu.mickey` as an Android app in the new Firebase project. Configure verification emails and apply the [household rules](budget/household/firestore.rules) to that project. The separate configuration in `budget/household/firebase.json` targets those rules. Specify the dedicated project explicitly if you deploy them with the Firebase CLI.

Supply the project’s public client configuration to the intended app build. The free-edition Android workflow can read the same keys from repository variables.

| Build value | Firebase setting |
| --- | --- |
| `CASHEW_HOUSEHOLD_PROJECT_ID` | Project ID |
| `CASHEW_HOUSEHOLD_APP_ID` | Firebase App ID for the intended platform |
| `CASHEW_HOUSEHOLD_API_KEY` | Firebase client API key for that app |
| `CASHEW_HOUSEHOLD_SENDER_ID` | Messaging sender ID or project number |

Local builds can supply these values as Dart defines or with `--dart-define-from-file`. Missing values leave the local Household profiles available. Firebase service-account credentials belong outside the app and repository. Household email sign-in uses its own Firebase session independently of Google Drive sign-in.

In **Settings → Household profiles → Household sharing**, the owner verifies an email, creates a household and copies an invitation code for the recipient’s verified email. The recipient accepts the code before the owner assigns access to individual accounts. Starting with a personal balance shows the name, currency and opening balance for confirmation. Shared transactions use their own ledger. Offline changes remain saved under the current login and sync when the app can reach the server. An edit superseded on another device goes into conflict status for review before editing again. After revocation the server rejects further access and writes. A disconnected device can still display data that it previously downloaded until it checks access again.

The Firestore rules tests run against the demo emulator with Java 21 and Node. From `budget/household`, install the development dependencies and run `npm test`. Verify the verified-email flow, invites, conflicting edits and access revocation on two configured devices before releasing. The rules and build integration are checked in. Production Firebase deployment and device verification are pending.

Official setup references: [Google Android signing certificates](https://developers.google.com/android/guides/client-auth), [Flutter Android Google sign-in configuration](https://pub.dev/documentation/google_sign_in_android/latest/), and [Drive application data scope](https://developers.google.com/workspace/drive/api/guides/appdata).
