/**
 * 每一步花了多少時間：從棋譜裡的時鐘紀錄算（Chess.com、Lichess 的 PGN 每一步後面都有 [%clk h:mm:ss]）。
 * 用時 = 同一方上一步走完時的剩餘時間 − 這一步走完時的剩餘時間 + 每步加秒。
 * 不用重跑引擎；沒有時鐘紀錄（或數量對不上）的對局回傳 null，畫面上就不顯示時間。
 */

export interface MoveTime {
  /** 這一步用了幾秒 */
  spent: number;
  /** 走完之後剩幾秒 */
  clock: number;
  /** 剩餘時間佔開局時間的比例（0–1），判斷是不是快沒時間 */
  left: number;
}

const cache = new Map<string, MoveTime[] | null>();

/** timeControl：「600」或「600+5」（秒，＋每步加秒） */
export function moveTimes(pgn: string, timeControl?: string): MoveTime[] | null {
  const key = `${timeControl ?? ''}|${pgn}`;
  if (cache.has(key)) return cache.get(key)!;
  const out = compute(pgn, timeControl);
  if (cache.size > 300) cache.clear();
  cache.set(key, out);
  return out;
}

function compute(pgn: string, timeControl?: string): MoveTime[] | null {
  const [baseStr, incStr] = (timeControl ?? '').split('+');
  const base = Number(baseStr);
  if (!base || !Number.isFinite(base)) return null; // 通信棋（1/86400）之類沒有固定時間
  const inc = Number(incStr) || 0;
  const body = pgn.replace(/^\[.*\]\s*$/gm, '');
  const clocks: number[] = [];
  for (const m of body.matchAll(/%clk\s+(\d+):(\d+):(\d+(?:\.\d+)?)/g)) {
    clocks.push(Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]));
  }
  // 時鐘數要跟步數一樣，不然對不準
  const plies = body.replace(/\{[^}]*\}/g, ' ').replace(/\([^)]*\)/g, ' ').replace(/\d+\.(\.\.)?/g, ' ')
    .split(/\s+/).filter((t) => t && !/^(1-0|0-1|1\/2-1\/2|\*)$/.test(t)).length;
  if (!clocks.length || clocks.length !== plies) return null;
  return clocks.map((clock, i) => {
    const prev = i >= 2 ? clocks[i - 2] : base;
    return { spent: Math.max(0, Math.round((prev - clock + inc) * 10) / 10), clock, left: clock / base };
  });
}

/** 「12 秒」「1 分 05 秒」「0.4 秒」 */
export function formatSpent(s: number, en = false): string {
  if (s < 10) return en ? `${s.toFixed(1)}s` : `${s.toFixed(1)} 秒`;
  if (s < 60) return en ? `${Math.round(s)}s` : `${Math.round(s)} 秒`;
  const m = Math.floor(s / 60), r = Math.round(s % 60);
  return en ? `${m}m ${String(r).padStart(2, '0')}s` : `${m} 分 ${String(r).padStart(2, '0')} 秒`;
}

/** 走得太快：不到 5 秒就走（關鍵步上最常見的問題之一） */
export const FAST = 5;
/** 快沒時間：剩不到開局時間的 10% */
export const LOW_TIME = 0.1;

/** 走法列表用的短格式：「4s」「12s」「1:05」 */
export function shortSpent(s: number): string {
  if (s < 60) return `${s < 10 ? s.toFixed(1) : Math.round(s)}s`;
  return `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, '0')}`;
}
