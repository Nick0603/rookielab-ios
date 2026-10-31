// 由 scripts/build-baselines.ts 產生，不要手改。產生日期 2026-10-11
// 樣本：全球 chess.com 玩家（24 國輪流抽樣，scripts/fetch-players.ts）、rapid、60 天內有下棋，每段 50+ 人、每人最近 <=40 局
// 技術指標已單調化（分段越高只會越好或持平）；習慣型指標是原始值（見 build-baselines.ts）

export interface BandBaseline {
  id: 'r400' | 'r600' | 'r800' | 'r1000' | 'r1200' | 'r1400' | 'r1600' | 'r1800' | 'r2000' | 'r2001+';
  players: number;
  games: number;
  hungPerGame: number;
  missedFreeRate: number;
  missedMateRate: number;
  allowedMatePerGame: number;
  convertRate: number;
  hungRate: number;
  missedChanceRate: number;
  allowedMateRate: number;
  leadTimeoutRate: number;
  timeoutLossRate: number;
  matedEarlyRate: number;
  abandonRate: number;
  max: number;
}

export const BAND_BASELINES: BandBaseline[] = [
  {
    id: 'r400',
    players: 50,
    games: 1959,
    hungPerGame: 0.773,
    missedFreeRate: 0.279,
    missedMateRate: 0.545,
    allowedMatePerGame: 0.509,
    convertRate: 0.673,
    hungRate: 0.479,
    missedChanceRate: 0.425,
    allowedMateRate: 0.279,
    leadTimeoutRate: 0.025,
    timeoutLossRate: 0.021,
    matedEarlyRate: 0.072,
    abandonRate: 0.09,
    max: 400
  },
  {
    id: 'r600',
    players: 50,
    games: 1931,
    hungPerGame: 0.587,
    missedFreeRate: 0.232,
    missedMateRate: 0.39,
    allowedMatePerGame: 0.37,
    convertRate: 0.71,
    hungRate: 0.41,
    missedChanceRate: 0.373,
    allowedMateRate: 0.251,
    leadTimeoutRate: 0.014,
    timeoutLossRate: 0.013,
    matedEarlyRate: 0.047,
    abandonRate: 0.071,
    max: 600
  },
  {
    id: 'r800',
    players: 50,
    games: 1973,
    hungPerGame: 0.494,
    missedFreeRate: 0.2,
    missedMateRate: 0.333,
    allowedMatePerGame: 0.322,
    convertRate: 0.732,
    hungRate: 0.358,
    missedChanceRate: 0.313,
    allowedMateRate: 0.244,
    leadTimeoutRate: 0.025,
    timeoutLossRate: 0.036,
    matedEarlyRate: 0.046,
    abandonRate: 0.06,
    max: 800
  },
  {
    id: 'r1000',
    players: 50,
    games: 1945,
    hungPerGame: 0.454,
    missedFreeRate: 0.179,
    missedMateRate: 0.296,
    allowedMatePerGame: 0.259,
    convertRate: 0.803,
    hungRate: 0.35,
    missedChanceRate: 0.282,
    allowedMateRate: 0.201,
    leadTimeoutRate: 0.024,
    timeoutLossRate: 0.032,
    matedEarlyRate: 0.037,
    abandonRate: 0.064,
    max: 1000
  },
  {
    id: 'r1200',
    players: 50,
    games: 1991,
    hungPerGame: 0.39,
    missedFreeRate: 0.173,
    missedMateRate: 0.255,
    allowedMatePerGame: 0.224,
    convertRate: 0.793,
    hungRate: 0.307,
    missedChanceRate: 0.272,
    allowedMateRate: 0.18,
    leadTimeoutRate: 0.02,
    timeoutLossRate: 0.023,
    matedEarlyRate: 0.028,
    abandonRate: 0.037,
    max: 1200
  },
  {
    id: 'r1400',
    players: 50,
    games: 1982,
    hungPerGame: 0.356,
    missedFreeRate: 0.144,
    missedMateRate: 0.216,
    allowedMatePerGame: 0.205,
    convertRate: 0.813,
    hungRate: 0.288,
    missedChanceRate: 0.243,
    allowedMateRate: 0.147,
    leadTimeoutRate: 0.019,
    timeoutLossRate: 0.029,
    matedEarlyRate: 0.016,
    abandonRate: 0.064,
    max: 1400
  },
  {
    id: 'r1600',
    players: 50,
    games: 1988,
    hungPerGame: 0.294,
    missedFreeRate: 0.136,
    missedMateRate: 0.216,
    allowedMatePerGame: 0.155,
    convertRate: 0.809,
    hungRate: 0.248,
    missedChanceRate: 0.231,
    allowedMateRate: 0.131,
    leadTimeoutRate: 0.027,
    timeoutLossRate: 0.031,
    matedEarlyRate: 0.016,
    abandonRate: 0.044,
    max: 1600
  },
  {
    id: 'r1800',
    players: 50,
    games: 1967,
    hungPerGame: 0.294,
    missedFreeRate: 0.136,
    missedMateRate: 0.216,
    allowedMatePerGame: 0.155,
    convertRate: 0.767,
    hungRate: 0.248,
    missedChanceRate: 0.218,
    allowedMateRate: 0.129,
    leadTimeoutRate: 0.028,
    timeoutLossRate: 0.039,
    matedEarlyRate: 0.016,
    abandonRate: 0.029,
    max: 1800
  },
  {
    id: 'r2000',
    players: 50,
    games: 1977,
    hungPerGame: 0.294,
    missedFreeRate: 0.136,
    missedMateRate: 0.163,
    allowedMatePerGame: 0.132,
    convertRate: 0.785,
    hungRate: 0.248,
    missedChanceRate: 0.208,
    allowedMateRate: 0.114,
    leadTimeoutRate: 0.027,
    timeoutLossRate: 0.049,
    matedEarlyRate: 0.009,
    abandonRate: 0.059,
    max: 2000
  },
  {
    id: 'r2001+',
    players: 50,
    games: 1936,
    hungPerGame: 0.294,
    missedFreeRate: 0.135,
    missedMateRate: 0.163,
    allowedMatePerGame: 0.101,
    convertRate: 0.806,
    hungRate: 0.248,
    missedChanceRate: 0.207,
    allowedMateRate: 0.09,
    leadTimeoutRate: 0.036,
    timeoutLossRate: 0.059,
    matedEarlyRate: 0.005,
    abandonRate: 0.027,
    max: 99999
  }
];
