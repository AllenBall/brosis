import BrosisCore
import Foundation

/// 自动把装了的 harness 接进来（2026-09-09 用户要求：默认监控、自动添加并授权、可手动关）。
///
/// 手点那条路是 `MCPIntegrationWindow`，动作层是 `MCPIntegration.setEnabled`——
/// **这里一行配置逻辑都不重写**，只决定"什么时候、对谁"调它。
///
/// 四条边界，少一条就变成"自动给人添乱"：
///  1. **只碰装了的**（`installed`）。否则会在别人家目录里建出 `~/.grok/`、`~/.kimi-code/`
///     这些他根本没装的东西。
///  2. **手动关过的永不自动开**。面板 / 命令行点「关闭集成」会把 id 记进 optOut，
///     这条监控永远跳过它——否则"可以手动关闭"就是句空话，下一次 tick 就给他开回来。
///  3. **解析不了、写不了的不猜**：配置坏了（`configProblem`），或者只能给剪贴板片段
///     （`allowDirectWrite == false` 且找不到官方 CLI）时跳过，留给面板让人处理。
///  4. **指向别处的只在旧路径已经没了时才改**。指向一个**还在**的别的可执行文件，
///     多半是开发者故意接的构建目录，自动改掉是抢方向盘；指向一个已经不存在的路径
///     （app 挪过位置 / 重装过）则是纯故障，修掉它。
///
/// 性能（用户 2026-09-09 明确提的）：一次整表探测 = 6 个 harness 的 stat + 读配置 + 解析，
/// **本机实测 2 ms**（自检里那行 `整表探测 … ms` 每次都会重新量，慢过 2 s 就判失败）。
/// 30 分钟一次 ≈ 一个核的一亿分之一，所以这里**没有退避、没有指纹缓存**——那点复杂度
/// 买不到任何东西，反而会让"新装的 harness 多久被发现"变成一个说不清的数。
/// 定时器给了 120 s leeway 让系统合并唤醒；库没解锁时**连探测都不做**（发不了 grant，
/// 扫了也白扫）。
///
/// **不开学习模式**（用户明确要求）：学习模式是每 2 秒查一次 `mcp_audit` 的轮询，
/// 只该由人按一次、跑 60 秒。自动这条路不需要它：我们直接写的那几家配置里带了
/// `BROSIS_CLIENT_ID=<harness id>`（见 `MCPConfigWriter.entry`），客户端自报的名字
/// 因此**恒等于**我们发 grant 的名字，"名字对不上被全拒"从设计上就不会发生。
final class MCPAutoIntegration: @unchecked Sendable {

    static let shared = MCPAutoIntegration()

    /// 总开关。**默认开**——这就是用户要的行为。
    static let enabledKey = "mcp.autoIntegrate"

    static let intervalSeconds: TimeInterval = 30 * 60
    /// 解锁后延迟多久跑第一次：给启动阶段（授权、起流、首帧采集）让开。
    static let launchDelaySeconds: TimeInterval = 30

    /// 总开关。setter 自己写键并自己起停（与 `AutoIndexScheduler.isEnabled` 同一写法）。
    /// 关掉**不会**撤销已经接好的集成——那是另一件事，要撤在面板里一行一行点。
    ///
    /// 「哪几家被手动关过」不在这里：它是每个 harness 的状态，存在
    /// `MCPIntegration.optedOut`（`status` 要读、`setEnabled` 要写，两个都在那一层）。
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue { shared.start() } else { shared.stop() }
        }
    }

    // MARK: - 判定（纯函数）

    /// 这一轮该动谁。返回的就是 `decide` 手上那几条 `Status`——曾经返回一个只装
    /// `harnessID` 的 `Candidate`，于是 `tick` 还得回头在数组里把 `Status` 找回来，
    /// 外带一条永远走不到的 `else { continue }`。同时删掉的还有一个两分支的 `Action` 枚举：
    /// 两个分支下游做的事一模一样（都是 `setEnabled(true, …)`），它只被拼进日志字符串——
    /// 一个不分派的枚举会骗人，让下一个加分支的人以为有地方会区别对待。
    ///
    /// `commandExists` 注入是为了让自检不依赖本机真实文件。
    static func decide(statuses: [MCPIntegration.Status],
                       commandExists: (String) -> Bool) -> [MCPIntegration.Status] {
        statuses.filter { status in
            guard status.installed,
                  !status.manuallyDisabled,
                  status.configProblem == nil,
                  status.writeRoute != .snippetOnly
            else { return false }

            guard status.configured else { return true }
            if status.pointsElsewhere {
                // 旧路径还在 = 别人故意接的，别动；已经没了 = 纯故障，修。
                guard let current = status.currentCommand else { return false }
                return !commandExists(current)
            }
            return !status.hasGrant || !status.clientIDPinned
        }
    }

    // MARK: - 定时器

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.brosis.mcp-auto", qos: .utility)
    private var timer: DispatchSourceTimer?
    private weak var recorder: Recorder?
    /// **存 nil 而不是存一句现成的中文**：`shared` 是启动时就建出来的，
    /// 在那一刻把 L(...) 求值等于把它冻在启动时的语言上，用户中途换语言就露馅
    /// （和 `MCPIntegrationWindow.columns` 那个 `var` 不能写成 `let` 是同一个坑）。
    private var _lastDecision: String?

    var lastDecision: String {
        lock.withLock { _lastDecision } ?? L("还没跑过", "has not run yet")
    }

    func configure(recorder: Recorder) {
        lock.withLock { self.recorder = recorder }
    }

    func start() {
        lock.lock()
        guard timer == nil, Self.isEnabled else { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.launchDelaySeconds,
                   repeating: Self.intervalSeconds, leeway: .seconds(120))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        lock.unlock()
    }

    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    /// 把第一次扫描提前到现在。**省下的是 `launchDelaySeconds` 那 30 秒，不是 30 分钟**：
    /// 打开总开关时 `isEnabled` 的 setter 已经调了 `start()`，首次 tick 本来就排在 30 s 后。
    /// 留着它只为让复选框点下去当场有反应；`queue` 是串行的，和定时器不会叠着跑。
    func runNow() { queue.async { [weak self] in self?.tick() } }

    private func tick() {
        guard Self.isEnabled else { note("auto_disabled"); return }
        let recorder = lock.withLock { self.recorder }
        // 库没开就连探测都不做：grant 发不出去，扫一遍纯属白烧。
        guard let recorder, let store = recorder.withStore({ $0 }) else {
            note("store_closed")
            return
        }
        let fm = FileManager.default
        let todo = Self.decide(statuses: MCPIntegration.allStatuses(store: store),
                               commandExists: { fm.isExecutableFile(atPath: $0) })
        guard !todo.isEmpty else { note("nothing_to_do"); return }

        var done: [String] = []
        for status in todo {
            let id = status.harness.id
            // 只是给日志一个词。真要分派时再变成枚举，现在没有第二种做法。
            let reason = status.pointsElsewhere ? "repair_stale_path" : "wire"
            do {
                let outcome = try MCPIntegration.setEnabled(true, harness: status.harness,
                                                            store: store, manualToggle: false)
                done.append("\(id)=\(reason)")
                recorder.logEvent(kind: "mcp_auto_integrated",
                                  detail: "harness=\(id) action=\(reason) "
                                        + "summary=\(outcome.summary.prefix(200))")
            } catch {
                done.append("\(id)=failed")
                recorder.logEvent(kind: "mcp_auto_integration_failed",
                                  detail: "harness=\(id) error=\(error)")
            }
        }
        note(done.joined(separator: " "))
    }

    private func note(_ reason: String) {
        lock.withLock { _lastDecision = reason }
    }
}
