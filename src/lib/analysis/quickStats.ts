import { Chess } from 'chess.js';
import type { GameSummary } from '../types';
import { openingFamily } from '../openings';

/**
 * 只靠對局 metadata 就能算的統計 —— **完全不需要引擎**。
 *
 * 這是第一次使用的體驗關鍵：抓完 50 局就能立刻秀出一整面的洞察，
 * 使用者不必盯著進度條等引擎跑完才看到任何東西。
 * 需要引擎的深度分析（失誤分類、勝率曲線）在背景繼續跑。
 */

export interface OpeningStat {
  name: string;
  games: number;
  wins: number;
  winRate: number;
}

export interface QuickStats {
  total: number;
  record: { win: number; loss: number; draw: number };
  winRate: number;
  byColor: {
    white: { games: number; wins: number; winRate: number };
    black: { games: number; wins: number; winRate: number };
  };
  /** 依結束方式分類的輸棋 */
  lossBy: { checkmated: number; resigned: number; timeout: number; other: number };
  /** 依結束方式分類的贏棋 */
  winBy: { checkmate: number; resignation: number; timeout: number; other: number };
  timeoutRate: number;
  byTimeClass: Record<string, { games: number; wins: number; winRate: number }>;
  topOpenings: { asWhite: OpeningStat[]; asBlack: OpeningStat[] };
  /** 平均步數（我方） */
  avgMoves: number;
  /** 最短與最長的一局 */
  shortestLoss?: { moves: number; opponent: string; url?: string };
  /** 對手平均分數，以及贏/輸時的對手平均分數 */
  opponentRating: { avg: number; whenWin: number; whenLoss: number };
  /** 分數變化（若有 rating 資料） */
  ratingDelta?: { from: number; to: number; diff: number };
  /** 一天下超過 N 局之後的勝率衰退 */
  fatigue?: { earlyWinRate: number; lateWinRate: number; threshold: number };
  dateRange: { from: string; to: string };
}

const isTimeout = (t?: string) => /time/i.test(t ?? '') && !/insufficient/i.test(t ?? '');

function countMoves(pgn: string): number {
  try {
    const c = new Chess();
    c.loadPgn(pgn);
    return Math.ceil(c.history().length / 2);
  } catch {
    return 0;
  }
}

function rate(wins: number, games: number) {
  return games === 0 ? 0 : Math.round((wins / games) * 100);
}

export function buildQuickStats(games: GameSummary[]): QuickStats {
  const total = games.length;
  const win = games.filter((g) => g.result === 'win').length;
  const loss = games.filter((g) => g.result === 'loss').length;

  const w = games.filter((g) => g.color === 'white');
  const b = games.filter((g) => g.color === 'black');
  const wWin = w.filter((g) => g.result === 'win').length;
  const bWin = b.filter((g) => g.result === 'win').length;

  const losses = games.filter((g) => g.result === 'loss');
  const wins = games.filter((g) => g.result === 'win');

  const lossBy = {
    checkmated: losses.filter((g) => g.termination === 'checkmated').length,
    resigned: losses.filter((g) => g.termination === 'resigned').length,
    timeout: losses.filter((g) => isTimeout(g.termination)).length,
    other: 0,
  };
  lossBy.other = losses.length - lossBy.checkmated - lossBy.resigned - lossBy.timeout;

  const winBy = {
    checkmate: wins.filter((g) => g.termination === 'win').length,
    resignation: 0,
    timeout: 0,
    other: 0,
  };

  const byTimeClass: QuickStats['byTimeClass'] = {};
  for (const g of games) {
    const t = byTimeClass[g.timeClass] ?? { games: 0, wins: 0, winRate: 0 };
    t.games++;
    if (g.result === 'win') t.wins++;
    t.winRate = rate(t.wins, t.games);
    byTimeClass[g.timeClass] = t;
  }

  const openingsFor = (list: GameSummary[]): OpeningStat[] => {
    const m = new Map<string, { games: number; wins: number }>();
    for (const g of list) {
      const k = openingFamily(g.opening);
      const e = m.get(k) ?? { games: 0, wins: 0 };
      e.games++;
      if (g.result === 'win') e.wins++;
      m.set(k, e);
    }
    return [...m.entries()]
      .map(([name, v]) => ({ name, ...v, winRate: rate(v.wins, v.games) }))
      .sort((x, y) => y.games - x.games)
      .slice(0, 4);
  };

  const moveCounts = games.map((g) => countMoves(g.pgn)).filter((n) => n > 0);
  const avgMoves = moveCounts.length
    ? Math.round(moveCounts.reduce((a, c) => a + c, 0) / moveCounts.length)
    : 0;

  let shortestLoss: QuickStats['shortestLoss'];
  for (const g of losses) {
    const n = countMoves(g.pgn);
    if (n > 0 && (!shortestLoss || n < shortestLoss.moves)) {
      shortestLoss = { moves: n, opponent: g.opponent, url: g.url };
    }
  }

  const oppOf = (list: GameSummary[]) => {
    const r = list.map((g) => g.opponentRating).filter((x): x is number => !!x);
    return r.length ? Math.round(r.reduce((a, c) => a + c, 0) / r.length) : 0;
  };

  const rated = games.filter((g) => typeof g.myRating === 'number');
  const ratingDelta = rated.length >= 2
    ? { from: rated[rated.length - 1].myRating!, to: rated[0].myRating!,
        diff: rated[0].myRating! - rated[rated.length - 1].myRating! }
    : undefined;

  // 同一天的第 N 局之後表現是否下滑
  const byDay = new Map<string, GameSummary[]>();
  for (const g of [...games].reverse()) {
    const l = byDay.get(g.date) ?? [];
    l.push(g);
    byDay.set(g.date, l);
  }
  const THRESHOLD = 6;
  const early = { g: 0, w: 0 };
  const late = { g: 0, w: 0 };
  for (const list of byDay.values()) {
    list.forEach((g, i) => {
      const bucket = i < THRESHOLD ? early : late;
      bucket.g++;
      if (g.result === 'win') bucket.w++;
    });
  }
  const fatigue = late.g >= 5
    ? { earlyWinRate: rate(early.w, early.g), lateWinRate: rate(late.w, late.g), threshold: THRESHOLD }
    : undefined;

  const dates = games.map((g) => g.date).sort();

  return {
    total,
    record: { win, loss, draw: total - win - loss },
    winRate: rate(win, total),
    byColor: {
      white: { games: w.length, wins: wWin, winRate: rate(wWin, w.length) },
      black: { games: b.length, wins: bWin, winRate: rate(bWin, b.length) },
    },
    lossBy,
    winBy,
    timeoutRate: rate(lossBy.timeout, losses.length),
    byTimeClass,
    topOpenings: { asWhite: openingsFor(w), asBlack: openingsFor(b) },
    avgMoves,
    shortestLoss,
    opponentRating: {
      avg: oppOf(games),
      whenWin: oppOf(wins),
      whenLoss: oppOf(losses),
    },
    ratingDelta,
    fatigue,
    dateRange: { from: dates[0] ?? '', to: dates[dates.length - 1] ?? '' },
  };
}
