import { Chess } from 'chess.js';
import type { Bi } from '../i18n/lang';
import type { AnalyzedGame } from '../types';
import { phaseOf } from './analyzeGame';

export type Phase = 'opening' | 'middlegame' | 'endgame';
export const PHASES: { key: Phase; name: Bi }[] = [
  { key: 'opening', name: { zh: '開局', en: 'Opening' } },
  { key: 'middlegame', name: { zh: '中局', en: 'Middlegame' } },
  { key: 'endgame', name: { zh: '殘局', en: 'Endgame' } },
];

/**
 * 殘局種類：看進入殘局那一刻，雙方除了王和兵還剩什麼子。
 * pawn 兵殘局、rook 車殘局、minor 輕子殘局（象、馬）、queen 后殘局、rookMinor 車＋輕子、mixed 其他（后加其他子）。
 */
export type EndgameType = 'pawn' | 'rook' | 'minor' | 'queen' | 'rookMinor' | 'mixed';
export const ENDGAMES: { key: EndgameType; name: Bi; tip: Bi; puzzle?: string }[] = [
  { key: 'pawn', name: { zh: '兵殘局', en: 'Pawn endgames' }, tip: { zh: '王要主動上前；算清楚誰先升變、對王（opposition）', en: 'Activate the king; count who promotes first; use the opposition' }, puzzle: 'pawnEnd' },
  { key: 'rook', name: { zh: '車殘局', en: 'Rook endgames' }, tip: { zh: '車放在兵的後面、車要主動；記住 Lucena 與 Philidor 兩個局面', en: 'Rooks belong behind passed pawns and must stay active; know Lucena and Philidor' }, puzzle: 'rookEnd' },
  { key: 'minor', name: { zh: '輕子殘局', en: 'Minor-piece endgames' }, tip: { zh: '象怕兵卡在同色格，馬怕邊兵；王一樣要上前', en: 'Bishops hate pawns on their own color, knights hate rook pawns; bring the king' }, puzzle: 'minorEnd' },
  { key: 'queen', name: { zh: '后殘局', en: 'Queen endgames' }, tip: { zh: '先顧好自己的王，小心長將；推兵時讓后擋在前面', en: 'Shelter your king from perpetual checks; escort the pawn with the queen' }, puzzle: 'queenEnd' },
  { key: 'rookMinor', name: { zh: '車＋輕子殘局', en: 'Rook + minor endgames' }, tip: { zh: '子力少了更要算清楚：送子、捉雙在殘局一樣致命', en: 'Fewer pieces, same tactics: forks and hung pieces still decide it' }, puzzle: 'rookEnd' },
  { key: 'mixed', name: { zh: '其他殘局', en: 'Other endgames' }, tip: { zh: '后還在場上：先看將軍、吃子、威脅', en: 'Queens are still on: checks, captures and threats first' } },
];

export function endgameType(fen: string): EndgameType {
  const c = new Chess(fen);
  const n = { q: 0, r: 0, m: 0 };
  for (const row of c.board()) for (const sq of row) {
    if (!sq) continue;
    if (sq.type === 'q') n.q++;
    else if (sq.type === 'r') n.r++;
    else if (sq.type === 'b' || sq.type === 'n') n.m++;
  }
  if (!n.q && !n.r && !n.m) return 'pawn';
  if (n.q) return n.r || n.m ? 'mixed' : 'queen';
  if (n.r && n.m) return 'rookMinor';
  return n.r ? 'rook' : 'minor';
}

export interface PhaseStat {
  /** 走到這個階段的局數 */
  games: number;
  moves: number;
  /** 我方這個階段的平均準確率 */
  accuracy: number;
  /** 每 100 步的失誤（嚴重失誤、失誤、錯失良機） */
  errorsPer100: number;
  /** 這個階段每一步平均讓勝率掉多少（百分點；只算掉的，引擎認為最好的步是 0） */
  leak: number;
}

export interface EndgameStat {
  type: EndgameType;
  games: number;
  /** 進殘局時已經大優（勝率 ≥ 75%）的局數，與其中贏下來的局數 */
  ahead: number;
  converted: number;
  /** 進殘局時均勢（35%–65%）的局數，與其中輸掉的 */
  even: number;
  evenLost: number;
  accuracy: number;
  errors: number;
  /** 收不好的局：大優沒贏、均勢輸掉 */
  slips: { gameId: string; ply: number; date: string; opponent: string; winAtEntry: number; result: string }[];
}

const ERR = ['blunder', 'mistake', 'miss'];
const AHEAD = 0.75;

/**
 * 前中殘局各自下得怎樣、進了哪種殘局、大優有沒有收下來。
 * 階段跟 analyzeGame 同一套（子力 ≤ 16 為殘局、10 手內為開局）。
 */
export function phaseReport(games: AnalyzedGame[]) {
  const acc: Record<Phase, { games: number; moves: number; accSum: number; errs: number; leak: number; all: number }> = {
    opening: { games: 0, moves: 0, accSum: 0, errs: 0, leak: 0, all: 0 },
    middlegame: { games: 0, moves: 0, accSum: 0, errs: 0, leak: 0, all: 0 },
    endgame: { games: 0, moves: 0, accSum: 0, errs: 0, leak: 0, all: 0 },
  };
  const eg = new Map<EndgameType, EndgameStat & { accSum: number; moveN: number }>();

  for (const g of games) {
    let history;
    try { const c = new Chess(); c.loadPgn(g.pgn); history = c.history({ verbose: true }); } catch { continue; }
    const seen = new Set<Phase>();
    let entry: { type: EndgameType; win: number; ply: number } | null = null;
    for (const r of g.moves) {
      const m = history[r.ply - 1];
      if (!m) continue;
      const ph = phaseOf(r.moveNumber, m.before) as Phase;
      const a = acc[ph];
      if (!seen.has(ph)) { seen.add(ph); a.games++; }
      if (r.cls !== 'book') { a.moves++; a.accSum += r.accuracy; }
      if (ERR.includes(r.cls)) a.errs++;
      a.all++;
      a.leak += Math.max(0, r.winBefore - r.winAfter);
      if (ph === 'endgame') {
        if (!entry) entry = { type: endgameType(m.before), win: r.winBefore, ply: r.ply };
        const e = eg.get(entry.type) ?? { type: entry.type, games: 0, ahead: 0, converted: 0, even: 0, evenLost: 0, accuracy: 0, errors: 0, slips: [], accSum: 0, moveN: 0 };
        e.accSum += r.accuracy; e.moveN++;
        if (ERR.includes(r.cls)) e.errors++;
        eg.set(entry.type, e);
      }
    }
    if (entry) {
      const e = eg.get(entry.type)!;
      e.games++;
      const slip = () => e.slips.push({ gameId: g.id, ply: entry!.ply, date: g.date, opponent: g.opponent, winAtEntry: entry!.win, result: g.result });
      if (entry.win >= AHEAD) { e.ahead++; if (g.result === 'win') e.converted++; else slip(); }
      else if (entry.win >= 0.35 && entry.win <= 0.65) { e.even++; if (g.result === 'loss') { e.evenLost++; slip(); } }
    }
  }

  const phases = Object.fromEntries(PHASES.map(({ key }) => {
    const a = acc[key];
    return [key, {
      games: a.games, moves: a.moves,
      accuracy: a.moves ? Math.round((a.accSum / a.moves) * 10) / 10 : 0,
      errorsPer100: a.moves ? Math.round((a.errs / a.moves) * 1000) / 10 : 0,
      leak: a.all ? Math.round((a.leak / a.all) * 1000) / 10 : 0,
    } satisfies PhaseStat];
  })) as Record<Phase, PhaseStat>;

  const endgames: EndgameStat[] = [...eg.values()]
    .map(({ accSum, moveN, ...e }) => ({ ...e, accuracy: moveN ? Math.round((accSum / moveN) * 10) / 10 : 0 }))
    .sort((a, b) => b.games - a.games);

  // 下得最好、最需要補的階段：至少 3 局、20 步才比
  const ranked = PHASES.map((p) => p.key).filter((k) => phases[k].games >= 3 && phases[k].moves >= 20).sort((a, b) => phases[b].accuracy - phases[a].accuracy);
  const best = ranked.length >= 2 && phases[ranked[0]].accuracy - phases[ranked.at(-1)!].accuracy >= 4 ? ranked[0] : null;
  const worst = best ? ranked.at(-1)! : null;
  return { phases, endgames, best, worst };
}

/** 收不好：大優至少 2 局、收下不到 7 成；或均勢至少 2 局、輸掉超過一半 */
export const convertsPoorly = (e: EndgameStat) =>
  (e.ahead >= 2 && e.converted / e.ahead < 0.7) || (e.even >= 2 && e.evenLost / e.even > 0.5);
