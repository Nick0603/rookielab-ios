ZH = dict(
 subtitle="每一步都講清楚的西洋棋復盤",
 promo="下完一盤，打開就有答案：哪一步改變了局勢、當時可以怎麼走。快速復盤停在雙方的關鍵步，棋盤畫出牽制、保護與最佳步，陪你把每一盤棋看懂。",
 keywords="西洋棋,國際象棋,復盤,覆盤,棋局分析,對局分析,戰術,開局,棋譜,新手,教學,引擎,評估,失誤,免費",
 whatsNew="快速復盤重新設計：停在雙方的關鍵步，棋盤畫出牽制、保護與最佳步。開局停點告訴你這局下的開局與你最近的戰績。開啟新棋局提醒，下完棋就收到通知。首頁加入橫幅廣告，訂閱可以移除廣告。",
 description="""下完一盤棋，最想知道的就是：剛剛到底哪裡可以更好？
Rookie Lab 把每一盤都整理成看得懂的復盤，陪你把每一盤棋看懂。

【輸入帳號，馬上復盤】
輸入你的 Chess.com 或 Lichess 帳號，最近的對局自動列出來。也可以在 Chess.com、Lichess App 裡按「分享」，或貼上 PGN 棋譜。不用註冊、不用登入。

【快速復盤：停在雙方的關鍵步】
分析完從頭快速播一遍，停在真正改變局勢的地方：你的失誤與錯過的機會、對手送出的機會、局勢逆轉的那一步。你的關鍵步可以自己找找看更好的走法；對手的步看一眼就懂。

【棋盤上看得到原因】
停下來時，棋盤畫出剛走的那一步、當時最好的一步、威脅與牽制，沒有保護的子也會標出來。每個停點用兩句話說清楚發生什麼、為什麼。

【開局：這局下的是什麼】
播到開局理論結束時，告訴你這是哪個開局、理論走到第幾手，以及你最近用同一色下這個開局的戰績。

【下完棋就提醒你】
開啟新棋局提醒後，在 Chess.com 或 Lichess 下完棋，約十到二十分鐘後收到通知，回來看這一局。每天最多一則，晚上 10 點到早上 9 點不打擾。

Rookie Lab 適合剛開始認真下棋、想知道自己怎麼進步的你。下完一盤就來看看吧！

隱私說明：https://rookielab.io/privacy/
原始碼（GPLv3）：https://github.com/Nick0603/rookielab-ios""")
EN = dict(
 name="Rookie Lab: Chess Review",
 subtitle="Your last game, explained",
 promo="Your last game, explained in plain English, in seconds. Quick review stops where the game changed, for both sides, and draws pins, defenses and the best move.",
 keywords="free,unlimited,game review,analysis,blunder,mistakes,opening,tactics,coach,PGN,improve,engine",
 whatsNew="Quick review redesigned: it stops at key moments for both sides and draws pins, defenses and the best move on the board. A new opening stop shows the opening, book depth and your recent record with it. New-game reminders tell you when a fresh game is ready. The home screen now shows a banner ad; a subscription removes ads.",
 description="""Right after a game, you want to know one thing: what could have gone better?
Rookie Lab turns every game into a review you can follow, so you understand each one a little more.

[Enter a username, start reviewing]
Type your Chess.com or Lichess username and your recent games show up. You can also tap Share in the Chess.com or Lichess app, or paste a PGN. No sign-up, no login.

[Quick review that stops for both sides]
After analysis, the game plays through quickly and stops where it actually changed: your mistakes and missed chances, chances your opponent handed you, and the move where the game turned. On your key moves you can look for the better move yourself; your opponent's moves are explained at a glance.

[See the reason on the board]
At each stop the board shows the move just played, the best move, threats and pins, and pieces left undefended. Two short lines say what happened and why.

[Know your opening]
When the opening theory ends, you see which opening it was, how many moves were book, and your recent record with the same color in that opening.

[A nudge after you play]
Turn on new-game reminders and, about ten to twenty minutes after you finish a game on Chess.com or Lichess, you get a notification to come back and review it. At most one a day, never between 10 pm and 9 am.

Rookie Lab is for anyone getting serious about chess and wondering how to improve. Finish a game, then come take a look!

Privacy policy: https://rookielab.io/privacy/
Source code (GPLv3): https://github.com/Nick0603/rookielab-ios""")
LIMIT = dict(name=30, subtitle=30, promo=170, keywords=100, whatsNew=4000, description=4000)
if __name__ == '__main__':
    for lang, d in (('zh', ZH), ('en', EN)):
        for k, v in d.items():
            n = len(v)
            print(lang, k, n, 'OVER' if n > LIMIT[k] else 'ok')
        for bad in ['其實', '本來就', '永遠免費', '無限次', '不上傳', '答錯', '失敗']:
            if any(bad in v for v in d.values()): print('TONE', lang, bad)
