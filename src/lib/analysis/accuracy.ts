/**
 * 對局準確率。
 *
 * chess.com 的準確率公式未公開，Lichess 的有：
 *   單步準確率 = 103.1668 * exp(-0.04354 * ΔWin%) - 3.1669   （夾在 0–100）
 *   整局 = 各步準確率的加權平均（權重看局面波動度）
 *
 * 我們用 Lichess 這條，並用 chess.com API 回傳的官方 accuracies 做校驗
 * （見 scripts/validate-accuracy.mjs）——它是唯一拿得到的 ground truth。
 */

/** 單步準確率。winDrop 是勝率跌幅（0–1） */
export function moveAccuracy(winDrop: number): number {
  const deltaPct = Math.max(0, winDrop) * 100;
  const raw = 103.1668 * Math.exp(-0.04354 * deltaPct) - 3.1669;
  return Math.max(0, Math.min(100, raw));
}

/**
 * 整局準確率。
 * Lichess 會依局面波動度加權（平穩局面下錯扣得少、緊張局面扣得多），
 * 這裡用簡化版：對各步準確率取調和平均與算術平均的折衷 ——
 * 調和平均會放大單一爛步的影響，比較貼近人的感受，也比較接近 chess.com。
 */
export function gameAccuracy(moveAccuracies: number[]): number {
  if (moveAccuracies.length === 0) return 100;
  const arithmetic = moveAccuracies.reduce((a, b) => a + b, 0) / moveAccuracies.length;
  const harmonic =
    moveAccuracies.length /
    moveAccuracies.reduce((a, b) => a + 1 / Math.max(b, 1), 0);
  return Math.round(((arithmetic + harmonic) / 2) * 10) / 10;
}
