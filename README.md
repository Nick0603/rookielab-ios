# Rookie Lab for iOS — source code

This repository contains the complete corresponding source code of the **Rookie Lab: Chess Review** iOS app, published under the **GNU General Public License v3.0 or later** (see `LICENSE`).

The app bundles the [Stockfish](https://stockfishchess.org) chess engine (GPLv3, via [ChessKitEngine](https://github.com/chesskit-app/chesskit-engine)), so the app as a whole is distributed under the GPL.

## Contents

- `ios/` — the SwiftUI app, share extension, tests and the vendored engine package
- `ios/js/` + `src/` — TypeScript sources of the two JavaScript bundles shipped inside the app (`explain.js`, `report.js`)
- `package.json` — the scripts used to build those bundles

## Building

1. Install Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. `npm install && npm run build:ios-explain && npm run build:ios-report`
3. `cd ios && ./fetch-nnue.sh && xcodegen`
4. Open `RookieLab.xcodeproj`, set your own signing team and bundle identifier, then build.

Firebase configuration files (`GoogleService-Info*.plist`) are not included; the app runs without them (analytics and crash reporting are simply turned off).

## Trademarks

The GPL covers the code only. The name “Rookie Lab”, the logo, the mascot artwork and the rookielab.io domain are not licensed for reuse. If you distribute a modified version, please give it a different name and icon.

## Source for a specific release

Each App Store release is tagged (`v1.0.0`, …). Questions: https://rookielab.io/feedback/
