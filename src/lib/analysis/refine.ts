import { Chess } from 'chess.js';
import type { AnalyzedGame, MoveRecord } from '../types';
import { classifyMove, type MoveClass } from './classification';
import { gameAccuracy, moveAccuracy } from './accuracy';
import { isBrilliant } from './brilliant';
import { materialGap } from '../lesson/explain';
import { bookDepth, bookVersion } from '../book';

/**
 * 分析之後再用盤面修正分類。單局復盤（buildReplay）與跨局報告（buildReport）共用，兩邊才會一致；
 * 已經存在快取裡的舊分析也會套到，不用重跑引擎。
 *
 *   - 傑出：用盤面判斷（brilliant.ts）。舊規則只看對手第一手吃子，會把換子誤判成棄子，
 *     也抓不到「對手不能吃」的棄子
 *   - 錯失得子：可以得子卻沒得到也算 miss（見 isMaterialMiss）
 *   - 開局理論：從開局起連續都在開局表內的步（見 book.ts），失誤類的分類保留
 */

/**
 * 「可以得子卻沒得到」也算關鍵步（miss）：勝率可能掉得不多，但這是最該學的一種。
 * 三個條件都要有，不然會抓到一堆雜訊（52 局驗證：只看子力差會多出 115 個，收緊後 12 個）：
 *   - 該走的那步能多拿 3 分以上（約一個馬或象），兩條變化都走到交換結束才算
 *   - 勝率真的有掉（>= 3%）：引擎覺得兩步一樣好時，子力差只是變化截斷的位置不同
 *   - 局面還沒定（走之前勝率 15%–95%）：大優或大劣時多吃一個子沒有意義
 */
export const MISS_GAP = 3;
const MISS_MIN_DROP = 0.03;
export const isMaterialMiss = (r: MoveRecord, fenBefore: string, san: string) =>
  r.winBefore - r.winAfter >= MISS_MIN_DROP && r.winBefore >= 0.15 && r.winBefore <= 0.95
  && materialGap(fenBefore, san, r) >= MISS_GAP;

/** 已經是關鍵步、或不該再改的分類 */
const SETTLED: MoveClass[] = ['blunder', 'mistake', 'miss', 'brilliant', 'great', 'book'];

/** 開局表內仍然要標出來的分類 */
const KEEP_IN_BOOK: MoveClass[] = ['blunder', 'mistake', 'miss'];

/** 一步的分類修正；沒變就回傳同一個物件。inBook = 這步還在開局理論內 */
export function refineRecord(record: MoveRecord, fenBefore: string, san: string, inBook = false): MoveRecord {
  let r = record;
  if (inBook && !KEEP_IN_BOOK.includes(r.cls)) return r.cls === 'book' ? r : { ...r, cls: 'book' };
  if (!inBook && r.cls === 'book') r = { ...r, cls: r.best === san ? 'best' : 'good' };
  if (['best', 'excellent', 'great', 'brilliant'].includes(r.cls)) {
    const brilliant = isBrilliant(fenBefore, san, r);
    if (brilliant && r.cls !== 'brilliant') r = { ...r, cls: 'brilliant' };
    else if (!brilliant && r.cls === 'brilliant') r = { ...r, cls: r.best === san ? 'best' : 'excellent' };
  }
  if (!SETTLED.includes(r.cls) && isMaterialMiss(r, fenBefore, san)) r = { ...r, cls: 'miss' };
  return r;
}

// 報告在分析過程中每完成一局就重算一次，同一局只修正一次（開局表載入後再算一次）
const cache = new WeakMap<AnalyzedGame, { v: number; moves: MoveRecord[] }>();

/** 整局修正後的走法紀錄 */
export function refinedMoves(game: AnalyzedGame): MoveRecord[] {
  const hit = cache.get(game);
  if (hit && hit.v === bookVersion()) return hit.moves;
  const moves = game.moves ?? [];
  let out = moves;
  try {
    const c = new Chess();
    c.loadPgn(game.pgn);
    const history = c.history({ verbose: true });
    const depth = bookDepth(history.map((m) => m.after));
    out = moves.map((r) => {
      const m = history[r.ply - 1];
      return m ? refineRecord(r, m.before, m.san, r.ply <= depth) : r;
    });
  } catch { /* 棋譜讀不了就用原本的分類 */ }
  cache.set(game, { v: bookVersion(), moves: out });
  return out;
}

/**
 * 對手每一步的評分。分析只跑我方的步，但對手那步的前後評估其實都有了：
 *   - 對手走之前 = 我上一步走完之後（winAfter，換成對手視角）
 *   - 對手走之後 = 我下一步走之前（winBefore，換成對手視角）
 *   - 對手當時的最佳步 = 我上一步的 punishedBy；後續變化也一樣接得起來
 * 不用多跑引擎。對手第一步（我執黑時）沒有前一步的評估，只有在開局理論內才給分類。
 * 回傳的勝率是對手視角。
 */
export function opponentRecords(game: AnalyzedGame): Map<number, MoveRecord> {
  const out = new Map<number, MoveRecord>();
  let history;
  try { const c = new Chess(); c.loadPgn(game.pgn); history = c.history({ verbose: true }); } catch { return out; }
  const mine = new Map((game.moves ?? []).map((r) => [r.ply, r]));
  const myColor = game.color === 'white' ? 'w' : 'b';
  const depth = bookDepth(history.map((m) => m.after));
  history.forEach((m, i) => {
    const ply = i + 1;
    if (m.color === myColor) return;
    const prev = mine.get(ply - 1);
    const next = mine.get(ply + 1);
    if (!prev) {
      if (ply <= depth && next) {
        const w = 1 - next.winBefore;
        out.set(ply, { ply, moveNumber: Math.floor(i / 2) + 1, san: m.san, cls: 'book', winBefore: w, winAfter: w, line: next.bestLine ?? [], accuracy: 100 });
      }
      return;
    }
    const mated = new Chess(m.after).isCheckmate();
    if (!next && !mated) return;
    const winBefore = 1 - prev.winAfter;
    const winAfter = mated ? 1 : 1 - next!.winBefore;
    const isBest = prev.punishedBy === m.san;
    const cls = classifyMove({ winBefore, winAfter, isBest, hadWinningChance: winBefore >= 0.8 });
    const raw: MoveRecord = {
      ply, moveNumber: Math.floor(i / 2) + 1, san: m.san, cls, winBefore, winAfter,
      best: prev.punishedBy,
      // 對手走完之後的變化 = 我下一步的最佳變化；對手當時的最佳變化 = 我上一步走完之後的變化
      line: next?.bestLine ?? [],
      bestLine: prev.line,
      accuracy: moveAccuracy(Math.max(0, winBefore - winAfter)),
    };
    out.set(ply, refineRecord(raw, m.before, m.san, ply <= depth));
  });
  return out;
}

/** 對手的整局準確率（開局理論的步不算） */
export function opponentAccuracy(recs: Map<number, MoveRecord>): number | null {
  const list = [...recs.values()].filter((r) => r.cls !== 'book').map((r) => r.accuracy);
  return list.length ? gameAccuracy(list) : null;
}
