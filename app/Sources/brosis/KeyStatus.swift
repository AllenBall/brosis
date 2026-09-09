import BrosisCore
import CryptoKit
import Foundation

/// `--key-status`：只报密钥在不在、在哪条钥匙串上。**绝不创建、绝不删除、绝不打印密钥内容。**
///
/// 2026-09-09 加：0.4.7 装机后开库报 `rc=26 file is not a database`，而库文件完好。
/// 要分清两种处境——密钥还在但对不上，还是密钥根本没了——只能问钥匙串，
/// 而问它必须带 app 的权利，所以只能做成 app 自己的一个子命令。
enum KeyStatus {

    static func run() -> Int32 {
        print("brosis \(BuildInfo.version) 密钥状态（只读；不创建、不删除、不打印密钥）")
        // **createIfMissing: false 是这条命令的全部要害**：默认那个 true 会在读不到时
        // 直接生成一把新的并写进去——那正是把原密钥彻底盖掉的动作。
        let provider = KeychainKeyProvider(createIfMissing: false)
        var backend = KeychainKeyProvider.Backend.dataProtection
        do {
            let key = try provider.fetchKey(backend: &backend)
            print("- 找到了：\(key.count) 字节，来自 \(backend.rawValue)")
            print("- sha256 前 16 位（仅供比对，不是密钥本身）：\(Fingerprint.short(key))")
        } catch {
            print("- **没找到**：\(error)")
            print("- 两条钥匙串都没有 com.brosis.store / primary-db-key。")
        }
        return 0
    }
}

/// 只为把两个时间点的密钥对不对得上做个比对，不泄露密钥本身。
enum Fingerprint {
    static func short(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
