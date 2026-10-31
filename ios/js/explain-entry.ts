// iOS 用的解說：把網站的 explainMove 打包成一個 JS 檔，App 用 JavaScriptCore 執行（兩邊的說法一致）
// 產生：npm run build:ios-explain
import { explainMove, swapVoice } from '../../src/lib/lesson/explain';

// opponent：這步是對手走的 → 把「你」「對手」對調，說明一律從使用者的角度講
(globalThis as unknown as { RLExplain: (fen: string, san: string, record: string, opponent?: boolean) => string }).RLExplain = (fen, san, record, opponent) => {
  const e = explainMove(fen, san, JSON.parse(record), 'zh', true);
  return JSON.stringify(e && opponent ? swapVoice(e, 'zh') : e);
};
