import { pick } from '@/lib/i18n/lang';
import { scoreText, winProbToCp } from '../analysis/winprob';
import type { Lang } from '../i18n/lang';
import { cap as capFirst, genderOf, joinList, mkT, ownAt } from '../i18n/gen';
import { pieceName, pieceNameDef, tacticLabel, type PieceRef, type Tactic, type TacticTag } from './tactics';
import type { CandidateLine, Lesson } from './buildLesson';
import type { OpeningNote } from './opening';

/**
 * 教練台詞。D-06：只把 Lesson 裡算好的結論講成人話，不自己判斷。
 *
 * 語氣照 CLAUDE.md：只陳述事實、每段最多兩句、不說教（英文同一套原則）。
 * 勝率與走法一律從 Lesson 帶進來，不寫死。
 */

type Say = (t: Tactic, risk: boolean, n: (p: PieceRef) => string) => string;

const ZH: Record<TacticTag, Say> = {
  hanging: (t, r, n) => (r ? `${n(t.pieces[0])}沒人保護。` : `對手的 ${n(t.pieces[0])}沒人保護。`),
  outnumbered: (t, r, n) => {
    const why = t.cheaperAttacker ? `被 ${n(t.cheaperAttacker)}攻擊，換掉會虧。` : '被攻擊的比保護的多。';
    return r ? `${n(t.pieces[0])}${why}` : `對手的 ${n(t.pieces[0])}${why}`;
  },
  fork: (t, r, n) => (r ? `對手 ${t.by} 可以捉雙：${t.pieces.map(n).join('和 ')}。` : `${t.by} 可以捉雙：${t.pieces.map(n).join('和 ')}。`),
  pawn_fork: (t, r, n) => (r ? `對手 ${t.by} 可以兵捉雙：${t.pieces.map(n).join('和 ')}。` : `${t.by} 可以兵捉雙：${t.pieces.map(n).join('和 ')}。`),
  pin: (t, r, n) => (r ? `${n(t.pieces[0])}被牽制在 ${n(t.pieces[1])}前面。` : `對手的 ${n(t.pieces[0])}被牽制在 ${n(t.pieces[1])}前面。`),
  skewer: (t, r, n) => (r
    ? `${n(t.pieces[0])}被串打，躲開之後 ${n(t.pieces[1])}會被吃。`
    : `可以串打 ${n(t.pieces[0])}，後面的 ${n(t.pieces[1])}跑不掉。`),
  discovered: (t, r, n) => (r ? `對手 ${t.by} 一走開，就打到 ${n(t.pieces[0])}。` : `${t.by} 一走開，就打到對手的 ${n(t.pieces[0])}。`),
  mate_threat: (t, r) => {
    if (t.by?.endsWith('#')) return r ? `對手可以 ${t.by} 直接將死。` : `${t.by} 可以直接將死。`;
    return r ? `對手從 ${t.by} 開始有殺棋。` : `從 ${t.by} 開始有殺棋。`;
  },
  back_rank: (t, r) => (r ? `底線沒有退路，對手 ${t.by} 可以打底線殺。` : `對手底線沒有退路，${t.by} 可以打底線殺。`),
  trapped: (t, r, n) => (r ? `${n(t.pieces[0])}沒有退路。` : `對手的 ${n(t.pieces[0])}沒有退路。`),
  passed_pawn: (t, r, n) => (r ? `對手的 ${n(t.pieces[0])}是通路兵，前面沒人擋。` : `${n(t.pieces[0])}是通路兵，前面沒人擋。`),
  undeveloped: (t, _r, n) => `${t.pieces.map(n).join('、')}還在原位。`,
  early_queen: () => '后先出動，輕子還沒出。',
  moved_twice: (t, _r, n) => `${n(t.pieces[0])}走第二次，其他子還沒出動。`,
  uncastled: () => '王還沒入堡。',
};

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const and = (ps: string[]) => (ps.length <= 2 ? ps.join(' and ') : `${ps.slice(0, -1).join(', ')} and ${ps.at(-1)}`);

const EN: Record<TacticTag, Say> = {
  hanging: (t, r, n) => (r ? `Your ${n(t.pieces[0])} is undefended.` : `Their ${n(t.pieces[0])} is undefended.`),
  outnumbered: (t, r, n) => {
    const who = r ? `Your ${n(t.pieces[0])}` : `Their ${n(t.pieces[0])}`;
    return t.cheaperAttacker
      ? `${who} is attacked by the ${n(t.cheaperAttacker)}; trading loses material.`
      : `${who} has more attackers than defenders.`;
  },
  fork: (t, r, n) => (r
    ? `They can fork your ${and(t.pieces.map(n))} with ${t.by}.`
    : `${t.by} forks their ${and(t.pieces.map(n))}.`),
  pawn_fork: (t, r, n) => (r
    ? `They can fork your ${and(t.pieces.map(n))} with the pawn move ${t.by}.`
    : `The pawn move ${t.by} forks their ${and(t.pieces.map(n))}.`),
  pin: (t, r, n) => `${r ? 'Your' : 'Their'} ${n(t.pieces[0])} is pinned to the ${n(t.pieces[1])}.`,
  skewer: (t, r, n) => (r
    ? `Your ${n(t.pieces[0])} is skewered; once it moves, the ${n(t.pieces[1])} falls.`
    : `You can skewer the ${n(t.pieces[0])}; the ${n(t.pieces[1])} behind it can't escape.`),
  discovered: (t, r, n) => (r
    ? `When they play ${t.by}, your ${n(t.pieces[0])} comes under attack.`
    : `${t.by} uncovers an attack on their ${n(t.pieces[0])}.`),
  mate_threat: (t, r) => {
    if (t.by?.endsWith('#')) return r ? `They have mate in one: ${t.by}.` : `${t.by} is mate.`;
    return r ? `They have a mating attack starting with ${t.by}.` : `There is a mating attack starting with ${t.by}.`;
  },
  back_rank: (t, r) => (r
    ? `Your king has no escape square; ${t.by} is back-rank mate.`
    : `Their king has no escape square; ${t.by} is back-rank mate.`),
  trapped: (t, r, n) => `${r ? 'Your' : 'Their'} ${n(t.pieces[0])} has no safe square.`,
  passed_pawn: (t, r, n) => (r
    ? `Their ${n(t.pieces[0])} is a passed pawn with nothing in front of it.`
    : `Your ${n(t.pieces[0])} is a passed pawn with nothing in front of it.`),
  undeveloped: (t, _r, n) => `${cap(and(t.pieces.map(n)))} ${t.pieces.length > 1 ? 'are' : 'is'} still on the starting square.`,
  early_queen: () => 'The queen came out before the knights and bishops.',
  moved_twice: (t, _r, n) => `The ${n(t.pieces[0])} moved a second time while other pieces are still at home.`,
  uncastled: () => 'The king has not castled yet.',
};

/** 西／葡文：piece 帶定冠詞「el caballo en e5」；own = 「tu caballo en e5」／「el caballo del rival en e5」 */
type RomSay = (t: Tactic, risk: boolean, lang: 'es' | 'pt') => string;
const own = (p: PieceRef, mine: boolean, lang: 'es' | 'pt') => ownAt(lang, mine, p.type, p.square);
const ownList = (t: Tactic, mine: boolean, lang: 'es' | 'pt') => joinList(lang, t.pieces.map((p) => own(p, mine, lang)));
const defList = (ps: PieceRef[], lang: 'es' | 'pt') => joinList(lang, ps.map((p) => pieceNameDef(p, lang)));

const ROM: Record<TacticTag, RomSay> = {
  hanging: (t, r, l) => `${capFirst(own(t.pieces[0], r, l))} ${l === 'es' ? 'no tiene defensa' : 'está sem proteção'}.`,
  outnumbered: (t, r, l) => {
    const who = capFirst(own(t.pieces[0], r, l));
    const f = genderOf(l, t.pieces[0].type) === 'f';
    if (t.cheaperAttacker) {
      return l === 'es'
        ? `${who} está atacad${f ? 'a' : 'o'} por ${pieceNameDef(t.cheaperAttacker, l)}; cambiar pierde material.`
        : `${who} está sendo atacad${f ? 'a' : 'o'} por ${pieceNameDef(t.cheaperAttacker, l)}; a troca perde material.`;
    }
    return l === 'es' ? `${who} tiene más atacantes que defensores.` : `${who} tem mais atacantes do que defensores.`;
  },
  fork: (t, r, l) => (l === 'es'
    ? (r ? `El rival puede hacer una horquilla con ${t.by} sobre ${ownList(t, true, l)}.` : `${t.by} hace una horquilla sobre ${ownList(t, false, l)}.`)
    : (r ? `O adversário pode fazer um garfo com ${t.by} em ${ownList(t, true, l)}.` : `${t.by} faz um garfo em ${ownList(t, false, l)}.`)),
  pawn_fork: (t, r, l) => (l === 'es'
    ? (r ? `El rival puede hacer una horquilla con la jugada de peón ${t.by} sobre ${ownList(t, true, l)}.` : `La jugada de peón ${t.by} hace una horquilla sobre ${ownList(t, false, l)}.`)
    : (r ? `O adversário pode fazer um garfo com o lance de peão ${t.by} em ${ownList(t, true, l)}.` : `O lance de peão ${t.by} faz um garfo em ${ownList(t, false, l)}.`)),
  pin: (t, r, l) => {
    const f = genderOf(l, t.pieces[0].type) === 'f';
    return l === 'es'
      ? `${capFirst(own(t.pieces[0], r, l))} está clavad${f ? 'a' : 'o'} contra ${pieceNameDef(t.pieces[1], l)}.`
      : `${capFirst(own(t.pieces[0], r, l))} está cravad${f ? 'a' : 'o'} contra ${pieceNameDef(t.pieces[1], l)}.`;
  },
  skewer: (t, r, l) => (l === 'es'
    ? (r ? `${capFirst(own(t.pieces[0], true, l))} sufre un ataque en rayos X; cuando se mueva, cae ${pieceNameDef(t.pieces[1], l)}.`
      : `Puedes atacar en rayos X ${own(t.pieces[0], false, l)}; ${pieceNameDef(t.pieces[1], l)} que está detrás no puede escapar.`)
    : (r ? `${capFirst(own(t.pieces[0], true, l))} está sob um raio X; quando se mover, cai ${pieceNameDef(t.pieces[1], l)}.`
      : `Você pode fazer um raio X em ${own(t.pieces[0], false, l)}; ${pieceNameDef(t.pieces[1], l)} que está atrás não consegue escapar.`)),
  discovered: (t, r, l) => (l === 'es'
    ? (r ? `Cuando el rival juegue ${t.by}, ${own(t.pieces[0], true, l)} quedará bajo ataque.` : `${t.by} descubre un ataque contra ${own(t.pieces[0], false, l)}.`)
    : (r ? `Quando o adversário jogar ${t.by}, ${own(t.pieces[0], true, l)} ficará sob ataque.` : `${t.by} descobre um ataque contra ${own(t.pieces[0], false, l)}.`)),
  mate_threat: (t, r, l) => {
    const mate = !!t.by?.endsWith('#');
    return l === 'es'
      ? (mate ? (r ? `El rival tiene mate en una: ${t.by}.` : `${t.by} es mate.`)
        : (r ? `El rival tiene un ataque de mate que empieza con ${t.by}.` : `Hay un ataque de mate que empieza con ${t.by}.`))
      : (mate ? (r ? `O adversário tem mate em um: ${t.by}.` : `${t.by} é mate.`)
        : (r ? `O adversário tem um ataque de mate começando com ${t.by}.` : `Há um ataque de mate começando com ${t.by}.`));
  },
  back_rank: (t, r, l) => (l === 'es'
    ? `${r ? 'Tu rey no tiene' : 'El rey rival no tiene'} casilla de escape; ${t.by} es mate del pasillo.`
    : `${r ? 'Seu rei não tem' : 'O rei do adversário não tem'} casa de fuga; ${t.by} é mate do corredor.`),
  trapped: (t, r, l) => (l === 'es' ? `${capFirst(own(t.pieces[0], r, l))} no tiene casilla segura.` : `${capFirst(own(t.pieces[0], r, l))} não tem casa segura.`),
  passed_pawn: (t, r, l) => (l === 'es'
    ? `${capFirst(own(t.pieces[0], !r, l))} es un peón pasado, sin nada delante.`
    : `${capFirst(own(t.pieces[0], !r, l))} é um peão passado, sem nada pela frente.`),
  undeveloped: (t, _r, l) => (l === 'es'
    ? `${capFirst(defList(t.pieces, l))} ${t.pieces.length > 1 ? 'siguen' : 'sigue'} en su casilla inicial.`
    : `${capFirst(defList(t.pieces, l))} ainda ${t.pieces.length > 1 ? 'estão' : 'está'} na casa inicial.`),
  early_queen: (_t, _r, l) => (l === 'es' ? 'La dama salió antes que los caballos y los alfiles.' : 'A dama saiu antes dos cavalos e dos bispos.'),
  moved_twice: (t, _r, l) => (l === 'es'
    ? `${capFirst(pieceNameDef(t.pieces[0], l))} se movió por segunda vez mientras otras piezas siguen en casa.`
    : `${capFirst(pieceNameDef(t.pieces[0], l))} se moveu pela segunda vez enquanto outras peças ainda estão em casa.`),
  uncastled: (_t, _r, l) => (l === 'es' ? 'El rey todavía no ha enrocado.' : 'O rei ainda não fez o roque.'),
};

export const sentence = (t: Tactic, lang: Lang = 'zh') =>
  lang === 'es' || lang === 'pt' ? ROM[t.tag](t, t.side === 'risk', lang)
    : (lang !== 'zh' ? EN : ZH)[t.tag](t, t.side === 'risk', (p) => pieceName(p, lang));

/** 第 1 段：局面掃描。最多兩句 */
export function scanText(lesson: Lesson, lang: Lang = 'zh'): string {
  if (lesson.scan.length === 0) {
    const w = lesson.me === 'w';
    return mkT(lang)(`輪到${w ? '白' : '黑'}方。`, `${w ? 'White' : 'Black'} to move.`,
      `Juegan las ${w ? 'blancas' : 'negras'}.`, `Vez das ${w ? 'brancas' : 'pretas'}.`);
  }
  return lesson.scan.slice(0, 2).map((t) => sentence(t, lang)).join(pick(lang, '', ' '));
}

/** 第 2 段：一個候選步的後果 */
export function candidateText(c: CandidateLine, winBefore: number, lang: Lang = 'zh'): string {
  const x = mkT(lang);
  const risk = c.tactics.find((t) => t.side === 'risk');
  const odds = `${scoreText(winBefore)} → ${scoreText(c.winAfter)}`;
  if (lang !== 'zh') {
    const who = c.kind === 'played' ? x('', `Your move ${c.san}`, `Tu jugada ${c.san}`, `Seu lance ${c.san}`) : c.san;
    const reason = risk ? `${sentence(risk, lang)} ` : c.line[0] ? x('', `They reply ${c.line[0]}. `, `El rival responde ${c.line[0]}. `, `O adversário responde ${c.line[0]}. `) : '';
    return `${who}: ${reason}${x('', 'Score', 'Evaluación', 'Avaliação')} ${odds}.`;
  }
  const who = c.kind === 'played' ? `你走的 ${c.san}` : c.san;
  const reason = risk ? sentence(risk) : c.line[0] ? `對手回 ${c.line[0]}。` : '';
  return `${who}：${reason}評分 ${odds}。`;
}

/** 第 3 段：建議步與理由。沒有偵測到理由就只講勝率差，不編 */
export function bestText(lesson: Lesson, lang: Lang = 'zh'): string {
  const { best, why, candidates } = lesson;
  const x = mkT(lang);
  const fixed = why.resolved[0];
  const used = why.exploited[0];
  const lead = x(`建議 ${best.san}。`, `Play ${best.san}.`, `Juega ${best.san}.`, `Jogue ${best.san}.`);
  if (used) return `${lead}${pick(lang, '', ' ')}${sentence(used, lang)}`;
  if (fixed) {
    if (lang === 'es' || lang === 'pt') {
      const what = joinList(lang, fixed.pieces.map((p) => pieceName(p, lang))) || fixed.by;
      return lang === 'es'
        ? `${lead} Evita este riesgo: ${tacticLabel(fixed.tag, lang)} (${what}).`
        : `${lead} Evita este risco: ${tacticLabel(fixed.tag, lang)} (${what}).`;
    }
    const what = fixed.pieces.map((p) => pieceName(p, lang)).join(pick(lang, '和 ', ' and ')) || fixed.by;
    return lang === 'en'
      ? `${lead} It avoids the ${tacticLabel(fixed.tag, lang)} (${what}).`
      : `${lead}避開${tacticLabel(fixed.tag, lang)}：${what}。`;
  }
  const played = candidates.find((c) => c.kind === 'played');
  if (played) {
    const a = winProbToCp(best.winAfter), b = winProbToCp(played.winAfter);
    // 你走的那步直接輸掉（勝率 0，換不出分數）：只說高很多
    if (a !== null && b === null) return x(`${lead}評分比 ${played.san} 高很多。`, `${lead} It scores far better than ${played.san}.`,
      `${lead} Su evaluación es mucho mejor que la de ${played.san}.`, `${lead} Sua avaliação é muito melhor que a de ${played.san}.`);
    const diff = a !== null && b !== null ? Math.round((a - b) / 10) / 10 : null;
    // 講解是重新分析的，和當初判定可能有誤差；差距沒有意義時不硬講
    if (diff !== null && diff >= 0.3) return x(`${lead}評分比 ${played.san} 高 ${diff}。`, `${lead} It scores ${diff} better than ${played.san}.`,
      `${lead} Evalúa ${diff} mejor que ${played.san}.`, `${lead} Avalia ${diff} melhor que ${played.san}.`);
  }
  return x(`${lead}評分 ${scoreText(best.winAfter)}。`, `${lead} Score ${scoreText(best.winAfter)}.`,
    `${lead} Evaluación ${scoreText(best.winAfter)}.`, `${lead} Avaliação ${scoreText(best.winAfter)}.`);
}

/** 第 4 段：對手最強反擊與我方應對 */
export function defenceText(d: NonNullable<Lesson['defence']>, lang: Lang = 'zh'): string {
  return mkT(lang)(`對手最強的反擊是 ${d.reply}，用 ${d.answer} 應對。`, `Their strongest reply is ${d.reply}; answer with ${d.answer}.`,
    `Su mejor respuesta es ${d.reply}; contéstala con ${d.answer}.`, `A melhor resposta dele é ${d.reply}; responda com ${d.answer}.`);
}

/** 開局快播：停下來時的台詞 */
export function openingNoteText(n: OpeningNote, lang: Lang = 'zh'): string {
  const move = Math.ceil(n.ply / 2);
  return mkT(lang)(`第 ${move} 手，${sentence(n.tactic)}`, `Move ${move}: ${sentence(n.tactic, 'en')}`,
    `Jugada ${move}: ${sentence(n.tactic, 'es')}`, `Lance ${move}: ${sentence(n.tactic, 'pt')}`);
}
