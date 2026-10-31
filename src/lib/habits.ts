import { Chess, type Color, type Move, type Square } from 'chess.js';
import type { AnalyzedGame } from './types';
import { OPENING_MAX_MOVE, START_MINORS, openingNotes } from './lesson/opening';
import { EN_PIECE, ZH_PIECE, VALUE, forkOf, label, looseTactics, pieceName, withTurn, type PieceRef } from './lesson/tactics';
import type { Bi, Lang } from './i18n/lang';

/**
 * 口語化的問題分類：出子太慢、王沒入堡、被捉雙時救錯子……
 *
 * 跟 BlunderType 不同的地方：這裡看的是「習慣」，多半不會讓勝率當場崩掉，
 * 所以引擎的失誤分級抓不到，但低分段的老師講解時最常點出的就是這些。
 *
 * 全部從棋譜直接判斷，不跑引擎、不存進分析快取 —— 改這裡不需要動 ANALYSIS_VERSION。
 */

export type HabitKind =
  | 'slow_development' | 'uncastled' | 'lost_castling' | 'moved_twice'
  | 'early_queen' | 'knight_rim' | 'blocked_bishop' | 'wrong_piece_saved';

export interface HabitMeta {
  zh: string;
  en: string;
  /** 發生了什麼（事實） */
  desc: Bi;
  /** 下次怎麼做（一句話） */
  tip: Bi;
}

export const HABIT_META: Record<HabitKind, HabitMeta> = {
  slow_development: {
    zh: '出子太慢', en: 'Slow development',
    desc: { zh: '第 10 手還有兩個以上的馬或象在原位。', en: 'By move 10, two or more knights or bishops were still on their starting squares.' },
    tip: { zh: '開局每一步先問：還有哪個子沒出來？', en: 'Every opening move, ask: which piece is still at home?' },
  },
  uncastled: {
    zh: '王沒入堡', en: 'King stuck in the center',
    desc: { zh: '第 10 手王還在中間。', en: 'By move 10, the king was still in the center.' },
    tip: { zh: '把王那一側的馬和象出完，就能入堡。', en: 'Develop the knight and bishop on the king side, then castle.' },
  },
  lost_castling: {
    zh: '失去入堡權', en: 'Lost castling rights',
    desc: { zh: '入堡之前先動了王或車，之後那一側就不能入堡。', en: 'The king or a rook moved before castling, so that side can no longer castle.' },
    tip: { zh: '入堡之前，王和車都不要動。', en: 'Leave the king and rooks alone until you castle.' },
  },
  moved_twice: {
    zh: '同一個子走兩次', en: 'Moving the same piece twice',
    desc: { zh: '其他子還沒出動，同一個子又走了一次。', en: 'The same piece moved again while other pieces were still at home.' },
    tip: { zh: '沒被趕的話，先出還沒動過的子。', en: 'Unless it is attacked, bring out a piece that has not moved yet.' },
  },
  early_queen: {
    zh: '太早出后', en: 'Early queen',
    desc: { zh: '馬和象大多還沒出，后先出動。', en: 'The queen came out while most knights and bishops were still at home.' },
    tip: { zh: '后晚一點出，才不會被對手一邊出子一邊趕。', en: 'Bring the queen out later so the opponent cannot chase it while developing.' },
  },
  knight_rim: {
    zh: '馬跳到邊線', en: 'Knight on the rim',
    desc: { zh: '開局把馬跳到 a 線或 h 線。', en: 'A knight went to the a- or h-file in the opening.' },
    tip: { zh: '馬在中間能控制的格子比較多，先往 c、f 線跳。', en: 'A centralized knight controls more squares; aim for the c- and f-files first.' },
  },
  blocked_bishop: {
    zh: '擋住自己的象', en: 'Blocked bishop',
    desc: { zh: '推兵擋住還沒出動的象，象出不來。', en: 'A pawn move shut in a bishop that had not come out yet.' },
    tip: { zh: '推兵之前，先看會不會擋住自己的象。', en: 'Before pushing a pawn, check whether it blocks your own bishop.' },
  },
  wrong_piece_saved: {
    zh: '被捉雙時救錯子', en: 'Saved the wrong piece',
    desc: { zh: '對手同時攻擊兩個子，你救了比較便宜的那個。', en: 'The opponent attacked two pieces and you saved the cheaper one.' },
    tip: { zh: '被捉雙時先比價值，救比較值錢的那個。', en: 'When forked, compare values and save the more valuable piece.' },
  },
};

/** 開局習慣類：用「重下這一步」練 */
export const OPENING_HABITS: HabitKind[] = [
  'slow_development', 'uncastled', 'lost_castling', 'moved_twice', 'early_queen', 'knight_rim', 'blocked_bishop',
];

export interface HabitOption {
  square: Square;
  piece: PieceRef;
  value: number;
}

export interface Habit {
  kind: HabitKind;
  gameId: string;
  date: string;
  opponent: string;
  /** 1 起算，也是單局復盤的 step index（這一步走完的局面） */
  ply: number;
  moveNumber: number;
  /** 走之前的局面 —— 練習的起點 */
  fen: string;
  /** 當時走的（SAN） */
  played: string;
  side: Color;
  /** wrong_piece_saved：被捉的兩個子，與該救的那個 */
  options?: HabitOption[];
  answer?: Square;
}

/** 開局階段最晚看到第幾手（我方）的馬、象、兵 */
const EARLY_MOVE = 10;
const CASTLE_FLAGS = ['k', 'q'];
const isCastle = (m: Move) => CASTLE_FLAGS.some((f) => m.flags.includes(f));
const castlingRights = (fen: string, c: Color) =>
  [...(fen.split(' ')[2] ?? '')].filter((x) => (c === 'w' ? 'KQ' : 'kq').includes(x)).length;

/** 推兵前象至少能走這麼多格、推兵後剩不到一格，才算「擋住」 */
const BISHOP_OPEN = 3;
const BISHOP_SHUT = 1;

function bishopMobility(fen: string, me: Color, square: Square): number {
  const b = withTurn(fen, me);
  const x = b?.get(square);
  if (!b || !x || x.type !== 'b' || x.color !== me) return -1;
  return b.moves({ square, verbose: true }).length;
}

// 每一局只算一次：報告每次重繪（分析進度更新）都會呼叫，沒快取會卡住畫面
const habitCache = new WeakMap<AnalyzedGame, Habit[]>();

export function detectHabits(game: AnalyzedGame): Habit[] {
  const hit = habitCache.get(game);
  if (hit) return hit;
  const out = detectHabitsNow(game);
  habitCache.set(game, out);
  return out;
}

function detectHabitsNow(game: AnalyzedGame): Habit[] {
  let history: Move[];
  try {
    const c = new Chess();
    c.loadPgn(game.pgn);
    history = c.history({ verbose: true });
  } catch {
    return [];
  }
  const me: Color = game.color === 'white' ? 'w' : 'b';
  const out: Habit[] = [];
  const seen = new Set<HabitKind>();

  const add = (kind: HabitKind, i: number, extra: Partial<Habit> = {}) => {
    // 開局習慣每局只報第一次；救錯子每次都報
    if (kind !== 'wrong_piece_saved') {
      if (seen.has(kind)) return;
      seen.add(kind);
    }
    out.push({
      kind, gameId: game.id, date: game.date, opponent: game.opponent,
      ply: i + 1, moveNumber: Math.floor(i / 2) + 1,
      fen: history[i].before, played: history[i].san, side: me, ...extra,
    });
  };

  const FROM_NOTE: Record<string, HabitKind> = {
    undeveloped: 'slow_development', uncastled: 'uncastled', moved_twice: 'moved_twice', early_queen: 'early_queen',
  };
  for (const n of openingNotes(history.map((m) => m.san), me)) {
    const kind = FROM_NOTE[n.tactic.tag];
    if (kind) add(kind, n.ply - 1);
  }

  let myMove = 0;
  history.forEach((m, i) => {
    if (m.color !== me) return;
    myMove++;

    if (myMove <= OPENING_MAX_MOVE && !isCastle(m) && castlingRights(m.after, me) < castlingRights(m.before, me)) {
      add('lost_castling', i);
    }
    if (myMove <= EARLY_MOVE && m.piece === 'n' && !m.captured && 'ah'.includes(m.to[0])) {
      add('knight_rim', i);
    }
    if (myMove <= EARLY_MOVE && m.piece === 'p') {
      const blocked = START_MINORS[me].some(([sq, t]) =>
        t === 'b' && bishopMobility(m.before, me, sq) >= BISHOP_OPEN && bishopMobility(m.after, me, sq) <= BISHOP_SHUT);
      if (blocked) add('blocked_bishop', i);
    }

    // 救錯子：對手上一步捉雙，我移走的是比較便宜的，下一步對手就吃掉比較貴的
    const prev = history[i - 1];
    const next = history[i + 1];
    if (!prev || !next) return;
    const fork = forkOf(new Chess(prev.before), prev, me);
    if (!fork) return;
    const board = new Chess(m.before);
    const targets = fork.squares.slice(1).flatMap((sq): HabitOption[] => {
      const x = board.get(sq);
      return x && x.color === me ? [{ square: sq, piece: label(sq, x.type), value: VALUE[x.type] }] : [];
    });
    if (targets.length < 2 || targets.some((t) => t.value >= VALUE.k)) return; // 有將軍就不是「選一個救」
    const best = targets.reduce((a, b) => (b.value > a.value ? b : a));
    const saved = targets.find((t) => t.square === m.from);
    if (saved && saved.value < best.value && next.captured && next.to === best.square) {
      add('wrong_piece_saved', i, { options: targets, answer: best.square });
    }
  });

  return out.sort((a, b) => a.ply - b.ply);
}

/** 跨局統計：每種習慣出現在幾局 */
export function countHabits(games: AnalyzedGame[]): { kind: HabitKind; games: number }[] {
  const n = new Map<HabitKind, number>();
  for (const g of games) {
    for (const k of new Set(detectHabits(g).map((h) => h.kind))) n.set(k, (n.get(k) ?? 0) + 1);
  }
  return [...n.entries()].map(([kind, c]) => ({ kind, games: c })).sort((a, b) => b.games - a.games);
}

export interface OpeningVerdict {
  ok: boolean;
  why: string;
  san?: string;
}

/**
 * 開局習慣題的判定：看原則，不看引擎。
 * 好的一步 = 入堡、從原位出動馬或象（不跳邊線）、第一次推中心兵、吃到沒人保護的子；
 * 而且走完不能留下沒人保護、會被吃的子。
 */
export function judgeOpeningMove(fen: string, from: string, to: string, lang: Lang = 'zh'): OpeningVerdict {
  const t = (zh: string, en: string) => (lang !== 'zh' ? en : zh);
  const before = new Chess(fen);
  const board = new Chess(fen);
  let m: Move;
  try {
    m = board.move({ from, to, promotion: 'q' });
  } catch {
    return { ok: false, why: t('這步不合法。', 'That move is not legal.') };
  }
  const me = m.color;
  const san = m.san;

  const hangingBefore = new Set(looseTactics(before, me, me).filter((x) => x.tag === 'hanging').map((x) => x.squares[0]));
  const newlyHanging = looseTactics(board, me, me).find((x) => x.tag === 'hanging' && !hangingBefore.has(x.squares[0]));
  if (newlyHanging) {
    const n = pieceName(newlyHanging.pieces[0], lang);
    return { ok: false, san, why: t(`${n}沒人保護，對手可以直接吃。`, `Your ${n} is left undefended and can be taken for free.`) };
  }

  if (before.isCheck()) return { ok: true, san, why: t('先解除將軍。', 'Getting out of check comes first.') };
  if (isCastle(m)) return { ok: true, san, why: t('入堡：王離開中間，車也出來了。', 'Castling: the king leaves the center and the rook comes into play.') };
  if (m.captured && VALUE[m.captured] >= 3 && before.attackers(m.to, me === 'w' ? 'b' : 'w').length === 0) {
    return { ok: true, san, why: t(`吃到沒人保護的${ZH_PIECE[m.captured]}。`, `Wins an undefended ${EN_PIECE[m.captured]}.`) };
  }

  const fromHome = START_MINORS[me].some(([sq, p]) => sq === m.from && p === m.piece);
  if (fromHome) {
    return 'ah'.includes(m.to[0])
      ? { ok: false, san, why: t('馬跳到邊線，能控制的格子少。', 'A knight on the rim controls few squares.') }
      : { ok: true, san, why: t(`${pieceName(label(m.to, m.piece))}從原位出動。`, `Develops the ${EN_PIECE[m.piece]} from its starting square.`) };
  }
  if (m.piece === 'q') return { ok: false, san, why: t('后先不動，先出馬和象。', 'Keep the queen home for now; develop knights and bishops first.') };
  if (m.piece === 'k') return { ok: false, san, why: t('動王會失去入堡權。', 'Moving the king gives up castling.') };
  if (m.piece === 'r') return { ok: false, san, why: t('車先不動，入堡之後車自然就出來了。', 'Leave the rook for now; castling brings it into play.') };
  if (m.piece === 'p') {
    const blocks = START_MINORS[me].some(([sq, p]) =>
      p === 'b' && bishopMobility(fen, me, sq) >= BISHOP_OPEN && bishopMobility(board.fen(), me, sq) <= BISHOP_SHUT);
    if (blocks) return { ok: false, san, why: t('這個兵擋住了還沒出動的象。', 'This pawn blocks a bishop that has not come out yet.') };
    const homeRank = me === 'w' ? '2' : '7';
    if ('de'.includes(m.from[0]) && m.from[1] === homeRank) {
      return { ok: true, san, why: t('推中心兵，佔中心，也讓象出得來。', 'A center pawn move takes space and opens a path for a bishop.') };
    }
    return { ok: false, san, why: t('這步沒有出新的子。', 'This move does not bring out a new piece.') };
  }
  return { ok: false, san, why: t('這個子已經出動過，先出還沒動的子。', 'This piece has already moved; bring out one that has not.') };
}

/** 符合原則的步，給答錯時參考。沒有任何一步符合的局面不適合拿來練 */
export function goodOpeningMoves(fen: string, limit = 3): string[] {
  const out: string[] = [];
  for (const m of new Chess(fen).moves({ verbose: true })) {
    if (judgeOpeningMove(fen, m.from, m.to).ok) out.push(m.san);
    if (out.length >= limit) break;
  }
  return out;
}
