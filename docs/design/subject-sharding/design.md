# SPEC v2:per-key Sharded Sink(broker fan-in)— 嚴格順序、無 LWW fence

> **文件性質**:給 Claude coding agent(Opus 4.8 / Fable 5)的實作規格書。**本版取代 v1。**
> **Repo**:`superplayground3000/gam-redis-pubsub`,base branch `master`(baseline 對照分支 `master-backup-260705`)。
> **v2 變更主旨(HP 定案)**:**移除 LWW version fence(v1 的 D-8/D-9/D-10/D-13 全數作廢)**。正確性改由**端到端嚴格 per-key 順序**承擔:訊息依來源序套用,故無需版本比較。sink apply 回歸 repo 既有的 SET / HSET / DEL / rename-Lua 冪等寫法。
> 既定決策不變:`copies: 1`、`pipeline.threads: 1`、sink 以 `broker` 綁多個 shard durable、shard = employee 後綴 `mod N`。

---

## 0. 一頁摘要

**問題**:Connect v4.92.0 `nats_jetstream` pull input 硬編碼 `Fetch(1)`(`input_jetstream.go` L422),每 consumer 吞吐 ≈ `1/RTT`,`lp:m2g` family 不夠用。

**方案**:employee 後綴 `mod N` → shard token 摺進 subject(`kv.cdc.lp.m2g.s<K>.<op>`)→ 每 shard 一個 durable(1 durable = 1 FilterSubject)→ sink 一 pod 用 `broker` 綁 K 個 durable,拿 K× 平行 fetch。

**正確性模型(v2 核心)**:沒有 fence,「較舊的 change 永不蓋掉較新的 change」完全依賴 §3 的**順序保證鏈(O-1…O-7)**成立。鏈上每一環都是 MUST + 模板寫死 + 監控代理訊號;任何一環放鬆(例如把 forward `max_in_flight` 調回 256)都會**無聲地**重新引入舊蓋新,且系統沒有任何指標能直接偵測到它。

**吞吐帳(必讀)**:嚴格順序要求 forward 序列化發佈(O-3/O-4),forward 上限 ≈ `1/RTT(central Connect ↔ NATS)`。NATS 與 central 同區時 RTT ~1ms → forward 天花板 ~1000 msg/s(全 family 合計)。**sink 端 sharding 解的是跨區 fetch 瓶頸;forward 的序列化天花板是 no-LWW 設計的固有代價。**若未來全站吞吐需求超過此天花板,唯一出路是恢復 fence(v1)換回 forward 並行——此為已知ترade-off,寫入 §14 決策記錄。

---

## 1. 已驗證事實(不得重新辯論)

| # | 事實 | 佐證 |
|---|---|---|
| F1 | `Fetch(1)` 硬編碼於 pull 路徑;pull(bind) 模式下 input 的 `ack_wait`/`max_ack_pending` 欄位無效,以 **server 端 consumer 設定為準** | connect v4.92.0 `internal/impl/nats/input_jetstream.go` L422 |
| F2 | bind 模式若 consumer 設複數 `FilterSubjects` 只取 `[0]` → 多 filter durable 不可用 | 同檔 L294–297 |
| F3 | `broker` input 為 fan-in:每 child 一條 goroutine 寫入共享無緩衝 channel;**per-child FIFO 保留**;ack 沿 transaction 路由回原 child;單 child 斷線不影響其他;全部 child 關閉 broker 才關 | benthos v4.73.0 `internal/impl/pure/input_broker_fan_in.go` |
| F4 | `broker copies > 1` = 同 durable 多 puller,破壞 per-shard 單消費者順序 | 同上 + F1 |
| F5 | JetStream 對同一 FilterSubject 的 durable 依 stream sequence 順序交付;`max_ack_pending: 1` 時,前一訊息 ack 前不交付下一則(含重送不越序) | NATS consumer 語意 |
| F6 | JetStream `Nats-Msg-Id` + `duplicate_window` 去重(first-arrived-wins);超窗重複會落地 | 專案既有結論 |
| F7 | `metric type: timing` 需整數奈秒字串;負值 clamp + counter;`use_histogram_timing: true` 時 `*_ns` 系列以**秒**輸出 | 專案既有結論 |
| F8 | elector 對 pipeline 內容不可知:讀 ConfigMap → `ReplaceAll(__POD__)` → 整包 POST `/streams/{id}`;OnStartedLeading POST / OnStoppedLeading DELETE,一條 stream 內的 broker 全體 children 隨 Lease 原子起落 | repo `internal/elector/streams.go` L16–20、`main.go` |
| F9 | streams REST API 不展開環境變數 | repo 註解 |
| F10 | NATS server ≥ 2.10.0(`ConsumerAction` create-only) | 專案既有結論 |
| F11 | 現行 forward 為 `threads: 2`、`max_in_flight: 256`、`fallback → reject`;現行 consumer 預設 `maxAckPending: 1024` | repo `cdc-forward.yaml` L45/L167/L173、`values.yaml` L90 |
| F12 | `redis_streams` input 重連時先以 id `0` 讀回自身 PEL(id 序)再切 `>`;`commit_period` 批次 XACK,序列化發佈下 pending 恆為連續尾段 | Connect `redis_streams` 語意 + 專案既有結論 |

---

## 2. 決策記錄(v2)

| ID | 決策 | 理由 / 取捨 | 狀態 |
|---|---|---|---|
| D-1 | shard = employee 後綴 `mod N`(排除 active/standby 段) | 同 employee 全 variant 同 shard;人可預測 | ✅ |
| D-2 | shard token 摺進 `kv_prefix`;subject `kv.cdc.lp.m2g.s<K>.<op>` | 重用 publishSubject helper,stream 零改動 | ✅ |
| D-3 | 1 durable = 1 FilterSubject | F2 | ✅ |
| D-4 | sink = `broker` 綁多 durable;`copies: 1`;`threads: 1` | F3/F4;HP 核准 | ✅ |
| D-5 | **無 LWW fence**:apply 回歸 SET / HSET / DEL / `cdc_rename.lua`;無 `_v:` 側掛 key、無 tombstone、envelope 無 `version` | 正確性由順序鏈(§3)承擔;省去 keyspace 翻倍與 producer HINCRBY round-trip | ✅ v2 定案 |
| D-6 | forward 收緊為 `threads: 1` + `max_in_flight: 1` | O-3/O-4;天花板 ≈ 1/RTT(同區 ~1000 msg/s) | ✅ v2 新增 |
| D-7 | forward **移除 `fallback → reject` 路徑**,改純 `nats_jetstream`(阻塞重試) | reject→nack→PEL replay 會讓被 nack 的舊事件排在已發佈的新事件之後 → 越序;阻塞重試以 backpressure 換順序(fail-stop > 無聲錯序) | ✅ v2 新增 |
| D-8 | 所有 shard durable `max_ack_pending: 1` | O-6:重送不得越序;在 `Fetch(1)` 串行下無額外吞吐損失 | ✅ v2 新增 |
| D-9 | 隔離 shard `sx` 收無法解析/跨 shard rename 的事件 | 毒訊息隔離 + invariant 可觀測 | ✅ |
| D-10 | virtual shard over-provision(N=32 一次定大);shard→group 分配為純配置 | 改分配免 remap;改 N 需 §10 pause-drain | ✅ |
| D-11 | cutover 與 resharding 一律走 **pause-drain**(§10) | 無 fence 時雙重消費/雙寫者競速即正確性錯誤,不可容忍 | ✅ v2 修訂 |

---

## 3. 順序保證鏈(Ordering Guarantee Chain)— v2 的正確性核心

> 定理:O-1…O-7 全部成立 ⟹ 對任一 kv_key,region Redis 的套用序 = `app.events` 的 XADD 序(重複允許,越序不允許)。任何一環為假,結論不成立。

| 環 | 保證 | 由誰提供 | 實作綁定 | 代理監控 |
|---|---|---|---|---|
| O-1 | 來源全序:同 key 事件在單一 `app.events` stream 內由 XADD 序列化 | Redis | 既有(單 stream 前提;F12) | — |
| O-2 | forward 單活性:任一時刻僅一個 forward 實例消費 | Lease elector | 既有 | `elector_leading` |
| O-3 | forward 管線序:讀取序 = 處理序 | `pipeline.threads: 1` | **模板寫死**(現為 2,改) | render 檢查(T-1) |
| O-4 | forward 發佈序:逐則等 `PubAck` 再發下一則;失敗原地阻塞重試,**無 reject/nack 路徑** | `max_in_flight: 1` + 移除 fallback | **模板寫死**(現為 256 + fallback,改) | `output_error` 速率、發佈延遲、backlog 告警 |
| O-5 | 重複無害:PEL replay 只會重發「其後無更新事件」的連續尾段(F12),重複落地(超 `duplicate_window`)= 尾段重放,snapshot 冪等吸收;窗內由 `Nats-Msg-Id` 去重(F6) | O-4 序列化 + F12 + F6 | `duplicate_window` ≥ 最大 forward 停機重啟時間(values 註明耦合) | JetStream duplicate PubAck |
| O-6 | per-shard 交付序:同 shard 依 stream seq 交付;**前一則 ack 前不交付下一則**(重送不越序) | 1 durable 1 filter(D-3)+ `max_ack_pending: 1`(D-8)+ 單活性 puller(Lease + `copies: 1`) | nats-init 建 consumer 參數;**shard group 不繼承** `sinkDefaults.maxAckPending` | `num_redelivered`(重送=重複,非越序)、`num_ack_pending ≤ 1` 斷言 |
| O-7 | sink 套用序:交付序 = 套用序 | broker per-child FIFO(F3)+ `threads: 1` + ack-after-apply(`reject_errored`) | **模板寫死** | `cdc_apply` 序列整合測試(T-6) |

**兩個刻意的不對稱,agent 不得「統一」它們:**

1. **forward 禁止 reject,sink 保留 `reject_errored`。** forward 的 nack 走 Redis PEL replay,replay 期間後續事件可能已發佈 → 越序(O-4 破)。sink 的 nack 走 JetStream 重送,在 `max_ack_pending: 1` 下重送不可能越序(O-6),所以 sink 端 redis 寫失敗 → throw → nack → 重送是安全且正確的重試機制。
2. **shard durable 的 `maxAckPending` 寫死為 1,不走 group→sinkDefaults→legacy 繼承鏈。** 繼承鏈預設 1024(F11),對非 shard group 維持現狀;shard group 若誤繼承 1024,O-6 立即破且無任何指標會報警。

---

## 4. 需求(RFC 2119)

### 4.1 Forward leg(`cdc-forward.yaml`)

- **MUST** sharding mapping:同 v1 §6——`meta("kv_key").or(meta("new_key")).or("")` → values 可配置 regex(預設 `\{employee:(?P<id>[0-9]+)\}`)抽 id → `"s" + (id.number().int64() % N).string()`;不可解析 → `sx` + `cdc_forward_unrouted{reason="unparseable_shard"}`;rename old/new 跨 shard → `sx` + `cdc_forward_cross_shard_rename`。
- **MUST** envelope **不新增** `version` 欄位(D-5;v1 的該條作廢)。
- **MUST**(sharding 啟用時)render `pipeline.threads: 1`、`max_in_flight: 1`,且 **MUST NOT** 提供 values 覆寫;`connect.source.maxInFlight` 在 sharding 啟用時 **MUST** fail-loud 拒絕(防止舊 values 殘留無聲放鬆 O-4)。
- **MUST**(sharding 啟用時)output 為純 `nats_jetstream`(移除 `fallback` 與 `reject` 子項);發佈失敗由 output 層原地重試(backpressure)。
- **MUST** 未啟用 sharding 時全輸出與 base **byte-identical**(INV-S1)。

### 4.2 NATS consumers(nats-init)

- **MUST** 每 family 建 `s0..s{N-1}` + `sx` durable:pull、`--ack explicit`、`--deliver all`、`--max-deliver -1`、`--ack-wait <values>`、**`--max-ack-pending 1`(寫死,不繼承)**。
- **MUST** create-only 語意(F10);既存 durable 不重建。
- **MUST** prune 受 §10 手動 gate 保護。
- **SHOULD** `ack_wait` 預設 30s;values 註解註明與 sink 端 redis `retries × retry_period` 的耦合(重試總時長必須 < ack_wait,否則原訊息處理中即觸發重送——重送不越序但徒增重複)。

### 4.3 Sink leg(broker 變體)

- **MUST** group 帶 `shardsOf` + `shards` 時 render broker 變體,否則 byte-identical 舊模板。
- **MUST** `copies: 1`、`threads: 1` 寫死;child:`label: lp_m2g_s<K>`、`bind: true`、專屬 durable、child processors 蓋 `meta shard = "s<K>"`。
- **MUST** `wait-consumer` initContainer 迴圈 gate **全部** K 個 durable(helpers 派生 durable 清單;v1 遺漏,本版納入)。
- **MUST** stash mapping:`op/type/kv_key/old_key/new_key/src_ts` + op-gated body 解碼(`.catch(null)` + `decode_failed`),**無 version 檢查**。
- **MUST** apply 分支沿用 repo 既有語意:
  - create/update:`type == "hash"` → `redis` processor `hset`(flatten mapping 原樣);否則 `set`。
  - delete → `del`。
  - rename → `eval` 既有 `cdc_rename.lua`(value-preserving RENAME;old/new 同 employee → 同 hash tag → 同 slot,forward 已斷言)。
  - unknown op / decode_failed → counter + throw。
- **MUST** e2e 延遲 metric(F7:整數奈秒、clamp、`cdc_e2e_negative_delay`)、`cdc_apply{shard,op,type}`。
- **MUST** output `reject_errored: { drop: {} }`(§3 不對稱 #1)。
- **MUST NOT** `kv_key` 進任何 label。

### 4.4 values / `_helpers.tpl`

- 同 v1 §4.4 全部驗證規則,另加:
  - `sharding.families` 條目**移除** `tombstoneTtlMs`。
  - sharding 啟用 ∧ `connect.source.maxInFlight` 有值 → fail-loud(§4.1)。
  - shard group 條目出現 `consumer.maxAckPending` → fail-loud(D-8 不可覆寫)。

## 5. 配置規格

```yaml
connect:
  sharding:
    keyPattern: '\{employee:(?P<id>[0-9]+)\}'
    families:
      "lp:m2g":
        shards: 32
  sinkGroups:
    - { name: m2g-a, shardsOf: "lp:m2g", shards: [0,1,2,3,4,5,6,7] }
    - { name: m2g-b, shardsOf: "lp:m2g", shards: [8,9,10,11,12,13,14,15] }
    - { name: m2g-c, shardsOf: "lp:m2g", shards: [16,17,18,19,20,21,22,23] }
    - { name: m2g-d, shardsOf: "lp:m2g", shards: [24,25,26,27,28,29,30,31,"x"] }
    - { name: others, catchAll: true }
```

命名派生同 v1 §5(durable `cdc_sink_lp_m2g_s<K>`、filter `kv.cdc.lp.m2g.s<K>.>` 等)。

**Worked example (commit-safe, richly commented):**
`chart/examples/values-sharding.yaml` is a runnable version of the config above —
one sharded family (`lp:m2g`, 8 shards) plus non-sharded prefix groups and a
catch-all, with friendly comments on every field, the credential and DLQ-
incompatibility notes, and the exact `helm template` / `scripts/verify-sharding.sh`
commands that prove it. `chart/examples/README.md` indexes it alongside the other
chart examples. Prefer editing/reading those files when you want a hands-on config;
this section stays the normative spec.

---

## 6. 參考實作 A — forward patch

sharding mapping 與 routing-miss counters 同 v1 §6(不再重複);差異三處:

1. envelope **不加** `version`。
2. `pipeline.threads`:sharding 啟用時 render `1`(Helm 條件),否則維持 `2`。
3. output 區塊(sharding 啟用時):

```yaml
output:
  label: __POD__
  nats_jetstream:
    urls: [ "{{ include "rrcs.nats.url" . }}" ]
    auth: { user_credentials_file: {{ .Values.nats.auth.creds.publisher | quote }} }
    subject: {{ include "rrcs.nats.stream.publishSubject" . | quote }}
    headers:
      Nats-Msg-Id: ${! meta("event_id") }
      Content-Type: application/json
    max_in_flight: 1          # O-4:寫死;發佈失敗原地重試(阻塞=backpressure),
                              # 絕不 reject/nack(PEL replay 會越序,§3 不對稱 #1)
```

> 可觀測性補償:`cdc_forward_publish_failed` counter 隨 fallback 移除而消失,以標準 `output_error{label}` + `output_connection_*` + backlog 告警(§11 A5)取代。

---

## 7. 參考實作 B — sink pipeline(broker 變體,無 fence)

group `m2g-a` 渲染後目標形態(模板以 `range $g.shards` 產出 children):

```yaml
input:
  label: sink_m2g_a
  broker:
    copies: 1                              # D-4:寫死
    inputs:
      {{- range $k := $g.shards }}
      - label: lp_m2g_s{{ $k }}
        nats_jetstream:
          urls: [ "{{ include "rrcs.nats.url" $ }}" ]
          auth: { user_credentials_file: {{ $.Values.nats.auth.creds.subscriber | quote }} }
          stream: {{ $.Values.nats.stream.name | quote }}
          durable: cdc_sink_lp_m2g_s{{ $k }}   # server 端已設 max_ack_pending=1(O-6)
          bind: true
        processors:
          - mapping: 'meta shard = "s{{ $k }}"'
      {{- end }}

pipeline:
  threads: 1                               # O-7:寫死
  processors:
    - mapping: |
        meta op      = this.op
        meta type    = this.type.or("string")
        meta kv_key  = this.kv_key
        meta old_key = this.old_key.or("")
        meta new_key = this.new_key.or("")
        meta src_ts  = this.ts.or("0")
        let carries_body = this.op == "create" || this.op == "update"
        let is_encoded   = $carries_body && this.enc.or("") == "gzip:base64"
        let decoded = if $carries_body {
          if $is_encoded { this.body.decode("base64").decompress("gzip").catch(null) }
          else { this.body }
        } else { null }
        meta body = $decoded
        meta decode_failed = if $is_encoded && $decoded == null { "yes" } else { "no" }
    - switch:
        - check: meta("src_ts").number().catch(0) > 0
          processors:
            - mapping: |
                let delta = timestamp_unix_nano() - (meta("src_ts").number().int64() * 1000000)
                meta e2e_ns  = $delta.max(0).string()
                meta e2e_neg = if $delta < 0 { "yes" } else { "no" }
            - switch:
                - check: meta("e2e_neg") == "yes"
                  processors:
                    - metric: { type: counter, name: cdc_e2e_negative_delay,
                                labels: { shard: '${! meta("shard") }' } }
            - metric:
                type: timing
                name: cdc_e2e_apply_delay
                value: '${! meta("e2e_ns") }'
                labels: { shard: '${! meta("shard") }' }
    - switch:
        - check: meta("decode_failed") == "yes"
          processors:
            - metric: { type: counter, name: cdc_unprocessable,
                        labels: { shard: '${! meta("shard") }', reason: decode_error } }
            - mapping: 'root = throw("decode_error: kv_key=%s".format(meta("kv_key").or("?")))'
        - check: meta("op") == "create" || meta("op") == "update"
          processors:
            - switch:
                - check: meta("type") == "hash"
                  processors:
                    - redis:
                        url: {{ include "rrcs.redis.region.url" $ }}
                        kind: {{ include "rrcs.redis.region.connectKind" $ }}
                        command: hset
                        args_mapping: 'root = [meta("kv_key")].concat(meta("body").parse_json().key_values().map_each(kv -> [kv.key, kv.value.string()]).flatten())'
                - processors:
                    - redis:
                        url: {{ include "rrcs.redis.region.url" $ }}
                        kind: {{ include "rrcs.redis.region.connectKind" $ }}
                        command: set
                        args_mapping: 'root = [ meta("kv_key"), meta("body") ]'
            - metric:
                type: counter
                name: cdc_apply
                labels: { shard: '${! meta("shard") }', op: '${! meta("op") }', type: '${! meta("type") }' }
        - check: meta("op") == "delete"
          processors:
            - redis:
                url: {{ include "rrcs.redis.region.url" $ }}
                kind: {{ include "rrcs.redis.region.connectKind" $ }}
                command: del
                args_mapping: 'root = [ meta("kv_key") ]'
            - metric: { type: counter, name: cdc_apply,
                        labels: { shard: '${! meta("shard") }', op: delete, type: '${! meta("type") }' } }
        - check: meta("op") == "rename"
          processors:
            - redis:
                url: {{ include "rrcs.redis.region.url" $ }}
                kind: {{ include "rrcs.redis.region.connectKind" $ }}
                command: eval
                args_mapping: |
                  let script = {{ $.Files.Get "files/connect/cdc_rename.lua" | toJson }}
                  root = [ $script, 2, meta("old_key"), meta("new_key") ]
            - metric: { type: counter, name: cdc_apply,
                        labels: { shard: '${! meta("shard") }', op: rename, type: '${! meta("type") }' } }
        - processors:
            - metric: { type: counter, name: cdc_unprocessable,
                        labels: { shard: '${! meta("shard") }', reason: unknown_op } }
            - mapping: 'root = throw("unknown op: %s".format(meta("op").or("missing")))'

output:
  reject_errored:
    drop: {}          # 失敗 → nack → JetStream 重送;MAP=1 下重送不越序(O-6)
```

> **無 Lua fence 檔案**:v1 的 `cdc_lww.lua` / `cdc_rename_lww.lua` 不建立;沿用既有 `cdc_rename.lua`。

---

## 8. Elector 相容性(結論:零改動)

Elector 對 pipeline 內容不可知(F8):broker 與單 input 對它是同一坨 YAML 字串;一條 stream = 一個 group 的全部 shard children,隨 Lease 原子 POST/DELETE → O-2/O-6 的單活性由既有機制直接繼承。新模板用語意 label、不含 `__POD__`,`ReplaceAll` 為 no-op。唯一模板改動是 §4.3 的 `wait-consumer` 多 durable gate。

---

## 9. 不變量(INV)

| ID | 不變量 | 驗證 |
|---|---|---|
| INV-S1 | sharding 未配置 → render byte-identical | T-1 |
| INV-S2 | 同 employee 全 variant 同 shard | T-2 |
| INV-S3 | 每 durable 任一時刻至多一個 active puller | Lease + copies:1 + T-6 |
| INV-S4 | `{0..N-1, x}` 恰好被 enabled groups 覆蓋一次 | T-3 |
| INV-O1 | sharding 啟用時 forward `threads==1 ∧ max_in_flight==1 ∧ 無 reject 路徑` | T-1 render 斷言 |
| INV-O2 | 全部 shard durable `max_ack_pending==1` | T-9 部署後 `nats consumer info` 斷言 |
| INV-O3 | 對任一 key,region 套用序 = 來源 XADD 序(允許重複) | T-6/T-7 整合測試 |
| INV-S7 | `cdc_forward_cross_shard_rename` 恆 0 | alert A3 |
| INV-S8 | 無 `kv_key` label | T-5 |

---

## 10. Cutover / Resharding — pause-drain(v2 修訂,無 fence 時強制)

> **為何不能滾動雙跑**:舊 group filter `kv.cdc.lp.m2g.>` 是新 shard subjects 的超集。無 fence 時,新舊兩個 consumer 同時套用同一 key 的相鄰事件,交錯即可造成舊值終態。**雙重消費期在 v2 是正確性錯誤,不是浪費。**

1. 部署 shard durables(`s0..s31`+`sx`)與 shard groups(此時無流量,idle;`wait-consumer` 全數通過)。
2. **暫停 forward**:`connect.source.enabled: false`(或 scale 到 0)→ elector `OnStoppedLeading` DELETE stream → 發佈停止;producer 照常 XADD,積壓留在 `app.events`(確認 stream MAXLEN/retention 容得下暫停窗)。
3. 等舊 m2g durable `num_pending == 0` 且 `num_ack_pending == 0`(flip 前已發佈的訊息全數套用)。
4. 停用舊 m2g group、刪除舊 durable(超集 filter 隨之消失)。
5. 啟用 forward(帶 sharding、threads:1、MIF:1)→ 積壓依序流向 shard subjects,只有新 groups 消費。
6. 驗收:`cdc_apply{shard=~"s.*"}` 速率恢復;`sx` 為 0;e2e p99 回落(積壓消化後)。

**回滾**(步驟 5 前任一點):還原 forward values → 重新 enable 舊 group(durable 若已刪由 nats-init 重建,`--deliver all` 從 stream 現存訊息開始)→ 流量回舊 subject。
**Resharding(改 N)**:同一程序,步驟 3 的 drain 對象改為全部舊 shard durables。改 shard→group 分配則無需本程序(滾動即可,Lease 保證每 durable 單 puller 交接)。

---

## 11. 監控與告警

指標(v1 的 `cdc_lww_stale_rejected` 不存在;無 fence = 無越序直接訊號,以下皆為**代理**):

| 指標 | Labels | 意義 |
|---|---|---|
| `cdc_apply` | shard, op, type | 各 shard 套用速率/均衡 |
| `cdc_unprocessable` | shard, reason(decode_error/unknown_op) | 毒訊息(throw→重送循環,MAP=1 下會塞住該 shard → A1 抓) |
| `cdc_e2e_apply_delay`(timing) | shard | e2e 新鮮度;`use_histogram_timing: true` 下**秒**為單位 |
| `cdc_e2e_negative_delay` | shard | 時鐘偏斜 |
| `cdc_forward_unrouted{reason="unparseable_shard"}` / `cdc_forward_cross_shard_rename` | reason | key 破約 / invariant |
| `output_error`、`output_connection_*`(forward) | label | O-4 阻塞重試可視化(取代 v1 publish_failed counter) |
| `jetstream_consumer_num_redelivered` | durable | 重複量(MAP=1 下重送=重複非越序);突增查 ack_wait 與 sink 重試耦合 |

Alert(NATS 指標一律 `is_consumer_leader="true"`):

```promql
# A1 — shard 卡死(毒訊息重送循環或 region Redis 故障)
max by (durable) (jetstream_consumer_num_pending{durable=~"cdc_sink_lp_m2g_s.*", is_consumer_leader="true"}) > 1000
  and on() rate(cdc_apply_total[5m]) == 0

# A2 — shard 傾斜(hot employee)
max(rate(cdc_apply_total{shard!~"sx"}[10m])) / avg(rate(cdc_apply_total{shard!~"sx"}[10m])) > 3

# A3 — 隔離道非空(INV)
rate(cdc_forward_cross_shard_rename_total[5m]) > 0
  or rate(cdc_unprocessable_total[5m]) > 0
  or rate(cdc_apply_total{shard="sx"}[5m]) > 0

# A4 — e2e p99 超標(秒)
histogram_quantile(0.99, sum by (le) (rate(cdc_e2e_apply_delay_bucket[5m]))) > 5

# A5 — forward 阻塞重試(O-4 backpressure 可視化)
rate(output_error_total{label=~".*forward.*|__POD__"}[5m]) > 0
  or (redis_stream_pel_pending{stream="app.events"} > 10 * scalar(avg_over_time(redis_stream_pel_pending[1d])))

# A6 — O-6 斷言:任一 shard durable ack_pending 超過 1
max(jetstream_consumer_num_ack_pending{durable=~"cdc_sink_lp_m2g_s.*", is_consumer_leader="true"}) > 1
```

---

## 12. 前置/邊界任務

| 任務 | 內容 | Gate |
|---|---|---|
| P-1 | 確認 `app.events` retention(MAXLEN/MINID)足以吸收 §10 暫停窗與 forward 阻塞重試窗 | cutover 前 |
| P-2 | `duplicate_window` 校核:≥ 最大 forward 停機重啟時間(O-5);values 註解耦合 | 同批 PR |
| ~~v1 P-1/P-2/P-3~~ | writer 帶 version / fence 上線 / rename 帶 body | **作廢**(D-5) |

> rename 註:v2 沿用 value-preserving `cdc_rename.lua`,envelope 不需 body;v1 的 P-3 一併作廢。

---

## 13. 測試計畫

| ID | 類型 | 內容 | 準則 |
|---|---|---|---|
| T-1 | render | sharding off → byte-identical;sharding on → 斷言 forward `threads:1`/`max_in_flight:1`/無 `fallback:`、sink `copies:1`/`threads:1` | INV-S1、INV-O1 |
| T-2 | Bloblang 單元 | shard 函數表格測試(同 v1:active/standby 同 employee 同 shard;sx;跨 shard rename;`.or(new_key)`) | INV-S2 |
| T-3 | render fail-loud | 覆蓋缺漏/重複、`x` 未認領、family 同在 prefixes、`connect.source.maxInFlight` 殘留、shard group 覆寫 `maxAckPending` | 每案指名規則 |
| T-4 | 順序整合(核心) | 對單一 employee 交錯發 active/standby update 各 200 筆(值含遞增序號)→ 斷言 region 兩把 key 的**中間態序列**與來源一致(輪詢抓取)且終態=最後值 | INV-O3 |
| T-5 | 靜態 | `rpk connect lint`;grep 無 `kv_key` label | INV-S8 |
| T-6 | 故障注入:sink | apply 中 kill sink pod → Lease 轉移 → 重送 → 斷言無越序(值序列單調)、`num_ack_pending ≤ 1` 全程成立 | INV-O2/O3、INV-S9(ack 隔離) |
| T-7 | 故障注入:forward | PubAck 前 kill forward → PEL replay → 斷言 JetStream 內同 key 序 = XADD 序(允許尾段重複);縮短 `duplicate_window` 重跑,斷言重複落地仍不越序 | O-4/O-5 |
| T-8 | 吞吐 | tc netem 注入 RTT:單 shard ≈ 1/RTT、K child ≈ K/RTT;forward 實測 ≈ 1/RTT(確認 O-4 天花板數字進容量文件) | ≥ 理論 80% |
| T-9 | 部署後斷言 | 全 shard durable `nats consumer info`:`max_ack_pending == 1`、單 puller | INV-O2 |
| T-10 | Cutover 演練 | §10 全程含回滾;暫停窗內 XADD 持續、恢復後無遺漏(對帳 event_id 計數) | 無遺漏、無越序 |

---

## 14. 版本底線 + 已知天花板

| 項目 | 值 | 佐證 |
|---|---|---|
| `broker` input | benthos core(現用 v4.73.0) | `input_broker*.go` |
| `nats_jetstream` bind pull(`Fetch(1)`、`FilterSubjects[0]`) | Connect v4.92.0 現狀 | `input_jetstream.go` L294–297、L422 |
| durable + FilterSubject、create-only | nats-server 2.10.0 | F10 |
| `max_ack_pending`(consumer 建立參數) | JetStream 基礎功能,遠低於 2.10 底線 | NATS docs |
| **forward 吞吐天花板** | ≈ 1/RTT(central↔NATS),全 family 合計;同區 ~1000 msg/s | O-4 固有;超過需回 v1 fence 方案 |
| **越序偵測能力** | **無直接訊號**(無 fence);僅 §11 代理 + T-4/T-6/T-7 測試防護 | D-5 已知代價 |

## 15. PR Checklist

- [ ] T-1:sharding off byte-identical;on 時 forward/sink 序列化參數斷言全過
- [ ] forward:threads:1、max_in_flight:1、無 fallback/reject(sharding 啟用時);envelope 無 version
- [ ] nats-init:shard durable `--max-ack-pending 1` 寫死;`sx` 建立;prune 手動 gate
- [ ] sink 模板:broker + copies:1 + threads:1 寫死;`wait-consumer` 迴圈 gate 全部 durable
- [ ] 無任何 `_v:`/tombstone/version 相關碼(v1 殘留清除)
- [ ] 指標/dashboard/6 條 alert(A1–A6)更新;無 `kv_key` label
- [ ] §10 pause-drain 程序 + 回滾寫入 repo docs(含超集 filter 雙消費為何是正確性錯誤)
- [ ] T-2/T-4/T-5/T-9 進 CI;T-6/T-7/T-8/T-10 附可執行腳本
- [ ] PR 描述附 §14(含 forward 天花板與偵測能力缺口聲明)

## 16. Out of Scope

- LWW fence(v1 方案)——保留 v1 文件作為吞吐超過 forward 天花板時的升級路徑。
- `Fetch(1)` upstream patch / `Consumer.Messages()` 遷移(Strategy B)。
- `shared` mode、多 filter durable、非數字 shard key(server `partition()`)。
