// iOS 用的解說：把網站的 explainMove 打包成一個 JS 檔，App 用 JavaScriptCore 執行（兩邊的說法一致）
// 產生：npm run build:ios-explain
import { explainMove, swapVoice } from '../../src/lib/lesson/explain';
import type { Lang } from '../../src/lib/i18n/lang';

// opponent：這步是對手走的 → 把「你」「對手」對調，說明一律從使用者的角度講
// lang：App 目前的語言（zh／en／es／pt）；網站的 explainMove 查不到 es、pt 的文字時自己回英文
(globalThis as unknown as { RLExplain: (fen: string, san: string, record: string, opponent?: boolean, lang?: string) => string }).RLExplain = (fen, san, record, opponent, lang = 'zh') => {
  const l = lang as Lang;
  const e = explainMove(fen, san, JSON.parse(record), l, true);
  return JSON.stringify(e && opponent ? swapVoice(e, l) : e);
};

// 棋盤標示用：走完這步之後，剛走的子的攻守、盤面牽制、這步準備的威脅、雙方沒保護又被攻擊的子
import { moveRelations } from '../../src/lib/lesson/relations';
import { looseTactics } from '../../src/lib/lesson/tactics';
import { Chess } from 'chess.js';
(globalThis as unknown as { RLBoard: (fen: string, san: string) => string }).RLBoard = (fen, san) => {
  const board = new Chess(fen);
  try { board.move(san); } catch { return 'null'; }
  const r = moveRelations(fen, san);
  const link = (l: { from: string; to: string }) => ({ from: l.from, to: l.to });
  const hanging = (['w', 'b'] as const).flatMap((c) => looseTactics(board, c, c).filter((t) => t.tag === 'hanging').flatMap((t) => t.squares));
  return JSON.stringify({
    attacks: r.attacks.map(link), defends: r.defends.map(link), attackedBy: r.attackedBy.map(link),
    pins: r.pins.map((p) => ({ from: p.from, pinned: p.pinned, behind: p.behind })),
    threats: r.threats.map((t) => ({ from: t.from, to: t.to, kind: t.kind, san: t.san })),
    hanging,
  });
};

// 開局原則觀察（早出后、同子兩動、未出子、未入堡）：sans 是整局 SAN，me 是要看的一方
import { openingNotes } from '../../src/lib/lesson/opening';
import { openingNoteText } from '../../src/lib/lesson/script';
(globalThis as unknown as { RLOpening: (sans: string, me: string, lang?: string) => string }).RLOpening = (sans, me, lang = 'zh') =>
  JSON.stringify(openingNotes(JSON.parse(sans), me as 'w' | 'b').map((n) => ({ ply: n.ply, tag: n.tactic.tag, text: openingNoteText(n, lang as Lang) })));
