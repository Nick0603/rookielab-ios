# App 審查備註（App Store Connect → App 審查資訊 → 備註）

2026-11-01 因 Guideline 2.1 Information Needed 補上：實機操作影片（附件）＋下面六點。之後送審沿用，功能有變就改。

```
No account or login is required.

1. Screen recording: attached (recorded on a physical iPhone 14 Pro, latest iOS). It starts from launching the app and shows the typical flow: enter a public Chess.com username -> game list -> on-device analysis -> quick review that stops at key moments (hint, trying a move, the opponent's reply) -> deep analysis -> cross-game report. The app has no account registration/login/deletion, no user-generated content shared with other users, and no paid content or in-app purchases.

2. Purpose and audience: Rookie Lab helps beginner and improving chess players (roughly 400-1500 rated) learn from their own games. After a game on Chess.com or Lichess, players often don't know which moves mattered or why. The app grades every move, explains in plain language what each move did (forks, hanging pieces, threats), stops at the key moments so the player can find the better move themselves, and turns missed chances into a short daily practice set with spaced repetition.

3. How to use: On first launch choose Chess.com and enter the public username "rookielab-io" (any public Chess.com or Lichess username also works). Recent games are listed; tap one to see the analysis and quick review. Other tabs: Report (patterns across the last 10 games), Practice (daily 5 puzzles from your own missed chances, plus endgame lessons), Analysis (free analysis board), Me (settings and feedback). No sample files are needed.

4. External services: Chess.com Published-Data API and Lichess public API (read-only, to fetch the user's public games); Firebase Crashlytics (crash reports); our own server on Cloudflare (rookielab.io) for anonymous usage events and optional feedback. Chess analysis runs entirely on-device with the bundled Stockfish engine. No AI services, no payment processors, no authentication services.

5. Regional differences: none. The app works the same in all regions; only the interface language follows the device language (Traditional Chinese, English, Spanish, Portuguese).

6. Third-party material: game data comes from the public Chess.com and Lichess APIs, used under their public API terms. Stockfish is licensed under GPLv3; the app's complete source code is published at https://github.com/Nick0603/rookielab-ios. Chess piece images are the cburnett set (CC BY-SA 3.0). The app is not in a regulated industry.
```
