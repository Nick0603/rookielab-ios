import { pick } from '@/lib/i18n/lang';
import { Chess, type Color, type Move, type Square } from 'chess.js';
import type { Lang } from '../i18n/lang';
import { label, lineTactics, opp, pieceName, VALUE, withTurn, type PieceRef } from './tactics';

/**
 * 一步棋走完之後，剛走的那個子跟誰有攻守關係。
 * 只看剛走的子 —— 整盤的攻守全畫出來會滿版箭頭，反而看不懂。
 */

export interface Link {
  from: Square;
  to: Square;
  /** 被攻擊／被保護的那個子 */
  target: PieceRef;
  /** 發動的那個子 */
  by: PieceRef;
}

export interface Relations {
  /** 剛走的子攻擊了對方哪些子 */
  attacks: Link[];
  /** 剛走的子保護了自己哪些「正被攻擊」的子（沒被攻擊的保護只是雜訊） */
  defends: Link[];
  /** 剛走的子被對方哪些子攻擊 */
  attackedBy: Link[];
  /** 盤面上雙方所有的牽制（跟剛走哪一步無關） */
  pins: Pin[];
  /** 這步準備的威脅：對手不理會的話，下一步能做什麼（走這步之前做不到的） */
  threats: Threat[];
}

export interface Threat {
  san: string;
  from: Square;
  to: Square;
  /** mate＝將殺；win＝白吃子；hit＝走到安全的格子攻擊更大（或沒保護）的子；plan＝文章手動寫的想法 */
  kind: 'mate' | 'win' | 'hit' | 'plan';
  /** plan 的說明 */
  note?: string;
  side: Color;
  target?: PieceRef;
  /** 假設對手不理會、這步走出去之後的局面，給「模擬」用 */
  fen: string;
}

export interface Pin {
  /** 發動牽制的長程子 */
  from: Square;
  /** 被牽制的子 */
  pinned: Square;
  /** 被牽制的子後面那個子（王或更值錢的） */
  behind: Square;
  pinnedPiece: PieceRef;
  behindPiece: PieceRef;
}

const EMPTY: Relations = { attacks: [], defends: [], attackedBy: [], pins: [], threats: [] };

function boardPins(board: Chess): Pin[] {
  return (['w', 'b'] as const).flatMap((c) => lineTactics(board, c, c))
    .filter((t) => t.tag === 'pin')
    .map((t) => ({
      from: t.squares[0], pinned: t.squares[1], behind: t.squares[2],
      pinnedPiece: t.pieces[0], behindPiece: t.pieces[1],
    }));
}

/** 走到 sq 的子（價值 v）站得住嗎：沒人攻擊，或攻擊者都不比它便宜、而且保護數夠 */
function safeOn(board: Chess, sq: Square, v: number, me: Color): boolean {
  const atk = board.attackers(sq, opp(me));
  if (atk.length === 0) return true;
  const low = Math.min(...atk.map((s) => VALUE[board.get(s)!.type]));
  return low >= v && board.attackers(sq, me).length >= atk.length;
}

/** 輪到 me、在這個局面裡一步就能做到的威脅 */
function threatsIn(board: Chess, me: Color): Threat[] {
  const out: Threat[] = [];
  for (const m of board.moves({ verbose: true }) as Move[]) {
    const own = VALUE[m.promotion ?? m.piece];
    const b = new Chess(board.fen());
    b.move(m.san);
    const base = { san: m.san, from: m.from, to: m.to, side: me, fen: b.fen() };
    if (b.isCheckmate()) { out.push({ ...base, kind: 'mate' }); continue; }
    if (m.captured) {
      const undefended = board.attackers(m.to, opp(me)).length === 0;
      if (undefended || VALUE[m.captured] > own) out.push({ ...base, kind: 'win', target: label(m.to, m.captured) });
      continue;
    }
    if (!safeOn(b, m.to, own, me)) continue;
    // 走過去之後，這個子攻擊到的、比它值錢或沒人保護的子（王是將軍，不算）
    for (const row of b.board()) {
      for (const x of row) {
        if (!x || x.color === me || x.type === 'k') continue;
        if (!b.attackers(x.square, me).includes(m.to)) continue;
        // 沒保護的兵不算：開局一直冒出「出后打兵」只會誤導
        if (VALUE[x.type] > own || (VALUE[x.type] >= 3 && b.attackers(x.square, opp(me)).length === 0)) {
          out.push({ ...base, kind: 'hit', target: label(x.square, x.type) });
        }
      }
    }
  }
  return out;
}

const RANK = { mate: 0, win: 1, hit: 2, plan: 3 } as const;
const threatKey = (t: Threat) => `${t.san}|${t.kind}|${t.target?.square ?? ''}`;

/**
 * 這步準備了什麼：假設對手停一手，同一方再走一步能做到、但走這步之前做不到的威脅。
 * 例：慢義大利 …a6 之後，…b5 有 a6 保護，可以趕 c4 的象；走 a6 之前 …b5 會被 Bxb5 白吃。
 * 剛走的子自己能吃的已經算在「攻擊」裡，不重複。
 */
function preparedThreats(fenBefore: string, board: Chess, me: Color, at: Square): Threat[] {
  // 剛走的子已經直接攻擊到的目標，再講一次「準備攻擊」是重複的
  const direct = new Set<string>();
  for (const row of board.board()) {
    for (const x of row) if (x && x.color !== me && board.attackers(x.square, me).includes(at)) direct.add(x.square);
  }
  if (board.inCheck()) return [];
  const after = withTurn(board.fen(), me);
  const before = new Chess(fenBefore);
  if (!after || before.turn() !== me) return [];
  const old = new Set(threatsIn(before, me).map(threatKey));
  return threatsIn(after, me)
    .filter((t) => !old.has(threatKey(t)) && !(t.kind !== 'mate' && t.from === at) && !(t.target && direct.has(t.target.square)))
    .sort((a, b) => RANK[a.kind] - RANK[b.kind] || VALUE[b.target?.type ?? 'k'] - VALUE[a.target?.type ?? 'k'])
    // 同一步攻擊兩個子，只講最值錢的那個
    .filter((t, i, all) => all.findIndex((u) => u.san === t.san) === i)
    .slice(0, 2);
}

/**
 * 文章手動寫的想法（規則抓不到的，例如 c3 之後推 d4）：假設對手不理會，同一方走 idea 那步。
 * 走不出來就回傳 null。
 */
export function planThreat(fenAfter: string, san: string, note?: string): Threat | null {
  const turn = fenAfter.split(' ')[1] === 'w' ? 'b' : 'w';
  const b = withTurn(fenAfter, turn);
  if (!b) return null;
  try {
    const m = b.move(san);
    return { san: m.san, from: m.from, to: m.to, kind: 'plan', side: turn, note, fen: b.fen() };
  } catch { return null; }
}

export function moveRelations(fenBefore: string, san: string): Relations {
  const board = new Chess(fenBefore);
  let m;
  try { m = board.move(san); } catch { return EMPTY; }
  // 入堡動到兩個子，關係講不清楚，不畫
  if (m.flags.includes('k') || m.flags.includes('q')) return { ...EMPTY, pins: boardPins(board), threats: preparedThreats(fenBefore, board, m.color, m.to) };

  const me = m.color;
  const at = m.to;
  const attacks: Link[] = [];
  const defends: Link[] = [];
  for (const row of board.board()) {
    for (const x of row) {
      if (!x || x.square === at) continue;
      if (!board.attackers(x.square, me).includes(at)) continue;
      const link = { from: at, to: x.square, target: label(x.square, x.type), by: label(at, m.piece) };
      if (x.color !== me) attacks.push(link);
      else if (x.type !== 'k' && board.attackers(x.square, opp(me)).length > 0) defends.push(link);
    }
  }
  const moved = board.get(at)!;
  const attackedBy = board.attackers(at, opp(me)).map((s) => ({
    from: s, to: at, target: label(at, moved.type), by: label(s, board.get(s)!.type),
  }));
  const pins = boardPins(board);
  // 牽制已經包含「攻擊被牽制的子」，同一條線不再重複畫攻擊
  const onPin = (l: Link) => pins.some((p) => p.from === l.from && p.pinned === l.to);
  // 被牽制在王前面的子不能動，它的「攻擊」不是真的攻擊，畫出來會誤導
  const frozen = (sq: Square) => pins.some((p) => p.pinned === sq && board.get(p.behind)?.type === 'k');
  const real = (l: Link) => !onPin(l) && !frozen(l.from);
  return {
    attacks: attacks.filter(real), defends: defends.filter((l) => !frozen(l.from)), attackedBy: attackedBy.filter(real), pins,
    threats: preparedThreats(fenBefore, board, me, at),
  };
}

/** 分成四類，給固定版面用：每一類一格，沒有就是空字串 */
/** 「…b5 攻擊 c4 象」／「Qxf7# 將死」 */
export function threatText(t: Threat, lang: Lang = 'zh'): string {
  const en = lang !== 'zh';
  const mv = `${t.side === 'b' ? '…' : ''}${t.san}`;
  if (t.kind === 'mate') return en ? `${mv} mates` : `${mv} 將死`;
  if (t.kind === 'plan') return t.note ? `${mv}${pick(lang, '：', ': ')}${t.note}` : mv;
  const n = t.target ? pieceName(t.target, lang) : '';
  if (t.kind === 'win') return en ? `${mv} wins the ${n}` : `${mv} 吃掉 ${n}`;
  return en ? `${mv} attacks the ${n}` : `${mv} 攻擊 ${n}`;
}

export function relationsParts(r: Relations, lang: Lang = 'zh'): Record<'attacks' | 'defends' | 'attackedBy' | 'pins' | 'threats', string> {
  const n = (p: PieceRef) => pieceName(p, lang);
  const en = lang !== 'zh';
  const sep = pick(lang, '、', ', ');
  return {
    attacks: r.attacks.map((l) => n(l.target)).join(sep),
    defends: r.defends.map((l) => n(l.target)).join(sep),
    attackedBy: r.attackedBy.map((l) => n(l.by)).join(sep),
    pins: r.pins.map((p) => (en
      ? `${n(p.pinnedPiece)} pinned to the ${n(p.behindPiece)}`
      : `${n(p.pinnedPiece)}被牽制在 ${n(p.behindPiece)}前面`)).join(sep),
    threats: r.threats.map((t) => threatText(t, lang)).join(sep),
  };
}

/** 給棋盤下方的一行說明，例：「攻擊：e5 兵｜保護：e4 兵」／「Attacks: pawn on e5 | Protects: pawn on e4」 */
export function relationsText(r: Relations, lang: Lang = 'zh'): string {
  const n = (p: PieceRef) => pieceName(p, lang);
  const en = lang !== 'zh';
  const parts: string[] = [];
  if (r.attacks.length) parts.push(`${pick(lang, '攻擊：', 'Attacks: ')}${r.attacks.map((l) => n(l.target)).join(pick(lang, '、', ', '))}`);
  if (r.defends.length) parts.push(`${pick(lang, '保護：', 'Protects: ')}${r.defends.map((l) => n(l.target)).join(pick(lang, '、', ', '))}`);
  if (r.attackedBy.length) parts.push(`${pick(lang, '被攻擊：來自 ', 'Attacked by: ')}${r.attackedBy.map((l) => n(l.by)).join(pick(lang, '、', ', '))}`);
  if (r.pins.length) {
    parts.push(`${pick(lang, '牽制：', 'Pins: ')}${r.pins.map((p) => (en
      ? `${n(p.pinnedPiece)} pinned to the ${n(p.behindPiece)}`
      : `${n(p.pinnedPiece)}被牽制在 ${n(p.behindPiece)}前面`)).join(pick(lang, '、', ', '))}`);
  }
  if (r.threats.length) parts.push(`${pick(lang, '準備：', 'Prepares: ')}${r.threats.map((t) => threatText(t, lang)).join(pick(lang, '、', ', '))}`);
  return parts.join(pick(lang, '｜', ' | '));
}
