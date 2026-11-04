// iOS 用的跨局分析：網站的規則分析（快速統計、先學的一件事）與引擎分析的彙整（用時、殘局、習慣），打包成一個 JS 檔
// 產生：npm run build:ios-report。輸入輸出都是 JSON 字串，輸出已經是畫面要顯示的中文
import { buildQuickStats } from '../../src/lib/analysis/quickStats';
import { gameSignals, summarizeSignals, type SignalEvent } from '../../src/lib/analysis/signals';
import { METRICS, formatMetric, prescribe } from '../../src/lib/analysis/prescription';
import { timeStats } from '../../src/lib/analysis/timeStats';
import { ENDGAMES, PHASES, phaseReport } from '../../src/lib/analysis/phases';
import { HABIT_META, countHabits } from '../../src/lib/habits';
import type { AnalyzedGame, GameSummary } from '../../src/lib/types';
import type { Bi } from '../../src/lib/i18n/lang';

// lang：App 目前的語言（zh／en／es／pt）。網站資料表只有 zh、en 兩份文字，es、pt 先用英文
const tx = (lang: string, b: Bi) => (lang === 'zh' ? b.zh : b.en);

import { TABLE } from '../../src/lib/openings';

const g = globalThis as unknown as Record<string, (...a: string[]) => string>;

/** 只看棋譜的統計；lang 不是中文時，開局家族名稱換回英文原名（最短的那個，就是家族名） */
g.RLQuick = (games, lang = 'zh') => {
  const q = buildQuickStats(JSON.parse(games) as GameSummary[]);
  if (lang !== 'zh' && q) {
    const en = (zh: string) => [...TABLE].sort((a, b) => a[0].length - b[0].length).find(([, z]) => z.split(' — ')[0] === zh)?.[0] ?? zh;
    for (const list of [q.topOpenings.asWhite, q.topOpenings.asBlack]) for (const o of list) o.name = en(o.name);
  }
  return JSON.stringify(q);
};

/** 先學的一件事：跟同分段、下一個分段比，挑差最多的那一項 */
g.RLPrescription = (games, rating, lang = 'zh') => {
  const list = (JSON.parse(games) as GameSummary[]).map(gameSignals).filter((x): x is NonNullable<typeof x> => !!x);
  const events: SignalEvent[] = list.flatMap((x) => x.events);
  const p = prescribe(Number(rating), summarizeSignals(list), events);
  if (!p) return 'null';
  const row = (r: (typeof p.rows)[number]) => ({
    key: r.key, label: tx(lang, METRICS[r.key].label), hint: tx(lang, METRICS[r.key].hint), lesson: tx(lang, METRICS[r.key].lesson),
    mine: formatMetric(r.key, r.mine), same: formatMetric(r.key, r.same), next: formatMetric(r.key, r.next),
    better: METRICS[r.key].better, enough: r.enough, extra: !!r.extra, gap: r.gap,
  });
  return JSON.stringify({
    status: p.status, games: p.games, band: tx(lang, p.band.label), same: tx(lang, p.same.label), next: tx(lang, p.next.label),
    pick: row(p.pick), rows: p.rows.filter((r) => r.enough).map(row),
    example: p.example ? { gameId: p.example.gameId, ply: p.example.ply, moveNumber: p.example.moveNumber, played: p.example.played, opponent: p.example.opponent, date: p.example.date, fen: p.example.fen } : null,
  });
};

/** 引擎分析過的局：用時、各階段與殘局、開局習慣 */
g.RLDeep = (games, lang = 'zh') => {
  const list = JSON.parse(games) as AnalyzedGame[];
  const ph = phaseReport(list);
  return JSON.stringify({
    time: timeStats(list),
    phases: PHASES.map((x) => ({ key: x.key, name: tx(lang, x.name), ...(ph.phases as Record<string, object>)[x.key] })),
    endgames: ph.endgames.map((e) => {
      const meta = ENDGAMES.find((m) => m.key === e.type)!;
      return { type: e.type, name: tx(lang, meta.name), tip: tx(lang, meta.tip), games: e.games, ahead: e.ahead, converted: e.converted, even: e.even, evenLost: e.evenLost, accuracy: e.accuracy };
    }),
    habits: countHabits(list).map((h) => ({ kind: h.kind, games: h.games, name: tx(lang, HABIT_META[h.kind]), desc: tx(lang, HABIT_META[h.kind].desc), tip: tx(lang, HABIT_META[h.kind].tip) })),
  });
};
