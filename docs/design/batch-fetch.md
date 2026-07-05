# 設計文件:`nats_jetstream` input pull 路徑批次化 `Fetch()`

> **讀者**:實作此變更的 coding agent。
> **目標倉庫**:`redpanda-data/connect`(fork 後修改),檔案 `internal/impl/nats/input_jetstream.go`。
> **變更性質**:為 pull consumer 讀取路徑新增可設定的批次抓取(`fetch_count`)與批次逾時(`fetch_timeout`),取代目前硬編碼的 `Fetch(1)`。
> **相容性**:預設值等同現行行為,零破壞性升級。

---

## 0. TL;DR(給 agent 的一句話)

把 pull 路徑的 `natsSub.Fetch(1, nats.Context(ctx))` 改成「一次抓 `fetch_count` 則、內部緩衝、`Read()` 每次回傳一則」;逾時用**帶 deadline 的子 context**(不可與 `nats.MaxWait` 併用);`len(msgs) > 0` 一律先入緩衝,只有 `len == 0` 才判錯重試。伺服器端 consumer 的 `max_ack_pending` 必須 **≥ `fetch_count`**,否則批次會被伺服器上限削掉。

---

## 1. 背景與問題(已用原始碼核實)

現行 pull 路徑(`input_jetstream.go`,核實版本 **v4.98.0**,2026-06-26):

- 第 350–353 行:pull 分支只加 `nats.ManualAck()` + `nats.Bind(stream, durable)`,然後 `PullSubscribe`。**`ack_wait`(360)/`max_ack_pending`(363)只在 push 分支加入**,pull 模式下 YAML 這兩個欄位被靜默丟棄。
- 第 422 行:`msgs, err := natsSub.Fetch(1, nats.Context(ctx))` — **批次大小硬編碼為 1**,到 v4.98.0 仍如此,無任何 config 旋鈕。

**後果**:pull 讀取為單一 goroutine 序列呼叫 `Fetch(1)`,每則訊息各吃一趟 pull round-trip,吞吐 ≈ `1 / RTT`。跨區(+100ms)實測僅約 6 msg/s;同區實例可 >1000 msg/s。處理耗時 <5ms 完全不是瓶頸——瓶頸是「一趟來回只帶回一則」。

`max_ack_pending` 無法解決此問題:它是「在途未 ack 的上限」,但序列 `Fetch(1)` 使在途永遠 ≈1,遠低於上限,調大它毫無效果。真正的槓桿是**單趟 fetch 帶回的則數**,亦即本文件要參數化的目標。

---

## 2. 目標與非目標

**目標**
1. 新增 `fetch_count`(預設 `1`)與 `fetch_timeout`(預設 `"5s"`)兩個 input 欄位。
2. pull 路徑一次 `Fetch(fetch_count)`,將批次緩衝於 reader 內部,`Read()` 逐則回傳。
3. 保持 at-least-once 語意與逐則 ack 不變。
4. 預設值下行為與現行完全一致(可安全灰度)。

**非目標(本次不做)**
- 不改 push 路徑。
- 不改 ack 模型(仍為 per-message `Ack()/Nak()`,見 `convertMessage`)。
- 不引入背景 double-buffer 預抓(留待附錄 A 的 Strategy B)。
- 不嘗試在 pull 路徑傳 `nats.MaxAckPending`:因 pull 用 `nats.Bind` 綁既有 consumer,該 SubOpt 對已存在 consumer 無效,必須伺服器端設定(見 §5.7)。

---

## 3. 版本地板與相依(production 必讀)

| 元件 | 最低版本 | 依據 |
|---|---|---|
| Redpanda Connect(base:input 存在) | **3.46.0** | `nats_jetstream` input 首次引入 |
| Redpanda Connect(pull consumer 支援) | **4.0.0** | CHANGELOG「input now supports pull consumers」 |
| Redpanda Connect(本變更) | 以 fork 自 **4.98.0** 之 main 為基準;新欄位由本 PR 引入 | 本文件 |
| `nats.go`(legacy `Subscription.Fetch(batch, ...)`) | 已隨此 build 綁定 **v1.50.0**;批次 Fetch 自 pull GA 起即有 | `go.mod` / `js.go:2971` |
| NATS server(pull consumer) | **2.2.0**(JetStream GA) | NATS 官方 |
| NATS server(穩健 pull:`max_bytes`/`expires`/heartbeat) | **建議 ≥ 2.9.0** | 用於附錄 A;Strategy A 只需 2.2.0 |

**部署前置檢查(agent 需在 PR 說明列出)**
- 確認目標環境 NATS server **≥ 2.9.0**(建議;≥ 2.2.0 為硬底線)。
- 確認欲綁定的 durable pull consumer 之伺服器端 `max_ack_pending` **≥ 打算設定的 `fetch_count`**。

---

## 4. 設計總覽

採 **Strategy A(最小侵入、如需求所示「改 `fetch()`」)** 為本次實作標的:保留 legacy `PullSubscribe`,把 `Fetch(1)` 改為 `Fetch(fetch_count)` + 內部緩衝。

> **架構註記(取捨,非本次實作)**:對高延遲 WAN,最佳解其實是現代 `jetstream.Consumer.Messages()` 連續預抓迭代器(自動維持 client 端 prefetch 窗口,消除批次間的 round-trip 空檔)。它嚴格優於手動 `Fetch(N)` 迴圈。本 build 已可用(nats.go v1.50.0 已含 `jetstream` 套件,input 亦已 import)。因需求明確要求「改 `fetch()`」,故以 Strategy A 為主線交付,Strategy B 之取捨與骨架見 **附錄 A**,供架構決策。

---

## 5. 詳細設計 — Strategy A

### 5.1 Config schema 變更

在 `natsJetStreamInputConfig()`(約第 31–101 行的 `Fields(...)` 區塊)`max_ack_pending` 欄位之後新增:

```go
Field(service.NewIntField("fetch_count").
    Description("Pull 模式下每次 Fetch 請求最多抓取的訊息數。決定跨網路每趟 round-trip 帶回的批次大小;"+
        "跨高延遲鏈路時是吞吐的主要槓桿。僅在 pull consumer 生效(push 模式忽略)。"+
        "注意:必須 <= 伺服器端 consumer 的 max_ack_pending,否則會被伺服器上限削掉。").
    Advanced().
    Default(1).
    LintRule(`root = if this < 1 { [ "fetch_count must be >= 1" ] }`)).
Field(service.NewDurationField("fetch_timeout").
    Description("Pull 模式下單次 Fetch 請求的最長等待(pull expiry)。批次未在此時間內填滿時,伺服器回傳部分批次;"+
        "用來在低流量時保住延遲上限。僅在 pull consumer 生效。").
    Advanced().
    Default("5s")).
```

**設計理由**
- `Default(1)`:與現行 `Fetch(1)` 完全等價 → 零破壞性。
- `fetch_timeout` 預設 `5s`:對齊現行「無明確 MaxWait、由框架 ctx 主導」的體感;低流量時最壞每 5s 回傳一次部分批次。可依 SLA 調小(例:`500ms`)。
- 用 `service.NewDurationField`(非 string)以取得型別化解析與 lint。

### 5.2 struct 變更

於 `jetStreamReader`(約第 121–139 行)新增欄位:

```go
type jetStreamReader struct {
    // ...既有欄位...
    ackWait       time.Duration
    maxAckPending int

    // 新增:
    fetchCount   int
    fetchTimeout time.Duration

    // 新增:pull 批次緩衝(僅 Read goroutine 觸碰;mutex 為防禦性)
    pullMut sync.Mutex
    pullBuf []*nats.Msg

    // ...既有欄位...
}
```

### 5.3 設定解析(`newJetStreamReaderFromConfig`)

在解析 `max_ack_pending` 之後(約第 226–229 行後)新增:

```go
if j.fetchCount, err = conf.FieldInt("fetch_count"); err != nil {
    return nil, err
}
if j.fetchCount < 1 {
    return nil, errors.New("fetch_count must be >= 1")
}
if j.fetchTimeout, err = conf.FieldDuration("fetch_timeout"); err != nil {
    return nil, err
}
```

### 5.4 `Read()` 批次緩衝邏輯(核心變更)

**替換** `Read()` 中 `if !j.pull { ... }` 之後、目前 `for { ... Fetch(1) ... }` 的整段 pull 迴圈(約第 409–447 行的 pull 部分)為:

```go
func (j *jetStreamReader) Read(ctx context.Context) (*service.Message, service.AckFunc, error) {
    j.connMut.Lock()
    natsSub := j.natsSub
    j.connMut.Unlock()
    if natsSub == nil {
        return nil, nil, service.ErrNotConnected
    }

    if !j.pull {
        // ── push 路徑維持不變 ──
        nmsg, err := natsSub.NextMsgWithContext(ctx)
        if err != nil {
            if errors.Is(err, nats.ErrConnectionClosed) {
                j.disconnect()
                return nil, nil, service.ErrNotConnected
            }
            return nil, nil, err
        }
        return convertMessage(nmsg)
    }

    // ── pull 路徑:先出緩衝,空了才抓新批次 ──
    for {
        // 1) 緩衝有貨,直接回一則
        j.pullMut.Lock()
        if len(j.pullBuf) > 0 {
            m := j.pullBuf[0]
            j.pullBuf = j.pullBuf[1:]
            j.pullMut.Unlock()
            return convertMessage(m)
        }
        j.pullMut.Unlock()

        // 2) 緩衝空,抓一批。逾時用「帶 deadline 的子 context」;
        //    切勿同時傳 nats.MaxWait —— 會回 nats.ErrContextAndTimeout(js.go:3013)。
        fctx, cancel := context.WithTimeout(ctx, j.fetchTimeout)
        msgs, err := natsSub.Fetch(j.fetchCount, nats.Context(fctx))
        cancel()

        // 3) 契約:Fetch 若收到 >=1 則但未滿批次即到期,回 (部分訊息, nil);
        //    只有一則都沒收到才回 (nil, ErrTimeout)。故先處理 len(msgs) > 0。
        if len(msgs) > 0 {
            j.pullMut.Lock()
            j.pullBuf = append(j.pullBuf, msgs...)
            j.pullMut.Unlock()
            continue // 回圈頂端出緩衝
        }

        // 4) 空批次才判錯
        if err != nil {
            if errors.Is(err, nats.ErrTimeout) || errors.Is(err, context.DeadlineExceeded) {
                // NATS 內部 ctx 可能比外層 ctx 更早逾時;確認是否為外層取消
                select {
                case <-ctx.Done():
                    return nil, nil, ctx.Err()
                default:
                    continue
                }
            } else if errors.Is(err, nats.ErrConnectionClosed) {
                j.disconnect()
                return nil, nil, service.ErrNotConnected
            }
            return nil, nil, err
        }
        // 無訊息、無錯誤:繼續下一輪
    }
}
```

**要點**
- ack 語意不變:`convertMessage` 已為每則 `*nats.Msg` 綁定 `m.Ack()`(成功)/`m.Nak()`(失敗)。批次內逐則獨立 ack,允許亂序(pull `AckExplicit` 支援),與下游 LWW CAS 相容。
- mutex 為防禦性:目前框架以單一 goroutine 呼叫 `Read()`;緩衝僅 `Read()` 觸碰,ack 走各自 `*nats.Msg` 不碰緩衝。保留 mutex 以防未來並行化。

### 5.5 錯誤 / 逾時契約(已核實 nats.go v1.50.0)

| 情況 | Fetch 回傳 | 本設計處理 |
|---|---|---|
| 收滿 `fetch_count` | `(msgs, nil)` | 全入緩衝 |
| 收到部分(≥1)後到期 | `(部分 msgs, nil)`(js.go:3199) | 全入緩衝 |
| 一則未收到即到期 | `(nil, ErrTimeout)`(js.go:3179) | 檢查外層 ctx;未取消則重試 |
| 連線關閉 | `(nil, ErrConnectionClosed)` | `disconnect()` + `ErrNotConnected` |
| 同傳 Context 與 MaxWait | `(nil, ErrContextAndTimeout)`(js.go:3013) | **設計上避免**:只用子 context |

### 5.6 關閉 / 排空語意(不可丟訊息)

- 已 `Fetch` 到緩衝、但尚未回傳給 pipeline 的訊息,在關閉時**未被 ack** → 伺服器於 `ack_wait` 後重送。**at-least-once 不變,無資料遺失**;下游 CAS 對重送冪等。
- 建議(可選最佳化):在 `disconnect()` 對 `j.pullBuf` 內剩餘訊息呼叫 `m.Nak()` 以觸發即時重送、縮短恢復延遲;之後清空緩衝。務必在持有 `pullMut` 下操作,且與 `natsSub.Drain()` 順序協調(先 Nak 再 Drain)。若不做,靠 `ack_wait` 自然重送即可。

### 5.7 伺服器端前置條件(關鍵,否則批次無效)

pull 路徑以 `nats.Bind` 綁**既有** consumer,client 端 SubOpt 的 `max_ack_pending` 不生效。因此:

```bash
# 建立或調整 durable pull consumer(無 DeliverSubject = pull)
nats consumer add   APP_EVENTS <durable> --pull --ack explicit \
  --max-pending <M> --wait 30s --replay instant
#   或既有 consumer:
nats consumer edit  APP_EVENTS <durable> --max-pending <M> --wait 30s
```

規則:**`M`(伺服器 max_ack_pending)≥ `fetch_count`**,建議 `M ≥ 2 × fetch_count` 以容納「已抓批次 + pipeline 在途」。若 `M < fetch_count`,伺服器只會投遞至多 `M` 則,批次被削,吞吐受限。

---

## 6. 容量規劃(如何選 `fetch_count`)

序列 `Fetch(N)` 迴圈:緩衝抽乾後才發下一批,故每批之間有一次 RTT 空檔。有效吞吐 ≈ `min(處理能力 R, fetch_count / RTT)`。

**選值公式(頻寬時延積)**

```
fetch_count ≥ 目標吞吐(msg/s) × RTT(s)          # 抵銷批次間 RTT 空檔
建議加 2× headroom:fetch_count = 2 × 目標 × RTT
伺服器 max_ack_pending ≥ fetch_count(建議 2×)
pipeline.threads:使 R ≥ 目標,單則 5ms → threads ≥ ceil(目標 × 0.005)
```

**範例(目標 1000 msg/s、RTT 0.2s、單則 5ms)**

| 參數 | 值 | 說明 |
|---|---|---|
| `fetch_count` | `256`(≈ 2 × 1000 × 0.2 = 400 亦可,取 256 為 2 冪) | 每趟帶回上限 |
| 伺服器 `max_ack_pending` | `512` | ≥ fetch_count,含 headroom |
| `fetch_timeout` | `1s` | 低流量時延遲上限 |
| `pipeline.threads` | `8` | 5ms × 1000 / 8 ≈ 0.6 利用率 |

> 若批次間 RTT 空檔仍造成鋸齒吞吐,代表已達 Strategy A 的結構上限——改採附錄 A 的連續預抓。

---

## 7. 正確性論證

1. **at-least-once 不變**:訊息 `Ack()` 僅在 pipeline 成功後由框架呼叫;失敗 `Nak()` 或關閉未 ack → 伺服器重送。批次化只改「一次抓幾則」,不改 ack 時機。
2. **亂序安全**:pull `AckExplicit` 允許逐則、亂序 ack;`pipeline.threads > 1` 造成的亂序處理與亂序 ack 皆合法。下游 sink 為 LWW CAS fence(reorder-safe),批次+高並行不影響最終一致性。
3. **無重複放大**:重送由 `Nats-Msg-Id` / sink CAS 冪等吸收;批次化不新增重複來源。

---

## 8. 相容性與 rollout

- `fetch_count` 預設 `1` → 行為位元級等同現行,既有部署升級後不變。
- 灰度:先在單一非關鍵 pipeline 設 `fetch_count: 16` 觀察 §10 指標,再逐步升到容量規劃值。
- 回滾:設回 `fetch_count: 1`(或移除欄位)即恢復原行為,無狀態遷移。

---

## 9. 測試計畫(agent 必須交付)

**單元測試**(`input_jetstream_test.go`)
- `fetch_count` 預設為 1;`fetch_count: 0/-1` 被 lint/建構拒絕。
- `fetch_timeout` 解析正確;預設 `5s`。

**整合測試**(`integration_jetstream_test.go`,既有 harness)
1. **批次抓取**:publish 100 則、`fetch_count: 25`,斷言全數 100 則收到且內容正確、無漏無序錯。
2. **部分批次逾時**:publish 3 則、`fetch_count: 50`、`fetch_timeout: 500ms`,斷言 3 則在約 ≤600ms 內全收到(驗證部分批次即時回傳,不等填滿)。
3. **背壓/重送**:pipeline 注入間歇性 `Nak`(processor 拋錯),斷言被 nak 訊息重送且最終全數送達。
4. **向後相容**:`fetch_count: 1` 與變更前行為一致(可比對訊息序與數量)。
5. **關閉不丟訊息**:抓入緩衝後立即關閉,重啟後斷言緩衝中未 ack 訊息被重送。

**延遲模擬(建議,可用 toxiproxy 或容器 `tc netem` 注入 100ms)**
- 比較 `fetch_count: 1` vs `256` 在 100ms RTT 下的吞吐,量測應從個位數 msg/s 提升至數百 msg/s;記錄於 PR。

---

## 10. 監控與 production readiness

### 10.1 可監控的指標(what can be monitored)

**Redpanda Connect Prometheus(`:4195/metrics`)**

| 指標 | 意義 | 批次化後預期 |
|---|---|---|
| `input_received`(rate) | 進入速率 | 由 ~6/s 升至目標 |
| `input_latency_ns`(histogram) | 每則自 input 取得耗時 | p50 塌至 µs(多數自緩衝取);p99 ≈ 批次首則的 RTT |
| `processor_latency_ns` | 處理耗時 | 維持 <5ms |
| `output_sent` / `output_latency_ns` | sink 送達與延遲 | sink(Redis CAS)健康度 |
| `output_error`(rate) | 送達失敗 | 應為 0;非零須查 |

> input 每則會設 `nats_num_pending` metadata(來自 `msg.Metadata().NumPending`)。可用 `metrics.mapping` 或 `log` processor 取樣,間接觀測 consumer backlog:
> ```yaml
> metrics:
>   mapping: |
>     meta pod = hostname()
> ```
> 並在 pipeline 加一支取樣 `log` 印出 `${! meta("nats_num_pending") }`。

**NATS consumer(`nats consumer info APP_EVENTS <durable>` / nats exporter)**

| 欄位 | 意義 | 判讀 |
|---|---|---|
| `Ack Pending`(num_ack_pending) | 在途未 ack 數 | **關鍵**:批次生效時應上升逼近 `fetch_count`;若恆 ≈1 = 未生效(查 `fetch_count` 是否套用、或伺服器 `max_ack_pending` < fetch_count) |
| `Num Pending`(backlog) | 尚未投遞的堆積 | 應持續排空;只增不減 = 消費落後 |
| `Num Waiting` | 未完成的 pull 請求數 | Strategy A 序列抓取下 ≈1(正常);>1 表非預期並行 |
| `Num Redelivered` | 重送計數 | 飆高 = `ack_wait` 太小或 pipeline 過載 |
| `Delivered` − `Ack Floor` | 已投遞與已確認落差 | ≈ 在途;穩定不擴大代表消費跟得上 |

### 10.2 production readiness 告警門檻(建議)

| 告警 | 條件 | 動作 |
|---|---|---|
| 批次未生效 | `Ack Pending` p95 < `fetch_count × 0.25` 持續 10 分鐘,且 `Num Pending` > 0 | 檢查伺服器 `max_ack_pending ≥ fetch_count`、`fetch_count` 是否套用 |
| 消費落後 | `Num Pending` 上升趨勢持續 15 分鐘 | 提高 `fetch_count` / `pipeline.threads`;或評估附錄 A |
| 重送異常 | `Num Redelivered` rate 非零且上升 | 調大伺服器 `ack_wait`;查 sink 錯誤 |
| 送達失敗 | `output_error` rate > 0 | 查 sink/transport;確認 DLQ/fallback |
| 延遲退化 | `input_latency_ns` p99 > `fetch_timeout` | 調小 `fetch_timeout`;查網路 RTT |

### 10.3 上線驗收(go/no-go)

1. 目標 RTT 下,`input_received` 達到 SLA 吞吐。
2. `Ack Pending` 穩定逼近 `fetch_count`(批次確實生效)。
3. `Num Pending` 可在負載下排空、不單調成長。
4. `output_error` = 0、`Num Redelivered` 近 0。
5. 灰度回滾路徑(設回 `fetch_count: 1`)已驗證可用。

---

## 11. 操作成本與風險

| 項目 | 評估 |
|---|---|
| 實作規模 | 小:~1 新欄位×2、struct 2 欄位、`Read()` pull 段重寫、測試。單一檔案。 |
| 維運負擔 | **中-高**:此為 fork。需追蹤上游 `input_jetstream.go` 變更並 rebase;上游若重構 pull 路徑(原始碼已有 TODO 表示想全面改用現代 jetstream API)會產生衝突。 |
| 相容風險 | 低:預設值等同現行;可即時回滾。 |
| 誤設風險 | 中:`fetch_count > 伺服器 max_ack_pending` 會靜默削批次。以 §10.2「批次未生效」告警守住。 |
| 升級風險 | 中:綁定 nats.go legacy `Fetch` 契約;升級 nats.go 需回歸 §9 測試 2/3。 |

**降低維運成本的建議**:若能接受較大重構,直接採 **附錄 A(Strategy B)** 用現代 `jetstream` 迭代器,長期更貼近上游方向、且吞吐特性更佳,可一併免除本 fork 對 legacy `Fetch` 的綁定。

---

## 附錄 A:Strategy B — 現代 `jetstream.Consumer.Messages()` 連續預抓(取捨與骨架)

**為何更好**:`Fetch(N)` 迴圈在每批之間有 RTT 空檔;`Messages()`/`Consume()` 維持 client 端 prefetch 窗口(`PullMaxMessages`),消耗到低水位(`PullThresholdMessages`,預設約半)即自動於背景補抓,**連續填滿 WAN 管線**,吞吐更平順、對 RTT 更不敏感。本 build 已可用(input 已 import `github.com/nats-io/nats.go/jetstream`,並已持有 `jetstream.Consumer`)。

**版本地板**:NATS server **建議 ≥ 2.9.0**(pull 的 `max_bytes`/`expires`/heartbeat 穩健支援);nats.go 現代 `jetstream` 套件已含於 v1.50.0。

**調校旋鈕**(對應新 config 欄位 `pull_max_messages` / `pull_expiry` / `pull_threshold`):
- `PullMaxMessages(n)`:client 緩衝上限(≈ 取代 `fetch_count` 的角色);仍需伺服器 `max_ack_pending ≥ n`。
- `PullExpiry(d)`:單次底層 pull 請求逾時。
- `PullThresholdMessages(t)`:低於 `t` 即補抓(維持連續預抓)。

**骨架(Connect + Read 橋接)**:

```go
// Connect():pull 分支改用現代迭代器,寫入一個 channel 供 Read() 消費
cons, err := js.Consumer(ctx, j.stream, j.durable) // 已有此物件
it, err := cons.Messages(
    jetstream.PullMaxMessages(j.pullMaxMessages),
    jetstream.PullExpiry(j.pullExpiry),
    jetstream.PullThresholdMessages(j.pullThreshold),
)
j.msgIter = it // 存於 struct

// Read():阻塞取下一則(迭代器已在背景連續預抓)
jmsg, err := j.msgIter.Next() // 需以 ctx 包裝可取消;見 nats.go jetstream 範例
if err != nil { /* 分類處理:closed/timeout */ }
// jetstream.Msg 的 ack:jmsg.Ack() / jmsg.Nak();metadata 由 jmsg.Metadata() 取
return convertJetstreamMessage(jmsg) // 需新增轉換(欄位名對齊既有 convertMessage)
```

**注意**:現代 `jetstream.Msg` 的 metadata/header 取用 API 與 legacy `*nats.Msg` 不同,需新增 `convertJetstreamMessage`,並保持既有 metadata 鍵名(`nats_subject`、`nats_sequence_stream`、`nats_num_pending` 等)以維持下游相容。監控指標與 §10 相同;`Num Waiting` 會因連續預抓而 >1(正常)。

**取捨結論**:需求為「改 `fetch()`」故主線交付 Strategy A;若專案可承受較大重構並希望降低長期 fork 維護成本、取得更佳 WAN 吞吐,建議改採 Strategy B。

---

## 附錄 B:變更檔案清單與 PR checklist

**檔案**
- `internal/impl/nats/input_jetstream.go`(config 欄位、struct、解析、`Read()` pull 段)
- `internal/impl/nats/input_jetstream_test.go`(單元)
- `internal/impl/nats/integration_jetstream_test.go`(整合)
- `CHANGELOG.md`(新增條目,標註本版本引入 `fetch_count` / `fetch_timeout`)
- 元件文件(若倉庫有自動產生的 docs,重新產生)

**PR checklist**
- [ ] `fetch_count` 預設 1,行為位元級相容
- [ ] `fetch_count < 1` 於建構期被拒;lint 規則就位
- [ ] `Read()` 先出緩衝、`len(msgs) > 0` 一律入緩衝、只有空批次判錯
- [ ] 逾時只用子 context,未與 `nats.MaxWait` 併用(避免 `ErrContextAndTimeout`)
- [ ] 關閉時緩衝訊息不遺失(靠 `ack_wait` 重送,或選擇性 `Nak`)
- [ ] §9 全部測試通過,含 100ms 延遲模擬吞吐對照
- [ ] PR 說明列出:伺服器 `max_ack_pending ≥ fetch_count` 前置條件、NATS server 版本要求、§10 監控與告警門檻
- [ ] CHANGELOG 更新
