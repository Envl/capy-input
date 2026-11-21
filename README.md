# capy-companion

Open-source macOS companion app for [Little Capybara (小水豚输入法)](https://capy.lumik.space) — syncs Squirrel / Rime dictionaries with iOS over iCloud (or a self-hosted sync server) and surfaces on-screen terms locally via macOS Vision OCR.

- **Website:** https://capy.lumik.space
- **iOS TestFlight:** https://testflight.apple.com/join/ma8DWTpC
- **macOS Releases:** https://github.com/Envl/capy-input/releases

## Requirements

- macOS 14+ (Apple Silicon)
- Xcode & [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & Run

```bash
bash Scripts/prepare.sh
xcodegen generate
bash Scripts/native.sh mac   # build
bash Scripts/native.sh run   # build and launch
```

## Release

Pushing a version tag (`vX.Y.Z`) runs [`.github/workflows/release.yml`](.github/workflows/release.yml) to archive, Developer ID sign, notarize, generate the Sparkle `appcast.xml`, and publish `capy-companion.dmg` to GitHub Releases.

## License

MIT — see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
