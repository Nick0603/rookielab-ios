import { Chess, type Color, type Move, type PieceSymbol, type Square } from 'chess.js';
import type { GameSummary } from '../types';
import { withTurn } from '../lesson/tactics';

/**
 * 不用引擎、只看棋譜就能判斷的訊號：送子、漏吃、一步殺、多子沒贏下。
 *
 * 用途是「帳號送出後幾秒內就給處方」—— 引擎一局要 30–60 秒，這裡一局是毫秒級。
 * 定義與分段基準（bandBaselines.ts）必須一致：基準就是用這支檔案算出來的，
 * 改這裡的判斷就要重跑 scripts/build-baselines.ts。
 *
 * 規則是近似值（見 landing-by-elo.md 第 2 節）：
 * 送子不考慮被牽制的保護者與反擊，漏吃可能包含毒餌。一步殺是精確的。
 */

export type SignalKind = 'hung' | 'missed_free' | 'missed_mate' | 'allowed_mate' | 'threw_lead';

export interface SignalEvent {
  kind: SignalKind;
  gameId: string;
  date: string;
  opponent: string;
  color: GameSummary['color'];
  /** 1 起算的 ply，是我走的那一步 */
  ply: number;
  moveNumber: number;
  /** 我走之前的局面 */
  fen: string;
  /** 我實際走的 */
  played: string;
  /** 該走的：一步殺的那一步、吃免費子的那一步 */
  answer?: string;
  answerFrom?: Square;
  answerTo?: Square;
  /** 送出去／沒吃到的那個子所在的格子 */
  square?: Square;
  /** 走之前我方的子力領先（負數 = 落後）。挑範例時用，離 0 越近越還沒分出勝負 */
  lead: number;
}

export interface GameSignals {
  gameId: string;
  result: GameSummary['result'];
  /** 我方步數 */
  myMoves: number;
  hung: number;
  freeChances: number;
  missedFree: number;
  /** 這一局出現過我方一步殺的機會 */
  mateChance: boolean;
  /** 至少漏掉一次 */
  mateMissed: boolean;
  /** 我走完之後對手有一步殺，逐步計 */
  allowedMate: number;
  /** 連續兩個 ply 都成立的最大子力領先 */
  maxLead: number;
  /** chess.com／Lichess 給的結束方式（我方）：timeout、checkmated、resigned、abandoned… */
  termination?: string;
  events: SignalEvent[];
}

const V: Record<string, number> = { p: 1, n: 3, b: 3, r: 5, q: 9, k: 0 };
/** 多子：子力領先 3 分以上，大約多一個輕子（馬或象）。優勢夠明確、又比「多一個車」常見得多 */
export const LEAD_THRESHOLD = 3;
/** 送子：懸空的子要比這一步吃到的多這麼多分，才不算正常兌換 */
const HUNG_MARGIN = 2;

const opp = (c: Color): Color => (c === 'w' ? 'b' : 'w');

function material(b: Chess, c: Color): number {
  let s = 0;
  for (const row of b.board()) for (const x of row) if (x && x.color === c) s += V[x.type];
  return s;
}

/** c 方價值 >=3、被對手攻擊且沒有己方保護的子 */
function loosePieces(b: Chess, c: Color): Square[] {
  const out: Square[] = [];
  for (const row of b.board()) for (const x of row) {
    if (!x || x.color !== c || V[x.type] < 3) continue;
    if (b.attackers(x.square, opp(c)).length > 0 && b.attackers(x.square, c).length === 0) out.push(x.square);
  }
  return out;
}

/**
 * 不產生 SAN 的走法。
 *
 * chess.js 的 moves({ verbose: true }) 會替每一步產生 SAN（含消歧義與將殺判斷），
 * 實測佔掉九成以上的時間；這裡只需要起訖格與吃到的子。
 * 用的是 chess.js 的內部方法（_moves／_makeMove／_undoMove），只在這一處；
 * 版本更新改名時自動退回公開 API —— 結果一樣，只是變慢。
 */
interface LiteMove { from: Square; to: Square; piece: PieceSymbol; captured?: PieceSymbol; promotion?: PieceSymbol }
interface Internal { from: number; to: number; piece: PieceSymbol; captured?: PieceSymbol; promotion?: PieceSymbol }
interface Internals {
  _moves(o: { legal: boolean }): Internal[];
  _makeMove(m: Internal): void;
  _undoMove(): void;
  isCheckmate(): boolean;
}

const sq88 = (i: number) => ('abcdefgh'[i & 15] + '87654321'[i >> 4]) as Square;
const fast = (b: Chess): Internals | null => {
  const x = b as unknown as Partial<Internals>;
  return typeof x._moves === 'function' && typeof x._makeMove === 'function' && typeof x._undoMove === 'function'
    ? (x as Internals) : null;
};
const lite = (m: Internal): LiteMove =>
  ({ from: sq88(m.from), to: sq88(m.to), piece: m.piece, captured: m.captured, promotion: m.promotion });

function liteMoves(b: Chess): LiteMove[] {
  const f = fast(b);
  if (f) return f._moves({ legal: true }).map(lite);
  return b.moves({ verbose: true }).map((m) => ({ from: m.from, to: m.to, piece: m.piece, captured: m.captured, promotion: m.promotion }));
}

/** 走棋方的一步殺 */
function mateIn1(b: Chess): LiteMove | undefined {
  const f = fast(b);
  if (!f) {
    const m = b.moves({ verbose: true }).find((x) => x.san.endsWith('#'));
    return m && { from: m.from, to: m.to, piece: m.piece, captured: m.captured, promotion: m.promotion };
  }
  for (const m of f._moves({ legal: true })) {
    f._makeMove(m);
    const mate = f.isCheckmate();
    f._undoMove();
    if (mate) return lite(m);
  }
  return undefined;
}

/** 只在要顯示事件時才算 SAN */
function sanOf(fen: string, m: LiteMove | undefined): string | undefined {
  if (!m) return undefined;
  try { return new Chess(fen).move({ from: m.from, to: m.to, promotion: m.promotion }).san; } catch { return undefined; }
}

/** 走棋方可以合法吃到的 c 方懸空子 */
function capturable(b: Chess, c: Color, moves: LiteMove[]): Square[] {
  return loosePieces(b, c).filter((sq) => moves.some((x) => x.to === sq));
}

const valueAt = (b: Chess, sq: Square) => V[b.get(sq)?.type ?? 'p'];

export function gameSignals(g: GameSummary): GameSignals | null {
  let history: Move[];
  try {
    const c = new Chess();
    c.loadPgn(g.pgn);
    history = c.history({ verbose: true });
  } catch {
    return null;
  }
  const me: Color = g.color === 'white' ? 'w' : 'b';
  const out: GameSignals = {
    gameId: g.id, result: g.result, myMoves: 0, hung: 0, freeChances: 0, missedFree: 0,
    mateChance: false, mateMissed: false, allowedMate: 0, maxLead: -Infinity, events: [], termination: g.termination,
  };
  const base = { gameId: g.id, date: g.date, opponent: g.opponent, color: g.color };

  // 子力差：起始局面算一次，之後用吃子與升變累加，不必每一步重建棋盤
  const leads: number[] = [];
  if (history.length) {
    const b0 = new Chess(history[0].before);
    let lead = material(b0, me) - material(b0, opp(me));
    for (const m of history) {
      const gain = (m.captured ? V[m.captured] : 0) + (m.promotion ? V[m.promotion] - 1 : 0);
      lead += m.color === me ? gain : -gain;
      leads.push(lead);
    }
  }
  let leadPly = -1;

  history.forEach((m, i) => {
    const sustained = Math.min(leads[i], leads[i + 1] ?? leads[i]);
    if (sustained > out.maxLead) { out.maxLead = sustained; leadPly = i; }
    if (m.color !== me) return;

    out.myMoves++;
    const ev = { ...base, ply: i + 1, moveNumber: Math.floor(i / 2) + 1, fen: m.before, played: m.san, lead: leads[i - 1] ?? 0 };
    const before = new Chess(m.before);
    const legal = liteMoves(before);
    const after = new Chess(m.after);

    // 下面幾項檢查只在有候選時才算 —— 大部分的步根本沒有懸空的子
    let threat: { board: Chess | null; moves: LiteMove[] } | undefined;
    const threatened = () => {
      if (!threat) {
        const board = withTurn(m.before, opp(me));
        threat = { board, moves: board ? liteMoves(board) : [] };
      }
      return threat;
    };

    const mate = mateIn1(before);
    if (mate) {
      out.mateChance = true;
      if (!m.san.endsWith('#')) {
        out.mateMissed = true;
        out.events.push({ ...ev, kind: 'missed_mate', answer: sanOf(m.before, mate), answerFrom: mate.from, answerTo: mate.to });
      }
    }

    // 漏吃：自己有更值錢的子正被攻擊、或對手有一步殺的威脅時，先救火才對，不算漏吃
    let free = capturable(before, opp(me), legal);
    if (free.length) {
      const t = threatened();
      const facingMate = !!(t.board && mateIn1(t.board));
      const myWorstLoose = Math.max(0, ...(t.board ? capturable(t.board, me, t.moves) : []).map((sq) => valueAt(before, sq)));
      free = facingMate ? [] : free.filter((sq) => {
        if (valueAt(before, sq) < myWorstLoose) return false;
        // 吃完之後吃子的那個子不能反被吃掉更多（x 光、閃擊讓「沒保護」變成有保護）
        const take = legal.find((x) => x.to === sq)!;
        const b = new Chess(m.before);
        b.move({ from: take.from, to: take.to, promotion: take.promotion });
        return b.attackers(sq, opp(me)).length === 0 || V[take.piece] <= valueAt(before, sq);
      });
    }
    if (free.length) {
      out.freeChances++;
      if (!(m.captured && free.includes(m.to)) && !m.san.endsWith('#')) {
        out.missedFree++;
        const take = legal.find((x) => x.to === free[0]);
        out.events.push({ ...ev, kind: 'missed_free', square: free[0], answer: sanOf(m.before, take), answerFrom: take?.from, answerTo: take?.to });
      }
    }

    if (after.isCheckmate()) return;

    const gained = m.captured ? V[m.captured] : 0;
    const replies = liteMoves(after);
    let hung = capturable(after, me, replies).filter((sq) => valueAt(after, sq) - gained >= HUNG_MARGIN);
    if (hung.length) {
      // 走之前就懸空的不算這一步送的
      const t = threatened();
      const was = new Set(t.board ? loosePieces(t.board, me) : []);
      // 反擊：我這步同時讓對手有同等以上價值的子懸空，是互相威脅，不算送子
      const mine = withTurn(m.after, me) ?? after;
      const counter = Math.max(0, ...capturable(mine, opp(me), liteMoves(mine)).map((sq) => valueAt(after, sq)));
      hung = hung.filter((sq) => !was.has(sq) && valueAt(after, sq) > counter);
    }
    if (hung.length) {
      out.hung++;
      out.events.push({ ...ev, kind: 'hung', square: hung[0] });
    }

    const theirMate = mateIn1(after);
    if (theirMate) {
      out.allowedMate++;
      out.events.push({ ...ev, kind: 'allowed_mate', answer: sanOf(m.after, theirMate), answerFrom: theirMate.from, answerTo: theirMate.to });
    }
  });

  if (!history.length) out.maxLead = 0;
  if (out.maxLead >= LEAD_THRESHOLD && g.result !== 'win' && leadPly >= 0) {
    // 從領先最多的那個局面開始，輪到我走
    const at = history.findIndex((m, i) => i >= leadPly && m.color === me);
    if (at >= 0) {
      const m = history[at];
      out.events.push({ ...base, kind: 'threw_lead', ply: at + 1, moveNumber: Math.floor(at / 2) + 1, fen: m.before, played: m.san, lead: leads[at - 1] ?? 0 });
    }
  }
  return out;
}

export interface SignalSummary {
  games: number;
  /** 每局送子次數 */
  hungPerGame: number;
  /** 對手留下免費子的次數，與其中沒吃到的比例 */
  freeChances: number;
  missedFreeRate: number;
  /** 出現過一步殺機會的局數，與其中至少漏掉一次的比例 */
  mateChanceGames: number;
  missedMateRate: number;
  /** 每局放任對手一步殺的次數（逐步計） */
  allowedMatePerGame: number;
  /** 曾經多子（領先 3 分以上）的局數，與其中有贏下來的比例 */
  leadGames: number;
  convertRate: number;
  /** 至少送子一次的局數比例 */
  hungRate: number;
  /** 錯過關鍵機會：至少一次有一步殺沒走、或對手的子沒人保護沒吃到的局數比例 */
  missedChanceRate: number;
  /** 至少有一次走完讓對手一步殺的局數比例 */
  allowedMateRate: number;
  /** 多子的局裡，最後超時輸掉的比例 */
  leadTimeoutRate: number;
  /** 所有對局裡超時輸掉的比例 */
  timeoutLossRate: number;
  /** 自己走不到 EARLY_MATE_MOVES 步就被將死的比例 */
  matedEarlyRate: number;
  /** 斷線、放棄（abandoned）輸掉的比例 */
  abandonRate: number;
}

/** 開局就被將死：我方走不到 20 步 */
export const EARLY_MATE_MOVES = 20;
const lostBy = (g: GameSignals, re: RegExp) => g.result === 'loss' && re.test(g.termination ?? '');

const ratio = (a: number, b: number) => (b ? a / b : 0);

export function summarizeSignals(list: GameSignals[]): SignalSummary {
  const sum = (f: (g: GameSignals) => number) => list.reduce((s, g) => s + f(g), 0);
  const mateGames = list.filter((g) => g.mateChance);
  const leadGames = list.filter((g) => g.maxLead >= LEAD_THRESHOLD);
  const freeChances = sum((g) => g.freeChances);
  return {
    games: list.length,
    hungPerGame: ratio(sum((g) => g.hung), list.length),
    freeChances,
    missedFreeRate: ratio(sum((g) => g.missedFree), freeChances),
    mateChanceGames: mateGames.length,
    missedMateRate: ratio(mateGames.filter((g) => g.mateMissed).length, mateGames.length),
    allowedMatePerGame: ratio(sum((g) => g.allowedMate), list.length),
    leadGames: leadGames.length,
    convertRate: ratio(leadGames.filter((g) => g.result === 'win').length, leadGames.length),
    hungRate: ratio(list.filter((g) => g.hung > 0).length, list.length),
    missedChanceRate: ratio(list.filter((g) => g.mateMissed || g.missedFree > 0).length, list.length),
    allowedMateRate: ratio(list.filter((g) => g.allowedMate > 0).length, list.length),
    leadTimeoutRate: ratio(leadGames.filter((g) => lostBy(g, /time|outoftime/i)).length, leadGames.length),
    timeoutLossRate: ratio(list.filter((g) => lostBy(g, /time|outoftime/i)).length, list.length),
    matedEarlyRate: ratio(list.filter((g) => lostBy(g, /checkmat|mate/i) && g.myMoves < EARLY_MATE_MOVES).length, list.length),
    abandonRate: ratio(list.filter((g) => lostBy(g, /abandon/i)).length, list.length),
  };
}
