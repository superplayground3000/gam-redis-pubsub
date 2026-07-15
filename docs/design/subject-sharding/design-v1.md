# SPEC:per-key Sharded Sink(broker fan-in)— lp:m2g family 吞吐擴展

> **文件性質**:給 Claude coding agent(Opus 4.8 / Fable 5)的實作規格書。
> **Repo**:`superplayground3000/gam-redis-pubsub`,base branch `master`(baseline 對照分支 `master-backup-260705`)。
> **狀態**:已定案。人類 owner(HP)已核准以下三項關鍵決策:`copies: 1`、`pipeline.threads: 1`、sink 端以 `broker` input 綁多個 shard durable。

---

## 0. 一頁摘要(先讀這裡)

**問題**:Redpanda Connect v4.92.0 的 `nats_jetstream` pull input 硬編碼 `Fetch(1)`(源碼 `internal/impl/nats/input_jetstream.go` **L422**),每個 consumer 的跨區吞吐被綁在 ~`1/RTT`。`lp:m2g` key family 吞吐不足。

**方案**:key 的 employee 數字後綴 `mod N` 決定 shard → forward 端把 shard token 摺進既有 `kv_prefix` subject token(`kv.cdc.lp.m2g.s<K>.<op>`)→ 每個 shard 一個 durable pull consumer(**1 durable = 1 FilterSubject**)→ sink 端一個 pod 用 `broker` input 綁多個 shard durable,拿到 K× 平行 fetch。

**順序保證**:shard key 刻意排除 `active`/`standby` 段 → 同一 employee 的所有 key variant 必落同一 shard、同一 consumer。`threads: 1` + `copies: 1` 維持 per-shard FIFO apply;sink 端 LWW CAS fence(`redis_script` Lua)吸收殘餘重排(publish retry、redelivery),為第二道防線與 cutover 期間的正確性基礎。

**交付物**:forward mapping patch、新 sink pipeline 模板(broker 變體)、兩支 Lua(LWW fence、LWW rename)、values schema 與 `_helpers.tpl` fail-loud 驗證、nats-init durable 建立/清理、監控指標與 alert、測試、cutover 程序。

---

## 1. 背景與已驗證事實(不得重新辯論,直接依此實作)

以下事實均已在本專案先前迭代中以源碼或官方文件驗證,coding agent **不需**重新驗證,但實作不得與之矛盾:

| # | 事實 | 佐證 |
|---|---|---|
| F1 | `Fetch(1)` 硬編碼於 pull 路徑;`ack_wait`/`max_ack_pending` 在 pull(bind) 模式由 server 端 consumer 設定決定,input 欄位無效 | connect v4.92.0 `internal/impl/nats/input_jetstream.go` L422 |
| F2 | bind 模式讀 consumer info 時,若 consumer 設了複數 `FilterSubjects`,只取 `[0]` 當訂閱 subject → **多 filter durable 不可用** | 同檔 L294–297 + legacy `PullSubscribe`(~L351) |
| F3 | `broker` input 為 fan-in:每個 child 一條 goroutine 寫入共享無緩衝 channel;**per-child FIFO 保留**、ack 沿 transaction 路由回原 child;單 child 斷線不影響其他 child;全部 child 關閉 broker 才關閉 | benthos v4.73.0 `internal/impl/pure/input_broker_fan_in.go` |
| F4 | `broker` 的 `copies > 1` 會對同一 durable 產生多個 pull subscriber,訊息任意分配 → 破壞 per-shard 單消費者順序 | 同上 + F1 語意 |
| F5 | `redis_script` processor 自 **Connect v4.11.0** 引入;執行後訊息 content 被替換為 Lua 回傳值;EVALSHA + EVAL fallback | connect v4.92.0 `internal/impl/redis/script_processor.go` L31 |
| F6 | JetStream discard policy 無法做 LWW;正確 LWW 執行點為 sink 端原子 Lua CAS | 專案設計文件 `LWW_CDC_設計總整理.md` |
| F7 | `metric type: timing` 需整數奈秒字串;負值必須 clamp 並另計 counter;`use_histogram_timing: true` 時 `*_ns` 系列以**秒**輸出 | 專案既有結論 |
| F8 | Redis Cluster 多 key Lua 需 hash tag 同 slot;key 內既有 `{employee:NNNNNN}` hash tag | Redis Cluster spec |
| F9 | streams-mode REST API 不展開環境變數;`__POD__` token 由 elector 取代後 POST | repo `cdc-forward.yaml` 檔頭註解 |
| F10 | NATS server ≥ 2.10.0 為部署底線(`ConsumerAction` create-only 語意) | 專案既有結論 |

---

## 2. 決策記錄(Decision Table)

| ID | 決策 | 選項與理由 | 狀態 |
|---|---|---|---|
| D-1 | Shard 函數 = employee 數字後綴 `mod N` | vs. NATS server 端 `partition()`(hash-based,人不可預測、改分區要動 server config)。mod 可手算、config-only 演進 | ✅ 定案 |
| D-2 | Shard key 排除 `active`/`standby` 段,只取 `{employee:(?P<id>[0-9]+)}` 的 id | 同 employee 全 variant 同 shard 的硬需求;與 Redis Cluster hash tag colocalization 同一不變量 | ✅ 定案 |
| D-3 | Shard token 摺進 `kv_prefix`(subject = `<prefix>.lp.m2g.s<K>.<op>`) | 重用既有 publishSubject helper,stream 定義零改動(綁 `kv.cdc.>`) | ✅ 定案 |
| D-4 | 1 durable = 1 FilterSubject | F2 強制 | ✅ 定案 |
| D-5 | Sink 用 `broker` input,一 pod 綁多個 shard durable | 降低 Deployment 數;K× fetch 平行;F3 保證 ack 隔離 | ✅ 定案(HP 核准) |
| D-6 | `copies: 1` | F4 | ✅ 定案(HP 核准) |
| D-7 | `pipeline.threads: 1` | 嚴格 per-shard apply 順序;apply 為本地 Redis(sub-ms),序列化不是瓶頸 | ✅ 定案(HP 核准) |
| D-8 | 保留 LWW CAS fence(`redis_script`) | 吸收 publish retry / redelivery 殘餘重排;cutover 雙消費期的正確性基礎(見 §10) | ✅ 定案 |
| D-9 | 版本以側掛 key `_v:<kv_key>` 存放 | string/hash 型別統一;`_v:` 前綴不破壞 hash tag → 同 slot | ✅ 定案 |
| D-10 | Tombstone = 帶 `PX` TTL 的版本 key;TTL = GC horizon | TTL ≥ 最大 reorder/redelivery 延遲;預設 30m,values 可調 | ✅ 定案 |
| D-11 | 無法解析 shard 的 key → 隔離 shard `sx` | 毒訊息隔離道,恆為 0 才正常,配 alert | ✅ 定案 |
| D-12 | Virtual shard over-provision:N 一次定大(建議 32),shard→group 分配可調 | 改 N 需 remap + cutover;改分配只是滾動 | ✅ 定案 |
| D-13 | `version` 由 producer 以 `HINCRBY` 對 source Redis 鑄造、隨 XADD 進 envelope | F6;processing-time 注入永遠不成立 | ✅ 定案(writer 端為前置任務,見 §12) |

---

## 3. 術語

- **family**:key 的 first-two-segment 前綴,如 `lp:m2g`(routeMap 既有概念)。
- **shard**:family 內依 employee id `mod N` 切出的分區,token 形如 `s0`…`s31`;`sx` 為解析失敗隔離 shard。
- **shard durable**:一個 shard 專屬的 JetStream durable pull consumer,命名 `cdc_sink_<family_token>_s<K>`(family_token = family 的 `:`→`_`,如 `m2g` 取末段;完整規則見 §5.3)。
- **sink group**:一個 Deployment + Lease + streams-mode pipeline,經 `broker` 綁一組 shard durable。

---

## 4. 需求(RFC 2119 語彙)

### 4.1 Forward leg(`chart/files/connect/cdc-forward.yaml`)

- **MUST** 在既有 prefix-routing mapping 之後新增 sharding mapping,僅對 `connect.sharding.families` 內的 family 生效;未配置 sharding 時 render 結果 **MUST 與現狀 byte-identical**(沿用 repo 的 INV 慣例)。
- **MUST** 以 `meta("kv_key").or(meta("new_key")).or("")` 為 raw key 來源(rename/delete 可能缺 `kv_key`)。
- **MUST** 以 values 可配置的 regex(預設 `\{employee:(?P<id>[0-9]+)\}`)抽出 id;`re_find_object(...).catch({}).get("id").or("")` 防 throw。
- **MUST** `shard = "s" + (id.number().int64() % N).string()`;id 為空 → `"sx"` 並打 counter `cdc_forward_unrouted{reason="unparseable_shard"}`。
- **MUST** 對 `op == "rename"` 斷言 old/new 兩 key 解析出的 shard 相同;不同 → 路由至 `sx` 並打 counter `cdc_forward_cross_shard_rename`(invariant 指標,任何非零即 bug)。
- **MUST** envelope 新增 `"version": meta("version").or("")` 欄位(D-13)。
- **MUST NOT** 把 shard 計算的中間 meta(如 `kv_shard_reason`)外洩到 NATS headers(NATS output 僅送顯式 headers,維持現狀)。

### 4.2 NATS consumers(`nats-init-job.yaml` / `scripts/create-consumer.sh`)

- **MUST** 為每個 family 建立 N+1 個 durable:`s0..s{N-1}` + `sx`,FilterSubject `kv.cdc.<family_token_dotted>.s<K>.>`,pull、`--ack explicit`、`--deliver all`、`--max-deliver -1`,`ack_wait`/`max_ack_pending` 承襲 group→sinkDefaults→legacy 的繼承鏈。
- **MUST** 沿用 create-only `ConsumerAction` 語意(NATS ≥ 2.10.0,F10);既存 durable 不得被重建(delivery state 不可重置)。
- **MUST** 擴充 prune 邏輯:被移出配置的 shard durable 在 cutover 完成前 **MUST NOT** 自動刪除(見 §10 手動 gate)。

### 4.3 Sink leg(新模板:broker 變體)

- **MUST** 當 sinkGroup 帶 `shardsOf` + `shards` 時 render broker 變體;否則 render 既有單 input 模板,**byte-identical**。
- **MUST** `broker.copies: 1`(D-6)、`pipeline.threads: 1`(D-7)——寫死於模板,**MUST NOT** 開放 values 覆寫(防止誤設破壞順序;要改需改 spec)。
- **MUST** 每個 child:`label: <family_token>_s<K>`、`bind: true`、專屬 durable;child 層 processors 蓋 `meta shard = "s<K>"`。
- **MUST** stash mapping 解出 `op/type/kv_key/old_key/new_key/version/src_ts`,body 依 `enc` op-gated 解碼(沿用既有 `.catch(null)` + `decode_failed` 模式,並將 rename 納入帶 body 的 op)。
- **MUST** `version` 缺失或非整數字串 → `cdc_unprocessable{reason="missing_version"}` + throw(nack)。
- **MUST** create/update/delete 走同一支 LWW CAS Lua(§7.1),rename 走 LWW rename Lua(§7.2),均以 `redis_script` 執行(Connect ≥ 4.11.0,F5),`keys_mapping` 提供 `[data_key, "_v:"+data_key]`(rename 為 4 keys)。
- **MUST** 依 Lua 回傳計量:`0` → `cdc_lww_stale_rejected{shard,op}`;`1` → `cdc_apply{shard,op,type}`。
- **MUST** e2e 延遲:`src_ts > 0` 時以 `timestamp_unix_nano()` 差值餵 `metric type: timing`,負值 clamp 為 0 並打 `cdc_e2e_negative_delay{shard}`(F7)。
- **MUST** output 維持 `reject_errored: { drop: {} }`(成功 ack、throw nack)。
- **MUST NOT** 使用 `kv_key` 作為任何 Prometheus label。
- **SHOULD** 頂層 `input.label` 用語意名(group 名),pod 級區分交給 scrape-time labels;child label 已含 shard。

### 4.4 Helm values 與驗證(`values.yaml` / `_helpers.tpl`)

- **MUST** 新增 schema(§5),所有驗證 **fail-loud at render**(repo 慣例)。
- 驗證規則:
  1. `sharding.families` 的每個 family:`shards` 為 ≥2 的整數;family 字串符合既有 prefix 文法;**MUST NOT** 同時出現在任何 group 的 `prefixes`。
  2. 所有 enabled、`shardsOf: <family>` 的 group,其 `shards` 聯集 **MUST 恰好等於** `{0..N-1} ∪ {"x"}`,無重複、無遺漏。
  3. `shardsOf` 指向的 family **MUST** 存在於 `sharding.families`。
  4. group 名與 durable 名 **MUST** 通過既有 57-char 名稱預算與 DNS-1123/NATS token 檢查。
  5. sharded family 存在時 forward 的 routeMap **MUST** 自動納入該 family(prefix → token),不需重複宣告。

---

## 5. 配置規格(values schema)

```yaml
connect:
  sharding:
    # employee id 抽取規則(named capture group 必須叫 id)
    keyPattern: '\{employee:(?P<id>[0-9]+)\}'
    families:
      "lp:m2g":
        shards: 32            # N;virtual shard 數,一次定大(D-12)
        tombstoneTtlMs: 1800000   # GC horizon,MUST ≥ 最大 reorder/redelivery 延遲

  sinkGroups:
    # ── broker 變體:一 group 吃多個 shard ──
    - name: m2g-a
      shardsOf: "lp:m2g"
      shards: [0,1,2,3,4,5,6,7]
    - name: m2g-b
      shardsOf: "lp:m2g"
      shards: [8,9,10,11,12,13,14,15]
    - name: m2g-c
      shardsOf: "lp:m2g"
      shards: [16,17,18,19,20,21,22,23]
    - name: m2g-d
      shardsOf: "lp:m2g"
      shards: [24,25,26,27,28,29,30,31, "x"]   # sx 隔離道必須被恰好一個 group 認領
    # ── 既有語法完全不變 ──
    - name: caveat
      prefixes: ["tg:caveat"]
    - name: others
      catchAll: true
```

命名派生(範例 family `lp:m2g` → family_token `lp_m2g`,subject token `lp.m2g`):

| 物件 | 命名 |
|---|---|
| Publish subject | `kv.cdc.lp.m2g.s<K>.<op>`(sx:`kv.cdc.lp.m2g.sx.<op>`) |
| Durable | `cdc_sink_lp_m2g_s<K>` / `cdc_sink_lp_m2g_sx` |
| FilterSubject | `kv.cdc.lp.m2g.s<K>.>` |
| Deployment / Lease / SA | `connect-sink-m2g-a`、`connect-sink-m2g-a-elector`(沿用既有 `<name>` 派生規則) |
| streams-mode id | `reverse_leg_m2g-a`(沿用既有規則) |

---

## 6. 參考實作 A — forward mapping patch

插入點:`cdc-forward.yaml` 既有 prefix-routing mapping 區塊(`meta kv_prefix` 賦值)之後、routing-miss `switch` 之前。Helm 渲染時僅在 `connect.sharding.families` 非空時輸出。

```coffee
{{- if .Values.connect.sharding }}{{- if .Values.connect.sharding.families }}
# ── D3.1 per-key sharding:family 命中 sharding 配置時,把 shard token 摺進 kv_prefix ──
# shard key = keyPattern 抽出的 employee id(刻意排除 active/standby 段,D-2),
# 同 employee 全 variant → 同 shard → 同 durable → 同 consumer。
let shard_map = {{ include "rrcs.connect.shardMap" . }}   # e.g. {"lp.m2g": 32}
let fam_n     = $shard_map.get(meta("kv_prefix"))
let sh_id     = if $fam_n != null {
    $raw_key.re_find_object({{ .Values.connect.sharding.keyPattern | quote }})
            .catch({}).get("id").or("")
  } else { "" }
let sh_tok    = if $fam_n == null { "" }
  else if $sh_id == "" { "sx" }
  else { "s" + ($sh_id.number().int64() % $fam_n.int64()).string() }
# rename 跨 shard 斷言(invariant):old/new 解析出不同 shard = bug,隔離至 sx
let old_id = meta("old_key").or("").re_find_object({{ .Values.connect.sharding.keyPattern | quote }}).catch({}).get("id").or("")
let new_id = meta("new_key").or("").re_find_object({{ .Values.connect.sharding.keyPattern | quote }}).catch({}).get("id").or("")
let x_shard = $fam_n != null && meta("op").or("") == "rename" &&
              $old_id != "" && $new_id != "" &&
              ($old_id.number().int64() % $fam_n.int64()) != ($new_id.number().int64() % $fam_n.int64())
meta kv_prefix = if $fam_n == null { meta("kv_prefix") }
  else if $x_shard { meta("kv_prefix") + ".sx" }
  else { meta("kv_prefix") + "." + $sh_tok }
meta kv_shard_reason = if $fam_n == null { "" }
  else if $x_shard { "cross_shard_rename" }
  else if $sh_id == "" { "unparseable" }
  else { "sharded" }
{{- end }}{{- end }}
```

隨後在既有 routing-miss `switch` 內追加兩個 check(僅 sharding 開啟時 render):

```yaml
- check: meta("kv_shard_reason") == "unparseable"
  processors:
    - metric: { type: counter, name: cdc_forward_unrouted, labels: { reason: unparseable_shard } }
- check: meta("kv_shard_reason") == "cross_shard_rename"
  processors:
    - metric: { type: counter, name: cdc_forward_cross_shard_rename, labels: { reason: invariant_violation } }
```

Envelope 追加(既有 root mapping 內):`"version": meta("version").or("")`。

> **Agent 注意**:`$raw_key` 已在既有 prefix-routing 區塊宣告;sharding 區塊必須 render 在其後,共用該變數。若 prefixRouting 為 false 而 sharding 非空 → `_helpers.tpl` fail-loud(sharding 依賴 prefix routing)。

---

## 7. 參考實作 B — Lua(新檔,置於 `chart/files/connect/`)

### 7.1 `cdc_lww.lua`(set / delete 共用 fence)

```lua
-- LWW CAS fence
-- KEYS[1]=data key  KEYS[2]=version key "_v:"..KEYS[1](同 hash tag → 同 slot,F8)
-- ARGV: 1=ver(整數字串) 2=op("set"|"del") 3=type("string"|"hash") 4=body 5=tombstone TTL ms
local cur = redis.call('GET', KEYS[2])
if cur and tonumber(ARGV[1]) <= tonumber(cur) then
  return 0                                   -- stale:較舊或等值(重送),丟棄
end
if ARGV[2] == 'del' then
  redis.call('DEL', KEYS[1])
  redis.call('SET', KEYS[2], ARGV[1], 'PX', ARGV[5])   -- tombstone = ver key + GC TTL(D-10)
else
  if ARGV[3] == 'hash' then
    local t = cjson.decode(ARGV[4])
    local args = {}
    for k, v in pairs(t) do
      if type(v) == 'table' then v = cjson.encode(v) end
      args[#args + 1] = k
      args[#args + 1] = tostring(v)
    end
    redis.call('DEL', KEYS[1])               -- snapshot 語意:整筆替換
    if #args > 0 then redis.call('HSET', KEYS[1], unpack(args)) end
  else
    redis.call('SET', KEYS[1], ARGV[4])
  end
  redis.call('SET', KEYS[2], ARGV[1])        -- 存活 key 版本不設 TTL(合法復活清 TTL)
end
return 1
```

### 7.2 `cdc_rename_lww.lua`(old→tombstone + new→CAS set,單支原子)

```lua
-- 前提:forward 已斷言 old/new 同 employee(同 hash tag → 同 slot),
--       envelope 攜帶 new key 完整 snapshot body。
-- KEYS: 1=old 2=old_ver 3=new 4=new_ver
-- ARGV: 1=ver 2=type 3=body 4=tombstone TTL ms
local applied = 0
local curN = redis.call('GET', KEYS[4])
if (not curN) or tonumber(ARGV[1]) > tonumber(curN) then
  if ARGV[2] == 'hash' then
    local t = cjson.decode(ARGV[3]); local a = {}
    for k, v in pairs(t) do
      if type(v) == 'table' then v = cjson.encode(v) end
      a[#a+1] = k; a[#a+1] = tostring(v)
    end
    redis.call('DEL', KEYS[3])
    if #a > 0 then redis.call('HSET', KEYS[3], unpack(a)) end
  else
    redis.call('SET', KEYS[3], ARGV[3])
  end
  redis.call('SET', KEYS[4], ARGV[1])
  applied = 1
end
local curO = redis.call('GET', KEYS[2])
if (not curO) or tonumber(ARGV[1]) > tonumber(curO) then
  redis.call('DEL', KEYS[1])
  redis.call('SET', KEYS[2], ARGV[1], 'PX', ARGV[4])
  applied = 1
end
return applied
```

---

## 8. 參考實作 C — sink pipeline 模板(broker 變體)

新檔 `chart/files/connect/cdc-reverse-sharded.yaml`(或以既有 `cdc-reverse.yaml` 加 Helm 條件分支,agent 二擇一,以「未配置 sharding 時 render byte-identical」為驗收準則)。以下為 group `m2g-a`(shards 0–3)渲染後的**目標形態**;模板須以 `range` 產出 children:

```yaml
input:
  label: sink_m2g_a                      # 語意 label;pod 區分交給 scrape labels(§4.3)
  broker:
    copies: 1                            # D-6:寫死,不開放覆寫
    inputs:
      {{- range $k := $g.shards }}
      - label: lp_m2g_s{{ $k }}
        nats_jetstream:
          urls: [ "{{ include "rrcs.nats.url" $ }}" ]
          auth: { user_credentials_file: {{ $.Values.nats.auth.creds.subscriber | quote }} }
          stream: {{ $.Values.nats.stream.name | quote }}
          durable: cdc_sink_lp_m2g_s{{ $k }}
          bind: true                     # F1/F2:server 端 consumer 設定為準
        processors:
          - mapping: 'meta shard = "s{{ $k }}"'
      {{- end }}

pipeline:
  threads: 1                             # D-7:寫死;per-shard FIFO apply 的必要條件
  processors:
    # (1) 拆信封 + op-gated 解碼 + version 存在性檢查(§4.3;沿用既有 .catch(null) 模式,
    #     rename 納入帶 body 的 op)
    - mapping: |
        meta op      = this.op
        meta type    = this.type.or("string")
        meta kv_key  = this.kv_key
        meta old_key = this.old_key.or("")
        meta new_key = this.new_key.or("")
        meta version = this.version.or("")
        meta src_ts  = this.ts.or("0")
        let carries_body = this.op == "create" || this.op == "update" || this.op == "rename"
        let is_encoded   = $carries_body && this.enc.or("") == "gzip:base64"
        let decoded = if $carries_body {
          if $is_encoded { this.body.decode("base64").decompress("gzip").catch(null) }
          else { this.body }
        } else { null }
        meta body = $decoded
        meta decode_failed = if $is_encoded && $decoded == null { "yes" } else { "no" }
        meta ver_missing   = if meta("version").or("") == "" { "yes" } else { "no" }
    # (2) e2e apply 延遲(F7:整數奈秒字串、clamp、負值 counter)
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
    # (3) op 分派
    - switch:
        - check: meta("decode_failed") == "yes" || meta("ver_missing") == "yes"
          processors:
            - metric:
                type: counter
                name: cdc_unprocessable
                labels:
                  shard:  '${! meta("shard") }'
                  reason: '${! if meta("ver_missing") == "yes" { "missing_version" } else { "decode_error" } }'
            - mapping: 'root = throw("unprocessable: kv_key=%s".format(meta("kv_key").or("?")))'
        - check: meta("op") == "create" || meta("op") == "update" || meta("op") == "delete"
          processors:
            - redis_script:                                   # Connect >= 4.11.0(F5)
                url: {{ include "rrcs.redis.region.url" $ }}
                kind: {{ include "rrcs.redis.region.connectKind" $ }}
                keys_mapping: 'root = [ meta("kv_key"), "_v:" + meta("kv_key") ]'
                args_mapping: |
                  root = [
                    meta("version"),
                    if meta("op") == "delete" { "del" } else { "set" },
                    meta("type"),
                    meta("body").or(""),
                    {{ $family.tombstoneTtlMs | quote }}
                  ]
                script: {{ $.Files.Get "files/connect/cdc_lww.lua" | toJson }}
                retries: 3
                retry_period: 500ms
        - check: meta("op") == "rename"
          processors:
            - redis_script:
                url: {{ include "rrcs.redis.region.url" $ }}
                kind: {{ include "rrcs.redis.region.connectKind" $ }}
                keys_mapping: |
                  root = [ meta("old_key"), "_v:" + meta("old_key"),
                           meta("new_key"), "_v:" + meta("new_key") ]
                args_mapping: 'root = [ meta("version"), meta("type"), meta("body").or(""), {{ $family.tombstoneTtlMs | quote }} ]'
                script: {{ $.Files.Get "files/connect/cdc_rename_lww.lua" | toJson }}
                retries: 3
                retry_period: 500ms
        - processors:
            - metric: { type: counter, name: cdc_unprocessable,
                        labels: { shard: '${! meta("shard") }', reason: unknown_op } }
            - mapping: 'root = throw("unknown op: %s".format(meta("op").or("missing")))'
    # (4) CAS 結果計量(F5:content 已被 Lua 回傳值替換;throw 過的訊息不會到這裡)
    - switch:
        - check: 'content().string() == "0"'
          processors:
            - metric: { type: counter, name: cdc_lww_stale_rejected,
                        labels: { shard: '${! meta("shard") }', op: '${! meta("op") }' } }
        - processors:
            - metric:
                type: counter
                name: cdc_apply
                labels:
                  shard: '${! meta("shard") }'
                  op:    '${! meta("op") }'
                  type:  '${! meta("type") }'

output:
  reject_errored:
    drop: {}
```

> `sx` durable 由認領它的 group 以同樣的 child 形式綁入(`label: lp_m2g_sx`、`meta shard = "sx"`);`sx` 的訊息幾乎必然缺可解析 shard,但 envelope 仍完整,走同樣的 op 分派——它的存在意義是**隔離與可觀測**,不是丟棄。

---

## 9. 不變量(INV;違反任一即實作錯誤)

| ID | 不變量 | 驗證方式 |
|---|---|---|
| INV-S1 | 未配置 `connect.sharding` 時,`helm template` 全輸出與 base branch **byte-identical** | CI diff(測試計畫 T-1) |
| INV-S2 | 同一 employee 的任意 key variant(active/standby/…)恆映射同一 shard token | Bloblang 單元測試(T-2) |
| INV-S3 | 每個 shard durable 恆最多一個 active puller(Lease per group + copies:1 + F4) | 部署驗證 + `nats consumer info` |
| INV-S4 | `{0..N-1, x}` 被 enabled groups 恰好覆蓋一次 | render fail-loud(T-3) |
| INV-S5 | `stored_ver` 對任一 key 單調不減;等值或較舊寫入回 0 | Lua 單元測試(T-4) |
| INV-S6 | tombstone 存活期間(TTL 內)任何 `ver ≤ tombstone_ver` 的 set 不得復活該 key | Lua 單元測試(T-4) |
| INV-S7 | `cdc_forward_cross_shard_rename` 恆為 0 | Prometheus alert(§11) |
| INV-S8 | Prometheus label 集合中不存在 `kv_key` | code review + T-5 |
| INV-S9 | shard 訊息的 ack 只影響其來源 durable(F3) | 整合測試(T-6) |

---

## 10. Cutover 程序(含關鍵陷阱)

> **陷阱(必讀)**:舊 m2g group 的 filter `kv.cdc.lp.m2g.>` 是新 shard subjects(`kv.cdc.lp.m2g.s<K>.<op>`)的**超集**。forward 切換後,舊 durable 會與新 shard durables **雙重消費**同一批訊息。這在 D-8(fence)前提下無正確性風險——第二個 applier 因 `ver <=` 被 CAS 拒絕(cutover 期間 `cdc_lww_stale_rejected` 出現尖峰屬**預期行為**)——但舊 group 未移除前是純浪費,且**若 fence 未部署則絕不可執行本程序**。

1. **前置**:writer 已帶 `version`(D-13);region Redis 已無舊制(無 `_v:` fence)寫入路徑並存的窗口 → 先上 fence 版 reverse(所有既有 group),跑穩。
2. 部署 shard durables(`s0..s31` + `sx`)與四個 shard sink groups——此時 shard subjects 無流量,groups idle。
3. 確認每個 shard durable `num_pending == 0`、elector 各 group 恰一 leader。
4. 滾動更新 forward(啟用 `connect.sharding.families`)→ 新訊息流向 shard subjects;舊 durable 同時雙重消費(見上)。
5. 觀測舊 durable:**任一時刻 `num_pending == 0` 即表示 flip 前積壓已全數套用**(JetStream FIFO:flip 前訊息的 stream seq 較小,pending 歸零 = 其前所有序號皆已 ack)。
6. 停用舊 m2g group(`enabled: false`)→ 刪除舊 durable(手動 gate,§4.2)。
7. 驗收:`cdc_apply{shard=~"s.*"}` 總速率 ≈ 切換前 family 速率;`cdc_lww_stale_rejected` 尖峰回落至背景值;`sx` 流量為 0。

**回滾**:任一步異常 → 還原 forward values(sharding 移除)→ 流量回 `kv.cdc.lp.m2g.<op>` → 舊 group 若已停用則重新 enable。shard durables 留存不影響正確性(無流量)。

**Resharding(未來改 N)**:遵循 D-12 優先「改 shard→group 分配」;真要改 N,在 fence 前提下滾動即可,舊 N 的 subjects 依步驟 5–6 的同一 drain 判準收尾。

---

## 11. 監控與告警(交付物之一:更新 `dashboard.yaml` + alert rules)

新增指標(cardinality 全部有界:shard ≤ N+1):

| 指標 | 型別 | Labels | 意義 |
|---|---|---|---|
| `cdc_apply` | counter | shard, op, type | 各 shard 套用速率與均衡 |
| `cdc_lww_stale_rejected` | counter | shard, op | fence 工作證據;恆 0 可疑(疑漏 version) |
| `cdc_unprocessable` | counter | shard, reason | 毒訊息;`missing_version` 應恆 0 |
| `cdc_e2e_apply_delay` | timing(histogram) | shard | e2e 新鮮度;**`use_histogram_timing: true` 下以秒輸出,PromQL 門檻用秒**(F7) |
| `cdc_e2e_negative_delay` | counter | shard | 跨區時鐘偏斜 |
| `cdc_forward_cross_shard_rename` | counter | reason | INV-S7 斷言 |
| `cdc_forward_unrouted{reason="unparseable_shard"}` | counter | reason | key 格式破約 |

Alert rules(NATS 指標一律加 `is_consumer_leader="true"`):

```promql
# A1 — shard 卡死:有積壓但無套用
max by (durable) (jetstream_consumer_num_pending{durable=~"cdc_sink_lp_m2g_s.*", is_consumer_leader="true"}) > 1000
  and on() rate(cdc_apply_total[5m]) == 0

# A2 — shard 傾斜(hot employee)
max(rate(cdc_apply_total{shard!~"sx"}[10m])) / avg(rate(cdc_apply_total{shard!~"sx"}[10m])) > 3

# A3 — 隔離道非空(INV):sx 有流量或跨 shard rename
rate(cdc_forward_cross_shard_rename_total[5m]) > 0
  or rate(cdc_unprocessable_total{reason="missing_version"}[5m]) > 0
  or rate(cdc_apply_total{shard="sx"}[5m]) > 0

# A4 — e2e p99 超標(秒;依 SLA 調整)
histogram_quantile(0.99, sum by (le) (rate(cdc_e2e_apply_delay_bucket[5m]))) > 5
```

---

## 12. 前置/邊界任務(本 spec 之外,但為硬相依)

| 任務 | 內容 | Gate |
|---|---|---|
| P-1 writer 帶 version | producer 於 XADD 前 `HINCRBY kv:ver <kv_key> 1`,結果寫入 XADD `version` 欄位 | §10 步驟 1 前完成;`cdc_unprocessable{reason="missing_version"}` 恆 0 為驗收 |
| P-2 fence 版 reverse 全面上線 | 既有各 group 先換用 §7.1/§7.2 Lua(單 input 形態) | §10 步驟 1 |
| P-3 rename 事件帶 snapshot body | rename envelope MUST 含 new key 完整 body(§7.2 前提) | 與 P-1 同批 |

---

## 13. 測試計畫

| ID | 類型 | 內容 | 通過準則 |
|---|---|---|---|
| T-1 | render | `helm template`(sharding 未配置)vs base branch | byte-identical(INV-S1) |
| T-2 | Bloblang 單元(config `tests:` / `rpk connect test`) | shard 函數表格測試:`lp:m2g:active:{employee:000001}` 與 `lp:m2g:standby:{employee:000001}` 同 shard;`000008` 與 `000001` 在 N=32 分屬 s8/s1;無 tag → sx;rename old/new 不同 employee → `cross_shard_rename`;`.or(new_key)` fallback | 全綠(INV-S2) |
| T-3 | render fail-loud | shards 覆蓋缺漏/重複、`x` 未認領、family 同時出現在 prefixes、keyPattern 缺 `id` capture | 每案 render 失敗且錯誤訊息指名規則 |
| T-4 | Lua 單元(redis-cli EVAL,腳本化) | stale reject(`<`、`=`)、tombstone 阻擋舊 set、更新 ver 合法復活且清 TTL、hash 整筆替換不殘留舊欄位、空 hash body、rename:new-CAS 過/old-CAS 過的四象限、非 hash-tag 同 slot 時 CROSSSLOT 如期報錯 | 全綠(INV-S5/S6) |
| T-5 | 靜態 | `rpk connect lint` 全部渲染後 pipeline;grep 確認無 `kv_key` label | 全綠(INV-S8) |
| T-6 | 整合(kind/compose) | 對單一 employee 交錯發 active/standby 各 100 筆 update → region 最終值正確、`cdc_apply` 序 = 來源序(threads:1);nack 一筆(注入壞 body)→ 僅該 shard durable redeliver | 全綠(INV-S9) |
| T-7 | Cutover 演練 | 依 §10 全程走一遍(含雙消費期 stale 尖峰觀測與回滾) | 步驟 5 判準成立;回滾後流量完整 |
| T-8 | 吞吐驗證 | 注入 RTT(tc netem)量測:單 shard ≈ 1/RTT,K child ≈ K/RTT | 實測 ≥ 理論 80% |

---

## 14. 版本底線(隨附於 PR 描述)

| 元件/功能 | 底線 | 佐證 |
|---|---|---|
| `redis_script` processor | Redpanda Connect **v4.11.0** | 源碼 `script_processor.go` L31 `Version("4.11.0")` |
| `broker` input(fan-in/ack 路由/child processors) | benthos core,Stable(4.x 全系列;現用 v4.73.0) | 源碼 `input_broker*.go` |
| `nats_jetstream` bind pull(`Fetch(1)`、`FilterSubjects[0]`) | Connect v4.92.0 現狀 | 源碼 `input_jetstream.go` L294–297、L422 |
| Durable + FilterSubject、create-only `ConsumerAction` | nats-server **2.10.0** | 專案既有結論(F10) |
| Lua `cjson`/`unpack`、`SET … PX` | Redis 內建(≪ 7.2 生產基線) | Redis docs |
| `use_histogram_timing` 秒輸出語意 | 專案既有結論(F7) | — |

---

## 15. PR Checklist(agent 完成後逐項自查)

- [ ] `helm template`(sharding off)與 base byte-identical(T-1 綠)
- [ ] `copies: 1`、`threads: 1` 寫死於模板,無 values 覆寫路徑
- [ ] 每個 shard durable 恰一 FilterSubject;無任何多 filter consumer
- [ ] `sx` 被恰好一個 enabled group 認領;fail-loud 驗證齊備(T-3 綠)
- [ ] 兩支 Lua 以 `.Files.Get | toJson` 注入;`_v:` 前綴、hash tag 同 slot 逻辑無改動
- [ ] envelope 含 `version`;`missing_version` 走 unprocessable + nack
- [ ] 指標齊備且無 `kv_key` label;dashboard 與 4 條 alert 更新
- [ ] §10 cutover 與回滾程序寫入 repo docs(含雙消費陷阱說明)
- [ ] T-2/T-4/T-5/T-6 測試進 CI;T-7/T-8 提供可執行腳本
- [ ] PR 描述附 §14 版本底線表與本 spec 連結

---

## 16. Out of Scope

- 改 `Fetch(1)` 的 upstream patch 或 `jetstream.Consumer.Messages()` 遷移(Strategy B,另案追蹤)。
- `shared` mode(同 durable 多 puller)。
- 非數字 shard key(需 server 端 `partition()`,nats-server ≥ 2.8,另案)。
- Redis 7.4+/8.0+ field-level TTL 之 tombstone GC 替代(另案)。
