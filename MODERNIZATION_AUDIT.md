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
