import ChessKitEngine
import Foundation

/// 手機上的 Stockfish 17（ChessKitEngine）。
/// - 神經網路評估檔建置時打包進 App（fetch-nnue.sh）；開發時沒打包到的才下載到 Application Support。
/// - 一次只算一個局面：排隊，分析棋盤（interactive）插在跨局報告（background）前面。
/// - 每次回前兩名（MultiPV 2），第二名拿來提示「也可以」。
/// - 回覆照順序處理（本地版 ChessKitEngine）：每條線取最深的那一筆，bestmove 到了就收尾。
actor StockfishService {
  static let shared = StockfishService()

  enum State: Equatable { case idle, downloading(Double), starting, ready, failed(String) }
  enum Priority { case interactive, background }
  typealias Update = @Sendable ([EngineLine], Int) -> Void

  private(set) var state: State = .idle
  private var engine: Engine?
  private var listener: Task<Void, Never>?
  private var pending: CheckedContinuation<[EngineLine], Never>?
  private var lines: [Int: (depth: Int, line: EngineLine)] = [:]
  private var onUpdate: Update?
  private var shownDepth = 0
  private var cache: [String: [EngineLine]] = [:]

  private var busy = false
  private var running: Priority?
  private var stopped = false
  private var waiting: [(Priority, CheckedContinuation<Void, Never>)] = []
  private var multipv = 2

  static let nets = ["nn-1111cefa1111.nnue", "nn-37f18f62d772.nnue"]

  private static var netDir: URL {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("nnue", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }

  /// 評估檔在哪：App 內建的優先（建置時打包進去），沒有才用下載到 Application Support 的
  private static func netPath(_ name: String) -> String {
    if let u = Bundle.main.url(forResource: name, withExtension: nil) { return u.path }
    return netDir.appendingPathComponent(name).path
  }

  static var netsReady: Bool { nets.allSatisfy { FileManager.default.fileExists(atPath: netPath($0)) } }

  /// 下載評估檔（進度 0–1）
  func prepareNets(progress: @Sendable @escaping (Double) -> Void) async throws {
    for (k, name) in Self.nets.enumerated() {
      let dst = Self.netDir.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: Self.netPath(name)) { continue }
      state = .downloading(Double(k) / Double(Self.nets.count))
      progress(Double(k) / Double(Self.nets.count))
      let url = URL(string: "https://tests.stockfishchess.org/api/nn/\(name)")!
      let (tmp, resp) = try await URLSession.shared.download(from: url)
      guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
      try? FileManager.default.removeItem(at: dst)
      try FileManager.default.moveItem(at: tmp, to: dst)
    }
    progress(1)
  }

  private var starting: Task<Void, Error>?

  /// 只啟動一次：同時有好幾個畫面要引擎時，大家等同一個啟動（不然會開出兩個引擎，其中一個的回覆永遠等不到）
  func start() async throws {
    if state == .ready { return }
    if let t = starting { return try await t.value }
    let t = Task { try await self.boot() }
    starting = t
    defer { starting = nil }
    try await t.value
  }

  private func boot() async throws {
    if state == .ready { return }
    if !Self.netsReady { try await prepareNets { _ in } }
    state = .starting
    let e = Engine(type: .stockfish)
    engine = e
    // 留兩個核心給畫面（核心全吃滿，手機上捲動、動畫都會卡）
    await e.start(coreCount: max(2, ProcessInfo.processInfo.activeProcessorCount - 2), multipv: 2)
    // 等引擎跑起來（start 之後要等 readyok 才會設好）
    var tries = 0
    while !(await e.isRunning), tries < 100 {
      try await Task.sleep(nanoseconds: 50_000_000)
      tries += 1
    }
    guard await e.isRunning else { state = .failed("engine"); throw URLError(.cannotConnectToHost) }
    await e.send(command: .setoption(id: "EvalFile", value: Self.netPath(Self.nets[0])))
    await e.send(command: .setoption(id: "EvalFileSmall", value: Self.netPath(Self.nets[1])))
    listener = Task { [weak self] in
      guard let stream = await e.responseStream else { return }
      for await r in stream { await self?.handle(r) }
    }
    state = .ready
  }

  // MARK: 排隊

  /// 背景工作先排著不開始（快速復盤播放時：引擎一跑就佔滿 CPU，動畫會卡）。正在算的那個局面照常算完，不存半成品
  private var heldBackground = false

  func holdBackground(_ on: Bool) {
    heldBackground = on
    if !on, !busy, !waiting.isEmpty { busy = true; waiting.removeFirst().1.resume() }
  }

  private func acquire(_ p: Priority) async {
    if !busy && !(heldBackground && p == .background) { busy = true; running = p; return }
    await withCheckedContinuation { waiting.append((p, $0)) }
    running = p
  }

  private func release() {
    running = nil
    let i = waiting.firstIndex { $0.0 == .interactive } ?? (waiting.isEmpty || heldBackground ? nil : 0)
    if let i { waiting.remove(at: i).1.resume() } else { busy = false }
  }

  /// 分析棋盤換了局面：正在算的舊局面直接收尾（只停 interactive，不打斷報告）
  func stopInteractive() async {
    guard running == .interactive, pending != nil, let e = engine else { return }
    stopped = true
    await e.send(command: .stop)
  }

  // MARK: 回覆

  private func handle(_ r: EngineResponse) {
    switch r {
    case let .info(info):
      guard pending != nil, let pv = info.pv, !pv.isEmpty, let score = info.score else { return }
      let k = info.multipv ?? 1
      let depth = info.depth ?? 0
      // 同一個深度的回覆可能有好幾筆（上下界），留比較長的那條線
      if let old = lines[k], old.depth > depth || (old.depth == depth && old.line.pv.count > pv.count) { return }
      lines[k] = (depth, EngineLine(cp: score.cp.map { Int($0) }, mate: score.mate, pv: pv))
      // 分析棋盤：深度往上時即時更新
      if let onUpdate, depth > shownDepth {
        shownDepth = depth
        onUpdate(lines.keys.sorted().compactMap { lines[$0]?.line }, depth)
      }
    case .bestmove:
      // 回覆照順序到（本地版 ChessKitEngine 改成依序處理）：bestmove 到了，這一輪的 info 都已經收到
      finish()
    default: break
    }
  }

  private var job: UUID?

  private func timeout(_ token: UUID) async {
    guard job == token, pending != nil, let e = engine else { return }
    stopped = true
    await e.send(command: .stop)
    try? await Task.sleep(nanoseconds: 300_000_000)
    if job == token { finish() }
  }

  private func finish() {
    guard let c = pending else { return }
    pending = nil
    job = nil
    c.resume(returning: lines.keys.sorted().compactMap { lines[$0]?.line })
  }

  /// 這個局面的前兩名（走棋方視角）。
  /// 用「節點數」限制，不用深度（跟 Lichess 伺服器分析同一種做法）：每個局面花的時間穩定。
  func analyse(fen: String, nodes: Int = AnalysisStore.nodes, depth: Int? = nil, multipv want: Int = 2, priority: Priority = .background, onUpdate: Update? = nil) async -> [EngineLine] {
    let key = "\(fen)|\(depth.map { "d\($0)" } ?? "\(nodes)")|\(want)"
    if let hit = cache[key] { return hit }
    if state != .ready { try? await start() }
    guard let e = engine, state == .ready else { return [] }
    await acquire(priority)
    defer { release() }
    if let hit = cache[key] { return hit }
    // 已經將死或逼和：沒有步可以算（引擎會回 bestmove (none)）
    guard FEN.hasMoves(fen) else { return [] }
    lines = [:]
    shownDepth = 0
    stopped = false
    self.onUpdate = onUpdate
    let out: [EngineLine] = await withCheckedContinuation { c in
      pending = c
      let change = want != multipv
      multipv = want
      let token = UUID()
      job = token
      Task {
        if change { await e.send(command: .setoption(id: "MultiPV", value: "\(want)")) }
        await e.send(command: .position(.fen(fen)))
        if let depth { await e.send(command: .go(depth: depth)) } else { await e.send(command: .go(nodes: nodes)) }
      }
      // 保險：時間到了還沒收到 bestmove 就叫它停、自己收尾，絕不卡住整個排隊
      let limit = UInt64(2 + nodes / 100_000) * 1_000_000_000
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: limit)
        await self?.timeout(token)
      }
    }
    self.onUpdate = nil
    if !out.isEmpty, !stopped { cache[key] = out }
    return out
  }
}
