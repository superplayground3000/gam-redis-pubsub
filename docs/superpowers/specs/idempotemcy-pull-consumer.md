# 設計規則:NATS JetStream Durable Consumer 的 Create / Update 語意（給 Coding Agent 的實作契約）

> **適用管線**：`Redis Streams → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis KV`(per-key LWW CDC)。
> **本文管的範圍**:sink 端(以及任何一端)所綁定的 **server-side durable pull consumer** 的 provisioning、變更、重建、監控。
> **本文不管**:LWW CAS Lua fence 本身、Redis 端邏輯(見 `LWW_CDC_設計總整理.md`)。
>
> **一句話原則**:*一支已存在的 durable consumer,第二次 create 永遠不會重置它的 delivery state(ack floor / 位置 / pending);config 則可能被靜默更新、被拒絕、或 no-op,取決於 client action 與改到的欄位。要重置位置只有 delete + recreate 一途。*

---

## 0. 名詞定義(避免混淆兩種 "state")

| 術語 | 指什麼 | 第二次 create 會不會動 |
|---|---|---|
| **Config state** | consumer 的設定欄位(`AckPolicy`、`AckWait`、`MaxAckPending`、`FilterSubject`…) | **可能會**(見 §3、§4) |
| **Delivery / runtime state** | `ack_floor`、`delivered` 游標、`num_pending`、`num_ack_pending`、redelivery queue、consumer 位置 | **永遠不會**(除非 delete + recreate) |

Coding agent 在任何情況下都**不得**假設「重下一次 create 可以把 consumer 位置歸零/重播」。要達到那個效果**必須顯式 delete 再 create**。

---

## 1. Version Floor(硬性底線,實作前必須斷言)

| 元件 | 最低版本 | 為什麼 | 驗證來源 |
|---|---|---|---|
| **nats-server** | **v2.10.0** | `ConsumerAction`(`ActionCreate` / `ActionUpdate` / `ActionCreateOrUpdate`)在 **v2.10.0** 才引入;v2.9.x 沒有 action guard,create-on-existing **一律等同 create-or-update**。要「純 create 遇到既有 consumer 就明確報錯」的語意,底線就是 2.10.0。 | `server/consumer.go` 於 v2.9.0/v2.9.21 `grep ActionCreateOrUpdate` = 0;v2.10.0 = 5。行為驗證於 **v2.10.22** `addConsumerWithAssignment`。 |
| **nats-server(config 可更新)** | v2.9.0(含以前) | `updateConfig` / `checkNewConsumerConfig` 路徑在 2.9.x 已存在(能改 mutable 欄位、immutable 欄位報錯)。 | `server/consumer.go:603, :1468`(v2.9.0)。 |
| **nats.go** | 新 `jetstream` package(v1.x) | `CreateConsumer` / `UpdateConsumer` / `CreateOrUpdateConsumer` 才有顯式 action 對應;舊 `js.AddConsumer` 一律送 create-or-update。 | `jetstream/consumer.go:247-249`、`jetstream/stream.go:244/254/261`(驗證於 v1.37.0,action 常數在 v1.x 穩定;本管線宣稱 v1.50.0)。 |
| **NATS server(監控)** | v2.10+ | `/jsz` endpoint 提供 consumer 明細供 exporter 抓。 | 見 §8。 |

> **實作動作**:provisioning 程式啟動時先 `nats server info` / `$SYS` 斷言 server 版本 `>= 2.10.0`;若 `< 2.10.0`,**拒絕以 `ActionCreate` 語意運行**並 fail-fast(因為在 2.9.x 上 create 會靜默變成 update,drift 不會被擋)。

---

## 2. 核心不變量(Invariants,coding agent 必守)

- **INV-1**:consumer **由 provisioning(IaC/CLI)在 server 端預先建立**;Redpanda Connect 以 `bind: true` + `stream` + `durable` **只綁定、不建立**。Connect 端**不得**負責 consumer 的建立或變更。
- **INV-2**:provisioning 對同一 durable 的 create **必須 idempotent**——重跑且設定不變時是 no-op,不得產生副作用。
- **INV-3**:**不得**依賴「再 create 一次」去變更 **immutable 欄位**(§4);那會 error(`ActionCreate` 或 `CreateOrUpdate` 皆然)。
- **INV-4**:任何會**重置 delivery state**的操作(= delete + recreate)**必須**走顯式維運流程(維護窗 + 監控 + 告警靜音),不得由自動 reconcile 隱式觸發。
- **INV-5**:consumer 的正確性由 sink 端 **LWW CAS fence** 保證,與 consumer 位置、redelivery、亂序**無關**;因此 delete+recreate 造成的重播對**資料正確性安全**,但會造成 sink 寫入 / stale-reject 尖峰(§6),屬**成本**問題不是**正確性**問題。

---

## 3. Create 語意決策表(client action × server 行為)

> 來源:`server/consumer.go` `addConsumerWithAssignment`(v2.10.22)。既有 durable `X`,再收到一次 create:

```go
if eo, ok := mset.consumers[cName]; ok {
    if action == ActionCreate && !reflect.DeepEqual(*config, eo.config()) {
        return nil, NewJSConsumerAlreadyExistsError()   // (A)
    }
    err := eo.updateConfig(config)                       // (B) 其餘全走這
    ...
}
```

| # | client action | 送出的設定 vs 現有 | server 行為 | config | delivery state |
|---|---|---|---|---|---|
| 1 | `ActionCreate`(顯式 create-only) | **不同** | 回 `consumer already exists` error,**完全不動** | 不變 | **不變** |
| 2 | 任意 action | **完全相同**(`reflect.DeepEqual`) | 走 `updateConfig`,實質 no-op,回既有 | 不變 | **不變** |
| 3 | `ActionCreateOrUpdate`(**預設 / 舊 AddConsumer**) | 只改 **mutable** 欄位 | `updateConfig` 就地更新 | **更新** | **不變** |
| 4 | `ActionCreateOrUpdate` | 改到 **immutable** 欄位 | `checkNewConsumerConfig` 回 error(`... can not be updated`) | 不變 | **不變** |
| 5 | `ActionUpdate` | consumer 不存在 | 回 `consumer does not exist` | — | — |

**關鍵**:`updateConfig`(`server/consumer.go:1866+`)通篇**不觸碰** ack floor / pending / 序號游標 / redelivery。所以第 1–5 列**沒有任何一列會重置 delivery state**。

### Client action 對應(nats.go)

| 呼叫 | 送出 action | 對應決策表 |
|---|---|---|
| 舊 `js.AddConsumer` / 舊 `nats consumer add` | **不帶 action → `ActionCreateOrUpdate`** | 走 3/4 |
| `jetstream.CreateConsumer` | `"create"` → `ActionCreate` | 走 1/2 |
| `jetstream.UpdateConsumer` | `"update"` → `ActionUpdate` | 走 5 或更新 |
| `jetstream.CreateOrUpdateConsumer` | `""` → `ActionCreateOrUpdate` | 走 3/4 |

---

## 4. Mutable / Immutable 欄位清單(實作前必背)

> 來源:`checkNewConsumerConfig`(`server/consumer.go:1794-1852`)與 `updateConfig`(`:1866+`),v2.10.22。

**Immutable(改了會 error,決策表第 4 列):**
`DeliverPolicy`、`OptStartSeq`、`OptStartTime`、`AckPolicy`、`ReplayPolicy`、`Heartbeat`、`FlowControl`、`MaxWaiting`、push↔pull 互換(`DeliverSubject` 的有無)。

**Mutable(可就地更新):**
`AckWait`、`MaxAckPending`、`MaxDeliver`、`BackOff`、`RateLimit`、`SampleFrequency`、`InactiveThreshold`、`FilterSubject` / `FilterSubjects`,以及 no-op 記錄的 `Description`、`HeadersOnly`、`Metadata`。

> **pull consumer 特別注意**:`MaxWaiting` 是 **immutable**。想調 pull 併發等待上限**只能 delete + recreate**。
> **層次別搞混**:Redpanda Connect 在 pull/`bind` 模式下 `ack_wait`、`max_ack_pending`、`deliver` 這些欄位是 **Connect 端根本沒送到 server**(Connect 只綁不設);與 server 端「這些欄位其實 mutable」是**兩回事**。真正的控制面 = **server-side consumer 定義**。

---

## 5. Provisioning 規則(MUST / MUST NOT)

- **R-1(MUST)**:consumer 定義以**單一 source of truth**管理(IaC / 一個 `nats consumer add --config` 檔),禁止散落。
- **R-2(MUST)**:預設採 **`ActionCreate`(create-only)語意**跑 provisioning——這樣 config drift(有人手改過 consumer)會**明確報 `already exists` error**,而不是被靜默 update。drift 應是**告警**,不是靜默收斂。
  - *若*團隊政策是「IaC 一定收斂 config」→ 才用 `CreateOrUpdate`,但**必須**搭配 R-4 的 pre-flight diff 擋下 immutable 變更。二選一,寫進 runbook,不得混用。
- **R-3(MUST)**:idempotent 重跑必須安全(INV-2)——CI 每次部署重跑 create,設定不變時應為 no-op。
- **R-4(MUST)**:CI pre-flight **必須** diff「目標 config」vs「線上 config」(`$JS.API.CONSUMER.INFO`),若差異落在 **immutable 欄位**清單 → **block 部署**並要求走 §6 的 delete+recreate 維運流程。
- **R-5(MUST NOT)**:**不得**在自動 reconcile / 健康檢查迴圈裡呼叫 delete + recreate 當作「修復手段」。那會重置位置、造成重播(見 §6)。
- **R-6(MUST NOT)**:**不得**讓 Redpanda Connect 建立或變更 consumer(違反 INV-1);Connect 一律 `bind: true`。
- **R-7(SHOULD)**:consumer 名稱與 stream 名稱用**穩定語意識別碼**,禁用 per-pod / 帶時間戳的動態名(否則 rollout 時會意外建立新 consumer、位置從頭、metric series churn)。

---

## 6. Delete + Recreate:唯一會重置 delivery state 的操作

**觸發時機(且僅限這些)**:需變更 **immutable 欄位**(§4)。

**後果**:
1. delete 會**丟棄 consumer 的 ack floor、PEL、位置**;recreate 後從新 config 的 `DeliverPolicy` 起點開始。
2. 若 `DeliverPolicy = all` / `by_start_seq`,會**重播**一段(甚至整條)stream。
3. 對本管線的 **LWW CAS fence** 而言:**資料正確性安全**(fence 順序無關、redelivery-safe、冪等;`stored_ver` 只單調前進,舊 version 被 CAS 拒絕)。
4. **但成本高**:sink 端會出現大量 CAS 呼叫,其中絕大多數是 **stale-reject(Lua 回 0)**;output 寫入率、Redis CPU、stale-reject 率會尖峰。

**維運流程(MUST)**:
1. 開維護窗、對相關告警靜音(避免尖峰誤報)。
2. 若可能,recreate 時把 `DeliverPolicy` 設為能**縮小重播範圍**的起點(如 `by_start_time` 對齊上次 ack floor 對應時間 / `new`),而非盲目 `all`。
3. 監控 stale-reject 率回落、`num_pending` 收斂、ack floor 重新單調前進(§8)後才解除靜音。
4. 記錄一次「consumer recreate 事件」到變更稽核。

---

## 7. Operation Effort(維運成本評估)

| 操作 | 頻率 | 成本 | 風險 |
|---|---|---|---|
| idempotent create 重跑(R-3) | 每次部署 | 近乎 0(no-op) | 無 |
| 改 mutable 欄位(CreateOrUpdate) | 偶發 | 低,線上即時生效,不中斷 | 低;仍建議 diff 後套 |
| 改 immutable 欄位(delete+recreate,§6) | 罕見 | **高**:需維護窗、告警靜音、重播、監控收斂 | 中;正確性安全但尖峰擾動 |
| drift 偵測(R-4 pre-flight) | 每次部署 | 低(一次 CONSUMER.INFO) | 無;省下事故 |
| 監控 pipeline(§8) | 常態 | 一次性建置 + 常態 scrape | — |

**結論**:把 config 分成 mutable / immutable 兩級管理,日常變更走 mutable 就地更新(近零成本),immutable 變更集中在維護窗——維運成本可壓到很低。真正的成本集中在「immutable 變更」與「意外 recreate」兩件事,兩者都靠 §8 的監控可觀測、可告警。

---

## 8. Monitoring / Production Readiness

### 8.1 可監控訊號與 source of truth

| 訊號 | source of truth | 拿得到的方式 |
|---|---|---|
| consumer 是否被重建(位置重置) | `Created` timestamp | `nats consumer info` / `$JS.API.CONSUMER.INFO`(**注意:exporter 不匯出此欄位**,需 CLI/API 旁路檢查) |
| ack floor 是否單調前進 | `ack_floor.consumer_seq` | exporter metric(§8.2) |
| 消費落後(lag) | `num_pending` vs stream `last_seq` | exporter metric |
| in-flight 未 ack 量 | `num_ack_pending` | exporter metric |
| 重投量 | `num_redelivered` | exporter metric |
| config 現況(drift 偵測) | consumer config | `$JS.API.CONSUMER.INFO`(pre-flight,R-4) |
| Connect 綁定健康 | `input_connection_up` / `input_connection_failed` | Redpanda Connect Prometheus `:4195/metrics` |
| sink LWW 健康 | stale-reject 率(Lua 回 0) | Connect 端取 Lua 回傳(見 LWW 設計文件 §8) |

### 8.2 Prometheus 指標(prometheus-nats-exporter,`/jsz` collector,已對 source 確認)

> 需以 `-jsz=all`(或等效)啟動 exporter 指向 server `/jsz`。以下為 `collector/jsz.go` 實際 `BuildFQName` 的欄位名。

| Metric | 意義 |
|---|---|
| `jetstream_consumer_ack_floor_consumer_seq` | consumer 視角的 ack floor 序號 — **倒退 = 被重建** |
| `jetstream_consumer_ack_floor_stream_seq` | stream 視角的 ack floor 序號 |
| `jetstream_consumer_delivered_consumer_seq` | 已投遞游標(consumer 視角) — 大幅歸零 = 重建 |
| `jetstream_consumer_delivered_stream_seq` | 已投遞游標(stream 視角) |
| `jetstream_consumer_num_pending` | 尚未投遞的堆積量(lag 主訊號) |
| `jetstream_consumer_num_ack_pending` | 已投遞未 ack 的量 |
| `jetstream_consumer_num_redelivered` | 重投數 |
| `jetstream_consumer_num_waiting` | pull 等待請求數 |
| `jetstream_consumer_last_ack_seconds` | 距上次 ack 的秒數 |
| `jetstream_consumer_last_delivery_seconds` | 距上次投遞的秒數 |

**Labels**(必讀):`stream_name`、`consumer_name`、`account`、`server_id`、`server_name`、`cluster`、`is_consumer_leader`…

> **叢集(R>1)必守**:每個 replica 都會上報,**只有 leader 的數字權威**。所有告警**必須**用 `is_consumer_leader="true"` 過濾,或 `max by (stream_name, consumer_name) (...)` 聚合,否則會抓到 follower 的過時數字誤報。

### 8.3 告警規則(PromQL,依你的 stream/consumer 名替換)

```promql
# A. consumer 被意外重建 —— ack floor 倒退(最重要的異常)
- alert: JsConsumerAckFloorRegressed
  expr: |
    (
      max by (stream_name, consumer_name) (
        jetstream_consumer_ack_floor_consumer_seq{is_consumer_leader="true"}
      )
      -
      max by (stream_name, consumer_name) (
        jetstream_consumer_ack_floor_consumer_seq{is_consumer_leader="true"} offset 5m
      )
    ) < 0
  for: 1m
  labels: { severity: critical }
  annotations: { summary: "{{$labels.consumer_name}} ack floor 倒退,疑似 delete+recreate/位置重置" }

# B. lag 堆積
- alert: JsConsumerLagHigh
  expr: max by (stream_name, consumer_name) (jetstream_consumer_num_pending{is_consumer_leader="true"}) > 10000
  for: 5m
  labels: { severity: warning }

# C. 重投尖峰(可能對應 recreate 造成的重播,或 ack 逾時)
- alert: JsConsumerRedeliverySpike
  expr: rate(jetstream_consumer_num_redelivered{is_consumer_leader="true"}[5m]) > 0
  for: 10m
  labels: { severity: warning }

# D. in-flight 未 ack 卡住
- alert: JsConsumerAckStalled
  expr: |
    max by (stream_name, consumer_name)(jetstream_consumer_num_ack_pending{is_consumer_leader="true"}) > 0
    and max by (stream_name, consumer_name)(jetstream_consumer_last_ack_seconds{is_consumer_leader="true"}) > 300
  for: 5m
  labels: { severity: warning }

# E. Redpanda Connect 綁不上 consumer(config 衝突 / consumer 不存在)
- alert: ConnectInputDown
  expr: input_connection_up == 0
  for: 1m
  labels: { severity: critical }
```

> 告警 A、C 在**計畫性** delete+recreate(§6)期間**必須先靜音**,否則會誤報。

### 8.4 API/CLI 旁路檢查(prometheus 拿不到的)

- **偵測重建的權威證據**:週期性 `nats consumer info <stream> <consumer> --json` 取 `created` 欄位,與上次快照比對;**變新 = 被 delete+recreate**。把它變成一個小 exporter / cron,輸出一個 `consumer_created_timestamp` gauge 供告警(prometheus-nats-exporter 本身不匯出這欄)。
- **drift 偵測(R-4)**:pre-flight 拉 `config`,與 IaC 目標 diff,immutable 欄位有差 → block。

### 8.5 Production readiness 檢查清單(上線前)

- [ ] exporter 以 `-jsz=all` 抓到 §8.2 所有 metric,且 label 有 `is_consumer_leader`。
- [ ] §8.3 五條告警上線,且叢集下全部用 leader 過濾。
- [ ] `created` timestamp 旁路檢查(§8.4)就緒。
- [ ] R-4 pre-flight diff 進 CI,能擋下 immutable 變更。
- [ ] Redpanda Connect `input_connection_up` / `output_error` / `output_latency_ns`(p99)有面板與告警。
- [ ] 維護窗告警靜音流程(§6)寫進 runbook。

---

## 9. Pre-flight / CI 檢查規格(pseudo,coding agent 可直接實作)

```text
function reconcile_consumer(target_cfg):
    assert server_version() >= "2.10.0"                       # §1
    info = js_api.CONSUMER_INFO(stream, target_cfg.durable)   # nil if not exist

    if info == nil:
        js_api.CreateConsumer(stream, target_cfg)             # ActionCreate
        record_audit("created", target_cfg.durable)
        return

    diff = diff_config(info.config, target_cfg)
    if diff.empty():
        return                                                # no-op,INV-2

    if diff.touches_any(IMMUTABLE_FIELDS):                    # §4
        FAIL("immutable change on %s: %s — 需維護窗 delete+recreate(§6),CI 不自動執行"
             % (target_cfg.durable, diff.immutable_fields))   # R-4 block

    # 只剩 mutable 差異
    if policy == "create-only":                               # R-2 預設
        FAIL("config drift on %s: %s — 請確認是誰改的,或改用 update 流程"
             % (target_cfg.durable, diff.mutable_fields))
    else:  # policy == "converge"
        js_api.UpdateConsumer(stream, target_cfg)             # ActionUpdate,delivery state 不變
        record_audit("updated", target_cfg.durable, diff.mutable_fields)
```

`IMMUTABLE_FIELDS = {DeliverPolicy, OptStartSeq, OptStartTime, AckPolicy, ReplayPolicy, Heartbeat, FlowControl, MaxWaiting, push↔pull}`

---

## 10. Test Plan(驗收,對應 §3 決策表)

| # | 前置 | 動作 | 預期 |
|---|---|---|---|
| T1 | consumer 存在 | 相同 config 再 create | no-op;`created` 不變;`ack_floor` 不變(決策表 2) |
| T2 | consumer 存在,已消費一段 | 只改 `AckWait`(mutable)用 CreateOrUpdate | config 更新;**`ack_floor` / `num_pending` 不變**(決策表 3) |
| T3 | consumer 存在 | 改 `AckPolicy`(immutable)用 CreateOrUpdate | 回 `ack policy can not be updated`;**一切不變**(決策表 4) |
| T4 | consumer 存在 | 改任意欄位用 `ActionCreate` | 回 `consumer already exists`;**一切不變**(決策表 1) |
| T5 | consumer 存在,已消費一段 | delete + recreate(`DeliverPolicy=all`) | `created` 變新;`ack_floor` 歸零並重新前進;**LWW CAS 下資料仍正確**,但觀察到 stale-reject 尖峰(§6) |
| T6 | server v2.9.x | 以 `ActionCreate` 改 config | **不會**報 already exists(靜默 update)→ 驗證 §1 version floor 的必要性 |

每個 case 斷言 `nats consumer info --json` 的 `created` / `ack_floor` / `num_pending`,以及對應 §8.2 metric。

---

## 11. PR Checklist(合併前)

- [ ] 已斷言 nats-server `>= 2.10.0`(§1),否則 create-only 語意不成立。
- [ ] provisioning idempotent(INV-2 / R-3),CI 重跑為 no-op(T1)。
- [ ] Connect 一律 `bind: true`,不建立/變更 consumer(INV-1 / R-6)。
- [ ] 選定並寫死 provisioning 政策:`create-only`(預設,drift→報錯)或 `converge`(§5 R-2),不混用。
- [ ] R-4 pre-flight diff 能擋下 immutable 變更(§4 / §9),T3/T4 通過。
- [ ] delete+recreate 走維護窗流程 + 告警靜音(§6),且**不**出現在自動 reconcile 路徑(R-5)。
- [ ] §8.2 metric 抓得到、告警(§8.3)以 leader 過濾、`created` 旁路檢查(§8.4)就緒。
- [ ] consumer/stream 名為穩定語意識別碼(R-7)。
- [ ] 全部 test case(§10)通過並附證據。

---

### 附錄:source 參照(供 agent 自行複驗)

- `nats-io/nats-server` **v2.10.22** — `server/consumer.go`:`addConsumerWithAssignment`(existing-consumer 分支,含 `ActionCreate` guard 與 `updateConfig` 呼叫)、`checkNewConsumerConfig`(immutable 欄位 error 清單)、`updateConfig`(mutable 欄位就地更新、**不碰 delivery state**)。
- version floor:v2.9.0 / v2.9.21 無 `ActionCreateOrUpdate`;v2.10.0 起有。
- `nats-io/nats.go` **v1.37.0**(action 常數 v1.x 穩定)— `jetstream/consumer.go`(`consumerActionCreate/Update/CreateOrUpdate`)、`jetstream/stream.go`(`CreateConsumer`/`UpdateConsumer`/`CreateOrUpdateConsumer` 對應)、`jsm.go`(舊 `AddConsumer` 不帶 action)。
- `nats-io/prometheus-nats-exporter` — `collector/jsz.go`(§8.2 consumer metric 名稱與 label)。