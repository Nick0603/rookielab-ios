import Foundation

/// 殘局教材：先看要領，再看一步一步的示範（每一步有講解），最後跟引擎練。
/// 后殺單王、車殺單王的示範是引擎的走法（剛好就是縮小方框的技巧）；王兵、Lucena、Philidor 用教科書的標準棋路。
/// 每一步都在 LessonLineTests 驗證過是合法的
struct EndgameLesson {
  struct Step { let uci: String; let caption: String }
  let key: String
  let points: [String]
  let steps: [Step]

  static func of(_ key: String) -> EndgameLesson? { all.first { $0.key == key } }

  static let all: [EndgameLesson] = [
    EndgameLesson(key: "kq", points: [
      "王一定要上來幫忙，只靠后將不死",
      "后跟對方的王隔一個馬步，把它關在越來越小的方框裡",
      "王走到對方王的前面，后再將死；小心別逼和（對方要有步可走）",
    ], steps: [
      .init(uci: "e1d2", caption: "王先走近：后殺單王一定要王幫忙"),
      .init(uci: "e5d6", caption: "對方的王往中間跑"),
      .init(uci: "h1e4", caption: "后站到 e4，對方的王被關在左上角的方框裡"),
      .init(uci: "d6c5", caption: "對方的王在方框裡找出路"),
      .init(uci: "d2c3", caption: "王繼續靠近，方框外的格子都被我們看住"),
      .init(uci: "c5d6", caption: "對方的王退回來"),
      .init(uci: "c3b4", caption: "王再往前，跟對方的王越來越近"),
      .init(uci: "d6c7", caption: "對方的王只能往角落去"),
      .init(uci: "e4d5", caption: "后往前一格，方框又縮小了"),
      .init(uci: "c7b8", caption: "對方的王被趕到最後一排"),
      .init(uci: "b4b5", caption: "王走到旁邊準備幫忙將死"),
      .init(uci: "b8a7", caption: "對方的王躲進角落"),
      .init(uci: "d5f7", caption: "后將軍，把王趕回最後一排"),
      .init(uci: "a7b8", caption: "王只能回到 b8"),
      .init(uci: "b5b6", caption: "王站到對方王的前面，看住 a7、c7"),
      .init(uci: "b8c8", caption: "對方只剩 c8 可以走"),
      .init(uci: "f7e8", caption: "后走到最後一排將死！王幫忙看住了逃跑的格子"),
    ]),
    EndgameLesson(key: "kr", points: [
      "車把對方的王「切」在一邊：一條線一條線縮小它的空間",
      "王走到對方王的正對面（對王），車再在旁邊將軍",
      "對方沒有對王的時候，車走一步等著，讓對方先走",
    ], steps: [
      .init(uci: "a1d1", caption: "車先切斷 d 線：對方的王不能往左邊跑"),
      .init(uci: "e5e4", caption: "對方的王想靠近我們的王"),
      .init(uci: "e1f2", caption: "王走上來幫忙"),
      .init(uci: "e4f5", caption: "對方的王往右邊退"),
      .init(uci: "d1e1", caption: "車再往右切一條線：e 線也過不去了"),
      .init(uci: "f5g4", caption: "對方的王只剩右邊的空間"),
      .init(uci: "e1e4", caption: "車將軍，把王往上趕"),
      .init(uci: "g4g5", caption: "王被趕到第 5 排"),
      .init(uci: "f2g3", caption: "王跟上，保持靠近"),
      .init(uci: "g5f5", caption: "對方的王想從中間出來"),
      .init(uci: "e4e1", caption: "車退回 e 線，繼續把它切在右邊"),
      .init(uci: "f5g6", caption: "對方的王往上跑"),
      .init(uci: "g3f4", caption: "王一路跟上"),
      .init(uci: "g6f6", caption: "對方的王守住中間"),
      .init(uci: "f4g4", caption: "王走到旁邊，等對方先讓開"),
      .init(uci: "f6g7", caption: "對方的王往上退"),
      .init(uci: "g4f5", caption: "王再往前一格"),
      .init(uci: "g7f7", caption: "對方的王想守住 f 線"),
      .init(uci: "f5g5", caption: "王繞到旁邊，準備下一次對王"),
      .init(uci: "f7g7", caption: "兩個王正對面（對王）"),
      .init(uci: "e1f1", caption: "車再切一條線：對方只剩 g、h 兩條線"),
      .init(uci: "g7h8", caption: "對方的王被逼進角落"),
      .init(uci: "g5g6", caption: "王站到對方王的前面"),
      .init(uci: "h8g8", caption: "對方的王只能左右走"),
      .init(uci: "f1f2", caption: "車走一步等著：讓對方先走"),
      .init(uci: "g8h8", caption: "對方的王只能回到角落"),
      .init(uci: "f2f8", caption: "車走到最後一排將死！"),
    ]),
    EndgameLesson(key: "kp", points: [
      "王走在兵的前面，不是跟在後面推兵",
      "對王：兩個王正對面、中間隔一格時，輪到對方走的一方佔優",
      "兵推到第 7 排，王保護升變的格子，兵就能升后",
    ], steps: [
      .init(uci: "e6d6", caption: "王站到兵的前面旁邊，看住 d7、e7"),
      .init(uci: "e8d8", caption: "對方的王守在兵的前面"),
      .init(uci: "e5e6", caption: "兵推上來，王保護著它"),
      .init(uci: "d8e8", caption: "對方的王回到兵的正前方"),
      .init(uci: "e6e7", caption: "兵推到第 7 排，王在 d6 保護它"),
      .init(uci: "e8f7", caption: "對方的王只能讓開"),
      .init(uci: "d6d7", caption: "王看住 e8，升變的格子是我們的了"),
      .init(uci: "f7f6", caption: "對方的王來不及回來"),
      .init(uci: "e7e8q", caption: "兵升后！王走在兵前面，才推得上去"),
    ]),
    EndgameLesson(key: "lucena", points: [
      "王在兵前面出不來：先用車把對方的王趕遠一列",
      "車走到第 4 排，準備「搭橋」擋住將軍",
      "王走出來躲將軍，最後車擋在中間，兵升后",
    ], steps: [
      .init(uci: "c1d1", caption: "車將軍，把對方的王趕到 e 線（遠離兵）"),
      .init(uci: "d7e7", caption: "對方的王只能讓開"),
      .init(uci: "d1d4", caption: "關鍵一步：車走到第 4 排，準備搭橋"),
      .init(uci: "a2a1", caption: "對方的車準備從後面將軍"),
      .init(uci: "b8c7", caption: "王走出來"),
      .init(uci: "a1c1", caption: "對方的車開始將軍"),
      .init(uci: "c7b6", caption: "王往車那邊靠"),
      .init(uci: "c1b1", caption: "繼續將軍"),
      .init(uci: "b6c6", caption: "王躲開"),
      .init(uci: "b1c1", caption: "再將軍"),
      .init(uci: "c6b5", caption: "王走到第 5 排，靠近我們的車"),
      .init(uci: "c1b1", caption: "最後一次將軍"),
      .init(uci: "d4b4", caption: "搭橋：車擋在中間，將軍停了"),
      .init(uci: "b1c1", caption: "對方擋不住兵"),
      .init(uci: "b7b8q", caption: "兵升后！"),
    ]),
    EndgameLesson(key: "philidor", points: [
      "少一個兵要守和：車守在第 6 排，不讓對方的王上來",
      "對方的兵一推到第 6 排，王就上不來了：車馬上退到最後面",
      "車從後面一直將軍，對方的王沒地方躲，就是和棋",
    ], steps: [
      .init(uci: "a6b6", caption: "車守在第 6 排：對方的王不能上到第 6 排"),
      .init(uci: "h1h7", caption: "對方的車想從旁邊施壓"),
      .init(uci: "b6c6", caption: "車留在第 6 排，左右移動等著"),
      .init(uci: "e5e6", caption: "對方推兵到第 6 排"),
      .init(uci: "c6c1", caption: "關鍵一步：兵上來了，車退到最後面準備將軍"),
      .init(uci: "f5f6", caption: "對方的王想走上來保護兵"),
      .init(uci: "c1f1", caption: "從後面將軍"),
      .init(uci: "f6e5", caption: "對方的王只能退"),
      .init(uci: "f1e1", caption: "繼續將軍"),
      .init(uci: "e5d6", caption: "對方的王換邊躲"),
      .init(uci: "e1d1", caption: "還是將軍：王離開兵，兵就保不住"),
      .init(uci: "d6e5", caption: "對方的王回來"),
      .init(uci: "d1e1", caption: "一直將軍下去就是和棋"),
    ]),
  ]
}
