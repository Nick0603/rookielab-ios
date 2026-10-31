import type { AnalyzedGame } from '../types';
import { refinedMoves } from './refine';
import { FAST, LOW_TIME, moveTimes } from '../moveTimes';

const BAD = ['blunder', 'mistake', 'miss'];

export interface TimeStats {
  /** 有時鐘紀錄的局數、我方步數 */
  games: number;
  moves: number;
  /** 平均每步秒數 */
  avg: number;
  /** 失誤類（嚴重失誤、失誤、錯失良機）平均想多久；其他步平均想多久 */
  avgBad: number | null;
  avgOther: number | null;
  /** 失誤類裡，不到 FAST 秒就走的比例（0–1） */
  fastBadShare: number | null;
  badCount: number;
  /** 快沒時間（剩不到 10%）時，每 100 步的失誤數；時間還夠時的每 100 步失誤數 */
  lowRate: number | null;
  normalRate: number | null;
  lowMoves: number;
}

/** 跨局的思考時間：關鍵失誤是不是走太快、快沒時間時是不是特別容易出錯 */
export function timeStats(games: AnalyzedGame[]): TimeStats | null {
  let n = 0, moves = 0, total = 0, bad = 0, badT = 0, other = 0, otherT = 0, fastBad = 0;
  let low = 0, lowBad = 0, normal = 0, normalBad = 0;
  for (const g of games) {
    const times = moveTimes(g.pgn, g.timeControl);
    if (!times) continue;
    n++;
    for (const r of refinedMoves(g)) {
      const t = times[r.ply - 1];
      if (!t || r.cls === 'book') continue;
      moves++; total += t.spent;
      const isBad = BAD.includes(r.cls);
      if (isBad) { bad++; badT += t.spent; if (t.spent < FAST) fastBad++; } else { other++; otherT += t.spent; }
      // 走這步之前剩多少：走完剩的 + 這步用掉的
      const before = t.left + (t.clock ? t.spent / (t.clock / t.left) : 0);
      if (before < LOW_TIME) { low++; if (isBad) lowBad++; } else { normal++; if (isBad) normalBad++; }
    }
  }
  if (!moves) return null;
  const r1 = (x: number) => Math.round(x * 10) / 10;
  return {
    games: n, moves, avg: r1(total / moves),
    avgBad: bad ? r1(badT / bad) : null, avgOther: other ? r1(otherT / other) : null,
    fastBadShare: bad ? fastBad / bad : null, badCount: bad,
    lowRate: low >= 10 ? r1((lowBad / low) * 100) : null, normalRate: normal ? r1((normalBad / normal) * 100) : null, lowMoves: low,
  };
}
