import Foundation

/// Schema **v4**（M2 c 批 / T11）：分块与向量索引（计划 3.2「`chunks` / `vec_chunks` 仅在 D8
/// 通过后新增」、3.4「向量检索」、4.3「若 D8 通过：嵌入任务、sqlite-vec、混合检索」）。
///
/// 迁移只做**纯新增**：建两张表，不动任何已有列，老库开库时就地补建。
/// 两张表都是**本机派生数据**，语义与 `text_fts` 同级：
/// 可以随时删掉重建，不参与 D17 同步，不是证据。
///
/// **默认关闭**：v4 建了表，但 `RetrievalOptions.vectorsEnabled` 默认 `false`，
/// 没有嵌入模型时 `chunks` 里一行都不会有，检索也一次向量调用都不会发（3.11 的「未安装时显示未启用」）。
public enum SchemaV4 {

    /// 向量维度：**1024**（2026-09-08 / D30 从 512 改上来，schema v9）。
    ///
    /// 口径：**所有尺寸的嵌入模型都截到同一个维度**，这样换模型只需要重建向量、不用改表。
    /// D30 去掉 0.6B（原生 1024）之后清单里是 4B（原生 2560）与 8B（原生 4096），
    /// 两者都能 MRL 截到 1024；再往上取（1536 / 2560）就会把将来 1024 维的模型挡在外面。
    /// 512 是 0.6B 时代的选择（E9 实测截到 512 维 Recall@10 = 0.925、256 维 0.90，
    /// `tools/bench/results/e9_runtime_2026-09-07.md`）——换成大模型后再砍到 512
    /// 等于把升级的收益丢掉一半，所以取 1024。存储代价 1 KiB/块（int8），是 512 的两倍。
    /// 截断口径 = 取前 1024 维再重新 L2 归一化（`EmbeddingVector.truncateNormalize`）。
    ///
    /// **改这个常数必须同时加一版 schema 迁移**：`vec_chunks` 的维度写死在建表语句里，
    /// 老库要 drop 掉重建并清空 `chunks`（见 `Store.migrateIfNeeded` 的 v9）。
    public static let dimension = 1024

    /// 元素类型：**int8**（`vec0` 的 `int8[512]`），距离度量 **cosine**。
    ///
    /// - 为什么 int8 而不是 float32：1024 维 float32 = 4 KiB/块，int8 = 1 KiB/块。
    ///   1 个月合成库约 10 万个块，两者是 400 MiB 与 100 MiB 的差别，
    ///   直接影响 D21 的 0.6 GiB/月目标。
    /// - 为什么量化不会破坏结果：`vec0` 的 `distance_cosine_int8` 是
    ///   `1 - dot/(|a||b|)`，**对整体缩放不敏感**，所以每条向量可以各自用
    ///   `s = 127 / max|v_i|` 缩放到满量程再取整（见 `EmbeddingVector.quantizeInt8`）。
    ///   固定用 127 会很糟：L2 归一化的 1024 维向量分量典型只有 ±0.03，
    ///   乘 127 之后只剩十来个量化档。
    /// - sqlite-vec v0.1.9 只支持 float32 / int8 / bit 三种元素类型，**没有 float16**。
    public static let elementType = "int8"

    /// 分块表。`text_versions` 是不可变的原文；`chunks` 只记「这段原文的第 ord 块是哪一段」，
    /// 不复制正文（`offset` / `len` 是原文 **UTF-8 字节**偏移与长度，与 `text_versions.byte_len` 同口径）。
    ///
    /// - `vrow`：本机私有代理 rowid，`vec_chunks.chunk_rowid` 用它。与 `text_versions.vrow`
    ///   的设计理由相同（D23）：虚拟表只认整数 rowid。
    /// - 没有 `(device_id, id)` 业务主键：**这张表不参与 D17 同步**，删了重建即可，
    ///   不需要跨设备稳定的 id。
    /// - 外键 `ON DELETE CASCADE`：文本版本被删（用户删除的孤儿清理、配额过期）时
    ///   分块自动消失。`vec_chunks` 是虚拟表、**不受外键约束**，必须由
    ///   `Store.sweepOrphanVersions` 显式删（与 `text_fts` 完全一样的处理）。
    public static let createChunks = """
    CREATE TABLE chunks (
      vrow            INTEGER PRIMARY KEY,
      device_id       TEXT    NOT NULL,
      text_version_id INTEGER NOT NULL,
      ord             INTEGER NOT NULL,          -- 版本内的块序号，从 0 起
      "offset"        INTEGER NOT NULL,          -- 原文 UTF-8 字节偏移
      len             INTEGER NOT NULL,          -- 原文 UTF-8 字节长度
      chars           INTEGER NOT NULL,          -- 字符数（Character），只作口径说明
      embedded_at     INTEGER,                   -- NULL = 还没嵌入（任务的待办队列）
      model           TEXT,                      -- 嵌入用的模型 id
      dim             INTEGER,                   -- 实际写进 vec_chunks 的维度
      UNIQUE (device_id, text_version_id, ord),
      FOREIGN KEY (device_id, text_version_id) REFERENCES text_versions(device_id, id)
        ON DELETE CASCADE
    );
    CREATE INDEX idx_chunks_tv      ON chunks(device_id, text_version_id);
    CREATE INDEX idx_chunks_pending ON chunks(vrow) WHERE embedded_at IS NULL;
    """

    /// 向量索引（sqlite-vec `vec0`，v0.1.9 已静态编入 core，见 `Package.swift` 的 `CSqliteVec`）。
    ///
    /// `chunk_rowid` 与 `chunks.vrow` 一一对应；`k = ?` 的 kNN 查询在 v0.1.9 里是
    /// **全量扫描**（没有 ANN 索引），所以延迟随块数线性，实测数字见结果文件。
    public static let createVecChunks = """
    CREATE VIRTUAL TABLE vec_chunks USING vec0(
      chunk_rowid INTEGER PRIMARY KEY,
      embedding \(elementType)[\(dimension)] distance_metric=cosine
    );
    """

    /// `meta` 里记的嵌入配置。改了其中任何一项，已嵌入的向量就作废（要 `rebuildEmbeddings()`）。
    public enum MetaKey {
        /// 当前索引用的模型 id（例如 `Qwen3-Embedding-0.6B-8bit`）。
        public static let model = "embed_model"
        /// 当前索引的维度（应当等于 `SchemaV4.dimension`）。
        public static let dimension = "embed_dim"
        /// 分块参数的指纹（`ChunkConfig.fingerprint`）。
        public static let chunkConfig = "embed_chunk_config"
        /// 分块推进到的 `text_versions.vrow` 水位（可中断、可续跑）。
        public static let chunkWatermark = "embed_chunk_watermark"
    }

    /// v4 之后 `Store.open` 自检要求存在的表（追加到 `Schema.expectedTables`）。
    public static let expectedTables = ["chunks", "vec_chunks"]
}
