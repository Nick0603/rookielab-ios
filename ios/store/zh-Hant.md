# App Store 商店頁（繁體中文）

App 名稱、副標題、關鍵字的字數上限照 App Store Connect：名稱 30、副標題 30、宣傳文字 170、關鍵字 100（逗號分隔、不加空格）、描述 4000。
關鍵字不放其他公司的品牌名稱（Chess.com、Lichess 只在描述裡說明可以匯入）。

## 名稱
Rookie Lab: Chess Review

## 副標題
每一步都講清楚的西洋棋復盤

## 宣傳文字
下完一盤，打開就有答案：哪一步是好棋、哪一步錯過了機會。停在重點陪你看懂，錯過的機會變成每天 5 題練習，越下越有把握。

## 關鍵字
西洋棋,國際象棋,復盤,覆盤,棋局分析,對局分析,戰術,殘局,開局,棋譜,練習,新手,教學,引擎,評估,AI

## 描述
下完一盤棋，最想知道的就是：剛剛到底哪裡可以更好？
Rookie Lab 把每一盤都整理成看得懂的復盤，陪你把每一盤棋看懂。

【輸入帳號，馬上復盤】
輸入你的 Chess.com 或 Lichess 帳號，最近的對局自動列出來。也可以在 Chess.com、Lichess App 裡按「分享」直接送進 Rookie Lab。不用註冊、不用登入。

【快速復盤：停在重點】
分析完會從頭快速播一遍，每一步都標上評級。遇到好棋停下來告訴你好在哪；遇到錯過的機會停下來，換你找找看更好的一步。走得不理想時，會先讓你看到對手怎麼回應，再試一次。

【每一步都有說明】
不只告訴你「最佳著法」，而是用捉雙、得子、防守、躲開攻擊這些具體的說法，講清楚這一步做了什麼、差在哪裡。想再深入，可以比較兩三個候選步各走兩步後的局面，或在棋盤上自己走走看。

【每天 5 題，從你自己的棋來】
復盤裡錯過的機會會自動變成練習題，附上是哪一盤、對手剛走了什麼。照記憶曲線安排複習：還不熟的過幾題再出現，熟了就隔幾天再看一次，真的記住才畢業。

【跨局報告】
一次看最近 10 盤：準確率、各階段表現、常見的問題、用時分布，還有該優先練什麼。

【殘局教材】
常見殘局先看要領，再一步一步看示範，最後跟引擎練到會。

【在手機上分析】
分析引擎直接在你的手機上執行，對局與練習紀錄都存在手機裡。

Rookie Lab 適合剛開始認真下棋、想知道自己怎麼進步的你。下完一盤就來看看吧！

隱私說明：https://rookielab.io/privacy/
原始碼（GPLv3）：https://github.com/Nick0603/rookielab-ios

## 新功能（1.0）
第一版上架！輸入帳號就能復盤，錯過的機會每天變成 5 題練習。

## 網址
- 支援網址：https://rookielab.io/feedback/
- 行銷網址：https://rookielab.io/
- 隱私權政策網址：https://rookielab.io/privacy/

## 分類
- 主要：教育
- 次要：遊戲（桌上遊戲）

## 版權
© 2026 JIAN YU Chen

## 審核備註（給 App 審核團隊，英文）
No sign-in is required. On first launch, choose Chess.com and enter the public username "rookielab-io" (or any public Chess.com / Lichess username), then tap a game to see the analysis and quick review. The "Practice" tab builds daily puzzles from missed opportunities in analyzed games. All analysis runs on-device with the bundled Stockfish engine (GPLv3; full source: https://github.com/Nick0603/rookielab-ios). Game data is fetched from the public Chess.com and Lichess APIs.

## App 隱私（App Store Connect → App 隱私）
- 有收集資料
- 當機資料、其他診斷資料：App 功能；不連結身分；不追蹤
- 產品互動：分析；不連結身分；不追蹤
- 裝置 ID（隨機安裝 ID）：分析；不連結身分；不追蹤
- 電子郵件（回饋時選填）：App 功能；連結身分；不追蹤
- 其他使用者內容（回饋內容）：App 功能；不連結身分；不追蹤

## 年齡分級
所有項目「無」→ 4+

## 截圖（iPhone 6.9 吋，1320×2868）
在 iPhone 16 Pro Max 模擬器用開發參數直接開到各畫面（狀態列先 `xcrun simctl status_bar <id> override --time 9:41 --batteryLevel 100`）：
1. 快速復盤停在重點：`-demo chesscom:rookielab-io -demoReview 0 -demoLessonReview -lessonSkip`
2. 走錯後看對手回應：再加 `-lessonWrong`
3. 候選步比較：`-demo chesscom:rookielab-io -demoReview 0 -demoCompare`
4. 每日練習：`-demo chesscom:rookielab-io -demoPuzzle fork`
5. 報告：`-demo chesscom:rookielab-io -tab report`
6. 殘局：`-demo chesscom:rookielab-io -demoLesson lucena`

拍好後 `python3 ios/store/frame.py <截圖資料夾> ios/store/screenshots/zh-Hant` 加上標題。
