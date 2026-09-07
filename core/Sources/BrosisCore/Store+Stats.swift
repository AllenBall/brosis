import Foundation

extension Store {

    /// 按 `dbstat` 分项报告字节（2.4 存储行：原文 / 索引 / 元数据 / WAL）。
    ///
    /// 口径：
    /// - **正文** = `text_versions` 表 b-tree 的实占页字节（不是估算系数）；
    /// - **索引** = 全部索引 b-tree（显式 + `sqlite_autoindex_*`）+ FTS5 影子表（`text_fts_*`），
    ///   FTS 在 `ftsBytes` 里单列一次，两者是包含关系；
    /// - **元数据** = 其余表（观察、出现、规范化对象、审计、策略、遥测、`sqlite_schema`）；
    /// - **WAL / SHM** 直接量文件；
    /// - `textPayloadBytes` = `SUM(text_versions.byte_len)`，是原文净载荷，配额按它算。
    ///
    /// `dbstat` 只统计**已在主库文件里**的页。WAL 里还没 checkpoint 的脏页不计，
    /// 所以要拿稳定数字应该先 `maintenance()` 或 `checkpoint()`。
    public func stats() throws -> StoreStats {
        try withLock { conn in
            let rows = try dbstatRows(conn)
            var content = 0, index = 0, fts = 0, metadata = 0
            for row in rows {
                switch row.bucket {
                case "content": content += row.bytes
                case "fts": fts += row.bytes; index += row.bytes
                case "index": index += row.bytes
                default: metadata += row.bytes
                }
            }
            let pageSize = Int(try conn.scalarInt("PRAGMA page_size;") ?? 0)
            let pageCount = Int(try conn.scalarInt("PRAGMA page_count;") ?? 0)
            let freelist = Int(try conn.scalarInt("PRAGMA freelist_count;") ?? 0)

            func count(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
                Int(try conn.scalarInt(sql, binds) ?? 0)
            }
            return StoreStats(
                pageSize: pageSize,
                pageCount: pageCount,
                freelistPages: freelist,
                dbFileBytes: fileSize(databaseURL.path),
                walBytes: fileSize(databaseURL.path + "-wal"),
                shmBytes: fileSize(databaseURL.path + "-shm"),
                contentBytes: content,
                indexBytes: index,
                ftsBytes: fts,
                metadataBytes: metadata,
                freeBytes: freelist * pageSize,
                textPayloadBytes: try contentBytes(conn),
                observations: try count("SELECT COUNT(*) FROM observations;"),
                liveObservations: try count("SELECT COUNT(*) FROM observations WHERE deleted_at IS NULL;"),
                tombstonedObservations: try count("SELECT COUNT(*) FROM observations WHERE deleted_at IS NOT NULL;"),
                textVersions: try count("SELECT COUNT(*) FROM text_versions;"),
                occurrences: try count("SELECT COUNT(*) FROM occurrences;"),
                ftsRows: try ftsRowCount(conn),
                apps: try count("SELECT COUNT(*) FROM apps;"),
                deletions: try count("SELECT COUNT(*) FROM deletions;"))
        }
    }

    /// dbstat 的逐 b-tree 明细，按字节倒序。
    public func statsDetail() throws -> [StatsRow] {
        try withLock { conn in try dbstatRows(conn).sorted { $0.bytes > $1.bytes } }
    }

    private func dbstatRows(_ conn: SQLiteConnection) throws -> [StatsRow] {
        // aggregate=1 让 dbstat 每个 b-tree 只出一行（否则每页一行，12 个月库上是几十万行）。
        // 聚合模式下 pgsize 是该 b-tree 的实占总字节，pageno 变成页数（dbstat.c 的口径）。
        let indexNames = Set(try conn.textColumn(
            "SELECT name FROM sqlite_schema WHERE type = 'index';"))
        let st = try conn.prepare("SELECT name, pgsize, pageno FROM dbstat('main', 1);")
        defer { st.finalize() }
        var out: [StatsRow] = []
        while try st.step() {
            guard let name = st.text(0) else { continue }
            let bytes = Int(st.int(1) ?? 0)
            let pages = Int(st.int(2) ?? 0)
            let bucket: String
            if name == "text_versions" {
                bucket = "content"
            } else if name.hasPrefix("text_fts") {
                bucket = "fts"
            } else if indexNames.contains(name) || name.hasPrefix("sqlite_autoindex_") {
                bucket = "index"
            } else {
                bucket = "metadata"
            }
            out.append(StatsRow(name: name, bucket: bucket, bytes: bytes, pages: pages))
        }
        return out
    }
}
