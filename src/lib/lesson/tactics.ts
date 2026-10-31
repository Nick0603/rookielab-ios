import { Chess, type Color, type Move, type PieceSymbol, type Square } from 'chess.js';
import type { Lang } from '../i18n/lang';

/**
 * 戰術標籤：把「這個局面有什麼風險、有什麼機會」變成確定性的判斷。
 *
 * D-06：這裡全部是規則，不經 LLM。教練台詞（script.ts）只能講這裡判定出來的東西，
 * 判不出來就不講 —— 不推測沒有數據支持的原因。
 *
 * 第一版只收 A 級：用 chess.js 的攻擊判斷就能確定偵測的。
 * 過載、消除保護者、引離／引入屬 B 級，要靠引擎變化加規則，之後再加。
 */

export type TacticTag =
  | 'hanging' | 'outnumbered' | 'fork' | 'pawn_fork' | 'pin' | 'skewer'
  | 'discovered' | 'mate_threat' | 'back_rank' | 'trapped' | 'passed_pawn'
  | 'undeveloped' | 'early_queen' | 'moved_twice' | 'uncastled';

export interface Tactic {
  tag: TacticTag;
  /** 從使用者視角：risk = 我的風險，chance = 我的機會 */
  side: 'risk' | 'chance';
  /** 要標在棋盤上的格子 */
  squares: Square[];
  /** 牽涉到的子（組句子時再依語言轉成「c3 馬」或「knight on c3」） */
  pieces: PieceRef[];
  /** 造成這個戰術的那一步（SAN） */
  by?: string;
  /** outnumbered 專用：被比自己便宜的子攻擊時，是哪一顆（台詞要講實際原因） */
  cheaperAttacker?: PieceRef;
}

/** 顯示用詞統一在這裡。priority 越小越先講 */
export const TACTIC_META: Record<TacticTag, { zh: string; en: string; priority: number }> = {
  mate_threat: { zh: '殺棋威脅', en: 'Mate threat', priority: 0 },
  back_rank: { zh: '底線殺', en: 'Back-rank mate', priority: 0 },
  fork: { zh: '捉雙', en: 'Fork', priority: 1 },
  pawn_fork: { zh: '兵捉雙', en: 'Pawn fork', priority: 1 },
  hanging: { zh: '沒被保護的子', en: 'Undefended piece', priority: 2 },
  pin: { zh: '牽制', en: 'Pin', priority: 3 },
  skewer: { zh: '串打', en: 'Skewer', priority: 3 },
  discovered: { zh: '閃擊', en: 'Discovered attack', priority: 3 },
  trapped: { zh: '被困的子', en: 'Trapped piece', priority: 4 },
  outnumbered: { zh: '攻守數不夠', en: 'Outnumbered', priority: 5 },
  passed_pawn: { zh: '通路兵', en: 'Passed pawn', priority: 6 },
  undeveloped: { zh: '出子落後', en: 'Slow development', priority: 7 },
  early_queen: { zh: '過早出后', en: 'Early queen', priority: 7 },
  moved_twice: { zh: '同子走兩次', en: 'Same piece twice', priority: 7 },
  uncastled: { zh: '還沒入堡', en: 'Not castled', priority: 7 },
};

export const VALUE: Record<PieceSymbol, number> = { p: 1, n: 3, b: 3, r: 5, q: 9, k: 100 };
export const ZH_PIECE: Record<PieceSymbol, string> = { p: '兵', n: '馬', b: '象', r: '車', q: '后', k: '王' };

/** 低於這個價值的子（兵）被攻擊太常見，報了只會吵 */
export const MIN_VALUE = 3;
/** 通路兵要推到第幾橫列（己方視角，1 起算）才值得講 */
export const PASSED_MIN_RANK = 5;

export const EN_PIECE: Record<PieceSymbol, string> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };

/** 某一格上的某種子 */
export interface PieceRef {
  square: Square;
  type: PieceSymbol;
}

export const label = (square: Square, type: PieceSymbol): PieceRef => ({ square, type });

/** 中文「c3 馬」；英文「knight on c3」 */
export const pieceName = (p: PieceRef, lang: Lang = 'zh'): string =>
  (lang !== 'zh' ? `${EN_PIECE[p.type]} on ${p.square}` : `${p.square} ${ZH_PIECE[p.type]}`);
export const opp = (c: Color): Color => (c === 'w' ? 'b' : 'w');

const FILES = 'abcdefgh';
const toSquare = (f: number, r: number) => `${FILES[f]}${r + 1}` as Square;
const fileOf = (s: Square) => s.charCodeAt(0) - 97;
const rankOf = (s: Square) => Number(s[1]) - 1;

/** 換行棋方。用來問「如果現在輪到對手，他能做什麼」 */
export function withTurn(fen: string, turn: Color): Chess | null {
  const p = fen.split(' ');
  if (p[1] !== turn) { p[1] = turn; p[3] = '-'; }
  try { return new Chess(p.join(' ')); } catch { return null; }
}

function piecesOf(board: Chess, color: Color): { square: Square; type: PieceSymbol }[] {
  const out: { square: Square; type: PieceSymbol }[] = [];
  for (const row of board.board()) {
    for (const c of row) if (c && c.color === color) out.push({ square: c.square, type: c.type });
  }
  return out;
}

const cheapest = (board: Chess, squares: Square[]) =>
  Math.min(...squares.map((s) => VALUE[board.get(s)?.type ?? 'k']));

const sideOf = (owner: Color, me: Color): Tactic['side'] => (owner === me ? 'risk' : 'chance');
const attackerSide = (attacker: Color, me: Color): Tactic['side'] => (attacker === me ? 'chance' : 'risk');

/** 沒被保護的子、攻守數不夠 */
export function looseTactics(board: Chess, owner: Color, me: Color): Tactic[] {
  const out: Tactic[] = [];
  for (const p of piecesOf(board, owner)) {
    if (p.type === 'k' || VALUE[p.type] < MIN_VALUE) continue;
    const atk = board.attackers(p.square, opp(owner));
    if (atk.length === 0) continue;
    const def = board.attackers(p.square, owner);
    const base = { side: sideOf(owner, me), squares: [p.square], pieces: [label(p.square, p.type)] };
    if (def.length === 0) { out.push({ tag: 'hanging', ...base }); continue; }
    const low = atk.find((s) => VALUE[board.get(s)?.type ?? 'k'] < VALUE[p.type]);
    if (low) out.push({ tag: 'outnumbered', ...base, cheaperAttacker: label(low, board.get(low)!.type) });
    else if (atk.length > def.length) out.push({ tag: 'outnumbered', ...base });
  }
  return out;
}

/** 這一步走完之後，那顆子是否同時捉兩個以上的目標 */
export function forkOf(board: Chess, move: Move, me: Color): Tactic | null {
  if (move.piece === 'k' || move.flags.includes('k') || move.flags.includes('q')) return null;
  const after = new Chess(board.fen());
  after.move(move.lan.length > 4 ? { from: move.from, to: move.to, promotion: move.promotion } : { from: move.from, to: move.to });
  const mover = move.color;
  const enemy = opp(mover);
  const own = VALUE[move.promotion ?? move.piece];

  // 捉雙的子自己會被白吃就不算。將軍時只看合法應手：能吃掉它而且不虧，捉雙就不成立
  if (after.isCheck()) {
    const defended = after.attackers(move.to, mover).length > 0;
    const refuted = after.moves({ verbose: true }).some((r) =>
      r.to === move.to && (r.piece === 'k' || !defended || VALUE[r.piece] <= own));
    if (refuted) return null;
  } else {
    const atk = after.attackers(move.to, enemy);
    if (atk.length > 0 && (after.attackers(move.to, mover).length === 0 || cheapest(after, atk) < own)) return null;
  }

  const targets = piecesOf(after, enemy).filter((t) =>
    after.attackers(t.square, mover).includes(move.to)
    && (t.type === 'k' || VALUE[t.type] > own
      || (VALUE[t.type] >= MIN_VALUE && after.attackers(t.square, enemy).length === 0)));
  if (targets.length < 2) return null;

  return {
    tag: move.piece === 'p' ? 'pawn_fork' : 'fork',
    side: attackerSide(mover, me),
    squares: [move.to, ...targets.map((t) => t.square)],
    pieces: targets.map((t) => label(t.square, t.type)),
    by: move.san,
  };
}

/** 這一步讓「另一顆」長程子多打到一個有價值的目標 */
export function discoveredOf(board: Chess, move: Move, me: Color): Tactic | null {
  if (move.flags.includes('k') || move.flags.includes('q')) return null;
  const after = new Chess(board.fen());
  after.move({ from: move.from, to: move.to, promotion: move.promotion });
  const mover = move.color;
  const enemy = opp(mover);

  for (const t of piecesOf(after, enemy)) {
    if (t.square === move.to) continue;
    if (t.type !== 'k' && VALUE[t.type] < MIN_VALUE) continue;
    const before = new Set(board.attackers(t.square, mover));
    const sliders = after.attackers(t.square, mover).filter((s) =>
      s !== move.to && !before.has(s) && 'brq'.includes(after.get(s)?.type ?? ''));
    for (const s of sliders) {
      const sv = VALUE[after.get(s)!.type];
      if (t.type === 'k' || VALUE[t.type] > sv || after.attackers(t.square, enemy).length === 0) {
        return {
          tag: 'discovered', side: attackerSide(mover, me),
          squares: [s, t.square], pieces: [label(t.square, t.type)], by: move.san,
        };
      }
    }
  }
  return null;
}

const ROOK_DIRS = [[1, 0], [-1, 0], [0, 1], [0, -1]];
const BISHOP_DIRS = [[1, 1], [1, -1], [-1, 1], [-1, -1]];

/** 牽制與串打：沿長程子的線往前找，剛好碰到兩顆對方的子 */
export function lineTactics(board: Chess, attacker: Color, me: Color): Tactic[] {
  const out: Tactic[] = [];
  const enemy = opp(attacker);
  for (const p of piecesOf(board, attacker)) {
    const dirs = p.type === 'q' ? [...ROOK_DIRS, ...BISHOP_DIRS]
      : p.type === 'r' ? ROOK_DIRS : p.type === 'b' ? BISHOP_DIRS : null;
    if (!dirs) continue;
    for (const [df, dr] of dirs) {
      const hit: { square: Square; type: PieceSymbol }[] = [];
      let f = fileOf(p.square) + df;
      let r = rankOf(p.square) + dr;
      while (f >= 0 && f < 8 && r >= 0 && r < 8 && hit.length < 2) {
        const s = toSquare(f, r);
        const x = board.get(s);
        if (x) {
          if (x.color !== enemy) break;
          hit.push({ square: s, type: x.type });
        }
        f += df; r += dr;
      }
      if (hit.length < 2) continue;
      // 發動的長程子自己會被白吃，就不是機會也不是威脅
      if (isLost(board, p.square, attacker)) continue;
      const [front, back] = hit;
      const va = VALUE[p.type], vf = VALUE[front.type], vb = VALUE[back.type];
      const base = {
        side: attackerSide(attacker, me),
        squares: [p.square, front.square, back.square],
        pieces: [label(front.square, front.type), label(back.square, back.type)],
      };
      if (front.type !== 'k' && vf >= MIN_VALUE && vb > vf && (back.type === 'k' || vb > va)) {
        out.push({ tag: 'pin', ...base });
      } else if ((front.type === 'k' || (vf > vb && vf > va)) && vb >= MIN_VALUE
        && (vb > va || board.attackers(back.square, enemy).length === 0)) {
        out.push({ tag: 'skewer', ...base });
      }
    }
  }
  return out;
}

/** 這顆子待在原地或走到任何地方都會掉 */
function isLost(board: Chess, square: Square, owner: Color): boolean {
  const x = board.get(square);
  if (!x) return false;
  const atk = board.attackers(square, opp(owner));
  if (atk.length === 0) return false;
  return board.attackers(square, owner).length === 0 || cheapest(board, atk) < VALUE[x.type];
}

export function trappedTactics(fen: string, owner: Color, me: Color): Tactic[] {
  const b = withTurn(fen, owner);
  if (!b) return [];
  const out: Tactic[] = [];
  for (const p of piecesOf(b, owner)) {
    if (!'nbrq'.includes(p.type) || !isLost(b, p.square, owner)) continue;
    const escapes = b.moves({ square: p.square, verbose: true }).filter((m) => {
      if (m.captured && VALUE[m.captured] >= VALUE[p.type]) return true;
      const a = new Chess(b.fen());
      a.move({ from: m.from, to: m.to, promotion: m.promotion });
      return !isLost(a, m.to, owner);
    });
    if (escapes.length === 0) {
      out.push({ tag: 'trapped', side: sideOf(owner, me), squares: [p.square], pieces: [label(p.square, p.type)] });
    }
  }
  return out;
}

export function passedPawns(board: Chess, owner: Color, me: Color): Tactic[] {
  const out: Tactic[] = [];
  const enemyPawns = piecesOf(board, opp(owner)).filter((p) => p.type === 'p');
  for (const p of piecesOf(board, owner)) {
    if (p.type !== 'p') continue;
    const f = fileOf(p.square);
    const r = rankOf(p.square);
    const rel = owner === 'w' ? r + 1 : 8 - r;
    if (rel < PASSED_MIN_RANK) continue;
    const blocked = enemyPawns.some((e) =>
      Math.abs(fileOf(e.square) - f) <= 1 && (owner === 'w' ? rankOf(e.square) > r : rankOf(e.square) < r));
    if (!blocked) {
      out.push({ tag: 'passed_pawn', side: owner === me ? 'chance' : 'risk', squares: [p.square], pieces: [label(p.square, 'p')] });
    }
  }
  return out;
}

/**
 * 引擎回報走棋方有將殺時，把它變成標籤。
 * 將殺那一步是車或后打在對方底線 → 底線殺。
 */
export function mateTactic(fen: string, pv: string[], mate: number | undefined, me: Color): Tactic | null {
  if (!mate || mate <= 0 || pv.length === 0) return null;
  const board = new Chess(fen);
  const mover = board.turn();
  let first: Move | null = null;
  let last: Move | null = null;
  for (const u of pv.slice(0, mate * 2 - 1)) {
    try {
      last = board.move({ from: u.slice(0, 2), to: u.slice(2, 4), promotion: u[4] });
    } catch { return null; }
    first ??= last;
  }
  if (!first || !last) return null;
  const backRank = mover === 'w' ? '8' : '1';
  const isBackRank = board.isCheckmate() && 'rq'.includes(last.piece) && last.to[1] === backRank;
  return {
    tag: isBackRank ? 'back_rank' : 'mate_threat',
    side: attackerSide(mover, me),
    squares: [last.to],
    pieces: [],
    by: first.san,
  };
}

/** 一步棋本身造成了什麼：捉雙、閃擊、吃到沒人保護的子、新的牽制／串打 */
export function moveTactics(fen: string, uci: string, me: Color): Tactic[] {
  const board = new Chess(fen);
  const m = board.moves({ verbose: true }).find((x) => x.lan === uci);
  if (!m) return [];
  const out: Tactic[] = [];
  const fork = forkOf(board, m, me);
  if (fork) out.push(fork);
  const disc = discoveredOf(board, m, me);
  if (disc) out.push(disc);
  if (m.captured && VALUE[m.captured] >= MIN_VALUE && board.attackers(m.to, opp(m.color)).length === 0) {
    out.push({
      tag: 'hanging', side: attackerSide(m.color, me),
      squares: [m.to], pieces: [label(m.to, m.captured)], by: m.san,
    });
  }
  const after = new Chess(fen);
  after.move({ from: m.from, to: m.to, promotion: m.promotion });
  const existing = new Set(lineTactics(board, m.color, me).map(tacticKey));
  for (const t of lineTactics(after, m.color, me)) {
    if (!existing.has(tacticKey(t))) out.push({ ...t, by: m.san });
  }
  return out;
}

export const tacticKey = (t: Tactic) => `${t.tag}:${t.side}:${t.squares.join(',')}`;

/** 去重，依 priority 排序；同 priority 風險先講 */
export function sortTactics(list: Tactic[]): Tactic[] {
  const seen = new Set<string>();
  return list
    .filter((t) => { const k = tacticKey(t); if (seen.has(k)) return false; seen.add(k); return true; })
    .sort((a, b) =>
      TACTIC_META[a.tag].priority - TACTIC_META[b.tag].priority
      || (a.side === b.side ? 0 : a.side === 'risk' ? -1 : 1));
}

/** 走之前的局面掃描：雙方靜態的弱點，加上雙方下一步能發動的捉雙／閃擊 */
export function scanPosition(fen: string, me: Color): Tactic[] {
  const board = new Chess(fen);
  const out: Tactic[] = [];
  // 走棋方正被將軍時，「換另一方走」的局面不合法 —— 那一側只做靜態掃描
  const canFlip = (c: Color) => c === board.turn() || !board.isCheck();
  for (const owner of [me, opp(me)]) {
    out.push(...looseTactics(board, owner, me), ...passedPawns(board, owner, me));
    if (canFlip(owner)) out.push(...trappedTactics(fen, owner, me));
  }
  for (const attacker of [opp(me), me]) {
    out.push(...lineTactics(board, attacker, me));
    if (!canFlip(attacker)) continue;
    const b = withTurn(fen, attacker);
    if (!b) continue;
    for (const m of b.moves({ verbose: true })) {
      const t = forkOf(b, m, me) ?? discoveredOf(b, m, me);
      if (t) out.push(t);
    }
  }
  return sortTactics(out);
}
