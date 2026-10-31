import { Chess, type Color, type PieceSymbol, type Square } from 'chess.js';
import { label, opp, type Tactic, type TacticTag, type PieceRef } from './tactics';

/**
 * 開局原則。只在開局快播時用：把「局面是怎麼變壞的」一手一手標出來。
 * 每種只報第一次 —— 快播要停的點越少越好。
 */

/** 第幾手（我方）還沒出完輕子、還沒入堡就要講 */
export const DEVELOPMENT_CHECK_MOVE = 10;
/** 第幾手之前動后算「過早」 */
export const EARLY_QUEEN_MOVE = 5;
/** 錯在第幾手以內才算開局題 */
export const OPENING_MAX_MOVE = 12;

export interface OpeningNote {
  /** 1 起算：history[ply - 1] 走完之後 */
  ply: number;
  tactic: Tactic;
}

export const START_MINORS: Record<Color, [Square, PieceSymbol][]> = {
  w: [['b1', 'n'], ['g1', 'n'], ['c1', 'b'], ['f1', 'b']],
  b: [['b8', 'n'], ['g8', 'n'], ['c8', 'b'], ['f8', 'b']],
};

export function undevelopedMinors(board: Chess, color: Color): PieceRef[] {
  return START_MINORS[color]
    .filter(([s, t]) => { const x = board.get(s); return !!x && x.color === color && x.type === t; })
    .map(([s, t]) => label(s, t));
}

export function openingNotes(history: string[], me: Color): OpeningNote[] {
  const board = new Chess();
  const out: OpeningNote[] = [];
  const seen = new Set<TacticTag>();
  /** 我方已經動過的子目前所在的格子 */
  const moved = new Set<Square>();
  let myMove = 0;

  const note = (ply: number, t: Omit<Tactic, 'side'>) => {
    if (seen.has(t.tag)) return;
    seen.add(t.tag);
    out.push({ ply, tactic: { ...t, side: 'risk' } });
  };

  for (let i = 0; i < history.length; i++) {
    const beforeFen = board.fen();
    let m;
    try { m = board.move(history[i]); } catch { break; }
    if (m.color !== me) { moved.delete(m.to); continue; }
    myMove++;
    const ply = i + 1;
    const before = new Chess(beforeFen);
    const undevBefore = undevelopedMinors(before, me);

    if (m.piece === 'q' && myMove <= EARLY_QUEEN_MOVE && undevBefore.length >= 3) {
      note(ply, { tag: 'early_queen', squares: [m.to], pieces: [label(m.to, 'q')], by: m.san });
    }

    const underAttack = before.attackers(m.from, opp(me)).length > 0;
    if ('nbrq'.includes(m.piece) && moved.has(m.from) && !m.captured && !underAttack
      && myMove <= OPENING_MAX_MOVE && undevBefore.length >= 2) {
      note(ply, { tag: 'moved_twice', squares: [m.to], pieces: [label(m.to, m.piece)], by: m.san });
    }
    moved.delete(m.from);
    moved.add(m.to);

    if (myMove === DEVELOPMENT_CHECK_MOVE) {
      const undev = undevelopedMinors(board, me);
      if (undev.length >= 2) {
        note(ply, {
          tag: 'undeveloped',
          squares: undev.map((u) => u.square),
          pieces: undev,
        });
      }
      const home: Square = me === 'w' ? 'e1' : 'e8';
      const k = board.get(home);
      if (k && k.type === 'k' && k.color === me) note(ply, { tag: 'uncastled', squares: [home], pieces: [label(home, 'k')] });
    }
  }
  return out;
}
