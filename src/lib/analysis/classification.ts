/**
 * 走法分類 —— 對齊 chess.com Game Review 的十種分類。
 *
 * chess.com 用的是「Expected Points（期望得分，勝=1 和=0.5 負=0）」損失，
 * 官方 support 文件公布的門檻：
 *   Best        0.00
 *   Excellent   0.00–0.02
 *   Good        0.02–0.05
 *   Inaccuracy  0.05–0.10
 *   Mistake     0.10–0.20
 *   Blunder     0.20–1.00
 * 來源 support.chess.com/en/articles/8572705
 *
 * Brilliant / Great / Miss / Book 不是靠門檻，而是靠條件判斷（見下方各函式）。
 * chess.com 的 Expected Points Model 還會依玩家等級分調整，那部分未公開，我們不模擬。
 */
import type { Chess } from 'chess.js';

export type MoveClass =
  | 'brilliant'   // !!
  | 'great'       // !
  | 'best'
  | 'excellent'
  | 'good'
  | 'book'
  | 'inaccuracy'  // ?!
  | 'mistake'     // ?
  | 'miss'
  | 'blunder';    // ??

export type MoveClassIcon = '!!' | '!' | 'star' | 'thumb' | 'check' | 'book' | '?!' | '?' | 'x' | '??';

export interface MoveClassMeta {
  zh: string;
  en: string;
  symbol: string;
  /** 顏色語意，給 UI 用 */
  tone: 'brilliant' | 'great' | 'good' | 'neutral' | 'warn' | 'bad';
  /** 這一類自己的顏色（配色參考 chess.com）：徽章、走法列表、棋盤上的標記都用這個 */
  color: string;
  /** 圓形標記裡的圖示 */
  icon: MoveClassIcon;
  desc: string;
  descEn: string;
}

/**
 * 繁體中文譯名。
 * 註：chess.com 的官方 zh-TW 用語我無法從公開來源確認，
 * 以下是依台灣棋界慣用語選的，與 content-plan.md 的術語表一致。
 */
export const MOVE_CLASS_META: Record<MoveClass, MoveClassMeta> = {
  brilliant: {
    zh: '傑出', en: 'Brilliant', symbol: '!!', tone: 'brilliant', color: '#1baca6', icon: '!!',
    desc: '正確的棄子。送掉子力換取更大的回報，棄完之後局面站得住。',
    descEn: 'A sound sacrifice: material given up for a bigger return, and the position holds afterwards.',
  },
  great: {
    zh: '好棋', en: 'Great', symbol: '!', tone: 'great', color: '#5c8bb0', icon: '!',
    desc: '扭轉局面的關鍵一步，或是這個局面唯一能下的好棋。從劣勢回到均勢、或從均勢拉到優勢都算。',
    descEn: 'A turning point, or the only good move in the position — from worse to equal, or from equal to better.',
  },
  best: {
    zh: '最佳', en: 'Best', symbol: '', tone: 'good', color: '#81b64c', icon: 'star',
    desc: '引擎的首選。沒有比這更好的下法。',
    descEn: "The engine's top choice. Nothing is better.",
  },
  excellent: {
    zh: '優秀', en: 'Excellent', symbol: '', tone: 'good', color: '#2fa37c', icon: 'thumb',
    desc: '幾乎等同最佳，評分幾乎沒有掉。',
    descEn: 'Nearly as good as the best move; the score barely drops.',
  },
  good: {
    zh: '不錯', en: 'Good', symbol: '', tone: 'neutral', color: '#8fa382', icon: 'check',
    desc: '穩健的一步，比最佳略差一點，但沒有實質損失。',
    descEn: 'A solid move, slightly below the best, with no real loss.',
  },
  book: {
    zh: '開局理論', en: 'Book', symbol: '', tone: 'neutral', color: '#a88865', icon: 'book',
    desc: '開局書裡的常見走法，不計入失誤統計。',
    descEn: 'A standard opening move. Not counted in mistake statistics.',
  },
  inaccuracy: {
    zh: '不精確', en: 'Inaccuracy', symbol: '?!', tone: 'warn', color: '#e8b33d', icon: '?!',
    desc: '有點鬆，讓出一小部分優勢。通常不致命，但累積起來會差很多。',
    descEn: 'A little loose; gives away a small part of the advantage. Rarely fatal alone, but they add up.',
  },
  mistake: {
    zh: '失誤', en: 'Mistake', symbol: '?', tone: 'warn', color: '#f08c35', icon: '?',
    desc: '明顯下錯，局面實質變差。這個等級開始值得回頭看為什麼。',
    descEn: 'A clear error that makes the position worse. Worth reviewing from this level up.',
  },
  miss: {
    zh: '錯失良機', en: 'Miss', symbol: '', tone: 'warn', color: '#ff6f61', icon: 'x',
    desc: '對手給了機會你沒抓住——通常是可以白吃的子，或是一步將殺。',
    descEn: 'The opponent offered a chance you did not take — usually a free piece or a mate.',
  },
  blunder: {
    zh: '嚴重失誤', en: 'Blunder', symbol: '??', tone: 'bad', color: '#e5392a', icon: '??',
    desc: '嚴重失誤，評分大幅崩落。這是最該優先修掉的一類。',
    descEn: 'A serious error; the score collapses. The first kind to fix.',
  },
};

/** chess.com 官方門檻（期望得分損失） */
const THRESHOLDS: [number, MoveClass][] = [
  [0.02, 'excellent'],
  [0.05, 'good'],
  [0.10, 'inaccuracy'],
  [0.20, 'mistake'],
  [Infinity, 'blunder'],
];

export interface ClassifyMoveInput {
  /** 我走之前的勝率（我方視角，0–1） */
  winBefore: number;
  /** 我走之後的勝率（我方視角，0–1） */
  winAfter: number;
  /** 我走的是不是引擎首選 */
  isBest: boolean;
  /** 我走之前，引擎認為只有一步能維持局面（其餘都明顯更差） */
  isOnlyMove?: boolean;
  /** 我走之前對手剛犯錯，我有機會直接取得勝勢 */
  hadWinningChance?: boolean;
  /** 這一步是不是正確的棄子 */
  isSacrifice?: boolean;
  /** 仍在開局書範圍內 */
  inBook?: boolean;
}

export function classifyMove(input: ClassifyMoveInput): MoveClass {
  const { winBefore, winAfter, isBest, isOnlyMove, hadWinningChance, isSacrifice, inBook } = input;

  if (inBook) return 'book';

  const loss = Math.max(0, winBefore - winAfter);

  // 傑出：正確的棄子。條件參照 chess.com——棄完之後局面要站得住，
  // 且事前不能已經是勝勢（那種局面棄什麼都還是贏）
  // 門檻刻意收緊：實測 800 分的對局在寬門檻下會出現 0.8% 的「傑出」，
  // 那顯然不對 —— 傑出應該是罕見的。要求棄完之後確實站上風，
  // 且事前不能已經明顯優勢（那種局面隨便棄都還是贏）
  if (isSacrifice && isBest && winAfter >= 0.55 && winBefore < 0.7) return 'brilliant';

  // 好棋：把局面從劣勢救回來，或是唯一解
  if (isBest && loss <= 0.02) {
    const rescued = winBefore < 0.5 && winAfter >= 0.5;
    if (rescued || isOnlyMove) return 'great';
  }

  // 錯失良機：對手給了機會沒抓住。chess.com 把這個獨立於一般失誤之外，
  // 因為它的成因不同 —— 不是下錯，是沒看到
  if (hadWinningChance && loss > 0.10) return 'miss';

  if (isBest) return 'best';
  for (const [limit, cls] of THRESHOLDS) if (loss < limit) return cls;
  return 'blunder';
}

/** 判斷這一步是不是棄子：走完之後對手能吃到比我這步吃到的更值錢的東西 */
const PIECE_VALUE: Record<string, number> = { p: 1, n: 3, b: 3, r: 5, q: 9, k: 0 };

export function isSacrifice(
  boardAfter: Chess,
  played: { captured?: string; piece: string },
  punishUci?: string,
): boolean {
  if (!punishUci || punishUci.length < 4) return false;
  const gained = played.captured ? (PIECE_VALUE[played.captured] ?? 0) : 0;
  const target = boardAfter.get(punishUci.slice(2, 4) as never);
  const lost = target ? (PIECE_VALUE[target.type] ?? 0) : 0;
  // 送掉的比吃到的多至少一個輕子（3 分），才算棄子而非單純兌換
  return lost - gained >= 3;
}

/** 哪些分類要計入「失誤」統計 */
export const IS_ERROR: Record<MoveClass, boolean> = {
  brilliant: false, great: false, best: false, excellent: false, good: false, book: false,
  inaccuracy: true, mistake: true, miss: true, blunder: true,
};
