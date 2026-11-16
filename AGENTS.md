# Repository Guidelines

## Project Structure & Module Organization

UUyc companion is a macOS menu bar app built with Swift Package Manager, AppKit, and SwiftUI.

- `Sources/UUDisplay/`: app entry point, connection monitoring, display management, settings, permissions, and watchdog.
- `Sources/CGVirtualDisplayBridge/`: Objective-C bridge for private CoreGraphics APIs.
- `Sources/{vdprobe,uuprobe,uuwatch,dispoff}/`: diagnostic executables.
- `tests/`: standalone connection and monitor regression tests.
- `Assets/`: app icons and tour illustrations; `docs/`: planning notes and screenshots.
- `Vendor/`: local PermissionFlow and TourKit packages; consult each `VENDORED.md` before editing.

## Build, Test, and Development Commands

Use macOS 14+ and Xcode Command Line Tools with Swift 6.2+. All package dependencies are local copies under `Vendor/`; no private repository access is required.

- `swift build --build-system native --product UUDisplay`: build the app executable for development.
- `SIGN_IDENTITY=- scripts/build-app.sh`: build and package a release app at `build/UUyc companion.app` with ad-hoc signing.
- `SIGN_IDENTITY=- scripts/build-dmg.sh`: rebuild and create a drag-to-install DMG under `dist/`.
- `open "build/UUyc companion.app"`: launch the packaged app locally.
- `scripts/test-connection.sh`: run connection, identity, display lifecycle, and cache maintenance regressions.

Use `SIGN_IDENTITY="Your Certificate"` for stable signing; ad-hoc rebuilds require renewed Accessibility authorization. Adding `--install` to the packaging command replaces the installed app in `/Applications` and launches it.

## Coding Style & Naming Conventions

Follow surrounding Swift style: four-space indentation in app sources, `UpperCamelCase` types, and `lowerCamelCase` methods and properties. Match filenames to primary types, such as `UUConnectionState.swift`. Preserve existing Chinese UI copy and comments. No formatter or lint configuration is checked in; keep formatting changes scoped. Preserve vendored compatibility changes described in `VENDORED.md`.

## Testing Guidelines

Swift tests use standalone `@main` executables and `precondition` assertions; maintenance tests use Python `unittest`. There is no coverage threshold. Follow `tests/<feature>-main.swift` naming and add suites to the test script. Display lifecycle tests replace private APIs with `tests/fixtures/` mocks. Follow `docs/DISPLAY_IDENTITIES.md` for real display verification and explicit cache maintenance.

## Commit & Pull Request Guidelines

History uses concise descriptive subjects in Chinese or English, sometimes prefixed with `修复：`, `README：`, or a release version; Conventional Commits are not required. Keep commits focused. PRs should describe the problem and resulting behavior, link related issues, report validation, and include screenshots for visible UI changes.
