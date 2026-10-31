import { tl } from '@/lib/i18n/lang';
import { pick } from '@/lib/i18n/lang';
import { Chess, type PieceSymbol } from 'chess.js';
import type { Lang } from './i18n/lang';

const ZH: Record<PieceSymbol, string> = { k: '王', q: '后', r: '車', b: '象', n: '馬', p: '兵' };
const EN: Record<PieceSymbol, string> = { k: 'king', q: 'queen', r: 'rook', b: 'bishop', n: 'knight', p: 'pawn' };

/**
 * 走法代號的白話：「馬 f3→e5」「馬 f3 吃 e5 兵」「短入堡」「兵 e7→e8 升后」，英文 knight f3→e5 / castles kingside。
 * 入堡（castling）：O-O 短入堡（kingside）、O-O-O 長入堡（queenside），台灣棋界慣用「入堡」。
 * 走不了（代號跟局面對不上）就回傳空字串。
 */
export function moveName(fen: string, san: string, lang: Lang, withCapture = true): string {
  let m;
  try { m = new Chess(fen).move(san); } catch { return ''; }
  const en = lang !== 'zh';
  if (m.san.startsWith('O-O-O')) return pick(lang, '長入堡', 'castles queenside');
  if (m.san.startsWith('O-O')) return pick(lang, '短入堡', 'castles kingside');
  const p = tl(lang, ZH[m.piece], EN[m.piece]);
  let t = m.captured && withCapture
    ? (en ? `${p} ${m.from} takes ${EN[m.captured]} ${m.to}` : `${p} ${m.from} 吃 ${m.to} ${ZH[m.captured]}`)
    : `${p} ${m.from}→${m.to}`;
  if (m.promotion) t += en ? `, promotes to ${EN[m.promotion]}` : `，升${ZH[m.promotion]}`;
  return t;
}

/** 純代號裡的入堡（不知道局面時用）：O-O → 短入堡 */
export function castleName(san: string, lang: Lang): string {
  if (san.startsWith('O-O-O')) return pick(lang, '長入堡', 'castles queenside');
  if (san.startsWith('O-O')) return pick(lang, '短入堡', 'castles kingside');
  return '';
}

/** 文字裡用：Nxe5（馬 f3 吃 e5 兵） */
export function named(fen: string | undefined, san: string, lang: Lang): string {
  const name = fen ? moveName(fen, san, lang) : castleName(san, lang);
  return name ? (lang !== 'zh' ? `${san} (${name})` : `${san}（${name}）`) : san;
}
