import type { AnalyzedGame, LossReason } from '../types';

/** 開局失利：我方第 12 手時勝率已經 ≤ 25%（約落後 2 分），之後再也沒回到 50% */
export const OPENING_MOVES = 12;
const OPENING_LOST = 0.25;
const RECOVERED = 0.5;

/** winProb：我方每一步之後的勝率（我方視角） */
export function lostInOpening(winProb: number[]): boolean {
  if (!winProb.length) return false;
  const at = Math.min(OPENING_MOVES, winProb.length) - 1;
  return winProb[at] <= OPENING_LOST && Math.max(...winProb.slice(at)) < RECOVERED;
}

/**
 * 輸棋主因。順序：曾經大優後又失誤（大優後翻盤）> 開局就落後沒追回來 > 超時 > 曾經大優 > 一路被壓著打。
 * 開局就落後、最後才超時的局，根本原因在開局。
 */
export function decideLossReason(
  g: Pick<AnalyzedGame, 'result' | 'termination' | 'winProb'>,
  peakWinProb: number,
  hasBlunderAfterPeak: boolean,
): LossReason | undefined {
  if (g.result !== 'loss') return undefined;
  if (peakWinProb >= 0.85 && hasBlunderAfterPeak) return 'threw_winning';
  if (lostInOpening(g.winProb)) return 'opening';
  if (/time|outoftime/i.test(g.termination ?? '')) return 'timeout';
  if (peakWinProb >= 0.85) return 'threw_winning';
  return 'outplayed';
}

/** 彙整用：快取裡的舊分析沒有「開局失利」這一類，從每步勝率補判 */
export function lossReasonOf(g: AnalyzedGame): LossReason | undefined {
  if (g.result !== 'loss') return undefined;
  if (g.lossReason === 'threw_winning') return 'threw_winning';
  if (lostInOpening(g.winProb)) return 'opening';
  return g.lossReason;
}
