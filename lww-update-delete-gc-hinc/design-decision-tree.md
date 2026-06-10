# Redis Streams → NATS JetStream → Redis KV:per-key LWW CDC 設計總整理

> 目標:每個 key 只要「最新一次 change」最終生效即可;**較舊的 change 永不在較新的 change 之後被套用**(last-write-wins,snapshot 語意)。

---

## 1. 架構與核心機制

資料流:`Redis Streams → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis KV`

**核心機制 = sink 端的原子 LWW CAS fence**:在最後寫入 Redis KV 時,用一支 Lua 比較「進來的 version」與「已存的 version」,只有 `incoming_ver > stored_ver` 才套用(set 或 delete 一視同仁)。

這個 fence 的性質:
- **順序無關**:訊息可任意亂序、跨實例、重送;`stored_ver` 只會單調前進。
- **重送安全、冪等**:重複的 version 因為不 `>` 而被拒。
- **天生原子**:Redis 對同一 key(Cluster 下同一 slot)單執行緒序列化執行。
- **可拆掉昂貴的嚴格排序**:`threads:1`、`max_in_flight:1`、`MaxAckPending:1`、per-partition durable consumer、partition-by-key 路由全部可以拿掉,改走高並行。fence 是唯一同步點。

---

## 2. 設計思路(為什麼是這個方案)

- **NATS 不能做「比時間戳丟舊訊息」**:JetStream 是 append-only log,discard policy 只在 `max_msgs/bytes/age` 觸發;`DiscardNewPerSubject + MaxMsgsPerSubject=1` 是「保留最舊、拒絕新的」,方向相反;`Nats-Rollup` 是按到達順序覆蓋,不看事件時間。沒有任何「比較後條件丟棄」的伺服器端機制。
- **不能在 source 端的 Redpanda Connect 注入時間戳**:那是 processing-time;crash 後 PEL 重送會讓「較舊的事件」拿到「較新的時間戳」→ 舊蓋新。version 必須來自 source of truth(producer)。
- **Redis stream entry id(`ms-seq`)本來最理想**(Redis 單一單調來源),但 Redpanda Connect 的 `redis_streams` input 不暴露 entry id 為 metadata,當前架構取不到。
- 結論:**fence 放 sink,version 由 producer 鑄造並沿管線帶到 sink。**

---

## 3. 考量點清單

| 面向 | 考量 |
|---|---|
| **總閘門** | change 是 snapshot 還是 delta?delta(增量)用 LWW 會遺失舊增量 → 必須嚴格排序或 field-merge/CRDT。本設計成立的前提是 **snapshot(整筆新值)**。 |
| **操作類型** | set / delete / rename 三類,delete 與 rename 有額外要求(見 §6、§7)。 |
| **writer 拓樸** | 單一 writer / 多 writer 但每 key 單 owner / 多 writer 共寫同 key —— 決定哪些 version 來源可用。 |
| **version 性質** | 必須:來自 source of truth、per-key 單調、無碰撞(或有 tiebreaker)、反映真實新舊。 |
| **tiebreaker** | version 可能相等時(wall-clock)需 `(version, writer_id)` 形成全序,確保確定性收斂。真正的計數器不撞號,免。 |
| **connect source 複數** | 對正確性**無影響**(只會 reorder,被 CAS 吸收)。 |
| **sink connect 複數** | **永遠安全**(Redis per-key 序列化 CAS)。 |
| **delete** | 寫 tombstone(保留 ver),勿用實體 DEL;tombstone 要 GC;delete 由他人發出可能把 B 變 C。 |
| **rename** | KV key 用不變 ID → 退化成 set;KV key 就是 name → 跳出 per-key 模型,需原子雙 key + 全域 version + tombstone。 |
| **去重(Nats-Msg-Id)** | CAS 已冪等,dedup 變成「省一次 sink 寫入」的優化,非正確性必需。 |
| **Cluster** | version 計數器:單一 hash(簡單但單 slot 熱點)vs per-key `INCR`(分散 slot)。rename 雙 key 原子需 hash tag 同 slot。 |

---

## 4. writer 拓樸 × version 來源 對照表

| version 來源 | A 單一 writer | B 多 writer·分 key | C 多 writer·共 key | 說明 |
|---|---|---|---|---|
| 本地單調計數器 | ✅ | ✅ | ❌ | C 下跨 writer 的計數器不可比 |
| 共享原子計數器(`HINCRBY`) | ✅ | ✅ | ✅ | 跨 writer 單調、不撞號、不依賴時鐘;每寫多一趟 round-trip |
| wall-clock 時間戳 | ✅⚠️ | ✅⚠️ | ❌ | 僅單一時鐘來源安全;須跨重啟/NTP 單調 + tiebreaker;C 下 skew 倒序 |
| HLC | ✅ | ✅ | ✅ | C 下免共享計數器 round-trip,但較複雜 |
| Connect 注入 processing-time | ❌ | ❌ | ❌ | 重送倒序,永遠不成立 |
| Redis stream entry id | ⚠️ N/A | ⚠️ N/A | ⚠️ N/A | Connect 不暴露 |

**無腦安全跨所有情境的選擇:共享原子計數器(`HINCRBY`)。**

---

## 5. 各方案的 XADD key/value 設計

所有方案共用的 XADD 信封(`body_key: body`,其餘欄位進 metadata):

```
XADD <stream> *
  event_id  <uuid>            # 去重用(可選,CAS 已冪等)
  kv_key    <不可變 ID>        # sink KV 的 key(建議用 ID,非顯示名稱)
  op        set|delete|rename
  version   <單調值>           # ★ LWW fence 核心
  body      <json snapshot>    # body_key 指向此欄位
  # rename 額外:old_key、new_key
```

### 方案 1 — 共享原子計數器(推薦;A/B/C 全適用)
```bash
# producer 端,XADD 之前,對 source Redis 鑄造該 key 的下一個版本
v=$(redis-cli HINCRBY kv:ver "<kv_key>" 1)
redis-cli XADD app.events '*' \
  event_id "$(uuidgen)" kv_key "ORD-42" op set version "$v" \
  body '{"id":"ORD-42","name":"foo","amount":99.9}'
```

### 方案 2 — 本地 per-key 計數器(僅 A / B,每 key 單 owner)
owner 自己維護該 key 的單調序;若要跨重啟存活,實務上仍落到 source Redis 的 `HINCRBY`(等同方案 1)。process 內計數器重啟會歸零,風險自負。

### 方案 3 — wall-clock + tiebreaker(僅單 owner,不建議)
```bash
redis-cli XADD app.events '*' \
  kv_key "ORD-42" op set version "$(date +%s%N)" writer_id "host-3" \
  body '{...}'
# sink 比較 (version, writer_id);須保證時鐘跨重啟/NTP 單調
```

### 方案 4 — HLC(C 且想免 round-trip)
```bash
# version 為可比較字串 "<physical>:<logical>:<node>"
redis-cli XADD app.events '*' kv_key "ORD-42" op set version "1717830000123:7:n3" body '{...}'
```

### delete
```bash
v=$(redis-cli HINCRBY kv:ver "ORD-42" 1)
redis-cli XADD app.events '*' event_id "$(uuidgen)" kv_key "ORD-42" op delete version "$v" body ''
```

### rename — KV key 用 ID(推薦):就是普通 set
```bash
v=$(redis-cli HINCRBY kv:ver "ORD-42" 1)
redis-cli XADD app.events '*' kv_key "ORD-42" op set version "$v" \
  body '{"id":"ORD-42","name":"新名字"}'   # name 是欄位,key 不變
```

### rename — KV key 就是 name(升級方案)
```bash
# version 須能同時壓過 old/new 兩 key 的序列 → 全域 sequencer
v=$(redis-cli HINCRBY kv:gver global 1)
redis-cli XADD app.events '*' op rename old_key "舊名" new_key "新名" version "$v" body '{...新值...}'
# sink 用一支 Lua 原子處理:舊 key 寫 tombstone、新 key 做 CAS set
# Cluster 下 old/new 須同 slot(hash tag);否則無法原子
```

---

## 6. HINCRBY 用在哪裡

- **位置:producer 端、XADD 之前**,對 **source Redis** 的一個 versions hash 執行:`v = HINCRBY kv:ver <kv_key> 1`。
- **用途:鑄造該 `kv_key` 的單調 version**。因為 Redis 對該 hash 序列化執行,所有 writer(含多 writer 共寫同一 key 的情境 C)都拿到嚴格遞增、不撞號、不依賴時鐘的版本號 —— 這正是讓 LWW 在多 writer 下成立的關鍵。
- **它不在 sink**:sink 端用的是 Lua 裡的 `HSET`(CAS 套用),不是 `HINCRBY`。請務必分清:
  - `HINCRBY`(source)= **鑄造** version
  - Lua `HSET`(sink)= **帶 fence 套用**
- Cluster 取捨:單一 `kv:ver` hash 簡單但整個 hash 落單一 slot(熱點);替代是 per-key `INCR ver:<kv_key>` 分散到不同 slot。

---

## 7. 真正使用的 KV record 欄位(sink,Redis Hash per key)

| 欄位 | 必要性 | 說明 |
|---|---|---|
| `val` | 必備 | snapshot JSON;tombstone 時可清空或保留舊值 |
| `ver` | **必備** | 已套用的最大 version —— LWW fence |
| `deleted` | delete 時必備 | `0/1` tombstone 旗標,讓 delete 保留 `ver`,防復活 |
| `deleted_at` | delete 時必備 | tombstone 建立時間,供 GC |
| `updated_at` | 建議 | 最後套用時間,觀測用 |
| `src_event_id` | 建議 | 最後套用的 event_id,稽核/追蹤 |
| `nats_seq` | 選用 | JetStream 序號交叉防線;與 `ver` CAS 冗餘,可省 |

### Sink Lua(set/delete tombstone CAS,概念)
```lua
-- KEYS[1]=kv_key  ARGV: 1=val 2=ver 3=op 4=now
local cur = redis.call('HGET', KEYS[1], 'ver')
if cur == false or tonumber(ARGV[2]) > tonumber(cur) then
  if ARGV[3] == 'delete' then
    redis.call('HSET', KEYS[1], 'ver', ARGV[2], 'deleted', '1',
               'deleted_at', ARGV[4], 'val', '')
  else
    redis.call('HSET', KEYS[1], 'ver', ARGV[2], 'deleted', '0',
               'updated_at', ARGV[4], 'val', ARGV[1])
  end
  return 1   -- applied
end
return 0     -- stale,丟棄
```

### Tombstone GC
週期掃 `deleted=1 且 deleted_at < now - GC_horizon` 的 key 做實體刪除。
`GC_horizon ≥ 最大可能 reorder/redelivery 延遲`(等同 `duplicate_window` / Cassandra `gc_grace_seconds` 的思路)。過早 GC + 延遲很久的 stale 寫入 = 復活。

---

## 8. 監控(production readiness)

| 訊號 | 來源 | 意義 / 門檻 |
|---|---|---|
| stale-reject 率(Lua 回 0) | Redpanda Connect 指標(取 Lua 回傳) | 亂序下非零屬正常;突增或恆為零(可能漏帶 version)要查 |
| tombstone 數 / 最舊年齡 vs GC | redis_exporter | 落後 → 記憶體壓力 / 復活風險 |
| 復活斷言 | sink Lua / 旁路檢查 | set 套到「tombstone 有更高 ver」的 key 理論不可能,任何命中即 bug |
| rename 配對完整(升級方案) | 旁路檢查 | old_key 已 tombstone 但 new_key 未建立(或反之)= 非原子裂縫 |
| 端到端延遲 | payload 事件時間 vs sink 套用時間 | KV 新鮮度 SLA |
| Redis PEL / JetStream pending | redis_exporter / nats exporter | 管線 lag |
| output_error / latency / connection | Redpanda Connect Prometheus | sink/transport 健康 |

---

## 9. 一句話結論

snapshot + delete → 用這套 fence(delete 改 tombstone + GC,小心 delete 路徑把 B 變 C);rename 先問 key 是 ID 還是 name(ID 就退化成 set,name 才要升級到原子雙 key + 全域 version)。**把 KV 主鍵設成不可變 ID、version 用 `HINCRBY` 鑄造,是最穩、跨所有情境都成立的組合。**
