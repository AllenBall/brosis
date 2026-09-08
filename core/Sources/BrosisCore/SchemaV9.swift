import Foundation

/// Schema **v9**（2026-09-08 / D30）：统一向量维度从 512 改到 1024。
///
/// 背景：D30 让向量检索支持 Qwen3-Embedding 的多个尺寸（4B 原生 2560、8B 原生 4096）
/// 并允许在面板里切换。所有尺寸都 MRL 截到**同一个**维度，换模型才只需要重建向量、不用改表；
/// 去掉 0.6B 之后这个公共维度取 1024（取值理由见 `SchemaV4.dimension` 的注释）。
///
/// 为什么要一版迁移：`vec_chunks` 是 `vec0` 虚拟表，维度写死在建表语句里（`int8[512]`），
/// 没有 ALTER 的办法，只能 drop 掉按新维度重建。
///
/// 丢什么：`chunks` 与 `vec_chunks` 全清、四个 `embed_*` meta 键删掉。
/// 这两张表是**本机派生数据**（与 `text_fts` 同级，不同步、不是证据），
/// 清掉之后夜间嵌入任务会从头再跑一遍；证据、台账、FTS 一个字节都不动。
public enum SchemaV9 {

    public static let note =
        "v9：统一向量维度 512 → \(SchemaV4.dimension)（D30 多尺寸嵌入模型可切换）；"
        + "drop 并重建 vec_chunks，清空 chunks 与 embed_* meta（派生数据，重跑嵌入任务即可）"

    /// 迁移语句。**顺序有意义**：先删虚拟表再建，最后清 chunks 与 meta。
    public static let dropVecChunks = "DROP TABLE IF EXISTS vec_chunks;"
    public static let clearChunks = "DELETE FROM chunks;"

    /// 要一起删掉的 meta 键（与 `Store.rebuildEmbeddings` 删的是同一组）。
    public static let metaKeysToClear = [
        SchemaV4.MetaKey.model, SchemaV4.MetaKey.dimension,
        SchemaV4.MetaKey.chunkConfig, SchemaV4.MetaKey.chunkWatermark,
    ]
}
