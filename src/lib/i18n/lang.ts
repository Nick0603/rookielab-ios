/**
 * 語言的型別與工具。刻意不依賴 React —— 分析、教學資料這類純邏輯也要能用。
 *
 * 寫法：中英並排（tr('練習', 'Practice')、{ zh, en }），不用 key 對字典。
 * 全站一千多段字串，取 key 名稱很費工，回頭找「這個 key 在畫面哪裡」更費工；
 * 並排寫每一句一定有兩種語言，審英文時也能直接對照中文。
 *
 * 其他語言（es、pt…）用「以英文原文為 key」的字典（locales/<lang>.json）：
 * 查不到就回英文。要加語言：Lang 加一個值、LOCALES 加一列、放一份字典即可。
 */

export type Lang = 'zh' | 'en' | 'es' | 'pt';

/** 靠字典翻譯的語言（英文是原文，不查字典） */
export type DictLang = Exclude<Lang, 'zh' | 'en'>;

/** 雙語字串 */
export interface Bi {
  zh: string;
  en: string;
}

export type Dict = Record<string, string>;

const dicts: Partial<Record<DictLang, Dict>> = {};

/**
 * 帶變數的字串：key 裡用 {} 代替變數（"Last {} games"），譯文用 {1}、{2} 依序填回（"Últimas {1} partidas"）。
 * 執行時 tr() 拿到的是已經插值的英文（"Last 10 games"），靠樣式比對找回字典條目。
 * 變數內容如果本身是字典裡的詞（例如失誤類型名稱），也會一併翻譯。
 */
interface Pattern { re: RegExp; to: string; weight: number }
const patterns: Partial<Record<DictLang, Pattern[]>> = {};
const memo: Partial<Record<DictLang, Map<string, string>>> = {};

const escapeRe = (t: string) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function registerDict(lang: DictLang, dict: Dict): void {
  dicts[lang] = dict;
  memo[lang] = new Map();
  patterns[lang] = Object.entries(dict)
    .filter(([k]) => k.includes('{}'))
    .map(([k, to]) => {
      const parts = k.split('{}');
      return { re: new RegExp(`^${parts.map(escapeRe).join('(.*?)')}$`, 's'), to, weight: k.length - (parts.length - 1) * 2 };
    })
    .sort((a, b) => b.weight - a.weight);
}

export const hasDict = (lang: DictLang): boolean => lang in dicts;

/** 英文原文 → 該語言的譯文，查不到回英文 */
export function fromEn(lang: Lang, en: string): string {
  if (lang === 'en' || lang === 'zh') return en;
  const dict = dicts[lang];
  if (!dict) return en;
  const hit = dict[en];
  if (hit !== undefined) return hit;
  const cache = memo[lang]!;
  const cached = cache.get(en);
  if (cached !== undefined) return cached;
  let out = en;
  for (const p of patterns[lang] ?? []) {
    const m = p.re.exec(en);
    if (m) {
      out = p.to.replace(/\{(\d+)\}/g, (_, i: string) => {
        const v = m[Number(i)] ?? '';
        return dict[v] ?? v;
      });
      break;
    }
  }
  if (cache.size > 5000) cache.clear();
  cache.set(en, out);
  return out;
}

export const pick = (lang: Lang, zh: string, en: string): string =>
  lang === 'zh' ? zh : fromEn(lang, en);
export const bi = (lang: Lang, text: Bi): string => pick(lang, text.zh, text.en);

/** pick 的別名：檔案裡 pick 常被當區域變數名稱 */
export const tl = pick;
