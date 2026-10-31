// iOS 用的跨局分析：網站的規則分析（快速統計、先學的一件事）與引擎分析的彙整（用時、殘局、習慣），打包成一個 JS 檔
// 產生：npm run build:ios-report。輸入輸出都是 JSON 字串，輸出已經是畫面要顯示的中文
import { buildQuickStats } from '../../src/lib/analysis/quickStats';
import { gameSignals, summarizeSignals, type SignalEvent } from '../../src/lib/analysis/signals';
import { METRICS, formatMetric, prescribe } from '../../src/lib/analysis/prescription';
import { timeStats } from '../../src/lib/analysis/timeStats';
import { ENDGAMES, PHASES, phaseReport } from '../../src/lib/analysis/phases';
import { HABIT_META, countHabits } from '../../src/lib/habits';
import type { AnalyzedGame, GameSummary } from '../../src/lib/types';

const g = globalThis as unknown as Record<string, (...a: string[]) => string>;

g.RLQuick = (games) => JSON.stringify(buildQuickStats(JSON.parse(games) as GameSummary[]));

/** 先學的一件事：跟同分段、下一個分段比，挑差最多的那一項 */
g.RLPrescription = (games, rating) => {
  const list = (JSON.parse(games) as GameSummary[]).map(gameSignals).filter((x): x is NonNullable<typeof x> => !!x);
  const events: SignalEvent[] = list.flatMap((x) => x.events);
  const p = prescribe(Number(rating), summarizeSignals(list), events);
  if (!p) return 'null';
  const row = (r: (typeof p.rows)[number]) => ({
    key: r.key, label: METRICS[r.key].label.zh, hint: METRICS[r.key].hint.zh, lesson: METRICS[r.key].lesson.zh,
    mine: formatMetric(r.key, r.mine), same: formatMetric(r.key, r.same), next: formatMetric(r.key, r.next),
    better: METRICS[r.key].better, enough: r.enough, extra: !!r.extra, gap: r.gap,
  });
  return JSON.stringify({
    status: p.status, games: p.games, band: p.band.label.zh, same: p.same.label.zh, next: p.next.label.zh,
    pick: row(p.pick), rows: p.rows.filter((r) => r.enough).map(row),
    example: p.example ? { gameId: p.example.gameId, ply: p.example.ply, moveNumber: p.example.moveNumber, played: p.example.played, opponent: p.example.opponent, date: p.example.date, fen: p.example.fen } : null,
  });
};

/** 引擎分析過的局：用時、各階段與殘局、開局習慣 */
g.RLDeep = (games) => {
  const list = JSON.parse(games) as AnalyzedGame[];
  const ph = phaseReport(list);
  return JSON.stringify({
    time: timeStats(list),
    phases: PHASES.map((x) => ({ key: x.key, name: x.name.zh, ...(ph.phases as Record<string, object>)[x.key] })),
    endgames: ph.endgames.map((e) => {
      const meta = ENDGAMES.find((m) => m.key === e.type)!;
      return { type: e.type, name: meta.name.zh, tip: meta.tip.zh, games: e.games, ahead: e.ahead, converted: e.converted, even: e.even, evenLost: e.evenLost, accuracy: e.accuracy };
    }),
    habits: countHabits(list).map((h) => ({ kind: h.kind, games: h.games, name: HABIT_META[h.kind].zh, desc: HABIT_META[h.kind].desc.zh, tip: HABIT_META[h.kind].tip.zh })),
  });
};
