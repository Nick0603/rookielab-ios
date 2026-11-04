import { tl } from '@/lib/i18n/lang';
import { Chess, type PieceSymbol } from 'chess.js';
import type { Lang } from './i18n/lang';
import { bare, mkT } from './i18n/gen';

const ZH: Record<PieceSymbol, string> = { k: '王', q: '后', r: '車', b: '象', n: '馬', p: '兵' };
const EN: Record<PieceSymbol, string> = { k: 'king', q: 'queen', r: 'rook', b: 'bishop', n: 'knight', p: 'pawn' };

const pn = (t: PieceSymbol, lang: Lang) => (lang === 'es' || lang === 'pt' ? bare(lang, t) : tl(lang, ZH[t], EN[t]));

/**
 * 走法代號的白話：「馬 f3→e5」「馬 f3 吃 e5 兵」「短入堡」「兵 e7→e8 升后」，英文 knight f3→e5 / castles kingside。
 * 入堡（castling）：O-O 短入堡（kingside）、O-O-O 長入堡（queenside），台灣棋界慣用「入堡」。
 * 走不了（代號跟局面對不上）就回傳空字串。
 */
const memo = new Map<string, string>();

export function moveName(fen: string, san: string, lang: Lang, withCapture = true): string {
  const key = `${lang}|${withCapture ? 1 : 0}|${san}|${fen}`;
  const hit = memo.get(key);
  if (hit !== undefined) return hit;
  const out = computeName(fen, san, lang, withCapture);
  if (memo.size > 3000) memo.clear();
  memo.set(key, out);
  return out;
}

function computeName(fen: string, san: string, lang: Lang, withCapture: boolean): string {
  let m;
  try { m = new Chess(fen).move(san); } catch { return ''; }
  const c = castleName(m.san, lang);
  if (c) return c;
  const t = mkT(lang);
  const p = pn(m.piece, lang);
  let out = m.captured && withCapture
    ? t(`${p} ${m.from} 吃 ${m.to} ${ZH[m.captured]}`, `${p} ${m.from} takes ${EN[m.captured]} ${m.to}`,
      `${p} ${m.from} captura ${pn(m.captured, lang)} ${m.to}`, `${p} ${m.from} captura ${pn(m.captured, lang)} ${m.to}`)
    : `${p} ${m.from}→${m.to}`;
  if (m.promotion) out += t(`，升${ZH[m.promotion]}`, `, promotes to ${EN[m.promotion]}`,
    `, promociona a ${pn(m.promotion, lang)}`, `, promove a ${pn(m.promotion, lang)}`);
  return out;
}

/** 純代號裡的入堡（不知道局面時用）：O-O → 短入堡 */
export function castleName(san: string, lang: Lang): string {
  const t = mkT(lang);
  if (san.startsWith('O-O-O')) return t('長入堡', 'castles queenside', 'enroque largo', 'roque grande');
  if (san.startsWith('O-O')) return t('短入堡', 'castles kingside', 'enroque corto', 'roque pequeno');
  return '';
}

/** 文字裡用：Nxe5（馬 f3 吃 e5 兵） */
export function named(fen: string | undefined, san: string, lang: Lang): string {
  const name = fen ? moveName(fen, san, lang) : castleName(san, lang);
  return name ? (lang !== 'zh' ? `${san} (${name})` : `${san}（${name}）`) : san;
}
