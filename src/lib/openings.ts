/**
 * 開局名稱的台灣譯名。
 *
 * 用語遵循台灣棋界慣例：**義大利**（非意大利）、**防禦**（非防御）、
 * **西洋棋**（非國際象棋）。與 content-plan.md 的術語表一致。
 *
 * chess.com 回傳的開局名很長（例如
 * "Sicilian Defense Nyezhmetdinov Rossolimo Attack 4.Bxc6"），
 * 所以比對用「由長到短的關鍵字」，先中最具體的。
 */

export interface OpeningName {
  /** 台灣譯名 */
  zh: string;
  /** 原文（chess.com 給的） */
  en: string;
  /** 是否有找到對應譯名 */
  translated: boolean;
}

/**
 * 關鍵字 → 譯名。**順序重要**：愈具體的放愈前面，比對時取第一個命中的。
 */
export const TABLE: [string, string][] = [
  // 變化層級（比家族更具體，要先比對）
  ['Sicilian Defense Najdorf', '西西里防禦 — 納多夫變化'],
  ['Sicilian Defense Dragon', '西西里防禦 — 龍式變化'],
  ['Sicilian Defense Accelerated Dragon', '西西里防禦 — 加速龍式'],
  ['Sicilian Defense Closed', '封閉式西西里防禦'],
  ['Closed Sicilian', '封閉式西西里防禦'],
  ['Sicilian Defense Alapin', '西西里防禦 — 阿拉平變化'],
  ['Sicilian Defense Rossolimo', '西西里防禦 — 羅索里莫攻擊'],
  ['Sicilian Defense Nyezhmetdinov', '西西里防禦 — 羅索里莫攻擊'],
  ['Sicilian Defense Bowdler', '西西里防禦 — 鮑德勒攻擊'],
  ['Sicilian Defense Smith-Morra', '西西里防禦 — 史密斯莫拉棄兵'],
  ['Sicilian Defense Grand Prix', '西西里防禦 — 大獎賽攻擊'],
  ['Sicilian Defense Scheveningen', '西西里防禦 — 舍維寧根變化'],
  ['Sicilian Defense Taimanov', '西西里防禦 — 泰馬諾夫變化'],

  ['French Defense Winawer', '法蘭西防禦 — 維納韋爾變化'],
  ['French Defense Advance', '法蘭西防禦 — 挺進變化'],
  ['French Defense Exchange', '法蘭西防禦 — 兌換變化'],
  ['French Defense Tarrasch', '法蘭西防禦 — 塔拉什變化'],

  ['Caro-Kann Defense Advance', '卡羅康防禦 — 挺進變化'],
  ['Caro-Kann Defense Exchange', '卡羅康防禦 — 兌換變化'],
  ['Caro-Kann Defense Panov', '卡羅康防禦 — 帕諾夫攻擊'],

  ['Queens Gambit Declined Baltic', '后翼棄兵拒還 — 波羅的海防禦'],
  ['Queens Gambit Declined Chigorin', '后翼棄兵拒還 — 契戈林防禦'],
  ['Queens Gambit Declined', '后翼棄兵拒還'],
  ['Queens Gambit Accepted', '后翼棄兵接受'],
  ['Queens Gambit', '后翼棄兵'],

  ['Slav Defense Modern Triangle', '斯拉夫防禦 — 現代三角變化'],
  ['Slav Defense Modern', '斯拉夫防禦 — 現代變化'],
  ['Slav Defense Exchange', '斯拉夫防禦 — 兌換變化'],
  ['Semi-Slav Defense', '半斯拉夫防禦'],
  ['Slav Defense', '斯拉夫防禦'],

  ['Queens Indian Defense', '后翼印度防禦'],
  ['Kings Indian Defense', '王翼印度防禦'],
  ['Kings Indian Attack', '王翼印度攻擊'],
  ['Nimzo-Indian Defense', '尼姆佐印度防禦'],
  ['Grunfeld Defense', '格林菲爾德防禦'],
  ['Bogo-Indian Defense', '博戈印度防禦'],
  ['Catalan Opening', '加泰隆尼亞開局'],

  ['Ruy Lopez Berlin', '西班牙開局 — 柏林防禦'],
  ['Ruy Lopez Exchange', '西班牙開局 — 兌換變化'],
  ['Ruy Lopez', '西班牙開局'],

  ['Italian Game Giuoco Piano', '義大利開局 — 平靜變化'],
  ['Italian Game Two Knights', '義大利開局 — 雙馬防禦'],
  ['Italian Game Evans Gambit', '義大利開局 — 埃文斯棄兵'],
  ['Italian Game', '義大利開局'],
  ['Giuoco Piano', '義大利開局 — 平靜變化'],
  ['Two Knights Defense', '雙馬防禦'],

  ['Scotch Game', '蘇格蘭開局'],
  ['Vienna Game', '維也納開局'],
  ['Kings Gambit Accepted', '王翼棄兵接受'],
  ['Kings Gambit Declined', '王翼棄兵拒還'],
  ['Kings Gambit', '王翼棄兵'],
  ['Petrovs Defense', '俄羅斯防禦'],
  ['Petrov', '俄羅斯防禦'],
  ['Russian Game', '俄羅斯防禦'],
  ['Philidor Defense', '菲利多防禦'],
  ['Scandinavian Defense', '斯堪地那維亞防禦'],
  ['Center Game', '中央開局'],
  ['Danish Gambit', '丹麥棄兵'],
  ['Bishops Opening', '象位開局'],
  ['Ponziani Opening', '龐齊亞尼開局'],
  ['Four Knights', '四馬開局'],
  ['Three Knights', '三馬開局'],

  ['London System', '倫敦系統'],
  ['Colle System', '科爾系統'],
  ['Torre Attack', '托雷攻擊'],
  ['Anti-Torre Attack', '反托雷攻擊'],
  ['Anti Torre Attack', '反托雷攻擊'],
  ['Queens Pawn Opening Anti Torre', '后兵開局 — 反托雷攻擊'],
  ['Trompowsky Attack', '特羅姆波夫斯基攻擊'],
  ['Stonewall', '石牆系統'],
  ['Queens Pawn Opening', '后兵開局'],
  ['Queens Pawn Game', '后兵開局'],
  ['Kings Pawn Opening', '王兵開局'],

  ['Dutch Defense Leningrad', '荷蘭防禦 — 列寧格勒變化'],
  ['Dutch Defense Classical', '荷蘭防禦 — 古典變化'],
  ['Dutch Defense', '荷蘭防禦'],
  ['Benoni Defense', '貝諾尼防禦'],
  ['Benko Gambit', '班科棄兵'],
  ['Budapest Gambit', '布達佩斯棄兵'],
  ['Englund Gambit', '英格蘭棄兵'],
  // Lichess 開局資料庫的命名（開局練習頁的候選步用）
  ['Kings Pawn Game', '王兵開局'],
  ['Caro Kann', '卡羅康防禦'],
  ['Alekhine Defense', '阿廖欣防禦'],
  ['Zukertort Opening', '祖克托特開局'],
  ['Neo-Grunfeld Defense', '新格林菲爾德防禦'],
  ['Pterodactyl Defense', '翼手龍防禦'],
  ['Tarrasch Defense', '塔拉什防禦'],
  ['Blackmar-Diemer Gambit', '布萊克馬－迪默棄兵'],
  ['Hungarian Opening', '匈牙利開局'],
  ['Nimzo-Larsen Attack', '尼姆佐－拉森攻擊'],
  ['Latvian Gambit', '拉脫維亞棄兵'],
  ['Vienna Gambit', '維也納棄兵'],
  ['Rat Defense', '鼠式防禦'],
  ['Kadas Opening', '卡達斯開局'],
  ['Owen Defense', '歐文防禦'],
  ['Richter-Veresov Attack', '里希特－維列索夫攻擊'],
  ['Ware Opening', '韋爾開局'],
  ['English Defense', '英國式防禦'],
  ['Barnes Opening', '巴恩斯開局'],
  ['Lion Defense', '獅子防禦'],
  ['Rubinstein Opening', '魯賓斯坦開局'],
  ['Vant Kruijs Opening', '范特克魯伊斯開局'],
  ['Borg Defense', '博格防禦'],
  ['Mieses Opening', '米澤斯開局'],
  ['Sodium Attack', '鈉攻擊'],
  ['Mikenas Defense', '米凱納斯防禦'],
  ['St. George Defense', '聖喬治防禦'],
  ['Elephant Gambit', '大象棄兵'],
  ['Amar Opening', '阿馬開局'],
  ['Portuguese Opening', '葡萄牙開局'],
  ['Kings Knight Opening', '王翼馬開局'],
  ['Rapport-Jobava System', '拉波特－約巴瓦系統'],
  ['Blumenfeld Countergambit', '布魯門菲爾德反棄兵'],
  ['Hippopotamus Defense', '河馬防禦'],
  ['Polish Defense', '波蘭防禦'],
  ['Kangaroo Defense', '袋鼠防禦'],
  ['Bongcloud Attack', '邦雲攻擊'],
  ['Alekhines Defense', '阿廖欣防禦'],
  ['Pirc Defense', '皮爾茲防禦'],
  ['Modern Defense', '現代防禦'],
  ['Owens Defense', '歐文防禦'],
  ['Nimzowitsch Defense', '尼姆佐維奇防禦'],
  ['English Opening', '英國式開局'],
  ['Reti Opening', '雷蒂開局'],
  ['Bird Opening', '伯德開局'],
  ['Van Geet', '范格特開局'],
  ['Polish Opening', '波蘭開局'],
  ['Grob', '格羅布開局'],

  // 最泛的放最後
  ['Sicilian', '西西里防禦'],
  ['French Defense', '法蘭西防禦'],
  ['Caro-Kann', '卡羅康防禦'],
  ['Indian Game', '印度式開局'],
  ['Indian Defense', '印度式防禦'],
];

// 先按關鍵字長度排序，確保長的（較具體的）先比對到。
// 沒有這一步的話 "Queens Pawn Opening Anti Torre Attack" 會先中
// "Queens Pawn Opening" 而漏掉更精確的 "Anti Torre Attack"
const SORTED = [...TABLE].sort((a, b) => b[0].length - a[0].length);
const BY_LENGTH_ASC = [...TABLE].sort((a, b) => a[0].length - b[0].length);

// 去掉變音符號（Grünfeld、Réti、Kádas）與撇號，chess.com 與 Lichess 的拼法才對得上
const normalise = (s: string) =>
  s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/['’]/g, '').replace(/\s+/g, ' ').trim();

export function translateOpening(raw?: string): OpeningName {
  const en = (raw ?? '').trim();
  if (!en) return { zh: '未知開局', en: '', translated: false };

  // 傳進來的已經是中文（例如 openingFamily 的家族名）→ 反查原文，英文介面才顯示得出來
  if (/[\u4e00-\u9fff]/.test(en)) {
    // 同一個中文可能對到好幾個原文（Sicilian／Sicilian Defense），取最完整的那個
    const hit = SORTED.find(([, zh]) => zh === en)
      ?? BY_LENGTH_ASC.find(([, zh]) => zh.split(' — ')[0] === en);
    return hit ? { zh: en, en: hit[0], translated: true } : { zh: en, en: '', translated: false };
  }

  const key = normalise(en).toLowerCase();
  for (const [needle, zh] of SORTED) {
    if (key.includes(normalise(needle).toLowerCase())) {
      return { zh, en, translated: true };
    }
  }
  return { zh: en, en, translated: false };
}

/**
 * 開局「家族」——收斂到最上層的譯名，用來做統計分組。
 *
 * 比用字串切割可靠：`Sicilian Defense Najdorf`、`Closed Sicilian`、
 * `Sicilian Defense` 都會回到「西西里防禦」。
 * 用切割的話最後一個會因為沒有後綴而自成一群。
 */

export function openingFamily(raw?: string): string {
  const en = (raw ?? '').trim();
  if (!en) return '未知開局';
  const key = normalise(en).toLowerCase();
  // 由短到長找，第一個命中的就是最上層的家族
  for (const [needle, zh] of BY_LENGTH_ASC) {
    if (key.includes(normalise(needle).toLowerCase())) {
      // 變化名帶破折號，取破折號前面那段才是家族
      return zh.split(' — ')[0];
    }
  }
  return en.split(' ').slice(0, 2).join(' ');
}

/** 顯示用：依偏好回傳中文或原文 */
export function openingLabel(raw: string | undefined, mode: 'zh' | 'en'): string {
  const o = translateOpening(raw);
  return mode === 'en' ? (o.en || '未知開局') : o.zh;
}
