# Cashew Free Edition — Change Log

Branch: `feature/free-edition` (not merged into main).

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
