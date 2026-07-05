先抓取你的兩個 pipeline 設定來看現況。現在抓 reverse 那個。已讀到完整的 forward / reverse pipeline。在動手前,我要先驗證 Bloblang 的壓縮/編碼方法支援哪些演算法與版本下限(這是你一貫要求的 source 驗證),先查清楚再給設計。Source 已驗證完。讓我確認 `compress` method 的引入版本下限,給你明確的版本地板。注意到 `bloblang_encoding.go` 在 shallow clone 看起來是新檔。這對你的版本地板很關鍵——歷史上 `compress` 一直是 **processor**,但 `.compress()` 作為 **Bloblang method** 可能是近期才加的。我必須查清楚,否則版本下限會誤導。兩個檔案都讀完了，source 也驗證完。先講一個你可能還沒注意到的重點：**你現在遇到的不只是「太大」，還藏著一個資料損毀的 bug。** 兩者同源，同一個修法一起解掉。

## 根因：`content().string()` 對 binary 是錯的

forward leg 現在做的是：

```
let body = content().string()      # binary bytes 被當成 UTF-8 重新詮釋
root = { ..., "body": $body }       # 再塞進 JSON 字串欄位
```

這一步同時製造兩個問題：

| 問題 | 機制 | 後果 |
|---|---|---|
| **體積膨脹（你看到的）** | binary 裡的 control bytes（0x00–0x1F）在 JSON 字串裡多數要 escape 成 `\u00XX`，**1 byte → 6 bytes**；`"`、`\` → 2 bytes | 最壞膨脹接近 6×，輕鬆爆掉 payload 上限 |
| **資料損毀（隱性）** | Go 的 `encoding/json`（Bloblang 序列化底層）遇到**無效 UTF-8 byte 會替換成 U+FFFD**，不是 escape | binary 過 envelope 後**不可逆損毀**，寫回 region Redis 的值跟來源不一致 |

所以光是「想辦法壓小」還不夠 —— 只要 binary 不是合法 UTF-8，現在這條路就已經在默默改壞資料了。

## 解法：原始 bytes → 壓縮 → base64，envelope 結構與 op 邏輯完全不碰

核心是**不要再經過 `string()`**，直接拿 `content()`（原始 bytes）做 `compress("gzip").encode("base64")`。base64 是純 ASCII，進 JSON 不再 escape、無損；gzip 先把可壓縮的 binary 壓掉。對端對稱還原。

### forward（`cdc-forward.yaml`）— 改 mapping 這一段

```yaml
      - mapping: |
          let eid = meta("event_id").or(content().hash("sha256").encode("hex"))
          root = {
            "event_id": $eid,
            "op":       meta("op").or("update"),
            "type":     meta("type").or("string"),
            "kv_key":   meta("kv_key").or(""),
            "old_key":  meta("old_key").or(""),
            "new_key":  meta("new_key").or(""),
            "ts":       meta("ts").or("0"),
            "enc":      "gzip:base64",                                  # ★ 自描述編碼,給 reverse 判讀、利於日後相容
            "body":     content().compress("gzip").encode("base64")     # ★ 原始 bytes,不經 string(),無損
          }
          meta op = meta("op").or("update")
          meta event_id = $eid
```

兩個關鍵差異：`event_id` 的 fallback hash 改用 `content()`（對原始 bytes 算，穩定且不受 string 轉換影響）；`body` 用 `content()` 而非 `content().string()`。

### reverse（`cdc-reverse.yaml`）— 只改「stash 進 metadata」那一行

```yaml
      - mapping: |
          meta op = this.op
          meta type = this.type.or("string")
          meta kv_key = this.kv_key
          meta old_key = this.old_key
          meta new_key = this.new_key
          meta body = this.body.decode("base64").decompress("gzip")    # ★ 還原成原始 bytes
```

**下面的 `switch` / `set` / `hset` / `del` / rename-Lua / latency-xadd / `reject_errored` 一行都不用動。** 因為還原後 `meta("body")` 就是原始 bytes：

- `type: string` → `SET kv_key body`：bytes 直接寫，無損；
- `type: hash` → `meta("body").parse_json().key_values()...`：原本就是 JSON object 的 bytes，`parse_json()` 照吃；
- latency 那段 `meta("body").parse_json().ts...` 仍包在 `try/catch`，binary（非 JSON）body parse 失敗照樣被 best-effort 吞掉，行為不變。

這就是「邏輯不動」的精確含義：**envelope schema、subject 插值、`Nats-Msg-Id` dedup、op switch、no-LWW 語意全部保留**，只是在管線兩端各加一層對稱的 transport 編碼。

## 版本地板（source 驗證）

| 用到的 Bloblang method | 最低版本 | 來源 |
|---|---|---|
| `.compress(algo)` / `.decompress(algo)` | **Redpanda Connect v4.12.0**（2023-02-20） | benthos `CHANGELOG.md`：「New `compress` and `decompress` Bloblang methods.」列在 `## 4.12.0` 段 |
| `.encode("base64")` / `.decode("base64")` | 遠早於 v4.12.0（核心 string method） | `internal/bloblang/query/methods_strings.go`，`encode`/`decode` 的 `case "base64"` |
| 可用演算法（method） | `flate` `gzip` `pgzip` `lz4` `snappy` `zlib`（core）；`zstd` 在 `extended` build | `internal/impl/pure/algorithms.go` 的 `AddKnownCompressionAlgorithm(...)`；zstd 在 `extended/zstd.go` |

兩點要注意:

1. **v4.12.0 比你 reverse leg 已在用的 `redis_script`(v4.11.0) 高一個 minor**，確認你的 Connect image ≥ v4.12.0 即可（你目前的整體 baseline 應該遠高於此）。
2. **不要用 `zstd`**：它在 `extended` package（需 build tag）,標準 binary 不保證帶。用 **`gzip`** 最穩，core、壓縮率好，500 req/s 的 CPU 成本可忽略。要更高壓縮率可加 `level`：`compress("gzip", 9)`。

## 壓縮救得了 / 救不了，先量再決定

gzip 對「可壓縮的 binary」(protobuf、序列化結構、含重複 pattern 的二進位) 效果很好;對「已經是壓縮格式」(JPEG/PNG/zip/影片) 幾乎壓不動，base64 的 +33% 反而讓它比原始 bytes 還大。**先量你的實際壓縮率再決定**，官方剛好有現成 pattern，臨時丟一個 log 進 forward：

```yaml
      - log:
          level: INFO
          message: "size probe"
          fields_mapping: |
            root.raw  = content().length()
            root.gzip = content().compress("gzip").length()
            root.b64  = content().compress("gzip").encode("base64").length()
```

- 若 `b64` 穩定落在上限內 → 這個方案就夠了，收工。
- 若 `b64` 仍常常超限 → 代表 body 本身近乎不可壓縮，這時壓縮不是解，要走下面其一（兩者都已**超出「邏輯不動」**，列為 fallback）：
  - **調高 NATS 上限**：server `max_payload`（你現在像是被設成 64 KB；NATS 硬上限 64 MB，官方建議 ≤ 8 MB）；JetStream 另有 per-stream `nats stream edit --max-msg-size`。兩者取小。
  - **大物件外置**：body 寫 NATS Object Store 或 region 可達的 blob store，envelope 只帶引用 + checksum。這會改 reverse 的取值邏輯，屬於架構變更。

## contentLog 調整

壓縮後 envelope 的 `body` 欄位是 base64，forward 的 `nats_out` log、reverse 的 `nats_in` log 仍可讀（只是 body 看不到明文）。但 reverse 的 `redis_apply` log 印的是 `meta("body")` = decompress 後的原始 bytes，binary 會在 log 裡變亂碼。建議把那行改成印長度而非內容：

```yaml
            root.body_len = meta("body").length()    # 取代 root.body = meta("body")
```

## 監控（production readiness）

| 訊號 | 來源 | 門檻 / 意義 |
|---|---|---|
| `output_error`（forward 的 `nats_jetstream`） | Connect Prometheus `:4195` | 持續非零 = 發布被拒。payload 超限會表現為此，且**同一 `event_id` 進入重送迴圈** |
| consumer `num_redelivered` / `num_pending`（reverse） | `nats consumer info` / prometheus-nats-exporter | decompress 或 decode 失敗 → message errored → `reject_errored` nack → JetStream 重送。**單一 event_id redelivery 暴增 = poison message**（壞編碼/截斷） |
| envelope size 分佈 | 上面的 size-probe log（抽樣）或外部彙整 | 接近上限的尾端比例;判斷壓縮是否還夠用 |
| 壓縮率 `gzip/raw` | size-probe log | 趨近 1.0 = body 不可壓縮，預警要改走 max_payload / 外置 |
| `output_latency_ns` p99（forward） | Connect Prometheus | gzip 加進來的 CPU 成本，確認沒有意外抬高延遲 |
| `cdc_apply` counter（reverse 既有） | Connect Prometheus | 套用速率與 op 分佈不應因改編碼而改變;掉到 0 但 JetStream 有 pending = reverse 卡住 |
| region vs central 值一致性（抽樣比對） | 旁路 checker | 驗證**損毀 bug 已修**:抽 key 比對來源 bytes 與 region Redis bytes 的 checksum，應全等 |

最後那條抽樣比對特別值得做一次：它同時驗證「不再損毀」和「壓縮往返無損」兩件事，是這次改動的正確性回歸測試。

