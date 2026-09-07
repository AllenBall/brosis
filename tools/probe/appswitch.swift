// tools/probe/appswitch.swift
// brosis D2 应用切换探针 —— 只轮询前台应用与键鼠空闲秒数，不需要任何 TCC 权限。
//
// 不读窗口标题、不截屏、不用 Accessibility、不读浏览器 URL，因此不会触发
// 屏幕录制 / 辅助功能 / 自动化 任何一个授权弹窗。
//
// 编译：swiftc -O appswitch.swift -o appswitch
// 运行：./appswitch --duration 30 --verbose

import Foundation
import AppKit

let kVersion = "0.1.0"
let kLabel = "com.brosis.probe"
let kLoginWindowBundle = "com.apple.loginwindow"

// MARK: - 路径

func defaultDataDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("brosis-probe", isDirectory: true)
}

// MARK: - 参数

struct Options {
    var intervalS: Double = 2.0        // 轮询间隔（秒）
    var activeIdleS: Double = 60.0     // 活跃口径：采样时刻空闲秒数 < 该值，本次采样计入 active_s
    var suspendIdleS: Double = 900.0   // 兜底暂停：空闲秒数 >= 该值，视为锁屏 / 离开，停止累计停留
    var maxGapS: Double = 10.0         // 相邻两次采样间隔 > 该值，视为进程被挂起（系统睡眠等）
    var rotateS: Double = 1800.0       // 单区间最长时长，超过则切段落盘，避免崩溃丢数据
    var checkpointS: Double = 30.0     // 未完成区间的状态文件落盘间隔
    var minDwellS: Double = 0.5        // 短于该值的区间丢弃（轮询抖动）
    var forceResumeTicks: Int = 15     // 暂停中连续 N 次采样都检测到新输入，则强制恢复（防止恢复通知丢失）
    var durationS: Double? = nil       // 前台冒烟用：跑满该秒数后正常退出
    var dataDir: URL = defaultDataDir()
    var fileOverride: URL? = nil
    var verbose = false
    // 自测钩子：不接触 NSWorkspace / CGEventSource，用于在锁屏或无人值守时验证区间与时长口径
    var simulate: [(String, Double)]? = nil   // --simulate "com.a:6,com.b:6"
    var fakeIdle: Double? = nil               // --fake-idle 3
}

func usage() -> String {
    return """
    appswitch \(kVersion) — brosis D2 应用切换探针（无需任何权限）

    用法: appswitch [选项]

      --dir <目录>          数据目录，默认 ~/Library/Application Support/brosis-probe
      --file <路径>         JSONL 输出文件，默认 <数据目录>/appswitch.jsonl
      --interval <秒>       轮询间隔，默认 2
      --active-idle <秒>    活跃判定阈值，默认 60
      --suspend-idle <秒>   空闲兜底暂停阈值，默认 900
      --rotate <秒>         单区间最长时长，默认 1800
      --checkpoint <秒>     未完成区间的状态落盘间隔，默认 30
      --duration <秒>       跑满该秒数后退出（冒烟测试用），默认常驻
      --simulate <序列>     自测：用 "bundle:秒数,bundle:秒数" 代替真实前台应用，跑完退出
      --fake-idle <秒>      自测：用固定值代替真实键鼠空闲秒数
      --verbose             每写一条区间打印一行
      --version / --help

    输出：JSONL，每行一个前台停留区间
      {"start","end","bundle_id","name","dwell_s","active_s","end_reason"}
    """
}

func parseArgs() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    func need(_ flag: String) -> String {
        i += 1
        guard i < args.count else {
            FileHandle.standardError.write("缺少 \(flag) 的取值\n".data(using: .utf8)!)
            exit(2)
        }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--dir": o.dataDir = URL(fileURLWithPath: (need("--dir") as NSString).expandingTildeInPath, isDirectory: true)
        case "--file": o.fileOverride = URL(fileURLWithPath: (need("--file") as NSString).expandingTildeInPath)
        case "--interval": o.intervalS = Double(need("--interval")) ?? o.intervalS
        case "--active-idle": o.activeIdleS = Double(need("--active-idle")) ?? o.activeIdleS
        case "--suspend-idle": o.suspendIdleS = Double(need("--suspend-idle")) ?? o.suspendIdleS
        case "--rotate": o.rotateS = Double(need("--rotate")) ?? o.rotateS
        case "--checkpoint": o.checkpointS = Double(need("--checkpoint")) ?? o.checkpointS
        case "--duration": o.durationS = Double(need("--duration"))
        case "--simulate":
            var seq: [(String, Double)] = []
            for item in need("--simulate").split(separator: ",") {
                let kv = item.split(separator: ":")
                if kv.count == 2, let d = Double(kv[1]) { seq.append((String(kv[0]), d)) }
            }
            o.simulate = seq.isEmpty ? nil : seq
        case "--fake-idle": o.fakeIdle = Double(need("--fake-idle"))
        case "--verbose", "-v": o.verbose = true
        case "--version": print(kVersion); exit(0)
        case "--help", "-h": print(usage()); exit(0)
        default:
            FileHandle.standardError.write("未知参数: \(args[i])\n\n\(usage())\n".data(using: .utf8)!)
            exit(2)
        }
        i += 1
    }
    if o.intervalS < 0.2 { o.intervalS = 0.2 }
    if o.maxGapS < o.intervalS * 3 { o.maxGapS = o.intervalS * 3 }
    return o
}

// MARK: - 小工具

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f
}()

func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

func jsonEscape(_ s: String) -> String {
    var out = String()
    out.reserveCapacity(s.unicodeScalars.count + 8)
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
            else { out.unicodeScalars.append(u) }
        }
    }
    return out
}

func num(_ v: Double) -> String { String(format: "%.1f", v) }

// 键鼠空闲秒数：取所有键盘 / 鼠标事件类型中最小的“距上次事件秒数”。
// .combinedSessionState 覆盖本会话内的 HID 与合成事件，不需要任何权限。
let idleEventTypes: [CGEventType] = [
    .keyDown, .flagsChanged,
    .leftMouseDown, .rightMouseDown, .otherMouseDown,
    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    .mouseMoved, .scrollWheel
]

func idleSeconds() -> Double {
    var m = Double.greatestFiniteMagnitude
    for t in idleEventTypes {
        let v = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t)
        if v.isFinite && v >= 0 && v < m { m = v }
    }
    return m == Double.greatestFiniteMagnitude ? 0 : m
}

// MARK: - 探针

final class Probe {
    private let opts: Options
    private let jsonlURL: URL
    private let stateURL: URL
    private var out: FileHandle?

    // 暂停状态：可能同时来自多个来源（锁屏 / 睡眠 / 快速用户切换 / 空闲兜底），
    // 全部解除后才恢复记录。
    private var suspendReasons = Set<String>()
    private var inputWhileSuspended = 0

    // 当前区间
    private var hasInterval = false
    private var curBundle = ""
    private var curName = ""
    private var curStart = Date()
    private var curDwell: Double = 0
    private var curActive: Double = 0

    private var lastTick = Date()
    private var lastCheckpoint = Date.distantPast
    private var startedAt = Date()
    private var written = 0
    private var timer: Timer?

    var suspended: Bool { !suspendReasons.isEmpty }

    /// 空闲秒数；自测模式下用固定值
    private func currentIdle() -> Double { opts.fakeIdle ?? idleSeconds() }

    init(_ o: Options) {
        self.opts = o
        try? FileManager.default.createDirectory(at: o.dataDir, withIntermediateDirectories: true)
        self.jsonlURL = o.fileOverride ?? o.dataDir.appendingPathComponent("appswitch.jsonl")
        self.stateURL = o.dataDir.appendingPathComponent("current.json")
        if !FileManager.default.fileExists(atPath: jsonlURL.path) {
            FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
        }
        self.out = try? FileHandle(forWritingTo: jsonlURL)
    }

    func log(_ s: String) {
        print("[\(iso(Date()))] \(s)")
        fflush(stdout)
    }

    // MARK: 写入

    private func writeLine(_ s: String) {
        guard let out = out, let d = (s + "\n").data(using: .utf8) else { return }
        _ = try? out.seekToEnd()
        try? out.write(contentsOf: d)
    }

    private func emit(start: Date, end: Date, bundle: String, name: String,
                      dwell: Double, active: Double, reason: String) {
        let line = "{\"start\":\"\(iso(start))\",\"end\":\"\(iso(end))\","
            + "\"bundle_id\":\"\(jsonEscape(bundle))\",\"name\":\"\(jsonEscape(name))\","
            + "\"dwell_s\":\(num(dwell)),\"active_s\":\(num(active)),"
            + "\"end_reason\":\"\(reason)\"}"
        writeLine(line)
        written += 1
        if opts.verbose {
            log("写入 \(bundle) dwell=\(num(dwell))s active=\(num(active))s reason=\(reason)")
        }
    }

    // MARK: 区间生命周期

    private func begin(_ bundle: String, _ name: String, at: Date) {
        hasInterval = true
        curBundle = bundle; curName = name
        curStart = at; curDwell = 0; curActive = 0
    }

    @discardableResult
    private func flush(end: Date, reason: String) -> Bool {
        guard hasInterval else { return false }
        hasInterval = false
        let e = max(end, curStart)
        let dwell = max(0, min(curDwell, e.timeIntervalSince(curStart)))
        let active = max(0, min(curActive, dwell))
        curDwell = 0; curActive = 0
        removeState()
        guard dwell >= opts.minDwellS else { return false }
        emit(start: curStart, end: e, bundle: curBundle, name: curName,
             dwell: dwell, active: active, reason: reason)
        return true
    }

    // 把 lastTick..now 这段时间记到当前区间上
    private func accrue(now: Date, idle: Double) {
        guard hasInterval else { return }
        let delta = min(max(now.timeIntervalSince(lastTick), 0), opts.maxGapS)
        curDwell += delta
        if idle < opts.activeIdleS { curActive += delta }
    }

    // MARK: 未完成区间的断电保护

    private func saveState(_ now: Date) {
        guard hasInterval else { return }
        let obj = "{\"v\":\"\(kVersion)\",\"start\":\"\(iso(curStart))\",\"last_tick\":\"\(iso(now))\","
            + "\"bundle_id\":\"\(jsonEscape(curBundle))\",\"name\":\"\(jsonEscape(curName))\","
            + "\"dwell_s\":\(num(curDwell)),\"active_s\":\(num(curActive))}"
        try? obj.data(using: .utf8)?.write(to: stateURL, options: .atomic)
    }

    private func removeState() { try? FileManager.default.removeItem(at: stateURL) }

    private func recoverState() {
        guard let d = try? Data(contentsOf: stateURL),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let s = o["start"] as? String, let lt = o["last_tick"] as? String,
              let bundle = o["bundle_id"] as? String,
              let start = isoFormatter.date(from: s), let end = isoFormatter.date(from: lt) else {
            removeState(); return
        }
        let name = (o["name"] as? String) ?? ""
        let dwell = ((o["dwell_s"] as? NSNumber)?.doubleValue) ?? 0
        let active = ((o["active_s"] as? NSNumber)?.doubleValue) ?? 0
        removeState()
        guard dwell >= opts.minDwellS, end >= start else { return }
        emit(start: start, end: end, bundle: bundle, name: name,
             dwell: min(dwell, end.timeIntervalSince(start)), active: active, reason: "recovered")
        log("恢复了上次未收口的区间：\(bundle) dwell=\(num(dwell))s")
    }

    // MARK: 暂停 / 恢复

    func suspend(_ reason: String) {
        let now = Date()
        if !suspended, hasInterval {
            accrue(now: now, idle: currentIdle())
            flush(end: now, reason: reason)
        } else {
            flush(end: min(now, lastTick), reason: reason)
        }
        suspendReasons.insert(reason)
        inputWhileSuspended = 0
        lastTick = now
        log("暂停记录（\(reason)），当前暂停来源: \(suspendReasons.sorted().joined(separator: ","))")
    }

    func resume(_ reason: String, clearing: String) {
        suspendReasons.remove(clearing)
        lastTick = Date()
        inputWhileSuspended = 0
        if suspended {
            log("收到 \(reason)，仍有暂停来源: \(suspendReasons.sorted().joined(separator: ","))")
        } else {
            log("恢复记录（\(reason)）")
        }
    }

    // MARK: 主循环

    func tick() {
        let now = Date()
        let gap = now.timeIntervalSince(lastTick)
        let idle = currentIdle()

        // 1) 采样间隔异常大：进程被挂起（系统睡眠 / 长时间调度延迟），按上次心跳收口
        if gap > opts.maxGapS {
            if hasInterval {
                flush(end: lastTick, reason: "gap")
                log("检测到 \(Int(gap)) 秒采样空档，按上次心跳收口")
            }
            lastTick = now
        }

        // 2) 观测前台应用（自测模式下按脚本序列产生）
        let bundle: String
        let name: String
        if let sim = opts.simulate {
            let t = now.timeIntervalSince(startedAt)
            var acc = 0.0
            var pick: String? = nil
            for (b, d) in sim {
                if t < acc + d { pick = b; break }
                acc += d
            }
            guard let b = pick else { shutdown("simulate-end") }
            bundle = b
            name = "sim:" + b
        } else if let app = NSWorkspace.shared.frontmostApplication {
            bundle = app.bundleIdentifier ?? "unknown"
            name = app.localizedName ?? "(未知)"
        } else {
            bundle = "none"; name = "(无前台应用)"
        }

        // 3) 锁屏直判：锁屏 / 登录窗口时前台应用就是 com.apple.loginwindow。
        //    这是最可靠的一路信号，即使 com.apple.screenIsLocked 分布式通知没送达也成立。
        let atLoginWindow = (bundle == kLoginWindowBundle)
        if atLoginWindow && !suspendReasons.contains("loginwindow") {
            if hasInterval {
                accrue(now: now, idle: idle)
                flush(end: now, reason: "screen_locked")
            }
            suspendReasons.insert("loginwindow")
            inputWhileSuspended = 0
            log("前台为登录窗口，判定锁屏，暂停记录")
        }
        if !atLoginWindow && suspendReasons.contains("loginwindow") {
            suspendReasons.remove("loginwindow")
            lastTick = now
            log("前台已离开登录窗口，判定解锁"
                + (suspended ? "，仍有暂停来源: \(suspendReasons.sorted().joined(separator: ","))" : "，恢复记录"))
        }

        // 4) 暂停中：只判断能否恢复
        if suspended {
            if suspendReasons.contains("idle") && idle < opts.suspendIdleS {
                resume("检测到输入", clearing: "idle")
            }
            if suspended && !atLoginWindow && idle < 5 {
                // 恢复类通知不保证送达：连续检测到新输入且不在登录窗口，则强制恢复
                inputWhileSuspended += 1
                if inputWhileSuspended >= opts.forceResumeTicks {
                    log("暂停中连续 \(inputWhileSuspended) 次采样检测到输入，强制恢复（原暂停来源: \(suspendReasons.sorted().joined(separator: ","))）")
                    suspendReasons.removeAll()
                    inputWhileSuspended = 0
                }
            } else if atLoginWindow || idle >= 5 {
                inputWhileSuspended = 0
            }
            lastTick = now
            if suspended { return }
        }

        // 5) 空闲兜底：长时间无键鼠输入，视为锁屏 / 离开。
        //    区间结束时刻回拨到“最后一次输入”，把这段空闲从停留时长里扣掉。
        if idle >= opts.suspendIdleS {
            if hasInterval {
                let end = max(curStart, now.addingTimeInterval(-idle))
                flush(end: end, reason: "idle")
            }
            suspendReasons.insert("idle")
            inputWhileSuspended = 0
            lastTick = now
            log("空闲 \(Int(idle)) 秒，按兜底规则暂停记录")
            return
        }

        // 6) 正常累计
        if hasInterval && bundle == curBundle {
            accrue(now: now, idle: idle)
            if curDwell >= opts.rotateS {
                // 满 30 分钟切段。若此刻已经空闲了一段时间（>= 活跃阈值），把这段空闲
                // 从已落盘的段里挪到新段上：旧段收口在“最后一次输入”，新段以同一时刻开始
                // 并预置这段空闲的 dwell。这样之后若空闲达到兜底阈值，回拨仍能把它扣掉；
                // 否则这段空闲会永久留在旧段里（最多多记 suspendIdle 秒，见 README 六 已知偏差）。
                let cut = now.addingTimeInterval(-idle)
                if idle >= opts.activeIdleS && cut > curStart {
                    flush(end: cut, reason: "rotate")
                    begin(bundle, name, at: cut)
                    curDwell = idle          // 空闲这段先挂在新段上，active 不计
                } else {
                    flush(end: now, reason: "rotate")
                    begin(bundle, name, at: now)
                }
            }
        } else {
            if hasInterval {
                // 切换：本轮 delta 仍记给上一个应用，收口于发现时刻（最多滞后一个轮询间隔）
                accrue(now: now, idle: idle)
                flush(end: now, reason: "switch")
            }
            begin(bundle, name, at: now)
        }

        lastTick = now
        if now.timeIntervalSince(lastCheckpoint) >= opts.checkpointS {
            lastCheckpoint = now
            saveState(now)
        }
    }

    func start() {
        startedAt = Date()
        lastTick = startedAt
        log("appswitch \(kVersion) 启动 pid=\(getpid()) 间隔=\(num(opts.intervalS))s "
            + "活跃阈值=\(num(opts.activeIdleS))s 空闲暂停=\(num(opts.suspendIdleS))s")
        log("数据文件: \(jsonlURL.path)")
        recoverState()

        let wsnc = NSWorkspace.shared.notificationCenter
        func obs(_ n: Notification.Name, _ h: @escaping () -> Void) {
            wsnc.addObserver(forName: n, object: nil, queue: .main) { _ in h() }
        }
        obs(NSWorkspace.willSleepNotification) { [weak self] in self?.suspend("sleep") }
        obs(NSWorkspace.didWakeNotification) { [weak self] in self?.resume("wake", clearing: "sleep") }
        obs(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.suspend("screens_slept") }
        obs(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.resume("screens_woke", clearing: "screens_slept") }
        obs(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.suspend("session_inactive") }
        obs(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.resume("session_active", clearing: "session_inactive") }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.suspend("screen_locked")
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.resume("screen_unlocked", clearing: "screen_locked")
        }

        let t = Timer(timeInterval: opts.intervalS, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = opts.intervalS * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()

        if let d = opts.durationS {
            let stop = Timer(timeInterval: d, repeats: false) { [weak self] _ in
                self?.shutdown("duration")
            }
            RunLoop.main.add(stop, forMode: .common)
        }
    }

    func shutdown(_ reason: String) -> Never {
        timer?.invalidate()
        let now = Date()
        if hasInterval {
            accrue(now: now, idle: currentIdle())
            flush(end: now, reason: "shutdown")
        }
        removeState()
        try? out?.close()
        log("退出（\(reason)）：本次运行 \(Int(now.timeIntervalSince(startedAt))) 秒，写入 \(written) 条区间")
        exit(0)
    }
}

// MARK: - 入口

let options = parseArgs()
let probe = Probe(options)

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigTerm.setEventHandler { probe.shutdown("SIGTERM") }
sigTerm.resume()
let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigInt.setEventHandler { probe.shutdown("SIGINT") }
sigInt.resume()

probe.start()
RunLoop.main.run()
