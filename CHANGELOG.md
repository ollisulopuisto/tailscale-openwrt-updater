# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Calendar Versioning](https://calver.org/) (`vYY.MM.DD.N`).

## [v26.08.12.7] - 2026-08-12

### Added
- Created `CHANGELOG.md` in English following Keep a Changelog v1.0.0 and CalVer conventions.
- Added `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` environment variable to GitHub Actions CI workflow to prepare for Node.js 24 runtime transition.

### Changed
- Translated all documentation (`README.md`, `TODO.md`), configuration templates (`ts-update.default`), init scripts (`ts-update-bootcheck.init`), and installer/updater scripts (`ts-update`, `netinstall.sh`, `install.sh`) to English for international GitHub publication.
- Translated test suite (`tests/run-tests.sh`) and CI workflow (`.github/workflows/ci.yml`) into English.
- Improved `sha256sum -c` cross-platform compatibility by supporting standard input (`sha256sum -c -`) and added `/sbin` to test runner PATH.
