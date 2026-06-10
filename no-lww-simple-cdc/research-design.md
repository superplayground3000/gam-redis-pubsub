# Redis Key CDC(create / update / delete / rename)— 無 LWW 簡化版設計

> 範圍:移除 LWW version fence,**忽略順序問題**(亂序、stale overwrite 視為可接受)。
> 資料流:`Redis Streams → Redpanda Connect(source)→ NATS JetStream → Redpanda Connect(sink)→ Redis KV`
> 保留:create / update / delete / rename 四種操作的端到端傳播、at-least-once + JetStream 去重、production 監控與維運設計。

---

## 1. 版本需求矩陣(最低版本)

| 元件 | 最低版本 | 原因 | 建議版本 |
|---|---|---|---|
| Redis(source,Streams) | **5.0** | `XADD` / `XREADGROUP` / `XACK` / PEL | 7.2(production baseline) |
| Redis(source,Streams) | **6.2** | `XAUTOCLAIM`(PEL 回收 supervisor 必需) | 7.2 |
| Redis(sink,KV) | **2.6** | Lua `EVAL` / `EVALSHA`(rename 原子處理) | 7.2 |
| Redis(sink,KV) | **4.0** | `UNLINK`(非阻塞刪除,選用) | 7.2 |
| Redpanda Connect | **3.46.0** | `nats_jetstream` output 引入版本 | ≥ 4.38.0 |
| Redpanda Connect | **4.1.0** | `nats_jetstream` output `headers` 欄位插值(`Nats-Msg-Id` 去重模式必需) | ≥ 4.38.0 |
| Redpanda Connect | **4.3.0** | `redis` processor 的 `command` / `args_mapping` 欄位(sink 端套用 op 必需) | ≥ 4.38.0 |
| NATS Server | **2.2.0** | JetStream GA、`Nats-Msg-Id` + `duplicate_window` 去重 | ≥ 2.10.x |
| nats CLI | 任意近期版 | `nats stream add` / `nats consumer add` | 最新 |

> 注意:Redpanda Connect streams mode REST API **不做環境變數插值**(只支援 Bloblang 函式插值);若採 active-passive streams-mode 部署,config 須先在外部模板化再 POST。

---

## 2. 架構總覽

```
┌──────────────┐   XREADGROUP/XACK   ┌──────────────────┐   publish + Nats-Msg-Id   ┌────────────────┐
│ Redis Stream │ ──────────────────► │ Redpanda Connect │ ────────────────────────► │ NATS JetStream │
│  app.events  │                     │     (source)     │                           │  KV_CDC stream │
└──────────────┘                     └──────────────────┘                           └───────┬────────┘
                                                                                            │ durable pull consumer
                                                                                            ▼
                                     ┌──────────────────┐   SET / DEL / Lua rename  ┌──────────────┐
                                     │ Redpanda Connect │ ────────────────────────► │  Redis KV    │
                                     │      (sink)      │                           │  (目標庫)    │
                                     └──────────────────┘                           └──────────────┘
```

設計原則(無 LWW 版):

1. **正確性退化為「最終每個事件至少被套用一次」**:不保證新蓋舊;晚到的舊事件**會**覆蓋新值(stale overwrite)。這是本版本明示接受的取捨。
2. **冪等性必須由 op 本身保障**(因為 at-least-once 重送無法避免):
   - `create` / `update` → `SET key val`:天生冪等(重放結果相同)。
   - `delete` → `DEL key`:天生冪等。
   - `rename` → **不可用 Redis `RENAME`**(重放第二次時 old key 已不存在會報錯)。改為 `DEL old + SET new`,重放安全。
3. **JetStream 去重(`Nats-Msg-Id` + `duplicate_window`)在無 LWW 版本中地位提升**:它是唯一防止「同一事件重複進入 JetStream」的機制(原 LWW 設計中 CAS 已冪等、dedup 只是優化;本版沒有 fence,dedup 是第一道防線)。但 sink 端 JetStream consumer 的重送仍可能重複套用——靠上面第 2 點的 op 冪等性吸收。
4. **event_id 仍由 producer 鑄造並寫入 XADD payload**:`redis_streams` input 不暴露 Redis entry id 為 metadata,去重 key 必須是應用層欄位。

---

## 3. Stream Message Template(Redis Streams,XADD 信封)

`body_key: body`;`body` 以外所有欄位會成為 Redpanda Connect metadata。

### 共用信封

| 欄位 | 必填 | 說明 |
|---|---|---|
| `event_id` | ✅ | producer 鑄造的唯一 ID(UUID);`Nats-Msg-Id` 去重 key |
| `op` | ✅ | `create` \| `update` \| `delete` \| `rename` |
| `kv_key` | create/update/delete ✅ | sink KV 的目標 key |
| `old_key` | rename ✅ | rename 來源 key |
| `new_key` | rename ✅ | rename 目標 key |
| `ts` | 建議 | producer 端事件時間(epoch ms),純觀測用(端到端延遲監控) |
| `body` | ✅(delete 可為空字串) | JSON snapshot;`body_key` 指向此欄位 |

### 各 op 的欄位組合

```text
create / update:
  event_id=<uuid> op=create|update kv_key=<key> ts=<ms> body=<json>

delete:
  event_id=<uuid> op=delete kv_key=<key> ts=<ms> body=""

rename:
  event_id=<uuid> op=rename old_key=<舊key> new_key=<新key> ts=<ms> body=<json(新key的完整snapshot)>
```

> rename 一律附上完整 snapshot(`body`),sink 以 `DEL old + SET new(body)` 落地,不依賴讀取舊值,重放冪等。

---

## 4. Example Commandline(XADD 等)

### 4.1 前置:建立 stream 與 consumer group

```bash
# '$' = 只吃新事件;要回放歷史改用 '0'
redis-cli XGROUP CREATE app.events cdc_propagator '$' MKSTREAM
```

### 4.2 create

```bash
redis-cli XADD app.events '*' \
  event_id "$(uuidgen)" \
  op create \
  kv_key "ORD-42" \
  ts "$(date +%s%3N)" \
  body '{"id":"ORD-42","name":"foo","amount":99.9}'
```

### 4.3 update

```bash
redis-cli XADD app.events '*' \
  event_id "$(uuidgen)" \
  op update \
  kv_key "ORD-42" \
  ts "$(date +%s%3N)" \
  body '{"id":"ORD-42","name":"foo","amount":120.0}'
```

### 4.4 delete

```bash
redis-cli XADD app.events '*' \
  event_id "$(uuidgen)" \
  op delete \
  kv_key "ORD-42" \
  ts "$(date +%s%3N)" \
  body ''
```

### 4.5 rename

```bash
redis-cli XADD app.events '*' \
  event_id "$(uuidgen)" \
  op rename \
  old_key "ORD-42" \
  new_key "ORD-99" \
  ts "$(date +%s%3N)" \
  body '{"id":"ORD-99","name":"foo","amount":120.0}'
```

> Go(go-redis v9.7.0+,Go 1.18+)注意事項:`XADD` 的 `Values` **不要用 `map`**(欄位順序會遺失),用 slice 形式 `[]interface{}{"event_id", id, "op", "create", ...}`。

### 4.6 JetStream stream 建立

```bash
nats stream add KV_CDC \
  --subjects 'kv.cdc.>' \
  --storage file \
  --replicas 3 \
  --retention limits \
  --discard old \
  --max-age 168h \
  --max-msg-size 1MB \
  --dupe-window 5m \
  --ack \
  --defaults

# sink 端 durable pull consumer
nats consumer add KV_CDC cdc_sink \
  --pull --deliver all --ack explicit \
  --max-deliver -1 --filter 'kv.cdc.>' --defaults
```

---

## 5. NATS JetStream Message Template

Subject 規則:`kv.cdc.<op>`(由 source 端以 metadata 插值)。

### create / update

```text
Subject : kv.cdc.create        (或 kv.cdc.update)
Headers :
  Nats-Msg-Id  : <event_id>          # JetStream 去重 key
  Content-Type : application/json
  op           : create              # 由 metadata 轉發
  kv_key       : ORD-42
  ts           : 1749530000123
Payload : {"id":"ORD-42","name":"foo","amount":99.9}
```

### delete

```text
Subject : kv.cdc.delete
Headers :
  Nats-Msg-Id  : <event_id>
  op           : delete
  kv_key       : ORD-42
  ts           : 1749530000123
Payload : (空)
```

### rename

```text
Subject : kv.cdc.rename
Headers :
  Nats-Msg-Id  : <event_id>
  op           : rename
  old_key      : ORD-42
  new_key      : ORD-99
  ts           : 1749530000123
Payload : {"id":"ORD-99","name":"foo","amount":120.0}
```

> sink 端 `nats_jetstream` input 會把 NATS headers 還原為 Redpanda Connect metadata,因此 `op` / `kv_key` / `old_key` / `new_key` 可在 sink pipeline 直接以 `meta()` 取用。

---

## 6. Redpanda Connect 設定

### 6.1 Source(Redis Streams → JetStream)

```yaml
# source.yaml  (Redpanda Connect >= 4.1.0;建議 >= 4.38.0)
http:
  address: 0.0.0.0:4195

input:
  label: redis_source
  redis_streams:
    url: redis://redis-source.internal:6379
    kind: simple
    streams: [ app.events ]
    consumer_group: cdc_propagator
    client_id: ${HOSTNAME:rpc-src-1}      # 每個 instance 必須唯一
    body_key: body
    create_streams: true
    start_from_oldest: true
    commit_period: 200ms
    timeout: 500ms
    limit: 50
    auto_replay_nacks: true

pipeline:
  threads: 4                              # 忽略順序 → 可放心並行
  processors:
    - mapping: |
        # 防禦:producer 漏帶 event_id 時以內容雜湊補上,維持去重有效
        meta event_id = meta("event_id").or(content().hash("sha256").encode("hex"))
        root = this

output:
  label: jetstream_sink
  fallback:
    - nats_jetstream:
        urls: [ nats://nats-1:4222, nats://nats-2:4222, nats://nats-3:4222 ]
        subject: kv.cdc.${! meta("op") }
        headers:
          Nats-Msg-Id: ${! meta("event_id") }   # 去重(需 RPC >= 4.1.0)
          Content-Type: application/json
        metadata:
          include_patterns: [ "op", "kv_key", "old_key", "new_key", "ts" ]
        max_in_flight: 256
        auth:
          user_credentials_file: /run/secrets/nats.creds
    - redis_streams:                            # 永久失敗 → DLQ
        url: redis://redis-source.internal:6379
        stream: app.events.dlq
        body_key: body
        max_in_flight: 16

logger: { level: INFO, format: json }
metrics:
  prometheus: { use_histogram_timing: true }
```

### 6.2 Sink(JetStream → Redis KV)

```yaml
# sink.yaml  (Redpanda Connect >= 4.3.0:redis processor command/args_mapping)
http:
  address: 0.0.0.0:4195

input:
  label: js_source
  nats_jetstream:
    urls: [ nats://nats-1:4222, nats://nats-2:4222, nats://nats-3:4222 ]
    subject: "kv.cdc.>"
    durable: cdc_sink
    stream: KV_CDC
    deliver: all
    ack_wait: 30s
    max_ack_pending: 1024          # 忽略順序 → 不需要 1
    auth:
      user_credentials_file: /run/secrets/nats.creds

pipeline:
  threads: 4
  processors:
    - switch:
        # ---- create / update → SET(冪等)----
        - check: meta("op") == "create" || meta("op") == "update"
          processors:
            - redis:
                url: redis://redis-kv.internal:6379
                command: SET
                args_mapping: 'root = [ meta("kv_key"), content().string() ]'

        # ---- delete → DEL(冪等)----
        - check: meta("op") == "delete"
          processors:
            - redis:
                url: redis://redis-kv.internal:6379
                command: DEL
                args_mapping: 'root = [ meta("kv_key") ]'

        # ---- rename → Lua: DEL old + SET new(原子且重放冪等)----
        - check: meta("op") == "rename"
          processors:
            - redis:
                url: redis://redis-kv.internal:6379
                command: EVAL
                args_mapping: |
                  root = [
                    "redis.call('DEL', KEYS[1]); redis.call('SET', KEYS[2], ARGV[1]); return 1",
                    "2",
                    meta("old_key"),
                    meta("new_key"),
                    content().string()
                  ]

        # ---- 未知 op → 標記錯誤,走 reject 重送/告警 ----
        - processors:
            - mapping: 'root = throw("unknown op: %s".format(meta("op").or("missing")))'

output:
  reject_errored:
    drop: {}        # 處理成功 → ack JetStream;processor 失敗 → nack,由 JetStream 重送

logger: { level: INFO, format: json }
metrics:
  prometheus: { use_histogram_timing: true }
```

設計說明:

- **寫入動作放在 processor、output 用 `reject_errored: drop`**:成功 → ack;失敗 → nack → JetStream 依 `ack_wait` 重送。重送靠 SET/DEL/Lua 的冪等性安全吸收。
- **rename 用 `EVAL` 而非 `RENAME`**:`RENAME` 在 old key 不存在時(重放第二次)會丟 error,破壞冪等;Lua `DEL+SET` 任意次重放結果一致,且單腳本在 Redis 內原子執行。
- **Redis Cluster 注意**:Lua 多 key 腳本要求 `old_key` / `new_key` 同 slot(hash tag,如 `{ORD}-42` → `{ORD}-99`)。做不到同 slot 時,改為兩個獨立 processor(`SET new` 先、`DEL old` 後),接受短暫雙 key 並存窗口(重放仍冪等)。
- 重複套用的固定上限頻率由 `EVALSHA` 優化可省頻寬:production 可預載腳本後改 `EVALSHA <sha> 2 ...`(Redis 2.6+)。

---

## 7. 端到端語意(本版本提供什麼、不提供什麼)

| 性質 | 是否保證 | 機制 |
|---|---|---|
| 不丟事件(at-least-once) | ✅ | Redis PEL + `XACK` 後置;JetStream explicit ack |
| 同一事件不重複進 JetStream | ✅(`duplicate_window` 內) | `Nats-Msg-Id` 去重;窗口外的重送會產生重複,靠 sink 冪等吸收 |
| sink 重放安全 | ✅ | SET / DEL / Lua(DEL+SET)全冪等 |
| 新蓋舊(LWW) | ❌(明示放棄) | 無 version fence;亂序/重送可能 stale overwrite |
| delete 不被舊 set 復活 | ❌(明示放棄) | 無 tombstone;晚到的舊 `set` 會讓被刪 key 復活 |
| rename 原子 | ✅(單 slot)/ ⚠️(跨 slot 有短暫窗口) | Lua DEL+SET |

> `duplicate_window` 選 5m:須 ≥(Redpanda Connect 最長停機 + Redis PEL idle 門檻)。500 msg/s × 5m ≈ 15 萬筆 dedup index,記憶體可忽略。

---

## 8. 維運(Operation Efforts)

| 項目 | 作法 | 頻率/負擔 |
|---|---|---|
| **PEL 回收** | `redis_streams` input **不會呼叫 `XAUTOCLAIM`**;需獨立 supervisor sidecar:`XAUTOCLAIM app.events cdc_propagator <claimer> 60000 0-0 COUNT 100` 迴圈直到 cursor `0-0` | 常駐 sidecar(Redis ≥ 6.2) |
| **DLQ 巡檢** | `app.events.dlq` 長度告警 + 人工/自動重放 | 每日;告警驅動 |
| **source stream 修剪** | cron:`XTRIM app.events MINID ~ $(( ($(date +%s) - 3600) * 1000 )) LIMIT 1000`(JetStream 落地後 Redis 只需短保留) | 每 5–15 分鐘 |
| **JetStream 保留** | `--max-age 168h` 由 server 自動執行 | 零負擔 |
| **HA 擴展** | source/sink 皆可 active-active:同 `consumer_group`/`durable`、不同 `client_id`。**忽略順序後不需要 single-active**,多 pod 直接分流,故障切換零等待 | 一次性部署 |
| **Lua 腳本管理** | 啟動時 `SCRIPT LOAD` 預載 rename 腳本,設定改用 `EVALSHA`;Redis failover 後 `NOSCRIPT` 自動回退 `EVAL` | 一次性 |
| **容量規劃** | 500 msg/s 級別單 instance 綽綽有餘(JetStream 單 async publisher 實測可達數十萬 msg/s);瓶頸先看 dedup index 與 PEL,不是吞吐 | 季度 review |

---

## 9. 監控(Production Readiness)

| 訊號 | 來源 | 門檻 / 意義 |
|---|---|---|
| `XPENDING app.events cdc_propagator` 筆數 | redis_exporter(`oliver006/redis_exporter`)/ `XPENDING` | > 10× 穩態持續 5 分鐘 → source 卡住 |
| PEL 最大 idle time | `XPENDING ... IDLE` 擴展形式 | > `duplicate_window`/2 → 重送將落在去重窗口外的風險 |
| delivery-count ≥ 5 的 entry | `XPENDING - + 100` 擴展形式 | 毒訊息 → 移 DLQ |
| `input_received` / `output_sent` rate | Redpanda Connect Prometheus(:4195/metrics) | 歸零且 Redis 仍有 entries > 1 分鐘 → 管線停擺 |
| `output_error`、`processor_error` | Redpanda Connect Prometheus | 非零速率即告警(sink 端 = Redis 寫入失敗) |
| `output_latency_ns` p99 | Redpanda Connect Prometheus | > 100ms |
| `output_connection_up` / `_failed` / `_lost` | Redpanda Connect Prometheus | 任何重連事件記錄 |
| JetStream `messages` / consumer `num_pending` / `num_ack_pending` | `nats consumer info KV_CDC cdc_sink`、`prometheus-nats-exporter`、`nats-surveyor` | pending 持續成長 → sink 消化不及 |
| PubAck `duplicate=true` 比率 | `nats events --all` / server metrics | 突增 = 大量重送(查 source crash / PEL idle) |
| DLQ 長度 | `XLEN app.events.dlq`(redis_exporter) | > 0 即告警 |
| 端到端延遲 | `ts`(事件時間)vs sink 套用時間(sink processor 可另寫 `updated_at`) | KV 新鮮度 SLA |
| rename 殘留檢查(跨 slot 非原子時) | 旁路巡檢:old_key 仍存在且 new_key 也存在超過 N 秒 | 非原子裂縫偵測 |
| `/ready`(:4195) | curl / k8s probe | 非 200;注意 streams mode 下零 active stream 仍回 200,需另行檢查 stream 數 |

---

## 10. Caveats(明示的取捨與風險)

1. **stale overwrite 是常態風險**:任何 crash 重送、雙 consumer 競爭、網路重試都可能讓舊事件後到並覆蓋新值。本設計**接受**此行為;若日後不可接受,即回到 LWW version fence 設計(producer `HINCRBY` 鑄版 + sink Lua CAS)。
2. **delete 復活**:無 tombstone,被刪的 key 可能被晚到的舊 `create/update` 復活。
3. **rename 語意是「DEL old + SET new(snapshot)」**,不是 Redis 原生 `RENAME`——這是為了重放冪等的刻意選擇;rename 事件必須攜帶完整 snapshot。
4. **`duplicate_window` 外的重送會重複進 JetStream**:sink 冪等可吸收效果,但 JetStream stream 內會留重複訊息(影響審計/回放)。
5. **`redis_streams` input 不暴露 Redis entry id**:`event_id` 必須是 producer 寫進 XADD payload 的應用層欄位,這是去重契約,retrofit 困難,第一天就要做。
6. **跨 slot rename**(Redis Cluster、無 hash tag)只能拆兩步,存在短暫雙 key 窗口。

---

## 11. 驗證腳本

```bash
# 1) 去重驗證:同一 event_id 推 5 次,JetStream 應只收 1 筆
EID="evt-DUP-$(date +%s)"
for i in 1 2 3 4 5; do
  redis-cli XADD app.events '*' event_id "$EID" op update kv_key "ORD-42" \
    ts "$(date +%s%3N)" body '{"id":"ORD-42","n":'"$i"'}'
done
nats stream info KV_CDC | grep Messages    # 應只 +1

# 2) 四種 op 端到端
redis-cli XADD app.events '*' event_id "$(uuidgen)" op create kv_key "K1" ts "$(date +%s%3N)" body '{"v":1}'
redis-cli XADD app.events '*' event_id "$(uuidgen)" op update kv_key "K1" ts "$(date +%s%3N)" body '{"v":2}'
redis-cli XADD app.events '*' event_id "$(uuidgen)" op rename old_key "K1" new_key "K2" ts "$(date +%s%3N)" body '{"v":2}'
redis-cli XADD app.events '*' event_id "$(uuidgen)" op delete kv_key "K2" ts "$(date +%s%3N)" body ''

# 目標 KV 驗證(依序應為:{"v":1} → {"v":2} → K1 消失/K2 出現 → K2 消失)
redis-cli -h redis-kv.internal GET K1
redis-cli -h redis-kv.internal GET K2

# 3) 重放冪等驗證:手動讓 sink consumer 重送(nats consumer 重設 deliver),
#    重跑後 KV 終態應不變(SET/DEL/Lua 全冪等)
```
