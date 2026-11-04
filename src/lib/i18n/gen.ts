import type { Lang } from './lang';

/**
 * 程式組出來的句子（解說、復盤、練習）用的多語言工具。
 *
 * 字典（locales/*.json）處理不了插值與文法，所以產生句子的邏輯直接產出各語言：
 * t(zh, en, es, pt) 沒給 es／pt 時回英文。棋子的陰陽性、冠詞、單複數、列舉的連接詞、
 * 「你／對手」的人稱變化都在這裡。
 */

type Piece = 'p' | 'n' | 'b' | 'r' | 'q' | 'k';
type Gender = 'm' | 'f';

export const isRomance = (lang: Lang): lang is 'es' | 'pt' => lang === 'es' || lang === 'pt';

/** 依語言挑句子；es／pt 沒給就回英文 */
export function mkT(lang: Lang) {
  return (zh: string, en: string, es?: string, pt?: string): string =>
    lang === 'zh' ? zh : lang === 'es' ? (es ?? en) : lang === 'pt' ? ptContract(pt ?? en) : en;
}

/** 葡文縮合：por + o → pelo、por + a → pela（句子是拼出來的，冠詞前面的介系詞要在這裡處理） */
export const ptContract = (s: string): string => s.replace(/\bpor (o|a|os|as)\b/g, (_, art: string) => `pel${art}`);

const NAME: Record<'es' | 'pt', Record<Piece, [string, Gender, string]>> = {
  es: { p: ['peón', 'm', 'peones'], n: ['caballo', 'm', 'caballos'], b: ['alfil', 'm', 'alfiles'], r: ['torre', 'f', 'torres'], q: ['dama', 'f', 'damas'], k: ['rey', 'm', 'reyes'] },
  pt: { p: ['peão', 'm', 'peões'], n: ['cavalo', 'm', 'cavalos'], b: ['bispo', 'm', 'bispos'], r: ['torre', 'f', 'torres'], q: ['dama', 'f', 'damas'], k: ['rei', 'm', 'reis'] },
};

const NUM: Record<'es' | 'pt', Record<'m' | 'f', string[]>> = {
  es: { m: ['', 'un', 'dos', 'tres', 'cuatro', 'cinco', 'seis', 'siete', 'ocho', 'nueve'], f: ['', 'una', 'dos', 'tres', 'cuatro', 'cinco', 'seis', 'siete', 'ocho', 'nueve'] },
  pt: { m: ['', 'um', 'dois', 'três', 'quatro', 'cinco', 'seis', 'sete', 'oito', 'nove'], f: ['', 'uma', 'duas', 'três', 'quatro', 'cinco', 'seis', 'sete', 'oito', 'nove'] },
};

/** 沒有冠詞的名字：caballo／cavalo */
export const bare = (lang: 'es' | 'pt', t: Piece): string => NAME[lang][t][0];
export const genderOf = (lang: 'es' | 'pt', t: Piece): Gender => NAME[lang][t][1];

/** 定冠詞：el caballo／la torre、o cavalo／a torre */
export function def(lang: 'es' | 'pt', t: Piece): string {
  const [n, g] = NAME[lang][t];
  const art = lang === 'es' ? (g === 'm' ? 'el' : 'la') : (g === 'm' ? 'o' : 'a');
  return `${art} ${n}`;
}

/** 不定冠詞：un caballo／una torre、um cavalo／uma torre */
export function indef(lang: 'es' | 'pt', t: Piece): string {
  const [n, g] = NAME[lang][t];
  return `${NUM[lang][g][1]} ${n}`;
}

/** 一串子的名字，相同的合併成「dos peones」；單顆用定冠詞 */
export function pieceNames(lang: 'es' | 'pt', types: Piece[]): string {
  const order: Piece[] = [];
  const count = new Map<Piece, number>();
  for (const t of types) { if (!count.has(t)) order.push(t); count.set(t, (count.get(t) ?? 0) + 1); }
  return joinList(lang, order.map((t) => {
    const c = count.get(t)!;
    if (c === 1) return def(lang, t);
    const [, g, plural] = NAME[lang][t];
    return `${c < 10 ? NUM[lang][g][c] : c} ${plural}`;
  }));
}

/** 西／葡文列舉：a, b y c／a, b e c（y 在 i-、hi- 開頭的字前變 e） */
export function joinList(lang: 'es' | 'pt', items: string[]): string {
  if (items.length <= 1) return items.join('');
  const last = items[items.length - 1];
  const conj = lang === 'pt' ? 'e' : /^(i|hi(?!e))/i.test(last) ? 'e' : 'y';
  return `${items.slice(0, -1).join(', ')} ${conj} ${last}`;
}

export const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/**
 * 「你／對手」的視角。解說是從「走這步的人」講的；swapVoice 要換成對手的角度時，
 * 西／葡文不能靠字串取代（動詞變位、所有格結構都不同），所以用同一份邏輯再產生一次、
 * 把這裡的 swapped 打開，所有「你／對手」就整個對調。
 */
let swapped = false;
export const isSwapped = () => swapped;
export function withVoiceSwap<T>(on: boolean, fn: () => T): T {
  const prev = swapped;
  swapped = on;
  try { return fn(); } finally { swapped = prev; }
}

export interface Person {
  /** 這個人現在是不是「你」 */
  you: boolean;
  /** 句首主詞（含尾端空格）：西文「你」省略；葡文 você／o adversário */
  s: string;
  /** 動詞：傳入第三人稱現在式，西文的「你」加 s */
  v: (third: string) => string;
  /** 所有格 + 子：tu caballo／el caballo del rival、seu cavalo／o cavalo do adversário */
  own: (t: Piece) => string;
  /** 「你的」或「對手的」：tu／su…（沒有名詞時用於 own 之外的片段，目前只給葡文 você／adversário 用） */
  noun: string;
}

/** mine：這是走這步的人（解說裡的「你」）嗎 */
export function person(lang: 'es' | 'pt', mine: boolean): Person {
  const you = mine !== swapped;
  if (lang === 'es') {
    return {
      you,
      s: you ? '' : 'el rival ',
      v: (third) => (you ? `${third}s` : third),
      own: (t) => {
        const [n, g] = NAME.es[t];
        return you ? `tu ${n}` : `${g === 'm' ? 'el' : 'la'} ${n} del rival`;
      },
      noun: you ? 'tú' : 'el rival',
    };
  }
  return {
    you,
    s: you ? 'você ' : 'o adversário ',
    v: (third) => third,
    own: (t) => {
      const [n, g] = NAME.pt[t];
      return you ? `${g === 'm' ? 'seu' : 'sua'} ${n}` : `${g === 'm' ? 'o' : 'a'} ${n} do adversário`;
    },
    noun: you ? 'você' : 'o adversário',
  };
}

/** 「tu caballo en e5」／「el caballo del rival en e5」 */
export function ownAt(lang: 'es' | 'pt', mine: boolean, t: Piece, square: string): string {
  return `${person(lang, mine).own(t)} ${lang === 'es' ? 'en' : 'em'} ${square}`;
}
