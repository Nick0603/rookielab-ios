import { tl } from '@/lib/i18n/lang';
import { scoreText } from '../analysis/winprob';
import { Chess, type Color, type Move, type PieceSymbol, type Square } from 'chess.js';
import type { Lang } from '../i18n/lang';
import type { MoveRecord } from '../types';
import { EN_PIECE, moveTactics, opp, TACTIC_META, trappedTactics, VALUE, ZH_PIECE, type Tactic } from './tactics';
import { moveRelations } from './relations';
import { sacrificedPiece } from '../analysis/brilliant';
import { castleName, moveName } from '../moveName';

/**
 * 關鍵步解說：一句結論、幾句推理、兩條可以播放的延伸棋局。
 *
 * 全部是確定性判斷（D-06），從引擎給的兩條變化出發：
 *   你走的 → 對手最強的應手 → 接下來（record.line）
 *   該走的 → 接下來（record.bestLine）
 * 再用盤面規則說出「為什麼」：誰攻擊誰、誰沒保護、保護被移開、捉雙……
 */

export type Motif =
  | 'allowed_mate' | 'missed_mate'
  | 'hanging' | 'bad_exchange' | 'left_undefended' | 'ignored_threat' | 'opened_line' | 'lost_material'
  | 'tactic' | 'allowed_threat' | 'trapped'
  | 'missed_free' | 'missed_tactic' | 'missed_material'
  | 'positional'
  | 'good_sacrifice' | 'good_move';

export type MarkKind = 'threat' | 'defend' | 'best' | 'played';

export interface LineStep {
  san: string;
  from: Square;
  to: Square;
  /** 走完這步的局面 */
  fen: string;
  /** 這步是誰走的 */
  mine: boolean;
  caption: string;
}

export interface Variation {
  kind: 'played' | 'best';
  title: string;
  startFen: string;
  steps: LineStep[];
  /** 走完之後的結論，例：「你丟了馬，淨少 3 分」 */
  outcome: string;
  /** 子力結論跟引擎評估不一致時的補充，例：該走的那步丟了子，但勝率仍高 */
  note?: string;
  /** 子力淨得失（我方視角） */
  net: number;
  mate?: 'me' | 'opp';
}

export interface Explanation {
  motif: Motif;
  headline: string;
  reasons: string[];
  /** 畫在「走完這步」的局面上 */
  arrows: [Square, Square, MarkKind][];
  squares: [Square, MarkKind][];
  lines: Variation[];
  /** 給驗證腳本用：每個說法背後的事實 */
  facts: Record<string, unknown>;
}

const BAD = ['blunder', 'mistake', 'miss', 'inaccuracy'];

function tr(lang: Lang) {
  return (zh: string, en: string) => (lang !== 'zh' ? en : zh);
}

const pname = (t: PieceSymbol, lang: Lang) => (tl(lang, ZH_PIECE[t], EN_PIECE[t]));

/** 「你的 e5 馬」／「your knight on e5」 */
function whose(sq: Square, t: PieceSymbol, mine: boolean, lang: Lang) {
  return lang !== 'zh'
    ? `${mine ? 'your' : 'the opponent\'s'} ${EN_PIECE[t]} on ${sq}`
    : `${mine ? '你的' : '對手的'} ${sq} ${ZH_PIECE[t]}`;
}

function list(items: string[], lang: Lang) {
  if (items.length <= 1) return items.join('');
  return lang !== 'zh' ? `${items.slice(0, -1).join(', ')} and ${items.at(-1)}` : items.join('、');
}

function playSan(fen: string, san: string): Move | null {
  try { return new Chess(fen).move(san); } catch { return null; }
}

/** 代號＋白話：Nxe5（馬 f3 吃 e5 兵）；不知道走之前的局面就只給代號 */
const nm = (m: { san: string; before?: string } | null | undefined, lang: Lang) => {
  if (!m) return '';
  const name = m.before ? moveName(m.before, m.san, lang) : castleName(m.san, lang);
  return name ? (lang !== 'zh' ? `${m.san} (${name})` : `${m.san}（${name}）`) : m.san;
};

/** 一步棋的說明：誰、吃了什麼、將軍、捉雙、攻擊了什麼 */
function caption(fen: string, m: Move, me: Color, lang: Lang): string {
  const t = tr(lang);
  const mine = m.color === me;
  const who = mine ? t('你', 'You') : t('對手', 'Opponent');
  const bits: string[] = [];
  if (m.captured) bits.push(t(`吃掉${whose(m.to, m.captured, !mine, lang)}`, `takes ${whose(m.to, m.captured, !mine, lang)}`));
  if (m.promotion) bits.push(t(`升變成${ZH_PIECE[m.promotion]}`, `promotes to a ${EN_PIECE[m.promotion]}`));
  const after = new Chess(m.after);
  if (after.isCheckmate()) bits.push(t('將死', 'checkmate'));
  else if (after.isCheck()) bits.push(t('將軍', 'check'));
  const tac = moveTactics(fen, m.lan, mine ? me : opp(me))
    .filter((x) => ['fork', 'pawn_fork', 'pin', 'skewer', 'discovered'].includes(x.tag))[0];
  if (tac) bits.push(tacticText(tac, !mine, lang));
  else if (!m.captured) {
    const rel = moveRelations(fen, m.san);
    const hit = rel.attacks
      .filter((l) => l.target.type !== 'k' && (VALUE[l.target.type] > VALUE[m.piece] || new Chess(m.after).attackers(l.to, opp(m.color)).length === 0) && VALUE[l.target.type] >= 3)
      .sort((a, b) => VALUE[b.target.type] - VALUE[a.target.type])[0];
    if (hit) bits.push(t(`攻擊${whose(hit.to, hit.target.type, !mine, lang)}`, `attacks ${whose(hit.to, hit.target.type, !mine, lang)}`));
  }
  // 代號後面附白話（哪個子從哪走到哪、入堡），吃了什麼在後面的說明裡
  const name = moveName(fen, m.san, lang, false);
  const named = name ? `${m.san}${t(`（${name}）`, ` (${name})`)}` : m.san;
  return `${who} ${named}${bits.length ? t('：', ': ') + bits.join(t('，', ', ')) : ''}`;
}

/** 戰術的一句話；targetsMine = 被打的是我方 */
function tacticText(tac: Tactic, targetsMine: boolean, lang: Lang): string {
  const t = tr(lang);
  const names = tac.pieces.map((p) => whose(p.square, p.type, targetsMine, lang));
  const label = lang !== 'zh' ? TACTIC_META[tac.tag].en.toLowerCase() : TACTIC_META[tac.tag].zh;
  switch (tac.tag) {
    case 'fork':
    case 'pawn_fork':
      return t(`同時攻擊${list(names, lang)}（${label}）`, `attacks ${list(names, lang)} at once (${label})`);
    case 'pin':
      return t(`牽制${names[0]}，它後面是${names[1] ?? ''}`, `pins ${names[0]} to ${names[1] ?? ''}`);
    case 'skewer':
      return t(`串打${names[0]}，後面還有${names[1] ?? ''}`, `skewers ${names[0]}, with ${names[1] ?? ''} behind`);
    case 'discovered':
      return t(`打開線路攻擊${list(names, lang)}（${label}）`, `uncovers an attack on ${list(names, lang)} (${label})`);
    default:
      return label;
  }
}

/** 復盤播放時每一步的一句說明：誰走了什麼、吃了什麼、將軍、捉雙、攻擊了什麼 */
export function describeMove(fenBefore: string, san: string, me: Color, lang: Lang = 'zh'): string {
  const m = playSan(fenBefore, san);
  return m ? caption(fenBefore, m, me, lang) : san;
}

/**
 * 把一串 SAN 走成延伸棋局，並找出「交換結束」的那一步：
 * 最後一步如果是吃子、而且還吃得回來，就退回到上一個穩定的地方再算子力，
 * 不然會在交換到一半時說「你少了一個馬」。
 */
function buildLine(kind: Variation['kind'], title: string, startFen: string, sans: string[], me: Color, lang: Lang, captions = true): Variation {
  const t = tr(lang);
  const steps: LineStep[] = [];
  const moves: Move[] = [];
  let fen = startFen;
  for (const san of sans) {
    const m = playSan(fen, san);
    if (!m) break;
    steps.push({ san: m.san, from: m.from, to: m.to, fen: m.after, mine: m.color === me, caption: captions ? caption(fen, m, me, lang) : m.san });
    moves.push(m);
    fen = m.after;
  }

  // 從尾端一步一步退：最後一步是吃子、而且還吃得回來，就先不算它（交換還沒結束）。
  // 不要一口氣退到最後一個非吃子步，那會把整串交換都丟掉，連「錯過了什麼」都看不到
  let settled = moves.length;
  // 用便宜的子吃貴的子（例：馬吃車），就算被吃回來也是賺：留著，並把對手吃回來的那一下算進子力帳
  let recapture: Move | null = null;
  while (settled > 0) {
    const m = moves[settled - 1];
    if (!m.captured || new Chess(m.after).attackers(m.to, opp(m.color)).length === 0) break;
    if (VALUE[m.captured] > VALUE[m.piece]) { recapture = m; break; }
    settled--;
  }
  if (settled === 0 && moves.length > 0) settled = Math.min(1, moves.length);
  const kept = moves.slice(0, settled);
  const lost: PieceSymbol[] = [];
  const won: PieceSymbol[] = [];
  let net = 0;
  for (const m of kept) {
    const gain = (m.captured ? VALUE[m.captured] : 0) + (m.promotion ? VALUE[m.promotion] - 1 : 0);
    if (m.color === me) { net += gain; if (m.captured) won.push(m.captured); }
    else { net -= gain; if (m.captured) lost.push(m.captured); }
  }
  // 假設對手吃回剛剛吃子的那個子
  if (recapture) {
    if (recapture.color === me) { net -= VALUE[recapture.piece]; lost.push(recapture.piece); }
    else { net += VALUE[recapture.piece]; won.push(recapture.piece); }
  }
  const end = kept.length ? new Chess(kept.at(-1)!.after) : new Chess(startFen);
  const mate = end.isCheckmate() ? (end.turn() === me ? 'me' : 'opp') : undefined;

  const names = (ps: PieceSymbol[]) => list(ps.map((p) => pname(p, lang)), lang);
  let outcome: string;
  if (mate === 'me') outcome = t('你被將死。', 'You get checkmated.');
  else if (mate === 'opp') outcome = t('將死對手。', 'You deliver checkmate.');
  else if (!lost.length && !won.length && !kept.some((m) => m.promotion)) outcome = t('雙方都沒有丟子。', 'No material changes hands.');
  else {
    const parts: string[] = [];
    if (lost.length) parts.push(t(`你丟了${names(lost)}`, `you lose ${names(lost)}`));
    if (won.length) parts.push(t(`吃到${names(won)}`, `you win ${names(won)}`));
    // 升變也算子力（淨得失裡已經算進去，句子要說出來）
    const promos = kept.filter((m) => m.promotion);
    const myPromo = promos.filter((m) => m.color === me).map((m) => m.promotion!);
    const oppPromo = promos.filter((m) => m.color !== me).map((m) => m.promotion!);
    if (myPromo.length) parts.push(t(`你升變出${names(myPromo)}`, `you promote to ${names(myPromo)}`));
    if (oppPromo.length) parts.push(t(`對手升變出${names(oppPromo)}`, `the opponent promotes to ${names(oppPromo)}`));
    const verdict = net > 0 ? t(`淨賺 ${net} 分`, `net +${net}`) : net < 0 ? t(`淨少 ${-net} 分`, `net −${-net}`) : t('打平', 'even');
    outcome = lang !== 'zh'
      ? `${parts.join(', ').replace(/^./, (c) => c.toUpperCase())} (${verdict}).`
      : `${parts.join('，')}，${verdict}。`;
  }
  // 整條變化都播（子力結算到哪就播到哪）。以前播到最後一次吃子就停，後面安靜的步被切掉，
  // 變化看起來斷在半路，該走的那步只看到「丟了車」，看不到引擎為什麼還是選它
  return { kind, title, startFen, steps: steps.slice(0, Math.max(kept.length, Math.min(steps.length, 1))), outcome, net, mate };
}

/** 給首頁示範這類需要自己組延伸棋局的地方：同樣的逐步說明與子力結算 */
export function buildVariation(title: string, startFen: string, sans: string[], me: Color, lang: Lang = 'zh'): Variation {
  return buildLine('played', title, startFen, sans, me, lang);
}

const uciOf = (m: Move) => m.lan;

/** 該走的那步好在哪 */
function whyBest(fenBefore: string, best: Move, line: Variation, me: Color, lang: Lang, vs?: Variation, played?: Move, win?: { best: string; played: string }): string {
  const t = tr(lang);
  if (line.mate === 'opp') return t(`${nm(best, lang)} 開始可以將死對手。`, `${nm(best, lang)} starts a forced checkmate.`);
  const board = new Chess(fenBefore);
  if (best.captured && board.attackers(best.to, opp(me)).length === 0 && VALUE[best.captured] >= 1) {
    return t(`${nm(best, lang)} 直接吃掉${whose(best.to, best.captured, false, lang)}，它沒人保護。`,
      `${nm(best, lang)} simply takes ${whose(best.to, best.captured, false, lang)}, which was undefended.`);
  }
  const tac = moveTactics(fenBefore, uciOf(best), me).find((x) => x.side === 'chance' && ['fork', 'pawn_fork', 'pin', 'skewer', 'discovered'].includes(x.tag));
  if (tac) return `${nm(best, lang)} ${tacticText(tac, false, lang)}${t('。', '.')}`;
  // 救一個正被攻擊、保護不夠的子
  // 你走的也做到同一件事，就不能拿來當「比較好」的理由
  const saved = savedPiece(fenBefore, best, me);
  const playedSaved = played ? savedPiece(fenBefore, played, me) : null;
  if (saved && !(playedSaved && playedSaved.sq === saved.sq)) {
    return t(`${nm(best, lang)} 保住${whose(saved.sq, saved.type, true, lang)}，它原本正被攻擊。`,
      `${nm(best, lang)} saves ${whose(saved.sq, saved.type, true, lang)}, which was under attack.`);
  }
  if (line.net > 0) return t(`照這樣走，${line.outcome}`, `Following this line: ${line.outcome}`);
  if (vs && line.net - vs.net >= 1) {
    return t(`照這樣走，${line.outcome}比你走的多 ${line.net - vs.net} 分。`, `Following this line: ${line.outcome} That is ${line.net - vs.net} better than your move.`);
  }
  if (new Chess(best.after).isCheck()) {
    return t(`${nm(best, lang)} 將軍，搶到先手，對手只能先應付。`, `${nm(best, lang)} gives check and keeps the initiative.`);
  }
  const rel = moveRelations(fenBefore, best.san);
  const playedHits = played ? new Set(moveRelations(fenBefore, played.san).attacks.map((l) => l.to)) : new Set<string>();
  const hit = rel.attacks.filter((l) => l.target.type !== 'k' && VALUE[l.target.type] >= 3 && !playedHits.has(l.to))[0];
  if (hit) return t(`${nm(best, lang)} 攻擊${whose(hit.to, hit.target.type, false, lang)}，對手要先應付。`,
    `${nm(best, lang)} attacks ${whose(hit.to, hit.target.type, false, lang)}, so the opponent has to respond.`);
  if (rel.threats[0]) return t(`${nm(best, lang)} 準備 ${nm(rel.threats[0], lang)}。`, `${nm(best, lang)} prepares ${nm(rel.threats[0], lang)}.`);
  if (win) {
    return t(`差別在比較長遠的局面：${nm(best, lang)} 之後評分維持在 ${win.best}，你走的掉到 ${win.played}。`,
      `The difference is long-term: after ${nm(best, lang)} the score stays at ${win.best}; your move drops it to ${win.played}.`);
  }
  return t(`${nm(best, lang)} 是引擎認為最好的一步，局面保持得住。`, `${nm(best, lang)} is the engine's choice and keeps your chances.`);
}

/** 走之前正被攻擊、保護不夠的我方子（輕子以上），這一步走完不再有事 */
function savedPiece(fenBefore: string, m: Move, me: Color): { sq: Square; type: PieceSymbol } | null {
  const before = new Chess(fenBefore);
  const after = new Chess(m.after);
  for (const row of before.board()) {
    for (const x of row) {
      if (!x || x.color !== me || x.type === 'k' || VALUE[x.type] < 3) continue;
      if (!looseOn(before, x.square, x.type, me)) continue;
      const now = x.square === m.from ? m.to : x.square;
      const p = after.get(now);
      if (p && p.color === me && !looseOn(after, now, p.type, me)) return { sq: x.square, type: x.type };
    }
  }
  return null;
}

/** 這個子被吃會虧：沒人保護，或被更便宜的子攻擊，或攻擊比保護多 */
function looseOn(board: Chess, sq: Square, type: PieceSymbol, me: Color): boolean {
  const atk = board.attackers(sq, opp(me));
  if (!atk.length) return false;
  const def = board.attackers(sq, me);
  if (!def.length) return true;
  if (atk.some((s) => VALUE[board.get(s)!.type] < VALUE[type])) return true;
  return atk.length > def.length;
}

/** 兩格之間（不含端點）的格子，只算直線／斜線 */
function between(a: Square, b: Square): Square[] {
  const f1 = a.charCodeAt(0) - 97, r1 = Number(a[1]) - 1, f2 = b.charCodeAt(0) - 97, r2 = Number(b[1]) - 1;
  const df = Math.sign(f2 - f1), dr = Math.sign(r2 - r1);
  if (!(f1 === f2 || r1 === r2 || Math.abs(f2 - f1) === Math.abs(r2 - r1))) return [];
  const out: Square[] = [];
  for (let f = f1 + df, r = r1 + dr; f !== f2 || r !== r2; f += df, r += dr) out.push(`${String.fromCharCode(97 + f)}${r + 1}` as Square);
  return out;
}

/**
 * 該走的那步比你走的多拿幾分子力（兩條變化都走到交換結束才算）；該走的是將殺就回 99。
 * 復盤用來找「可以得子卻沒得到」的步，每一步都要算，所以不產生說明文字。
 */
export function materialGap(fenBefore: string, san: string, record: MoveRecord): number {
  const bestSans = record.bestLine?.length ? record.bestLine : record.best ? [record.best] : [];
  if (!bestSans.length || bestSans[0] === san) return 0;
  const me = new Chess(fenBefore).turn();
  const played = buildLine('played', '', fenBefore, [san, ...record.line], me, 'zh', false);
  const best = buildLine('best', '', fenBefore, bestSans, me, 'zh', false);
  if (best.mate === 'opp' && played.mate !== 'opp') return 99;
  return best.net - played.net;
}

/** captions = false：延伸棋局不產生逐步說明（很重）。只需要分類與結論時用，例如報告的關鍵步清單 */
export function explainMove(fenBefore: string, san: string, record: MoveRecord, lang: Lang = 'zh', captions = true): Explanation | null {
  const t = tr(lang);
  const board = new Chess(fenBefore);
  const me = board.turn();
  const played = playSan(fenBefore, san);
  if (!played) return null;
  const after = new Chess(played.after);
  const bad = BAD.includes(record.cls);

  const playedLine = buildLine('played', t(`你走的 ${san} 之後`, `After your ${san}`), fenBefore, [san, ...record.line], me, lang, captions);
  const bestSans = record.bestLine?.length ? record.bestLine : record.best ? [record.best] : [];
  const best = bestSans.length ? playSan(fenBefore, bestSans[0]) : null;
  const bestLine = best && best.san !== played.san
    ? buildLine('best', t(`該走的 ${nm(best, lang)}`, `The better ${nm(best, lang)}`), fenBefore, bestSans, me, lang, captions)
    : null;
  const reply = record.line[0] ? playSan(played.after, record.line[0]) : null;
  // 子力帳跟引擎評估對不上時補一句，不然「該走的那步淨少 5 分」會讓人看不懂
  // 對外一律用引擎分數（你的角度），不顯示勝率
  const sBefore = scoreText(record.winBefore, record.evalBefore, me);
  const sAfter = scoreText(record.winAfter, record.evalAfter, me);
  if (bestLine && !bestLine.mate && bestLine.net < 0) {
    bestLine.note = t(`子力雖然少了，這仍是引擎評估最好的走法（評分 ${sBefore}）。`, `Material is down, but this is still the engine's best option (score ${sBefore}).`);
  }
  if (!playedLine.mate && playedLine.net >= 0 && record.winBefore - record.winAfter >= 0.1) {
    playedLine.note = t(`子力沒有少，但評分掉到 ${sAfter}。`, `No material is lost, but the score drops to ${sAfter}.`);
  }

  const reasons: string[] = [];
  const arrows: Explanation['arrows'] = [];
  const squares: Explanation['squares'] = [];
  const facts: Record<string, unknown> = {};
  const lines = [playedLine, ...(bestLine ? [bestLine] : [])];
  const drop = t(`評分 ${sBefore} → ${sAfter}。`, `Score ${sBefore} → ${sAfter}.`);
  const bestReason = () => {
    if (!best || !bestLine) return '';
    if (playedLine.mate === 'me' && bestLine.mate !== 'me') return t(`${nm(best, lang)} 可以避開這個殺。`, `${nm(best, lang)} avoids the mate.`);
    return whyBest(fenBefore, best, bestLine, me, lang, playedLine, played, { best: sBefore, played: sAfter });
  };

  // ── 好棋：說出這步做到了什麼，播放接下來 ──
  if (!bad) {
    // 傑出：找出送出去的子。對手可能吃（播出吃了之後的結果），也可能不能吃（吃了更糟）
    const given = record.cls === 'brilliant' ? sacrificedPiece(fenBefore, san) : null;
    const sac = !!given;
    const taken = !!given && reply?.captured && reply.to === given.square;
    const tac = moveTactics(fenBefore, played.lan, me).find((x) => x.side === 'chance' && ['fork', 'pawn_fork', 'pin', 'skewer', 'discovered'].includes(x.tag));
    // 這步本身沒有戰術，但接下來有（例：Bxe7 Qxe7 之後 Nf5+ 捉雙）
    const next = !tac ? (() => {
      let f = fenBefore;
      const ms: Move[] = [];
      for (const st of playedLine.steps) { const m = playSan(f, st.san); if (!m) break; ms.push(m); f = m.after; }
      for (let i = 2; i < Math.min(ms.length, 6); i += 2) {
        const x = moveTactics(ms[i - 1].after, ms[i].lan, me).find((y) => y.side === 'chance' && ['fork', 'pawn_fork', 'pin', 'skewer', 'discovered'].includes(y.tag));
        if (x) return { m: ms[i], tac: x };
      }
      return null;
    })() : null;
    const why = after.isCheckmate()
      ? t(`${san} 將死對手。`, `${san} is checkmate.`)
      : playedLine.mate === 'opp'
      ? t(`${san} 開始連續將軍，對手逃不掉。`, `${san} starts a forced mate.`)
      // 傑出：先講送出了哪個子；同時有戰術就一起講（那通常就是對手不能吃的原因）
      : sac && taken ? t(`${san} 送出${whose(given!.square, given!.type, true, lang)}${tac ? `，同時${tacticText(tac, false, lang)}` : ''}。對手吃了之後：${playedLine.outcome}`,
        `${san} gives away ${whose(given!.square, given!.type, true, lang)}${tac ? `, and ${tacticText(tac, false, lang)}` : ''}. After the capture: ${playedLine.outcome}`)
      : sac ? t(`${san} 送出${whose(given!.square, given!.type, true, lang)}${tac ? `，同時${tacticText(tac, false, lang)}` : ''}。對手吃了會更糟，引擎建議的應手是 ${reply?.san ?? ''}。`,
        `${san} offers ${whose(given!.square, given!.type, true, lang)}${tac ? `, and ${tacticText(tac, false, lang)}` : ''}. Taking it would make things worse; the engine's reply is ${reply?.san ?? ''}.`)
      : tac ? `${san} ${tacticText(tac, false, lang)}${t('。', '.')}`
      : next ? t(`${san} 之後，對手應完你有 ${nm(next.m, lang)}，${tacticText(next.tac, false, lang)}。`,
        `After ${san} and the reply, you have ${nm(next.m, lang)}, which ${tacticText(next.tac, false, lang)}.`)
      : whyBest(fenBefore, played, playedLine, me, lang).replace(/^.*是引擎認為最好的一步，局面保持得住。$/,
        t(`${san} 是引擎的首選，評分維持在 ${sAfter}。`, `${san} is the engine's top choice; the score stays at ${sAfter}.`));
    reasons.push(why);
    if (!sac && playedLine.steps.length > 1 && (playedLine.net !== 0 || playedLine.mate)) reasons.push(t(`接下來：${playedLine.outcome}`, `What follows: ${playedLine.outcome}`));
    if (tac) for (const p of tac.pieces) squares.push([p.square, 'threat']);
    if (given) squares.push([given.square, 'best']);
    return {
      motif: sac ? 'good_sacrifice' : 'good_move',
      // 標題講出這步做到了什麼，不要只寫「好棋」
      headline: sac ? t('傑出：棄子換更大的收穫', 'Brilliant: a sound sacrifice')
        : after.isCheckmate() ? t('將殺', 'Checkmate')
        : playedLine.mate === 'opp' ? t('開始連續將軍', 'Starts a forced mate')
        : tac ? t(TACTIC_META[tac.tag].zh, TACTIC_META[tac.tag].en)
        : next ? t(`準備${TACTIC_META[next.tac.tag].zh}`, `Sets up a ${TACTIC_META[next.tac.tag].en.toLowerCase()}`)
        : t('好棋', 'Strong move'),
      reasons, arrows, squares, lines: [playedLine], facts: { tactic: tac?.tag, net: playedLine.net },
    };
  }

  // ── 以下是走差的步：先講最嚴重的 ──
  let motif: Motif = 'positional';
  let headline = t('局面變差', 'Position got worse');
  const lineMoves: Move[] = [];
  { let f = fenBefore; for (const st of playedLine.steps) { const m = playSan(f, st.san); if (!m) break; lineMoves.push(m); f = m.after; } }
  const gap = (bestLine?.net ?? 0) - playedLine.net;
  // 真的有子力損失，才講「丟子」類的原因；只是正常交換就不算
  const losesMaterial = playedLine.net <= -1 || gap >= 2;
  // 錯過的比丟掉的大：先講錯過的（例：沒吃白送的象，比丟一個兵嚴重）
  const missedBigger = !!bestLine && bestLine.net >= 3 && bestLine.net > -playedLine.net;
  const RISK = ['fork', 'pawn_fork', 'pin', 'skewer', 'discovered', 'mate_threat', 'back_rank'];
  const replyTactic = reply ? moveTactics(played.after, reply.lan, me).find((x) => x.side === 'risk' && RISK.includes(x.tag)) : undefined;

  /** 損失發生在幾步之後：保住某個子的機會沒把握、後面有捉雙，或只是一路被逼丟子 */
  const diagnoseLater = () => {
    const capOf = (m: Move) => caption(new Chess(m.before).fen(), m, me, lang) + t('。', '.');
    const oppCaps = lineMoves.filter((m, i) => i > 0 && m.color !== me && m.captured);
    const saved = best ? savedPiece(fenBefore, best, me) : null;
    // 那個子可能先逃到別格才被吃，所以比對子的種類
    const savedLost = saved && oppCaps.some((m) => m.captured === saved.type);
    const later = lineMoves.slice(1, 6).map((m, i) => ({ m, i: i + 1 })).filter(({ m }) => m.color !== me)
      .map(({ m, i }) => ({ m, tac: moveTactics(new Chess(lineMoves[i - 1].after).fen(), m.lan, me).find((x) => x.side === 'risk' && RISK.includes(x.tag)) }))
      .find((x) => x.tac);
    // 你移開的子原本擋在對手的攻擊線上（例：c6 兵擋著 f3 到 a8 的斜線）
    // 只看對手前兩手內的吃子：太後面的吃子跟這一步的因果太遠
    const through = oppCaps.find((m) => lineMoves.indexOf(m) <= 3 && between(m.from, m.to).includes(played.from as Square));
    // 對手趕幾步之後，你的子被困住（例：象被 f6、g5 兩個兵趕到沒地方去）
    const trapped = (() => {
      for (let i = 1; i < Math.min(lineMoves.length, 6); i++) {
        if (lineMoves[i].color === me) continue;
        // 正被將軍時子本來就動不了，那不是被困
        if (new Chess(lineMoves[i].after).inCheck()) continue;
        const tr = trappedTactics(lineMoves[i].after, me, me)[0];
        if (tr && oppCaps.some((m) => m.captured === tr.pieces[0].type)) return { by: lineMoves[i], piece: tr.pieces[0] };
      }
      return null;
    })();
    if (through) {
      motif = 'opened_line';
      headline = t('讓出了攻擊線', 'Opened a line for the opponent');
      reasons.push(t(`你的${pname(played.piece, lang)}原本擋在 ${played.from}，移開之後，對手的${pname(through.piece, lang)}可以從 ${through.from} 打到${whose(through.to, through.captured!, true, lang)}。`,
        `Your ${EN_PIECE[played.piece]} was blocking on ${played.from}. Moving it opens the line from ${through.from} to ${whose(through.to, through.captured!, true, lang)}.`));
      arrows.push([through.from, through.to, 'threat']);
      squares.push([played.from, 'threat']);
      reasons.push(capOf(through));
      facts.lostSquare = through.to;
    } else if (trapped) {
      motif = 'trapped';
      headline = t(`${pname(trapped.piece.type, lang)}被困住`, `Your ${EN_PIECE[trapped.piece.type]} gets trapped`);
      reasons.push(t(`走完這步，對手 ${nm(trapped.by, lang)} 之後，${whose(trapped.piece.square, trapped.piece.type, true, lang)}被困住：往哪走都會被吃。`,
        `After ${nm(trapped.by, lang)}, ${whose(trapped.piece.square, trapped.piece.type, true, lang)} is trapped: every square it can go to loses it.`));
      squares.push([trapped.piece.square, 'threat']);
      const took = oppCaps.find((m) => m.captured === trapped.piece.type);
      if (took) reasons.push(capOf(took));
      facts.trapped = trapped.piece.square;
    } else if (saved && savedLost) {
      motif = 'ignored_threat';
      headline = t('漏看對手的威脅', "Missed the opponent's threat");
      const b0 = new Chess(fenBefore);
      const atkNames = list(b0.attackers(saved.sq, opp(me)).map((sq) => whose(sq, b0.get(sq)!.type, false, lang)), lang);
      reasons.push(t(`走這步之前，${whose(saved.sq, saved.type, true, lang)}已經被${atkNames}攻擊，而且保護不夠。這步沒有處理它，幾步之後就被吃掉。`,
        `Before this move, ${whose(saved.sq, saved.type, true, lang)} was already attacked by ${atkNames} and not defended enough. It was not addressed and gets taken a few moves later.`));
      squares.push([saved.sq, 'threat']);
      const took = oppCaps.find((m) => m.captured === saved.type);
      if (took) reasons.push(capOf(took));
      facts.lostSquare = saved.sq;
    } else if (later) {
      motif = 'tactic';
      headline = t(`對手有${TACTIC_META[later.tac!.tag].zh}`, `Allowed a ${TACTIC_META[later.tac!.tag].en.toLowerCase()}`);
      reasons.push(t(`走完這步，對手可以走到 ${nm(later.m, lang)}，${tacticText(later.tac!, true, lang)}。`,
        `After this, the opponent gets ${nm(later.m, lang)}, which ${tacticText(later.tac!, true, lang)}.`));
      facts.tactic = later.tac!.tag;
    } else {
      motif = 'lost_material';
      headline = t('幾步之內會丟子', 'Loses material within a few moves');
      const lostNames = list(oppCaps.length ? oppCaps.map((m) => whose(m.to, m.captured!, true, lang)) : [], lang);
      reasons.push(reply
        ? t(`走完這步，對手從 ${nm(reply, lang)} 開始一路逼${lostNames ? `，接連吃掉${lostNames}` : ''}。`,
          `After this, the opponent starts with ${nm(reply, lang)} and keeps up the pressure${lostNames ? `, winning ${lostNames}` : ''}.`)
        : t('走完這步，幾步之內會丟子。', 'This loses material within a few moves.'));
    }
  };

  if (playedLine.mate === 'me' || record.blunderType === 'allowed_mate') {
    motif = 'allowed_mate';
    headline = t('走完被將殺', 'Walked into mate');
    const n = playedLine.steps.filter((s) => !s.mine).length;
    reasons.push(playedLine.mate === 'me'
      ? t(`走完這步，對手有 ${n} 步殺：${playedLine.steps.slice(1).map((s) => s.san).join(' ')}。`,
        `After this move the opponent mates in ${n}: ${playedLine.steps.slice(1).map((s) => s.san).join(' ')}.`)
      : t('走完這步，對手有連續將軍的殺法。', 'After this move the opponent has a forced mate.'));
    if (reply) arrows.push([reply.from, reply.to, 'threat']);
    const k = after.board().flat().find((x) => x?.type === 'k' && x.color === me);
    if (k) squares.push([k.square, 'threat']);
    facts.mateLen = n;
  } else if (bestLine?.mate === 'opp' || record.blunderType === 'missed_mate') {
    motif = 'missed_mate';
    headline = t('錯過將殺', 'Missed a mate');
    reasons.push(bestLine?.mate === 'opp'
      ? t(`這裡有將殺：${bestLine.steps.map((s) => s.san).join(' ')}。`, `There was a mate here: ${bestLine.steps.map((s) => s.san).join(' ')}.`)
      : t(`${best?.san ?? ''} 開始可以將死對手。`, `${best?.san ?? ''} starts a forced mate.`));
  } else if (losesMaterial && playedLine.net < 0 && !missedBigger) {
    // 找出真正造成損失的那一次吃子：跳過「我吃、他吃回來」的正常交換
    const k = lineMoves.findIndex((m, i) => m.color !== me && m.captured
      && !(i > 0 && lineMoves[i - 1].color === me && lineMoves[i - 1].captured && lineMoves[i - 1].to === m.to && i - 1 > 0));
    const c = k >= 0 ? lineMoves[k] : undefined;
    // 我這步是吃子、之後被吃回來：兌換算錯；不是吃子：送子
    const tradeAtStart = !!played.captured;
    if (replyTactic && !(reply?.captured)) {
      motif = 'tactic';
      headline = t(`對手有${TACTIC_META[replyTactic.tag].zh}`, `Allowed a ${TACTIC_META[replyTactic.tag].en.toLowerCase()}`);
      reasons.push(t(`走完這步，對手 ${reply!.san} ${tacticText(replyTactic, true, lang)}。`, `After this, ${reply!.san} ${tacticText(replyTactic, true, lang)}.`));
      arrows.push([reply!.from, reply!.to, 'threat']);
      for (const p of replyTactic.pieces) squares.push([p.square, 'threat']);
      facts.tactic = replyTactic.tag;
    } else if (c && c.to === played.to && (k === 1
      // 對手先將軍再吃：中間我沒把這個子移走，還是算送子
      || (lineMoves.slice(1, k).every((m) => m.color !== me || m.from !== played.to) && lineMoves.slice(1, k).some((m) => m.color !== me && m.san.includes('+'))))) {
      // 對手第一手就吃掉我剛走過去的子
      const atk = after.attackers(played.to, opp(me));
      const def = after.attackers(played.to, me);
      const cheap = atk.map((sq) => after.get(sq)!).filter((p) => VALUE[p.type] < VALUE[played.piece]);
      const atkNames = list(atk.map((sq) => whose(sq, after.get(sq)!.type, false, lang)), lang);
      for (const sq of atk) arrows.push([sq, played.to, 'threat']);
      for (const sq of def) arrows.push([sq, played.to, 'defend']);
      squares.push([played.to, 'threat']);
      facts.attackers = atk.length; facts.defenders = def.length;
      if (tradeAtStart) {
        motif = 'bad_exchange';
        headline = t('兌換算錯', 'Bad trade');
        reasons.push(t(`你用${pname(played.piece, lang)}吃了${whose(played.to, played.captured!, false, lang)}，但 ${played.to} 被${atkNames}守著。`,
          `You took ${whose(played.to, played.captured!, false, lang)} with your ${EN_PIECE[played.piece]}, but ${played.to} is covered by ${atkNames}.`));
      } else {
        motif = 'hanging';
        headline = t(`送子：${played.to} 的${pname(played.piece, lang)}`, `Hung the ${EN_PIECE[played.piece]} on ${played.to}`);
        reasons.push(t(`你把${pname(played.piece, lang)}走到 ${played.to}，這格被${atkNames}攻擊。`,
          `You moved your ${EN_PIECE[played.piece]} to ${played.to}, where ${atkNames} can take it.`));
      }
      reasons.push(def.length === 0
        ? t(`${played.to} 沒有任何你的子保護，對手 ${nm(c, lang)} 白吃。`, `Nothing of yours protects ${played.to}, so ${nm(c, lang)} wins it for free.`)
        : cheap.length
          ? t(`雖然有保護，但對手用比它便宜的${pname(cheap[0].type, lang)}吃，換下來還是你虧。`,
            `It is protected, but the opponent takes with a cheaper ${EN_PIECE[cheap[0].type]}, so the trade still costs you.`)
          : t(`攻擊 ${atk.length} 個、保護 ${def.length} 個，吃來吃去最後是你吃虧。`,
            `${atk.length} attacker(s) against ${def.length} defender(s): the exchanges end in the opponent's favor.`));
    } else if (c) {
      // 對手吃掉我別的子：找出為什麼那個子會沒人顧
      const xName = whose(c.to, c.captured!, true, lang);
      const wasThere = board.get(c.to);
      const same = wasThere && wasThere.color === me && wasThere.type === c.captured;
      const guardedBefore = same && board.attackers(c.to, me).includes(played.from);
      const guardedAfter = after.attackers(c.to, me).includes(played.to);
      squares.push([c.to, 'threat']);
      arrows.push([c.from, c.to, 'threat']);
      if (k === 1 && guardedBefore && !guardedAfter) {
        motif = 'left_undefended';
        headline = t('保護被移開', 'Removed a defender');
        reasons.push(t(`你的${pname(played.piece, lang)}原本在保護${xName}，走到 ${played.to} 之後，${xName}就沒人顧了。`,
          `Your ${EN_PIECE[played.piece]} was protecting ${xName}. After moving to ${played.to}, it no longer does.`));
        arrows.push([played.from, c.to, 'defend']);
        reasons.push(caption(c.before, c, me, lang) + t('。', '.'));
      } else if (k === 1 && between(c.from, c.to).includes(played.from as Square)) {
        motif = 'opened_line';
        headline = t('讓出了攻擊線', 'Opened a line for the opponent');
        reasons.push(t(`你的${pname(played.piece, lang)}原本擋在 ${played.from}，移開之後，對手的${pname(c.piece, lang)}可以直接打到${xName}。`,
          `Your ${EN_PIECE[played.piece]} was blocking on ${played.from}. Moving it lets the opponent reach ${xName}.`));
        reasons.push(caption(c.before, c, me, lang) + t('。', '.'));
      } else if (k === 1 && same && looseOn(board, c.to, c.captured!, me)) {
        motif = 'ignored_threat';
        headline = t('漏看對手的威脅', "Missed the opponent's threat");
        const atkNames = list(board.attackers(c.to, opp(me)).map((sq) => whose(sq, board.get(sq)!.type, false, lang)), lang);
        reasons.push(t(`走這步之前，${xName}已經被${atkNames}攻擊，而且保護不夠。這步沒有處理它。`,
          `Before this move, ${xName} was already attacked by ${atkNames} and not defended enough. This move did nothing about it.`));
        reasons.push(caption(c.before, c, me, lang) + t('。', '.'));
      } else {
        diagnoseLater();
      }
      facts.lostSquare = c.to;
      facts.lossPly = k;
    } else {
      diagnoseLater();
    }
  }

  // 沒有丟子：錯過機會，或讓對手有威脅
  if (motif === 'positional' && best && bestLine) {
    const bestTac = moveTactics(fenBefore, best.lan, me).find((x) => x.side === 'chance' && ['fork', 'pawn_fork', 'pin', 'skewer', 'discovered'].includes(x.tag));
    if (best.captured && board.attackers(best.to, opp(me)).length === 0 && VALUE[best.captured] >= 3 && bestLine.net > 0) {
      motif = 'missed_free';
      headline = t(`錯過白吃的${pname(best.captured, lang)}`, `Missed a free ${EN_PIECE[best.captured]}`);
      squares.push([best.to, 'best']);
    } else if (bestTac && gap >= 2) {
      motif = 'missed_tactic';
      headline = t(`錯過${TACTIC_META[bestTac.tag].zh}`, `Missed a ${TACTIC_META[bestTac.tag].en.toLowerCase()}`);
      for (const p of bestTac.pieces) squares.push([p.square, 'best']);
    } else if (gap >= 2) {
      motif = 'missed_material';
      headline = t('錯過得子的機會', 'Missed a chance to win material');
    }
  }
  // 錯過的比較大，但這步本身也會丟子：補一句後面的戰術
  if (['missed_free', 'missed_tactic', 'missed_material'].includes(motif) && playedLine.net < 0) {
    const later = lineMoves.slice(1, 6).map((m, i) => ({ m, i: i + 1 })).filter(({ m }) => m.color !== me)
      .map(({ m, i }) => ({ m, tac: moveTactics(lineMoves[i - 1].after, m.lan, me).find((x) => x.side === 'risk' && RISK.includes(x.tag)) }))
      .find((x) => x.tac);
    if (later) {
      reasons.push(t(`而且走完這步，對手可以走到 ${nm(later.m, lang)}，${tacticText(later.tac!, true, lang)}。`,
        `On top of that, the opponent gets ${nm(later.m, lang)}, which ${tacticText(later.tac!, true, lang)}.`));
    }
  }
  if (motif === 'positional' && reply) {
    const rel = moveRelations(played.after, reply.san);
    const hit = rel.attacks.filter((l) => l.target.type !== 'k' && VALUE[l.target.type] >= 3
      && (VALUE[l.target.type] > VALUE[reply.piece] || new Chess(reply.after).attackers(l.to, me).length === 0))[0];
    if (replyTactic || hit || rel.threats.some((x) => x.kind === 'mate') || new Chess(reply.after).isCheck()) {
      motif = 'allowed_threat';
      headline = t('讓對手有威脅', 'Gave the opponent a threat');
      const cap = caption(played.after, reply, me, lang);
      const mateThreat = rel.threats.find((x) => x.kind === 'mate');
      const extra = mateThreat
        ? t(`，準備 ${nm(mateThreat, lang)} 將死`, `, threatening ${nm(mateThreat, lang)} mate`)
        : hit && !cap.includes(hit.to)
          ? t(`，接著攻擊${whose(hit.to, hit.target.type, true, lang)}`, `, then attacks ${whose(hit.to, hit.target.type, true, lang)}`) : '';
      reasons.push(t(`走完這步，對手最強的應手是 ${cap}${extra}。`, `After this, the opponent's strongest reply is ${cap}${extra}.`));
      if (hit) squares.push([hit.to, 'threat']);
      arrows.push([reply.from, reply.to, 'threat']);
    }
  }
  if (motif === 'positional') {
    reasons.push(t('這步沒有馬上丟子，但讓局面明顯變差。', 'This move does not lose material right away, but the position gets clearly worse.'));
    if (reply) reasons.push(t(`對手最強的應手是 ${caption(played.after, reply, me, lang)}。`, `The opponent's strongest reply: ${caption(played.after, reply, me, lang)}.`));
  }
  if (playedLine.net >= 0 && !playedLine.mate) {
    // 走差了但子力沒吃虧：問題不在子力，別讓子力帳看起來像是賺了
    playedLine.outcome = t(`子力沒有吃虧，但評分從 ${sBefore} 掉到 ${sAfter}。`,
      `No material lost, but the score drops from ${sBefore} to ${sAfter}.`);
    // 結論已經講了評分掉多少，補充說明不用再講一次
    playedLine.note = undefined;
  }
  // 錯過類：先講該走的那步，才知道錯過了什麼
  const missed = ['missed_free', 'missed_tactic', 'missed_material'].includes(motif);
  const br = bestReason();
  // bestReason 多半以「Qb4+（后 e7→b4）…」開頭，就不再重複代號
  if (missed && br) reasons.unshift(br.startsWith(best!.san) ? t('該走 ', 'The move was ') + br : t(`該走 ${nm(best, lang)}：`, `The move was ${nm(best, lang)}: `) + br);
  if (playedLine.steps.length > 1 && playedLine.net < 0 && motif !== 'allowed_mate') {
    reasons.push(t(`照引擎的變化走下去：${playedLine.outcome}`, `Following the engine's line: ${playedLine.outcome}`));
  }
  if (br && !missed) reasons.push(t(`比較好的是 ${best!.san}：`, `Better was ${best!.san}: `) + br);
  if (best && best.san !== played.san) arrows.push([best.from, best.to, 'best']);
  reasons.push(drop);

  facts.playedNet = playedLine.net;
  facts.bestNet = bestLine?.net;
  const seen = new Set<string>();
  const marks = arrows.filter(([a, b]) => !seen.has(a + b) && !!seen.add(a + b));
  return { motif, headline, reasons, arrows: marks, squares, lines, facts };
}

/**
 * 換成另一方的角度：解說是從「走這步的人」講的（你、對手）。講對手的失誤時，
 * 用對手的角度產生，再把「你／對手」對調，讀起來就是「對手錯在哪、你可以怎麼懲罰」。
 */
export function swapVoice(e: Explanation, lang: Lang): Explanation {
  const sw = lang !== 'zh'
    ? (s: string) => s
      .replace(/\bthe opponent's\b/g, '\u0001').replace(/\bThe opponent's\b/g, '\u0002')
      .replace(/\bthe opponent\b/g, '\u0003').replace(/\bThe opponent\b/g, '\u0004')
      .replace(/\byour\b/g, "the opponent's").replace(/\bYour\b/g, "The opponent's")
      .replace(/\byou\b/g, 'the opponent').replace(/\bYou\b/g, 'The opponent')
      .replace(/\u0001/g, 'your').replace(/\u0002/g, 'Your').replace(/\u0003/g, 'you').replace(/\u0004/g, 'You')
    : (s: string) => s.replace(/對手/g, '\u0001').replace(/你/g, '對手').replace(/\u0001/g, '你');
  return {
    ...e,
    headline: sw(e.headline),
    reasons: e.reasons.map(sw),
    lines: e.lines.map((l) => ({
      // 「吃到兵，淨賺 1 分」沒有主詞，換了角度要補上「對手」
      ...l, title: sw(l.title), note: l.note ? sw(l.note) : undefined,
      outcome: lang !== 'zh' ? sw(l.outcome) : /^(吃到|淨|打平)/.test(l.outcome) ? `對手${sw(l.outcome)}` : sw(l.outcome),
      steps: l.steps.map((s) => ({ ...s, caption: sw(s.caption), mine: !s.mine })),
    })),
  };
}
