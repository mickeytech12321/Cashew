# Cashew Modernization — Phase 1 Audit (2026-11-23)

Status: **Audit started; migration and successful APK are not yet verified.**

## Baseline
- Branch: `feature/free-edition`; app: `budget/`.
- Flutter CI: **3.35.7**; Android Gradle Plugin **8.9.2**; Kotlin **2.2.20**; Gradle wrapper previously set to **8.14**.
- Android package/application ID: `com.mickey.cashew`; `minSdk 23`, `targetSdk 34`, `compileSdk 35`. Android 13 compatibility is required.
- Last verified CI failure: [Android build #51](https://github.com/mickeytech12321/Cashew/actions/runs/45202843882), at `:file_picker:compileDebugJavaWithJavac`: legacy `PluginRegistry.Registrar` is unavailable.

## Findings and priority
1. **BLOCKER — outdated Git fork of file_picker.** `budget/pubspec.yaml` references `https://github.com/melWiss/flutter_file_picker.git`; its Android Java plugin still uses removed v1 Flutter embedding `Registrar`. Replace with maintained package and migrate app API, rather than patching cache.
2. **BLOCKER — dependency compatibility debt.** `value_layout_builder` needs CI-time Dart source patching; `flutter_plugin_android_lifecycle` is forced through `dependency_overrides`; CI injects missing Android namespaces into cached plugins. Remove each workaround only after proper source/dependency migration.
3. **HIGH — upstream Firebase project credentials.** `budget/android/app/google-services.json` and backup JSON files are present; `budget/lib/firebase_options.dart` exists. Audit initialization and disable cloud paths by default until a project owned by the fork is configured. Never route user financial data to upstream Firebase by accident.
4. **HIGH — Android toolchain version pressure.** `local_auth_android` and `flutter_plugin_android_lifecycle` warn that compile SDK 36+ is needed. AndroidX Glance is forcibly pinned to 1.1.1 to avoid an alpha dependency requiring SDK 37 and AGP 9.1. Upgrade as a compatible set, preserving minSdk support for Android 13.
5. **MEDIUM — Android identity cleanup.** Main/debug/profile manifests now use `com.mickey.cashew`; Kotlin declarations changed, but files remain under `com/example/budget`. Audit app links, Firebase identity, provider authorities, resources and all original package references.
6. **MEDIUM — maintained release workflow.** Current workflow only produces debug APK, uses CI cache mutation, and there is a separate Firebase Hosting PR workflow failing. Add static analysis, tests, release build/signing plan, and distinguish unrelated Hosting failures from Android build.
7. **MEDIUM — two vendored modified Flutter packages.** `sliding_sheet` and `implicitly_animated_reorderable_list` are local path dependencies; assess Flutter API compatibility and retain custom behavior.
8. **MEDIUM — free edition feature regression.** Inventory purchase/paywall checks, backup/import/export, widgets, notifications, authentication, and Drift database migration before changing behavior. Preserve applicable open-source licenses and attribution.

## Migration order / exit gates
- **Phase 1:** complete dependency and source usage inventory, identify Firebase and payment call sites, establish baseline CI errors.
- **Phase 2–3:** select stable Flutter/Dart and maintained dependencies together; remove unsupported plugin forks; `flutter pub get`, `flutter analyze`, tests.
- **Phase 4:** align AGP/Kotlin/Gradle/SDK; Android debug APK builds; package ID is verified.
- **Phase 5–6:** ensure cloud safety and verify free-edition functionality, local database compatibility, widgets and file import/export.
- **Phase 7–8:** reproducible green CI, release artifact, installation on Android 13, changelog and release notes.

## Verification policy
A committed plan is not a passing build. Each phase must cite its commit and CI run, record failures honestly, and only be marked complete after its exit gates pass.

## Source-level verification (follow-up)
- Inspected `budget/lib/main.dart`: app startup unconditionally calls `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)` **before** local database initialization. Simply removing the Google Services Gradle plugin does not prevent Firebase initialization. This is a confirmed privacy and configuration blocker; cloud functionality must be isolated carefully without breaking local startup.
- Inspected `budget/lib/struct/firebaseAuthGlobal.dart`: code signs in anonymously or with Google and obtains Firestore instances. These paths need explicit configuration gating and tests before release.
- Inspected `budget/android/app/src/main/AndroidManifest.xml`: upstream `cashewapp.web.app` deep links remain. They must be removed or replaced with owned domains after evaluating app-link behavior.
- The file-picker replacement build was in progress when these notes were added; do not infer success from the dependency edit.


## Dependency audit — 2026-11-23

This audit is based on the current pubspec and the checked-in lockfile; the lockfile is stale relative to recent pubspec edits. CI runs `flutter pub get` and may resolve newer transitive plugin versions. A green APK build is not yet confirmed.

### Confirmed legacy Android embedding failures in CI
- `image_picker_android 0.8.8+2`: removed Flutter `PluginRegistry.Registrar` API; parent image_picker upgraded to ^1.2.0.
- `in_app_purchase_android 0.3.6`: removed Flutter API; purchase code removed from premiumPage and purchase dependencies removed from pubspec.
- `path_provider_android 2.2.1`: removed Flutter API; Android implementation overridden to ^2.2.18.
- `home_widget 0.8.1`: Kotlin/JVM target mismatch; upgraded to ^0.9.0.

### Other Android plugin versions in checked-in lockfile requiring verification
`google_sign_in_android 6.1.16`, `local_auth_android 1.0.32`, `quick_actions_android 1.0.7`, `shared_preferences_android 2.1.4`, `url_launcher_android 6.3.2`, and `flutter_charset_detector_android 1.0.0`. These are NOT confirmed broken; do not blindly force incompatible federated implementation versions.

### Architectural cleanup still required
- Premium UI, subscription banners, and compatibility stubs remain; no checkout implementation should be restored.
- Firebase packages and Google sign-in remain declared although free-edition cloud initialization is disabled; remove only after tracing all import/call sites and replacing the corresponding features.
- CI currently patches legacy plugin namespaces and value_layout_builder in the pub cache; replace those with maintained packages or vendored source fixes after the first successful build.
- The app's Android Java target was aligned to Java 17 and core-library desugaring upgraded to 2.1.4.
- Verify runtime startup, offline database, core screens, and unlocked features on a real Android device after producing an APK.

### Build acceptance criteria
1. `flutter pub get` completes with a reproducible dependency graph.
2. `flutter build apk --debug` succeeds and CI publishes `cashew-free-edition-debug`.
3. App launches and operates offline without Google sign-in or billing.
4. Premium-only features are accessible without payment; no purchase prompts remain.
