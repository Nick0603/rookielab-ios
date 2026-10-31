import type { BlunderType } from '../types';
import type { Bi } from '../i18n/lang';
import { BAND_BASELINES, type BandBaseline } from './bandBaselines';
import type { SignalEvent, SignalKind, SignalSummary } from './signals';

/**
 * 「你該先學的一件事」：拿使用者的規則訊號跟**下一個分段**比，挑差距最大的那一項。
 *
 * 取代 aggregate.ts 的 pickHeadline() 寫死順序 —— 不同分段的主要問題不同
 * （landing-by-elo.md 第 2、3 節）：≤550 是將殺、551–850 是送子與漏吃、851 以上是優勢轉換。
 * 全部來自規則，不等引擎，所以帳號送出後幾秒內就能給。
 */

/** 產品用的分段（出題規則、難度、優先指標） */
export type BandId = 'A' | 'B' | 'C' | 'D' | 'E' | 'F';

/** 跟別人比用的細分段：每 200 分一段（bandBaselines.ts，全球玩家），比 BANDS 細 */
export interface CompareBand { id: BandBaseline['id']; label: Bi; base: BandBaseline }
const cmpLabel = (i: number): Bi => {
  const b = BAND_BASELINES[i];
  const lo = i === 0 ? null : BAND_BASELINES[i - 1].max + 1;
  if (lo === null) return { zh: `${b.max} 分以下`, en: `Under ${b.max + 1}` };
  if (i === BAND_BASELINES.length - 1) return { zh: `${lo} 分以上`, en: `${lo}+` };
  return { zh: `${lo}–${b.max} 分`, en: `${lo}–${b.max}` };
};
export const COMPARE_BANDS: CompareBand[] = BAND_BASELINES.map((base, i) => ({ id: base.id, label: cmpLabel(i), base }));
export const compareOf = (rating: number): number => {
  const i = BAND_BASELINES.findIndex((b) => rating <= b.max);
  return i < 0 ? BAND_BASELINES.length - 1 : i;
};

export interface Band {
  id: BandId;
  /** 分數上限（含） */
  max: number;
  label: Bi;
}

export const BANDS: Band[] = [
  { id: 'A', max: 550, label: { zh: '550 分以下', en: 'Under 550' } },
  { id: 'B', max: 850, label: { zh: '551–850 分', en: '551–850' } },
  { id: 'C', max: 1150, label: { zh: '851–1150 分', en: '851–1150' } },
  { id: 'D', max: 1450, label: { zh: '1151–1450 分', en: '1151–1450' } },
  { id: 'E', max: 1750, label: { zh: '1451–1750 分', en: '1451–1750' } },
  { id: 'F', max: Infinity, label: { zh: '1751 分以上', en: '1751+' } },
];

export const bandOf = (rating: number): Band => BANDS.find((b) => rating <= b.max)!;
export type MetricKey = 'missedMateRate' | 'missedChanceRate' | 'allowedMateRate' | 'hungRate' | 'missedFreeRate' | 'convertRate'
  | 'matedEarlyRate' | 'leadTimeoutRate' | 'timeoutLossRate' | 'abandonRate';

interface MetricMeta {
  /** 數字越小越好，或越大越好 */
  better: 'lower' | 'higher';
  format: 'pct' | 'perGame';
  /** skill：分數越高越好（跟下一段比）；habit：不隨分數變好，只跟同分段比 */
  trend: 'skill' | 'habit';
  /** 有範例局面可以畫的才有 */
  event?: SignalKind;
  /** 對應到練習頁的提示類型 */
  drill?: BlunderType;
  label: Bi;
  /** 數字代表什麼 */
  hint: Bi;
  /** 先學的一件事 */
  lesson: Bi;
  /** 樣本夠不夠下結論 */
  enough: (s: SignalSummary) => boolean;
}

export const METRICS: Record<MetricKey, MetricMeta> = {
  missedMateRate: {
    trend: 'skill', better: 'lower', format: 'pct', event: 'missed_mate', drill: 'missed_mate',
    label: { zh: '漏掉將殺', en: 'Missed mate' },
    hint: { zh: '有一步殺的局裡，至少漏掉一次', en: 'Games with a mate-in-one where it was missed' },
    lesson: { zh: '每一步先看：我能不能直接將死對手', en: 'Every move, check first: can I checkmate right now?' },
    enough: (s) => s.mateChanceGames >= 3,
  },
  allowedMateRate: {
    trend: 'skill', better: 'lower', format: 'pct', event: 'allowed_mate', drill: 'allowed_mate',
    label: { zh: '放任對手將殺', en: 'Allowed mate' },
    hint: { zh: '至少一次走完之後，對手有一步殺的局數比例', en: 'Games where at least once the opponent had mate in one after your move' },
    lesson: { zh: '走之前先看：對手下一步能不能將死我', en: 'Before moving, check: can my opponent mate me next move?' },
    enough: (s) => s.games >= 10,
  },
  hungRate: {
    trend: 'skill', better: 'lower', format: 'pct', event: 'hung', drill: 'hanging',
    label: { zh: '送子', en: 'Hung pieces' },
    hint: { zh: '至少送子一次的局數比例（走完之後有子沒人保護、對手可以直接吃）', en: 'Games with at least one piece left undefended and takeable after your move' },
    lesson: { zh: '走之前先看：這步走完，哪個子沒人保護', en: 'Before moving, check: after this move, which piece is left undefended?' },
    enough: (s) => s.games >= 10,
  },
  missedFreeRate: {
    trend: 'skill', better: 'lower', format: 'pct', event: 'missed_free', drill: 'missed_free',
    label: { zh: '漏吃', en: 'Missed free pieces' },
    hint: { zh: '對手的子沒人保護，你沒吃', en: 'An undefended enemy piece you did not take' },
    lesson: { zh: '每一步先看：對手有沒有子沒人保護', en: "Every move, check first: is any of your opponent's pieces undefended?" },
    enough: (s) => s.freeChances >= 8,
  },
  convertRate: {
    trend: 'habit', better: 'higher', format: 'pct', event: 'threw_lead',
    label: { zh: '多子贏下', en: 'Converted when a piece up' },
    hint: { zh: '子力領先 3 分以上（約多一個馬或象）的局，最後有贏', en: 'Games where you were 3+ points ahead (about a knight or bishop) and won' },
    lesson: { zh: '領先之後，先換子，局面越簡單越好收', en: 'When ahead, trade pieces: the simpler the position, the easier to win' },
    enough: (s) => s.leadGames >= 3,
  },
  missedChanceRate: {
    trend: 'skill', better: 'lower', format: 'pct', event: 'missed_free', drill: 'missed_free',
    label: { zh: '錯過關鍵機會', en: 'Missed key chances' },
    hint: { zh: '至少一次有一步殺沒走、或對手的子沒人保護卻沒吃的局數比例', en: 'Games where you at least once missed a mate in one or a free piece' },
    lesson: { zh: '每一步先看：能不能將殺、有沒有白吃的子', en: 'Every move, check first: is there a mate, or a free piece to take?' },
    enough: (s) => s.games >= 10,
  },
  leadTimeoutRate: {
    trend: 'habit', better: 'lower', format: 'pct',
    label: { zh: '多子超時', en: 'Lost on time when a piece up' },
    hint: { zh: '子力領先 3 分以上的局，最後超時輸掉', en: 'Games 3+ points ahead that were lost on time' },
    lesson: { zh: '領先之後走簡單的步、換子，別把時間花光', en: 'When ahead, play simple moves and trade; do not burn the clock' },
    enough: (s) => s.leadGames >= 3,
  },
  timeoutLossRate: {
    trend: 'habit', better: 'lower', format: 'pct',
    label: { zh: '超時輸棋', en: 'Lost on time' },
    hint: { zh: '所有對局裡，超時輸掉的比例', en: 'Share of all games lost on time' },
    lesson: { zh: '每一步給自己一個時間上限，剩三成時間就加快', en: 'Give each move a time budget; speed up with 30% of the clock left' },
    enough: (s) => s.games >= 10,
  },
  matedEarlyRate: {
    trend: 'skill', better: 'lower', format: 'pct',
    label: { zh: '開局就被將死', en: 'Mated early' },
    hint: { zh: '自己走不到 20 步就被將死的比例', en: 'Checkmated before your 20th move' },
    lesson: { zh: '出子前先顧好王：別太早出后，早點入堡', en: 'Keep the king safe first: no early queen raids, castle early' },
    enough: (s) => s.games >= 10,
  },
  abandonRate: {
    trend: 'habit', better: 'lower', format: 'pct',
    label: { zh: '斷線、放棄', en: 'Abandoned' },
    hint: { zh: '因為斷線或離開而輸掉的比例', en: 'Games lost by disconnecting or leaving' },
    lesson: { zh: '下之前確認網路與時間，下了就下完', en: 'Check your connection and time before starting, then finish the game' },
    enough: (s) => s.games >= 10,
  },
};

/** 處方卡除了優先指標，也列出這些給使用者看（不拿來挑「先學的一件事」） */
const EXTRA: MetricKey[] = ['convertRate', 'leadTimeoutRate', 'timeoutLossRate', 'matedEarlyRate', 'hungRate', 'missedChanceRate', 'allowedMateRate', 'abandonRate'];

/**
 * 各分段優先看的指標（landing-by-elo.md 第 3 節）。
 *
 * 漏吃（missedFreeRate）暫不上處方卡：對引擎校正只有 67% 同意，低於 70% 門檻
 * （scripts/calibrate-signals.ts，每段 30 局）。送子 88%、一步殺 100%。
 */
const PRIORITY: Record<BandId, MetricKey[]> = {
  A: ['missedChanceRate', 'allowedMateRate', 'hungRate'],
  B: ['hungRate', 'allowedMateRate', 'missedChanceRate'],
  C: ['convertRate', 'hungRate', 'missedChanceRate'],
  D: ['convertRate', 'hungRate', 'missedChanceRate'],
  E: ['convertRate', 'allowedMateRate', 'missedChanceRate'],
  F: ['convertRate', 'allowedMateRate', 'missedChanceRate'],
};

/**
 * 比下一段差不到一整個「分段間距」（相鄰兩段平均差多少）就不算要補：
 * 20 局的樣本裡，送子 30% 對 29% 這種差距是誤差，標「先補這項」會誤導
 */
export const AT_LEVEL = 1;

/** 規則訊號至少要這麼多局才下結論 */
export const MIN_GAMES = 10;

export interface MetricRow {
  key: MetricKey;
  mine: number;
  same: number;
  next: number;
  enough: boolean;
  /** 不是優先指標：只列出來看，不拿來挑 */
  extra?: boolean;
  /** 標準化差距：比下一個分段差多少個「分段間距」，正數 = 比下一段差 */
  gap: number;
}

export interface Prescription {
  band: Band;
  /** 對照的細分段（每 200 分）：同分段與下一段 */
  same: CompareBand;
  next: CompareBand;
  rating: number;
  games: number;
  rows: MetricRow[];
  pick: MetricRow;
  /** gap：還沒到下一個分段；ahead：差一點點；ready：優先指標都已經達到（或超過）目標，不用特別補 */
  status: 'gap' | 'ahead' | 'ready';
  example?: SignalEvent;
}

/** 分段之間的平均間距，用來把不同單位的指標放在同一把尺上比 */
export const BAND_SPREAD = (key: MetricKey) => spread(key);
function spread(key: MetricKey): number {
  const a = BAND_BASELINES[0][key];
  const d = BAND_BASELINES[BAND_BASELINES.length - 1][key];
  return Math.max(Math.abs(a - d) / (BAND_BASELINES.length - 1), 1e-6);
}

export function prescribe(rating: number, s: SignalSummary, events: SignalEvent[]): Prescription | null {
  if (s.games < MIN_GAMES) return null;
  const band = bandOf(rating);
  const ci = compareOf(rating);
  const sameB = COMPARE_BANDS[ci];
  const nextB = COMPARE_BANDS[Math.min(ci + 1, COMPARE_BANDS.length - 1)];

  const keys = [...PRIORITY[band.id], ...EXTRA.filter((k) => !PRIORITY[band.id].includes(k))];
  const rows: MetricRow[] = keys.map((key) => {
    const dir = METRICS[key].better === 'lower' ? 1 : -1;
    // 習慣型指標不隨分數變好，差距跟同分段比
    const target = METRICS[key].trend === 'skill' ? nextB.base[key] : sameB.base[key];
    return {
      key,
      mine: s[key],
      same: sameB.base[key],
      next: nextB.base[key],
      enough: METRICS[key].enough(s),
      extra: !PRIORITY[band.id].includes(key),
      gap: (dir * (s[key] - target)) / spread(key),
    };
  });

  const usable = rows.filter((r) => r.enough && !r.extra);
  if (!usable.length) return null;
  const pick = usable.reduce((a, b) => (b.gap > a.gap ? b : a));

  // 範例局面：挑還沒分出勝負的那一個，離均勢最近的最有說服力
  const kind = METRICS[pick.key].event;
  const example = !kind ? undefined : events
    .filter((e) => e.kind === kind)
    .reduce<SignalEvent | undefined>((best, e) => (!best || Math.abs(e.lead) < Math.abs(best.lead) ? e : best), undefined);

  return {
    band, same: sameB, next: nextB, rating, games: s.games, rows, pick,
    status: usable.every((r) => r.gap <= 0) ? 'ready' : pick.gap > AT_LEVEL ? 'gap' : 'ahead',
    example,
  };
}

/** 表格格子裡的數字。每局次數的單位寫在指標說明裡，格子只放數字，手機才排得下 */
export function formatMetric(key: MetricKey, v: number): string {
  return METRICS[key].format === 'pct' ? `${Math.round(v * 100)}%` : v.toFixed(2);
}
