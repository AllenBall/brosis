import Foundation

extension Store {

    /// 13 项悬空引用检查 + `integrity_check` + `foreign_key_check` + FTS5 `integrity-check`。
    /// 逐项与 E3 的 S7（`tools/proto/test_correctness.py: scenario_7_dangling`）对齐，
    /// 差别只有第 4 / 5 项的口径注释（本包的 FTS 是 contentless + 显式维护，不是触发器）。
    public func integrityReport() throws -> IntegrityReport {
        try withLock { conn in
            func n(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
                Int(try conn.scalarInt(sql, binds) ?? 0)
            }
            var items: [IntegrityReport.Item] = []
            func check(_ name: String, _ value: Int, expected: Int = 0) {
                items.append(IntegrityReport.Item(name: name, value: value, expected: expected))
            }

            check("occurrence 指向不存在的 observation", try n("""
                SELECT COUNT(*) FROM occurrences o WHERE NOT EXISTS(
                  SELECT 1 FROM observations ob WHERE ob.device_id = o.device_id AND ob.id = o.observation_id);
                """))
            check("occurrence 指向不存在的 text_version", try n("""
                SELECT COUNT(*) FROM occurrences o WHERE NOT EXISTS(
                  SELECT 1 FROM text_versions tv WHERE tv.device_id = o.device_id AND tv.id = o.text_version_id);
                """))
            check("FTS 行没有对应的 text_version", try n("""
                SELECT COUNT(*) FROM text_fts_docsize d WHERE NOT EXISTS(
                  SELECT 1 FROM text_versions tv WHERE tv.vrow = d.id);
                """))
            check("text_version 没有对应的 FTS 行", try n("""
                SELECT COUNT(*) FROM text_versions tv WHERE NOT EXISTS(
                  SELECT 1 FROM text_fts_docsize d WHERE d.id = tv.vrow);
                """))
            check("没有任何 occurrence 引用的 text_version（孤儿版本）", try n("""
                SELECT COUNT(*) FROM text_versions tv WHERE NOT EXISTS(
                  SELECT 1 FROM occurrences o WHERE o.device_id = tv.device_id AND o.text_version_id = tv.id);
                """))
            check("已逻辑删除的 observation 仍留有 occurrence", try n("""
                SELECT COUNT(*) FROM observations ob WHERE ob.deleted_at IS NOT NULL AND EXISTS(
                  SELECT 1 FROM occurrences o WHERE o.device_id = ob.device_id AND o.observation_id = ob.id);
                """))
            check("已逻辑删除的 observation 仍留有 thumb_ref", try n("""
                SELECT COUNT(*) FROM observations WHERE deleted_at IS NOT NULL AND thumb_ref IS NOT NULL;
                """))
            check("同一设备内 sha256 重复的 text_version", try n("""
                SELECT COUNT(*) FROM (SELECT device_id, sha256 FROM text_versions
                                       GROUP BY 1,2 HAVING COUNT(*) > 1);
                """))
            check("同一 observation 内 ord 重复的 occurrence", try n("""
                SELECT COUNT(*) FROM (SELECT device_id, observation_id, ord FROM occurrences
                                       GROUP BY 1,2,3 HAVING COUNT(*) > 1);
                """))

            // 派生结果引用了已删观察却没标 stale
            var badDerived = 0
            for table in ["sessions", "ledgers"] {
                let st = try conn.prepare("SELECT device_id, evidence FROM \(table) WHERE stale = 0;")
                var pending: [(String, String)] = []
                while try st.step() {
                    if let dev = st.text(0), let ev = st.text(1) { pending.append((dev, ev)) }
                }
                st.finalize()
                for (dev, evidence) in pending {
                    let ids = evidenceObservationIDs(evidence)
                    if ids.isEmpty { continue }
                    var live = 0
                    for chunk in ids.chunked(into: 400) {
                        let marks = placeholders(chunk.count)
                        live += try n("""
                            SELECT COUNT(*) FROM observations
                             WHERE device_id = ? AND id IN (\(marks)) AND deleted_at IS NULL;
                            """, [.text(dev)] + chunk.map { SQLValue.int($0) })
                    }
                    if live != ids.count { badDerived += 1 }
                }
            }
            check("引用了已删观察却未标 stale 的 sessions / ledgers", badDerived)

            // 缩略图：磁盘 vs 引用
            let fm = FileManager.default
            let onDisk = Set((try? fm.contentsOfDirectory(atPath: thumbnailDirectory.path)) ?? [])
            let referenced = Set(try conn.textColumn(
                "SELECT thumb_ref FROM observations WHERE thumb_ref IS NOT NULL;"))
            check("磁盘上无人引用的缩略图文件", onDisk.subtracting(referenced).count)
            check("被引用但磁盘上已丢失的缩略图文件", referenced.subtracting(onDisk).count)

            // foreign_key_check
            var fkViolations = 0
            let fk = try conn.prepare("PRAGMA foreign_key_check;")
            while try fk.step() { fkViolations += 1 }
            fk.finalize()
            check("PRAGMA foreign_key_check 违规行", fkViolations)

            let integrity = try conn.scalarText("PRAGMA integrity_check;") ?? "?"
            var ftsIC = "ok"
            let r = conn.tryExec("INSERT INTO text_fts(text_fts, rank) VALUES ('integrity-check', 0);")
            if r.rc != 0 { ftsIC = r.message }

            // D22 已知限制的口径说明（不作断言）：bigram 从 2 字起才有 token，
            // 纯汉字单字的文本版本进得了索引但 phrase 查询永远不命中，计划 3.4 规定走扫描。
            let shortTV = try n("SELECT COUNT(*) FROM text_versions WHERE LENGTH(text) < 2;")

            return IntegrityReport(danglingChecks: items,
                                   integrityCheck: integrity,
                                   foreignKeyViolations: fkViolations,
                                   ftsIntegrityCheck: ftsIC,
                                   shortTextVersions: shortTV)
        }
    }
}
