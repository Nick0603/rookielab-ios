/**
 * 開局局面表的鍵：棋子位置＋輪到誰＋易位權（不看吃過路兵格與步數），FNV-1a 32 位元，base36。
 * 產生腳本（scripts/build-book.mjs）與網站（src/lib/book.ts）共用這一支，兩邊才算得一樣。
 */
export function bookKey(fen) {
  const s = fen.split(' ').slice(0, 3).join(' ');
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(36);
}
