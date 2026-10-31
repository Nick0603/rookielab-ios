/**
 * D-08：勝率是主要的顯示方式；復盤時另外附上引擎評分（+1.3 / M3）給想看分數的人。
 *
 * centipawn 的致命缺陷：「在贏定局面損失 100cp」與「在均勢局面損失 100cp」
 * 數字相同但意義完全不同。勝率沒有這個問題，而且對新手直覺得多。
 */

/**
 * centipawn → 勝率。用 Lichess 公開的實證擬合公式：
 *   Win% = 50 + 50 * (2 / (1 + exp(-0.00368208 * cp)) - 1)
 *
 * 為什麼不用課本上的 1/(1+10^(-c/4))：後者是理論推導，前者是拿真實對局
 * 資料擬合出來的，在實際局面上貼合得多。chess.com 的 Expected Points Model
 * 未公開，但同樣是資料驅動，用 Lichess 這條會比理論式更接近它。
 *
 * 參數 cp 以 centipawn 為單位（100 = 一個兵）。
 */
const K = 0.00368208;

export function cpToWinProb(cp: number): number {
  return 1 / (1 + Math.exp(-K * cp));
}

/** cpToWinProb 的反函數：舊快取只存勝率，反推回 cp。勝率 0 或 1 是將殺，反推不出步數 */
export function winProbToCp(p: number): number | null {
  if (p <= 0 || p >= 1) return null;
  return Math.log(p / (1 - p)) / K;
}

/** 引擎評分的文字（白方視角）：+1.3、-0.4、M3、-M2 */
export function formatEval(e: { cp?: number; mate?: number }): string {
  if (e.mate !== undefined) return e.mate < 0 ? `-M${-e.mate}` : `M${e.mate}`;
  const v = (e.cp ?? 0) / 100;
  const t = Math.abs(v) >= 10 ? Math.abs(v).toFixed(0) : Math.abs(v).toFixed(1);
  return t === '0.0' ? '0.0' : `${v > 0 ? '+' : '-'}${t}`;
}

export function evalToWinProb(cp: number | undefined, mate: number | undefined): number {
  if (mate !== undefined) return mate > 0 ? 1 : 0;
  if (cp === undefined) return 0.5;
  return cpToWinProb(cp);
}

/**
 * 終局局面引擎不會回評估（沒有合法走法可搜），evalToWinProb 會退回 0.5。
 * 若不特別處理，「將死對手」那一步會被算成勝率 100→50 而誤判成失誤 ——
 * 等於告訴使用者「你贏的那一步搞砸了」。
 */
export function terminalWinProb(
  isCheckmate: boolean,
  isDraw: boolean,
  moverIsMe: boolean,
): number | null {
  if (isCheckmate) return moverIsMe ? 1 : 0; // 走完就將死 → 走的人贏
  if (isDraw) return 0.5;
  return null;
}

/** 引擎評估一律以走棋方為視角，轉成「我方」視角 */
export function toMyPerspective(winProbForMover: number, moverIsMe: boolean): number {
  return moverIsMe ? winProbForMover : 1 - winProbForMover;
}

export const formatPct = (p: number): string => `${Math.round(p * 100)}%`;

/**
 * 依勝率跌幅分級。用勝率而非 centipawn 分級，是刻意的：
 * 在已經輸定的局面再掉 300cp 不該被標成 blunder，那對學習沒有意義。
 */
export type MoveGrade = 'blunder' | 'mistake' | 'inaccuracy' | 'ok';

export function gradeByWinProbDrop(drop: number): MoveGrade {
  // 門檻對齊 chess.com 官方公布的 Expected Points 損失
  // （Blunder ≥ 0.20、Mistake ≥ 0.10、Inaccuracy ≥ 0.05）
  if (drop >= 0.20) return 'blunder';
  if (drop >= 0.10) return 'mistake';
  if (drop >= 0.05) return 'inaccuracy';
  return 'ok';
}

/**
 * 顯示用的引擎分數（從「你」的角度：正數你較好，1 分約一個兵，M3 = 三步殺）。
 * 全站對外一律用分數，不顯示勝率；勝率只留在內部算分類。
 * win 是我方視角勝率；ev 是引擎原始評分（白方視角，有的話才帶得出幾步殺），me 是我方顏色。
 */
export function scoreText(win: number, ev?: { cp?: number; mate?: number }, me?: 'w' | 'b'): string {
  const sign = me === 'b' ? -1 : 1;
  if (ev && me) {
    if (ev.mate !== undefined) return formatEval({ mate: ev.mate * sign });
    if (ev.cp !== undefined) return formatEval({ cp: ev.cp * sign });
  }
  const cp = winProbToCp(win);
  if (cp === null) return win >= 1 ? 'M' : '-M';
  return formatEval({ cp: Math.round(cp) });
}

/** 一步棋前後的分數：「+1.9 → +0.2」 */
export function scoreChange(r: { ply?: number; winBefore: number; winAfter: number; evalBefore?: { cp?: number; mate?: number }; evalAfter?: { cp?: number; mate?: number } }, meArg?: 'w' | 'b'): string {
  // 走這步的是誰：第奇數個半步是白方
  const me = meArg ?? (r.ply ? (r.ply % 2 === 1 ? 'w' : 'b') : undefined);
  return `${scoreText(r.winBefore, r.evalBefore, me)} → ${scoreText(r.winAfter, r.evalAfter, me)}`;
}
