# CashU Google sign-in and Drive backup

This branch uses a Google Cloud OAuth project owned by the app publisher. Basic Drive backup and device sync use the Google Drive API app data folder. Firebase and Gmail are separate services.

## Current project setup

The [Cashew Free Edition project](https://console.cloud.google.com/auth/overview?project=cashew-free-edition) has the Drive API enabled. The OAuth consent screen uses External / Testing, the project owner's account is on the test-user list, and Data Access declares `drive.appdata`. The app includes the project's public Web OAuth client ID. A publisher building against a different project can override it with `CASHEW_GOOGLE_WEB_CLIENT_ID`.

The **CashU Android Preview** client is registered with package `com.cashu.mickey.preview` and certificate SHA-1 `79:1E:3A:C5:68:49:EA:AB:27:6B:B7:67:EC:35:35:89:F3:A7:B3:68`. The preview can install alongside `com.cashu.mickey` and has its own local database. An APK with a different signing key or Android package needs its own matching OAuth registration. For an in-place update of the earlier test app, use its original signing key and register `com.cashu.mickey` with that certificate (`09:B9:9A:4C:9E:4E:3A:95:3F:D8:8C:51:FE:FF:6D:EB:FC:DF:84:20` for the former ARM64 test build).

From 5.4.7, each variant shows **CashU** on the launcher. To upgrade the installed 5.4.6+419 preview in place, keep `com.cashu.mickey.preview` and sign with the original preview key. Verify the signed APK's fingerprint before distribution. The launcher label does not determine whether Android installs the APK as an update.

**CashU Android** is registered separately with package `com.cashu.mickey.next` and certificate SHA-1 `DD:6D:B2:EA:C9:E6:57:1B:4F:1A:BE:0C:BB:5B:A4:EF:9C:F2:20:0C`. To build this package, set `CASHU_SIDE_BY_SIDE_BUILD=true`, `CASHEW_TEST_RELEASE=true`, and `CASHU_TEST_KEYSTORE` to its signer. Keep the previous CashU installation and its database in place. To move local records, use **Export Cashew Data File** in the old app and **Import Cashew Data File** in the new one, then reopen the new app and check the restored accounts. Configure permissions and the Gemini key separately on the new installation.

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

To use another project's public Web client ID, set the GitHub Actions repository **variable** `CASHEW_GOOGLE_WEB_CLIENT_ID`. The workflow forwards it to Dart. A local build can pass the same override as:

```text
--dart-define=CASHEW_GOOGLE_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
```

GitHub-hosted debug keys can differ from a local debug key. OAuth will work only for the SHA‑1 of the APK actually installed. For repeatable testing, consistently use a registered signer. Keep signing keys, passwords, OAuth client secrets, service account keys, and access tokens out of repository variables, commits and chat.

The Android app reads the public Web client ID from its compiled configuration. APKs installed on test devices must use the registered signing certificate. Manual workflow runs validate an override when one is supplied.

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

## CashU on the web

The hosted app is [CashU on Vercel](https://cashu-gamma.vercel.app/). This origin is registered on the project’s existing Web OAuth client. The publisher’s test-user list still applies.

Run `bash scripts/build_cashu_web.sh` from the repository root. The web build uses Flutter 3.50.1 and the SQLite compatibility setup. Serve `budget/build/web` over HTTP for local testing or deploy it through the supplied Vercel configuration. The budget and transaction database is stored in the browser for that site origin.

The browser uses the public Web client ID for the CashU OAuth project. A `CASHEW_GOOGLE_WEB_CLIENT_ID` build environment variable can select another publisher-owned Web OAuth client. In Google Auth Platform → Clients, register the exact hosted HTTPS origin under **Authorized JavaScript origins** for the selected client. Use a stable Vercel domain for repeated testing. For a local OAuth test, register the exact localhost URL and port. Browser builds do not need an Android signing fingerprint.

From **Settings → Backup and data → Google Drive**, sign in with Google's button, then choose **Allow Google Drive backups** to grant `drive.appdata`. After the grant, use Backup or Restore. New browser profiles start with automatic Drive backups and sync disabled. Google access is optional, and browser storage remains available when signed out. Test with an account on the OAuth project's Audience test-user list while the project is in Testing.

## Verify a configured build

- Sign in from **Settings → Backup and data → Google Drive** with an authorized Google account. On Android and the web, choose **Allow Google Drive backups** to grant Drive app-data permission separately. New installations start with automatic backups and sync off. Existing settings retain their saved choices.
- Create a backup, confirm it appears in **Manage backups**, then verify that it restores into a test installation on restart.
- Try a canceled sign-in and a denied Drive grant. Local finance features should remain usable.
- For device sync, confirm both installations use the same OAuth project and Google account. Drive's app data is app-scoped. The new Android package starts with independent app data. Use **Export Cashew Data File** in the old app, then **Import Cashew Data File** in CashU and reopen it to restore on the new package if the existing Drive files are unavailable.

## Credentials for later services

| Service | Configuration to collect |
| --- | --- |
| Drive attachments | Same Android OAuth project and clients, plus the optional `drive.file` scope. |
| Gmail scanning | Gmail API enabled in the same project, plus the Gmail scope and any applicable verification. Keep it separate from backup consent. |
| Firebase Auth and household sharing | A separate publisher-owned project, registered app, verified email/password sign-in and the isolated [household rules](budget/household/firestore.rules). See the setup below. |
| Browser builds | Register the hosted JavaScript origin on the Web OAuth client and verify sign-in and Drive access with a test account. |
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

In **More → Financial tools → Household profiles → Household sharing**, the owner verifies an email, creates a household and copies an invitation code for the recipient’s verified email. The recipient accepts the code before the owner assigns access to individual accounts. Starting with a personal balance shows the name, currency and opening balance for confirmation. Shared transactions use their own ledger. Offline changes remain saved under the current login and sync when the app can reach the server. An edit superseded on another device goes into conflict status for review before editing again. After revocation the server rejects further access and writes. A disconnected device can still display data that it previously downloaded until it checks access again.

The Firestore rules tests run against the demo emulator with Java 21 and Node. From `budget/household`, install the development dependencies and run `npm test`. Verify the verified-email flow, invites, conflicting edits and access revocation on two configured devices before releasing. The rules and build integration are checked in. Production Firebase deployment and device verification are pending.

Official setup references: [Google Android signing certificates](https://developers.google.com/android/guides/client-auth), [Flutter Android Google sign-in configuration](https://pub.dev/documentation/google_sign_in_android/latest/), and [Drive application data scope](https://developers.google.com/workspace/drive/api/guides/appdata).
