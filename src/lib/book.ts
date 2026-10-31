import { useSyncExternalStore } from 'react';
import { bookKey } from './bookKey.mjs';

/**
 * 開局理論：Lichess 開局資料庫（CC0）每條開局線經過的局面（scripts/build-book.mjs → public/book.json）。
 * 從開局起連續都在表內的步算「開局理論」。表是非同步載入的，載入前一律當作不在表內；
 * 載入完成時 version 會變，用到分類的畫面靠 useBookVersion() 重算。
 */
let keys: Set<string> | null = null;
let version = 0;
let loading: Promise<void> | null = null;
const listeners = new Set<() => void>();

export function setBook(list: string[]) {
  keys = new Set(list);
  version++;
  listeners.forEach((l) => l());
}

export function loadBook(): Promise<void> {
  if (keys || typeof fetch === 'undefined') return Promise.resolve();
  loading ??= fetch('/book.json')
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`book: HTTP ${r.status}`))))
    .then((d: { keys: string[] }) => setBook(d.keys))
    .catch(() => { loading = null; });
  return loading;
}

export const bookVersion = () => version;

/** 走完這幾步之後，從開局起有幾步還在開局理論內 */
export function bookDepth(fensAfter: string[]): number {
  if (!keys) return 0;
  let n = 0;
  while (n < fensAfter.length && keys.has(bookKey(fensAfter[n]))) n++;
  return n;
}

/** 這個局面在不在開局理論表內（表還沒載入時一律 false） */
export const inBook = (fen: string) => !!keys?.has(bookKey(fen));

/** 開局表載入後回傳新的 version，放進 useMemo 的 deps 讓分類重算 */
export function useBookVersion(): number {
  return useSyncExternalStore(
    (cb) => { listeners.add(cb); void loadBook(); return () => listeners.delete(cb); },
    () => version,
    () => 0,
  );
}
