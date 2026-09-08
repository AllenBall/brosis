import BrosisCore
import Foundation

/// 配额执行（2026-09-08 / D34）。
///
/// **在此之前配额只是个显示**：`StoreOptions.quotaBytes` 硬编码 10 GiB，
/// `ExportController.expireWithNotice()` 写好了却没有任何地方调用它——库到了线也不会删，
/// 一直涨（交接文档 e 批候选第 ② 条就是这件事）。这个调度器把那条路接上。
///
/// 语义完全交给 core 与 `ExportController` 的三态，这里只负责"什么时候查一次"：
///   * `notNeeded`：没到线，什么都不做；
///   * `blocked`：到线了但"要删东西"的通知还没被用户确认 → 弹加密导出窗口，**不删**；
///   * `expired`：确认过了 → 按配额删最旧的原文，记事件。
///
/// 门控：库解锁着、没暂停、开关开着。锁库 / 暂停期间一律不查（那时也开不了库）。
final class QuotaScheduler: @unchecked Sendable {

    static let shared = QuotaScheduler()

    /// 解锁后延迟多久查第一次。让开库、起流、首帧采集先过去。
    static let launchDelaySeconds: TimeInterval = 45

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.brosis.quota", qos: .utility)
    private var timer: DispatchSourceTimer?
    private weak var recorder: Recorder?
    private weak var exporter: ExportController?
    private var _lastNote = "还没查过"

    var lastNote: String { lock.lock(); defer { lock.unlock() }; return _lastNote }

    func configure(recorder: Recorder, exporter: ExportController) {
        lock.lock()
        self.recorder = recorder
        self.exporter = exporter
        lock.unlock()
    }

    func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let interval = Settings.quotaCheckMinutes * 60
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.launchDelaySeconds, repeating: interval)
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

    /// 手动查一次（设置窗口的「现在检查并清理」）。返回给界面显示的一句话。
    /// **必须在主线程**：`ExportController` 是 @MainActor（它到线时会弹加密导出窗口）。
    @MainActor
    @discardableResult
    func checkNow() -> String {
        let (recorder, exporter) = lock.withLock { (self.recorder, self.exporter) }
        guard let recorder, let exporter else { return "还没接线" }
        // 开库时的配额是开库那一刻的设置；用户刚改过就先推给库，免得按旧值判。
        _ = recorder.withStore { $0.setQuotaBytes(Settings.quotaBytes) }
        guard Settings.autoExpire else {
            let action = recorder.withStore { try $0.quotaAction() } ?? nil
            let note = action.map { "只提示不清理（自动清理已关）：\($0.message)" } ?? "库没打开"
            self.note(note)
            return note
        }
        let note = exporter.expireWithNotice()
        self.note(note)
        return note
    }

    /// 定时器跑在 utility 队列上，而检查要碰 @MainActor 的 ExportController，所以回主线程。
    private func tick() {
        guard Settings.autoExpire else { note("自动清理关着，跳过"); return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { _ = self.checkNow() }
        }
    }

    private func note(_ text: String) {
        lock.lock()
        _lastNote = text
        lock.unlock()
        BrosisLog.lifecycle.notice("配额检查：\(text, privacy: .public)")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
