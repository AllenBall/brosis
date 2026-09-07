import Foundation

/// `--dump-ocr`：把自绘样张的真值与识别文本逐行打印出来。
///
/// 存在的理由和 `--dump-vectors` 一样是**可核对**：自检只报一个召回率与 CER，
/// 复核的人没法从那一行看出"没召回的那个 token 是被认错了，还是只是全角 / 半角写法不同"
/// （accurate 模型会把代码里的 `(` `)` `:` `,` 转成全角，见 D24 与 ocr_bench 的实测）。
/// 它同样不碰 TCC、不开库、不创建 NSApplication。
enum OCRDump {

    static func run() -> Int32 {
        print("brosis \(BuildInfo.version) 自绘样张 OCR 转储（只读，不开库、不碰 TCC）")
        for outcome in OCRSelfTest.run() {
            print("\n## \(outcome.sampleID)@\(outcome.scaleLabel) "
                  + "\(outcome.pixelWidth)×\(outcome.pixelHeight)")
            print("- 无标点标识符召回 严格 \(String(format: "%.3f", outcome.identifierRecall))")
            print("- 带标点标识符召回 NFKC 折叠后 "
                  + "\(String(format: "%.3f", outcome.foldedIdentifierRecall))"
                  + " / 严格 \(String(format: "%.3f", outcome.punctuatedStrictRecall))")
            print("- CER \(String(format: "%.4f", outcome.cer))"
                  + "、中文行 CER \(String(format: "%.4f", outcome.chineseCER))"
                  + "、置信度 \(String(format: "%.3f", outcome.meanConfidence))"
                  + "、\(Int(outcome.elapsedMS)) ms")
            if !outcome.missingIdentifiers.isEmpty {
                print("- 严格未召回（无标点组）："
                      + outcome.missingIdentifiers.joined(separator: " / "))
            }
            // 带标点组的逐字节未召回**总是**打出来（这正是本轮要说明的那件事：
            // 差的是全角括号 / 冒号，不是认错了字）。
            if !outcome.punctuatedStrictMissing.isEmpty {
                print("- 严格未召回（带标点组，逐字节）："
                      + outcome.punctuatedStrictMissing.joined(separator: " / "))
            }
            if !outcome.foldedMissingIdentifiers.isEmpty {
                print("- 折叠后仍未召回：" + outcome.foldedMissingIdentifiers.joined(separator: " / "))
            }
            print("```")
            print(outcome.recognizedText)
            print("```")
        }
        return 0
    }
}
