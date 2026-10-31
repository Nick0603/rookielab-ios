import { Chess } from 'chess.js';
import type { Engine } from '../engine/engine';
import type { AnalyzedGame, Blunder, EngineEval, GameSummary, MoveRecord } from '../types';
import { decideLossReason } from './lossReason';
import { classifyMove, isSacrifice } from './classification';
import { gameAccuracy, moveAccuracy } from './accuracy';
import { evalToWinProb, gradeByWinProbDrop, terminalWinProb, toMyPerspective } from './winprob';
import { classifyBlunder, pvToSan, uciToSan } from './classify';
import { isBrilliant } from './brilliant';

export interface AnalyzeOptions {
  depth?: number;
  /** 每分析完一步回報一次，供進度條用（US-B9） */
  onProgress?: (done: number, total: number) => void;
  signal?: AbortSignal;
}

const PIECE_VALUE: Record<string, number> = { p: 0, n: 3, b: 3, r: 5, q: 9, k: 0 };

/** 盤面上非兵的總子力 */
export function nonPawnMaterial(fen: string): number {
  const chess = new Chess(fen);
  let total = 0;
  for (const row of chess.board()) {
    for (const sq of row) if (sq) total += PIECE_VALUE[sq.type] ?? 0;
  }
  return total;
}

/**
 * 分階段用子力而非純步數。
 * 純步數版本（>30 步才算殘局）會讓多數對局根本走不到殘局，
 * 導致殘局樣本極小、失誤率被少數幾步放大。
 */
export function phaseOf(moveNumber: number, fen: string): 'opening' | 'middlegame' | 'endgame' {
  if (nonPawnMaterial(fen) <= 16) return 'endgame'; // 約等於雙方各剩一車一輕子
  if (moveNumber <= 10) return 'opening';
  return 'middlegame';
}

/**
 * 分析單局：逐步跑引擎、算勝率、找出失誤並分類。
 * 只分析「我方」的步數 —— 對手下得好不好不是這個產品要教的。
 */
export async function analyzeGame(
  game: GameSummary,
  engine: Engine,
  opts: AnalyzeOptions = {},
): Promise<AnalyzedGame> {
  const { depth = 12, onProgress, signal } = opts;

  const chess = new Chess();
  chess.loadPgn(game.pgn);
  const history = chess.history({ verbose: true });
  const myColor = game.color === 'white' ? 'w' : 'b';

  const winProb: number[] = [];
  const moves: MoveRecord[] = [];
  const blunders: Blunder[] = [];
  const phaseBlunders = { opening: 0, middlegame: 0, endgame: 0 };
  const phaseMoves = { opening: 0, middlegame: 0, endgame: 0 };

  let peakWinProb = 0;
  let peakPly = -1;
  let myMoveCount = 0;
  let missedOpponentBlunders = 0;

  const myPlies = history.filter((m) => m.color === myColor).length;
  let done = 0;

  for (let i = 0; i < history.length; i++) {
    if (signal?.aborted) break;
    const move = history[i];
    if (move.color !== myColor) continue;

    myMoveCount++;
    const moveNo = Math.floor(i / 2) + 1;
    const phase = phaseOf(moveNo, move.before);
    phaseMoves[phase]++;

    // 我走之前 & 走之後各評估一次，差額就是這一步的代價
    const before = await engine.analyse(move.before, depth);
    const wpBefore = toMyPerspective(evalToWinProb(before.cp, before.mate), true);

    // 終局局面引擎不回評估 → 必須自己判，否則「將死對手」那一步會被
    // 誤算成勝率 100→50 而標成失誤
    const boardAfter = new Chess(move.after);
    const terminal = terminalWinProb(boardAfter.isCheckmate(), boardAfter.isDraw(), true);

    const after = terminal === null
      ? await engine.analyse(move.after, depth)
      : { cp: undefined, mate: undefined, bestMove: undefined, pv: [], depth: 0 };

    // after 的評估是以「對手」為視角（換手了），要翻過來
    const wpAfter = terminal ?? toMyPerspective(evalToWinProb(after.cp, after.mate), false);

    winProb.push(wpAfter);
    if (wpAfter > peakWinProb) {
      peakWinProb = wpAfter;
      peakPly = i;
    }

    // 終局的一步（將死、逼和）不該被評分 —— 那是結果不是失誤
    const grade = terminal !== null ? 'ok' : gradeByWinProbDrop(wpBefore - wpAfter);

    // 對手送子我沒吃 —— 這是「漏看免費的棋」，單獨計數
    if (before.bestMove) {
      const best = uciToSan(move.before, before.bestMove);
      if (best?.captured && !move.captured) missedOpponentBlunders++;
    }

    const bestSanAll = before.bestMove ? uciToSan(move.before, before.bestMove)?.san : undefined;
    const punishSanAll = after.bestMove ? uciToSan(move.after, after.bestMove)?.san : undefined;
    const isBest = !!bestSanAll && bestSanAll === move.san;

    // 對手剛犯錯、我本來有機會取得勝勢 —— chess.com 的 Miss 就是這種情況
    const hadWinningChance = wpBefore >= 0.8 || (before.mate !== undefined && before.mate > 0);

    const cls0 = terminal !== null
      ? 'best'
      : classifyMove({
        winBefore: wpBefore,
        winAfter: wpAfter,
        isBest,
        isOnlyMove: false, // 需要 MultiPV 才能判斷，目前不開（會讓分析變慢一倍以上）
        hadWinningChance,
        isSacrifice: isSacrifice(boardAfter, move, after.bestMove),
      });

    // 傑出用盤面判斷（見 brilliant.ts）：棄子要是這一步造成的、對手吃得到、吃了我虧
    const nearBest = ['best', 'excellent', 'great', 'brilliant'].includes(cls0);
    const brilliant = nearBest && isBrilliant(move.before, move.san, { winBefore: wpBefore, winAfter: wpAfter } as MoveRecord);
    const cls = brilliant ? 'brilliant' : cls0 === 'brilliant' ? (isBest ? 'best' : 'excellent') : cls0;

    const acc = moveAccuracy(Math.max(0, wpBefore - wpAfter));

    if (grade === 'blunder') {
      const type = classifyBlunder({
        fenBefore: move.before,
        fenAfter: move.after,
        played: move,
        bestBefore: before.bestMove,
        punish: after.bestMove,
        pvAfter: after.pv,
        mateBefore: before.mate,
        mateAfter: after.mate,
      });

      blunders.push({
        ply: i + 1,
        move: move.san,
        best: bestSanAll ?? '',
        type,
        punishedBy: punishSanAll,
        winProbBefore: wpBefore,
        winProbAfter: wpAfter,
        line: pvToSan(move.after, after.pv, 4), // D-05：最多 4 步
      });
      phaseBlunders[phase]++;
    }

    moves.push({
      ply: i + 1,
      moveNumber: moveNo,
      san: move.san,
      cls,
      winBefore: wpBefore,
      winAfter: wpAfter,
      best: bestSanAll,
      punishedBy: punishSanAll,
      // 關鍵步解說要看得到交換結束、被困的子被吃掉，4 步常常不夠
      line: pvToSan(move.after, after.pv, 8),
      bestLine: pvToSan(move.before, before.pv, 8),
      blunderType: blunders.at(-1)?.ply === i + 1 ? blunders.at(-1)!.type : undefined,
      accuracy: acc,
      // 引擎回的是「輪到誰走」的視角：走之前輪到我、走之後輪到對手
      evalBefore: whiteEval(before, move.color === 'w'),
      evalAfter: terminal === null ? whiteEval(after, move.color !== 'w') : undefined,
    });

    done++;
    onProgress?.(done, myPlies);
  }

  const hasBlunderAfterPeak = blunders.some((b) => b.ply > peakPly);

  return {
    ...game,
    lossReason: decideLossReason({ ...game, winProb }, peakWinProb, hasBlunderAfterPeak),
    moves,
    accuracy: gameAccuracy(moves.filter((m) => m.cls !== 'book').map((m) => m.accuracy)),
    winProb,
    blunders,
    peakWinProb,
    myMoveCount,
    missedOpponentBlunders,
    phaseBlunders,
    phaseMoves,
  };
}

/** 引擎評分（輪到走的一方視角）→ 白方視角 */
function whiteEval(r: { cp?: number; mate?: number }, whiteToMove: boolean): EngineEval | undefined {
  const k = whiteToMove ? 1 : -1;
  if (r.mate !== undefined) return { mate: r.mate * k };
  if (r.cp !== undefined) return { cp: r.cp * k };
  return undefined;
}
