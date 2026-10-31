import { Chess } from 'chess.js';
import type { BlunderType } from '../types';
import type { Lang } from '../i18n/lang';

const VALUE: Record<string, number> = { p: 1, n: 3, b: 3, r: 5, q: 9, k: 0 };

/** 把 UCI 走法（e2e4、e7e8q）套到某個局面，回傳 SAN 與該步詳情 */
export function uciToSan(fen: string, uci: string) {
  if (!uci || uci.length < 4) return null;
  const chess = new Chess(fen);
  try {
    return chess.move({
      from: uci.slice(0, 2),
      to: uci.slice(2, 4),
      promotion: uci.length > 4 ? uci[4] : undefined,
    });
  } catch {
    return null;
  }
}

/** 把 UCI 主要變化轉成 SAN，並截斷到 maxPlies 步（D-05：只呈現前 3–4 步） */
export function pvToSan(fen: string, pv: string[], maxPlies = 4): string[] {
  const chess = new Chess(fen);
  const out: string[] = [];
  for (const uci of pv.slice(0, maxPlies)) {
    try {
      const m = chess.move({
        from: uci.slice(0, 2),
        to: uci.slice(2, 4),
        promotion: uci.length > 4 ? uci[4] : undefined,
      });
      if (!m) break;
      out.push(m.san);
    } catch {
      break;
    }
  }
  return out;
}

export interface ClassifyInput {
  /** 我走之前的局面 */
  fenBefore: string;
  /** 我走之後的局面 */
  fenAfter: string;
  /** 我實際走的（verbose move） */
  played: { from: string; to: string; piece: string; captured?: string; san: string };
  /** 我走之前，引擎認為的最佳步（UCI） */
  bestBefore?: string;
  /** 我走之後，對手的最佳應手（UCI）—— 也就是「怎麼懲罰我」 */
  punish?: string;
  /** 我走之後的主要變化（UCI），用來看幾步內是否失子 */
  pvAfter?: string[];
  /** 我走之前引擎回報的 mate 分數（正 = 我方可將死對方） */
  mateBefore?: number;
  /** 我走之後引擎回報的 mate 分數（以對手為視角，正 = 對手可將死我） */
  mateAfter?: number;
}

const VALUE_OF = (p?: string) => (p ? (VALUE[p] ?? 0) : 0);

/**
 * 沿著主要變化走，看我方在這幾步內淨損失多少子力。
 * 用來把「沒有立刻被吃、但幾步內就失子」的情況從 positional 撈出來。
 */
function materialLossInLine(fenAfter: string, pv: string[], maxPlies = 6): number {
  const chess = new Chess(fenAfter);
  const myColor = chess.turn() === 'w' ? 'b' : 'w'; // fenAfter 換手了，對手先走
  let net = 0;
  for (const uci of pv.slice(0, maxPlies)) {
    let m;
    try {
      m = chess.move({
        from: uci.slice(0, 2), to: uci.slice(2, 4),
        promotion: uci.length > 4 ? uci[4] : undefined,
      });
    } catch { break; }
    if (!m) break;
    if (m.captured) net += m.color === myColor ? VALUE_OF(m.captured) : -VALUE_OF(m.captured);
  }
  return -net; // 正數 = 我方淨損失
}

/**
 * 判定失誤屬於哪一類。
 * D-06：全部是確定性判斷，不經 LLM。LLM 只負責把結論講成人話。
 */
export function classifyBlunder(input: ClassifyInput): BlunderType {
  const { fenBefore, fenAfter, played, bestBefore, punish, mateBefore, mateAfter, pvAfter } = input;

  // 走完之後對手有連將殺 —— 對新手最該優先指出的一種
  if (mateAfter !== undefined && mateAfter > 0) return 'allowed_mate';

  // 我本來有將殺卻沒走（且我走的不是將殺）
  if (mateBefore !== undefined && mateBefore > 0) {
    const best = bestBefore ? uciToSan(fenBefore, bestBefore) : null;
    if (best && played.san !== best.san) return 'missed_mate';
  }

  // 對手送子沒吃：我走之前，最佳步是吃掉一個沒人保護的子，而我沒吃
  if (bestBefore) {
    const best = uciToSan(fenBefore, bestBefore);
    if (best?.captured && !played.captured) {
      const boardBefore = new Chess(fenBefore);
      const defenders = boardBefore.attackers(best.to, boardBefore.turn() === 'w' ? 'b' : 'w');
      if (defenders.length === 0 && VALUE[best.captured] >= 3) return 'missed_free';
    }
  }

  if (punish) {
    const reply = uciToSan(fenAfter, punish);
    // 對手的最佳應手就是吃掉我剛走過去的那顆子
    if (reply?.captured && reply.to === played.to) {
      // 我這步本身是吃子 → 兌換算錯；不是吃子 → 純粹送子
      return played.captured ? 'bad_exchange' : 'hanging';
    }
    if (reply?.captured && VALUE[reply.captured] >= 3) return 'missed_threat';
  }

  // 沒有立刻被吃，但主要變化裡幾步內就淨失子 → 仍然是「漏看對手威脅」
  if (pvAfter && pvAfter.length > 0 && materialLossInLine(fenAfter, pvAfter) >= 2) {
    return 'missed_threat';
  }

  return 'positional';
}

export const BLUNDER_LABEL_ZH: Record<BlunderType, string> = {
  hanging: '送子',
  bad_exchange: '兌換算錯',
  missed_threat: '漏看對手威脅',
  missed_free: '對手送子沒吃',
  missed_mate: '自己有將殺沒走',
  allowed_mate: '走完被對手將死',
  positional: '局面判斷失誤',
};

export const BLUNDER_LABEL_EN: Record<BlunderType, string> = {
  hanging: 'Hung a piece',
  bad_exchange: 'Bad trade',
  missed_threat: "Missed the opponent's threat",
  missed_free: 'Missed a free piece',
  missed_mate: 'Missed a mate',
  allowed_mate: 'Walked into mate',
  positional: 'Positional error',
};

export const blunderLabel = (t: BlunderType, lang: Lang = 'zh') =>
  (lang !== 'zh' ? BLUNDER_LABEL_EN : BLUNDER_LABEL_ZH)[t];
