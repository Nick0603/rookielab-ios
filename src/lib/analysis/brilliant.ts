import { Chess, type PieceSymbol, type Square } from 'chess.js';
import type { MoveRecord } from '../types';
import { withTurn } from '../lesson/tactics';

const V: Record<PieceSymbol, number> = { p: 1, n: 3, b: 3, r: 5, q: 9, k: 0 };

/**
 * 傑出（brilliant，!!）：正確的棄子。對齊 chess.com 的定義 ——
 * 最佳或接近最佳的一步，而且走完之後有一個輕子以上的子被白送（對手可以吃、吃了你虧），局面仍站得住。
 *
 * 分析時的 isSacrifice 只看「引擎建議對手吃」；但最精彩的棄子常常是對手吃了更糟、引擎建議不吃，
 * 那種判不出來。這裡直接看盤面：哪個子被送了。
 *
 *   - 勝率損失 <= 2%（最佳或優秀）
 *   - 走完之後，我方有輕子以上的子可以被合法吃掉，而且被吃是虧的
 *     （沒人保護，或攻擊它的子比它便宜）；這步本身吃到的不能比它值錢（那是交換不是棄子）
 *   - 走完勝率 >= 50%：棄完要站得住
 *   - 走之前 <= 90%：已經大優時隨便棄都贏，不算
 */
export function isBrilliant(fenBefore: string, san: string, r: MoveRecord): boolean {
  if (r.winBefore - r.winAfter > 0.02 || r.winAfter < 0.5 || r.winBefore > 0.9) return false;
  return !!sacrificedPiece(fenBefore, san);
}

/** 這步送出去的子（輕子以上、對手可以合法吃、吃了我虧）；沒有就是 null */
export function sacrificedPiece(fenBefore: string, san: string): { square: Square; type: PieceSymbol } | null {
  let m;
  try { m = new Chess(fenBefore).move(san); } catch { return null; }
  const after = new Chess(m.after);
  if (after.isCheckmate()) return null;
  const me = m.color;
  const gained = m.captured ? V[m.captured] : 0;
  const legal = after.moves({ verbose: true });
  // 走之前（假設輪到對手）就已經吃得到、而且吃了我虧的子：那是「沒去救」，不是這步棄出去的
  const beforeTurnOpp = withTurn(fenBefore, m.color === 'w' ? 'b' : 'w');
  const alreadyLoose = (sq: Square, type: PieceSymbol): boolean => {
    if (!beforeTurnOpp) return false;
    const takers = beforeTurnOpp.moves({ verbose: true }).filter((l) => l.to === sq && l.captured);
    if (!takers.length) return false;
    const defended = beforeTurnOpp.attackers(sq, me).length > 0;
    return !defended || Math.min(...takers.map((l) => V[l.piece])) < V[type];
  };
  for (const row of after.board()) {
    for (const x of row) {
      if (!x || x.color !== me || V[x.type] < 3) continue;
      const sq = x.square as Square;
      // 真的吃得到（被牽制的攻擊者不算）
      const takers = legal.filter((l) => l.to === sq && l.captured);
      if (!takers.length) continue;
      const defended = after.attackers(sq, me).length > 0;
      const cheapest = Math.min(...takers.map((l) => V[l.piece]));
      const loses = !defended || cheapest < V[x.type];
      if (!loses || V[x.type] <= gained) continue;
      if (sq !== m.to && alreadyLoose(sq, x.type)) continue;
      return { square: sq, type: x.type };
    }
  }
  return null;
}

