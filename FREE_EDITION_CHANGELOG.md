# Cashew Free Edition — Change Log

Branch: `feature/free-edition` (not merged into main).

## 2026-11-24 — Cashew × Say feature branch

- Offline account and credit metadata, linked card repayments, transfer review and undo/restore, and manual bank-statement reconciliation.
- Review-first bank message import with editable time, account matching, Arabic and English parsing, and opt-in Android notification intake.
- Cash-flow forecasts with goals, recurring entries and known-rate conversion. Wealth and investment tracking with price history and opt-in investment valuation.
- Offline assistant drafts and Android on-device dictation where supported. Monthly spending insights and an opt-in Android launcher widget.
- Local household profiles and account previews. Device-to-device transaction sync preserves newer edits, exposes eligible conflicts for review and retains deletion history.
- New Drive snapshots keep parsed import metadata without raw message bodies, and replace a previous backup only after upload completes. Restore validates the candidate before replacing local data.
- Schema remains at 47. Additional local tables are initialized on open. Flutter and SQLite verification cover fresh, v46-upgrade and partial-v47 scenarios.

Android build and device verification, authenticated household sharing, and live Drive round-trip verification remain pending. The [progress tracker](CASHEW_SAY_PROGRESS.md) records implementation status and outstanding release checks.

## 2026-11-23 — JVM target alignment for charset detector

- [Android build #68](https://github.com/mickeytech12321/Cashew/actions/runs/45206369283) **failed** at `:flutter_charset_detector_android:compileDebugKotlin`: Java target 1.8 versus Kotlin target 17.
- Added a scoped Android library Java 17 compatibility setting for `flutter_charset_detector_android` in `budget/android/build.gradle` (commit `25b8452`). This is a project-side configuration fix, not a downloaded dependency patch.
- **Verification pending:** the next CI build must confirm the error is gone and identify any subsequent blockers.

## 2026-11-23 — Offline-first preview isolation

- Introduced `enableCashewCloudServices = false` in `budget/lib/struct/cloudConfiguration.dart` and gated startup Firebase initialization and two Firebase authentication/Firestore helper entry points. This is a **preview configuration**, not a fully audited guarantee that every cloud call is disabled; other call sites require inspection.
- Skipped the unrelated upstream Firebase Hosting PR deployment job for `feature/free-edition`, which depends on upstream project `budget-app-flutter` and its secret. Other branches retain their previous behavior (commit `5a32ef4`).
- Android build result still unverified as of this changelog entry; do not distribute until build and offline smoke tests pass.

## 2026-11-23 — Modernization phase 1 audit and first dependency migration

- Added [MODERNIZATION_AUDIT.md](MODERNIZATION_AUDIT.md) with a prioritized inventory of build blockers, security concerns, and exit gates (commit `9c5f00a`).
- Replaced obsolete `melWiss/flutter_file_picker` Git dependency with maintained pub.dev `file_picker: ^8.3.7` to eliminate removed Flutter v1 `Registrar` Java API (commit `1bf2b11`).
- This dependency change is **not yet verified by a successful build**; the old fork had custom behavior and import/export must be regression-tested.
- The preceding Android CI run [#51](https://github.com/mickeytech12321/Cashew/actions/runs/45202843882) failed in the old Git file_picker plugin's Java compilation.

## 2026-11-23 — Android identity and dependency modernization

- Set Android `applicationId` and Gradle `namespace` to `com.mickey.cashew`.
- Updated Kotlin package declarations in MainActivity and all four home-screen widget providers.
- Removed the legacy Google Services Gradle plugin from the Android app build, because the checked-in `google-services.json` belongs to `com.budget.tracker_app` and must **not** be relabeled as if it were a new Firebase app.
- Removed the Play Billing permission from AndroidManifest.xml.
- Raised dependency constraints for `carousel_slider`, `flutter_sticky_header`, `home_widget`, `device_preview`, and overridden transitive `win32` to avoid known Dart/Flutter API incompatibilities.
- Previous CI improvements: Java 17, declarative Gradle plugins, legacy Android library namespace patching, Flutter 3.35.7 pin, and intl 0.20.2.

### Verification
**Not yet confirmed:** Android debug APK build. Check GitHub Actions > Android free-edition build check for the newest run and its detailed error logs. A successful run will contain the `cashew-free-edition-debug` artifact.

### Follow-up work
1. Validate package dependency resolution and fix app-side API changes caused by newer package versions.
2. Upgrade Flutter, Gradle, and Android Gradle Plugin as a compatible set, rather than untested independent version bumps.
3. Configure a **new** Firebase project/app for `com.mickey.cashew`, or explicitly disable cloud features and test offline behavior. The original project's Firebase credentials are not suitable for this new application ID.
4. Review remaining paid-feature UI and in-app purchase dependencies; preserve GPL-3.0 notices.
5. Move Kotlin source directories to match the package name after the build stabilizes.

### Where to watch
- [GitHub Actions](https://github.com/mickeytech12321/Cashew/actions/workflows/free-edition-android.yml)
- [Feature branch commits](https://github.com/mickeytech12321/Cashew/commits/feature/free-edition/)
- [Draft pull request](https://github.com/mickeytech12321/Cashew/pull/1)
