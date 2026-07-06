# Lab 設計文件 — Approach A 順序損壞情境重現(order-corruption repro)

日期:2026-07-06
狀態:設計完成,待另一個 session 實作
產出目錄(實作時建立):`labs/order-corruption-repro/`
上游討論:Approach A(election gate:新 leader 等待 > ackWait 才開始 pull)是否足以在
pull(10) + `set string` / `hset` / `rename` 工作負載下維持資料正確。
相關圖:`docs/superpowers/specs/2026-07-06-ordering-approaches-AB.drawio`(Approach A/B 兩頁)。

## 1. 目的

以可重複執行的 lab 實際重現六個「Approach A 防不住(或根本與 failover 無關)」的資料損壞
情境,把推理變成證據。每個情境有明確的注入序列、觸發方法、與損壞判定 oracle。
重現成功 = 該情境的 corruption oracle 命中;重現失敗(多次重試後)= 反證分析,同樣是
有價值的結果,必須如實記錄。

## 2. 被測系統事實(實作前先驗證,全部有 file:line)

| 事實 | 出處 |
|---|---|
| sink pipeline `threads: 4`,同一批訊息**並行** apply;檔內自註「same-key ops within one batch may apply out of order」「Set threads: 1 for strict per-key ordering」 | `chart/files/connect/cdc-reverse.yaml:21-24,43` |
| `ackWait: "30s"`、`maxAckPending: 1024`、`maxDeliver: -1`(server-side,由 nats-init Job 的 `nats consumer add` 套用;Connect 在 pull(bind) 模式忽略 input YAML 的同名欄位) | `chart/values.yaml:79-91` |
| dedup window 5m(`Nats-Msg-Id = event_id`)— 只擋 publish 重複,**不擋 consumer redelivery** | `chart/values.yaml:95` |
| rename = guarded Lua:`if EXISTS(old) then RENAME old new` — 單獨重放冪等,但 guard 是 state-dependent | `chart/files/connect/cdc_rename.lua`、`docs/nats-jetstream-and-redis-kv-message-flow.md:375-387` |
| hash 型 create/update → `HSET kv_key <flatten(body JSON)>`(部分欄位寫入,非全量) | `chart/files/connect/cdc-reverse.yaml:161-173` |
| 失敗 → `reject_errored` → nack → ackWait 後 redeliver | `chart/files/connect/cdc-reverse.yaml:220-222` |
| 現行設計明文為 no-LWW / no version fence:「reordered/late same-key arrivals overwrite」 | `docs/nats-jetstream-and-redis-kv-message-flow.md:414-416,505-506` |
| pull batch = 10(pull(10)):**此為使用者對本版 image 的描述,Phase 0 必須實測確認**(觀察 Connect 行為或 `nats consumer info` 的 delivered 節奏),並把實測值記入報告 | 待驗證 |

被測 image:`CONNECT_IMAGE`(預設 `hpdevelop/connect:v4.92.0-batch-nats`,與
`labs/robustness-test` 同一顆)。

## 3. 六情境完整定義(原文保留)

> 以下情境描述與總結表格為上游分析原文,實作時不得改寫語義;
> 每個情境對應 §5 的一個重現腳本。

### 先回答的例子(gate 擋得住的那一種)

「hset 後 rename,pull 了但還沒寫入 Redis 時 pod 被殺」— 這個**特定**情境 Approach A 的
gate 擋得住:兩筆都未 ack,新 leader 等 35s 後兩筆的 ackWait 都已到期,server 會把它們放進
redelivery 佇列、**依 stream sequence 順序**先於新訊息投遞,所以 hset 仍在 rename 之前。
但這有三個前提:gate 確實等超過 ackWait、sink 是 threads:1 串行、且「redelivery 先於
新訊息」這個 NATS server 行為成立(這點進 lab 實測驗證,不能只靠文件)。

真正的問題是:**gate 只保護「未 apply 且未 ack」的乾淨中斷**。下面這些情境它全都不保護,
而且大多會實際損壞資料。

### S1 — 已 apply、未 ack,整段重放(gate 完美也會發生):`HSET k` → `RENAME k→k'`

舊 leader 兩筆都寫進 Redis 了,但被 SIGKILL 在 ack 送出之前(pull(10) 批次下這是常態,
不是邊角)。新 leader 重放這段 suffix,**順序完全正確**仍然損壞:重放的 HSET 把 `k` 復活成
「只有這一筆訊息的欄位」的殘缺 hash(k 原本累積的其他欄位早已被第一次 rename 搬走);
接著重放 rename,EXISTS guard 看到復活的 `k` → 被**重新武裝** → 把殘缺 hash 蓋到 `k'` 上。
結果:`k'` 丟失其他欄位。**根因:rename 的 EXISTS guard 只保證「單獨重放」冪等;批次
suffix 重放時,前面重放的寫入會重新 arm 它。**

### S2 — 同樣是順序正確的重放:`RENAME k→k'` → `SET k=w`(key 重用/新世代)

連純 string 都中招。原始 apply 後:`k'`=舊值、`k`=w。重放 rename 時 guard 看到的是
**新世代的 k(=w)** → 把 w 搬到 `k'` → 舊值遺失;再重放 SET 把 k 建回來。最終 `k'`
錯誤地等於 w。

### S3 — pod 沒死也會發生:batch 處理時間 > ackWait

pull(10) 的尾端訊息在本地排隊等前面的訊息 apply;只要整批耗時超過 30s(Redis 慢、網路
抖動),server 就判定尾端訊息未 ack → **重投給同一個活著的 leader 的下一次 pull**。結果是
「複本插隊到後續訊息之後」:HSET 的複本排在 rename 之後 apply → 和 S1 相同的損壞。沒有
kill、沒有選舉,gate 永遠不觸發。而且 Approach A 要求 threads:1,串行會**拉長**批次耗時,
讓這個情境**更容易**發生 — gate 方案和 pull(10)+ackWait=30s 有內在張力。

### S4 — 穩態 nack 重排:`HSET k` 暫時失敗 → `RENAME k→k'` 成功

HSET 被 nack,30s 後重投;此時 rename 早已執行。重投的 HSET 在舊位置復活 ghost hash,
`k'` 永遠缺那筆欄位。同型:`DEL k` 暫時失敗、之後同 key 的 create 成功 → DEL 重投把
**新資料刪掉**。

### S5 — threads: 4(現行設定)讓同批直接亂序

同一 pull(10) 批裡 HSET 和 rename 落在不同 thread,rename 先跑 → 與 S4 同果。這是現在
就存在的行為,連故障都不需要;Approach A 必須改 threads:1 才有意義,而那又回頭放大 S3。

### S6 — gate 打開後,redelivery 排空不是原子的

重投佇列裡若某筆又失敗(nack),它再等 30s,佇列裡它**後面**的訊息照常先 apply —
S4 在 redelivery 佇列內部重演。gate 只保證「開始」有序,不保證「排空過程」有序。

### 總結表格(原文保留)

| 情境 | 觸發 | 需要 pod 死? | gate 防護? | 結果 |
|---|---|---|---|---|
| S1 hset→rename 重放 | kill 在 apply 後、ack 前 | 是 | **否** | k' 丟欄位 |
| S2 rename→set 重放 | 同上,key 重用 | 是 | **否** | k' 變成新值 |
| S3 批次耗時 > ackWait | 慢 apply | **否** | 否 | 同 S1/S2 |
| S4 nack 重排 | 單筆暫時錯誤 | **否** | 否 | ghost key / 誤刪 |
| S5 threads:4 同批並行 | 現行設定 | **否** | 否 | 同 S4 |
| S6 redelivery 中再失敗 | gate 後 nack | 是 | 部分 | 同 S4 |

核心結論(原文保留):**對 rename 這種 state-dependent 操作,「重複」本身就足以損壞資料,
不需要「重排」** — 而 at-least-once 天生保證會重複。Approach A 的 gate 只消滅六類情境中
的一類(乾淨的未-apply 中斷),付出每次選舉 35s 的代價。反過來看,這個分析意外強化了
Approach B:`maxAckPending=1` 把重放 suffix 的長度壓到 **1**,而單筆重放對這組 op 全部
安全(HSET 單獨重放冪等、rename 單獨重放被 guard 擋住、SET/DEL 冪等)。真正無法靠 A 或 B
解掉的只剩 S4 型的「rename/del 與前序失敗訊息的互動」— 在 B 下 S4 不會發生(HSET 失敗時
rename 根本還沒被投遞)。

## 4. Lab 總體設計

### 4.1 目錄結構(比照 `labs/robustness-test`)

```
labs/order-corruption-repro/
  README.md              # 執行方式、exit code 慣例、判讀指南
  DESIGN.md              # 指回本文件(或複製一份快照)
  scripts/
    lib.sh               # 共用 helper(見 4.3;可 source labs/robustness-test/scripts/lib.sh 再擴充)
    run-all-scenarios.sh # 單一進入點,S0→S6 逐一執行、寫 report
    s0-assumptions.sh    # 前提驗證(pull batch 大小、redelivery 順序)
    s1-replay-hset-rename.sh
    s2-replay-rename-set.sh
    s3-slow-batch-ackwait.sh
    s4-wrongtype-nack-reorder.sh
    s5-threads4-inbatch-race.sh
    s6-redelivery-drain-nack.sh
  reports/<ts>/          # gitignored;report.json / report.md / 各情境 log + redis 證據 dump
```

### 4.2 Exit code 慣例(**注意:與 robustness-test 語義相反,務必寫進 README**)

- `0` = **REPRODUCED**:corruption oracle 命中(lab 的目標就是重現)
- `3` = **INCONCLUSIVE**:時序沒 arm 到(如 kill 前批次已全 ack)→ 由 runner 重試(上限見各情境)
- `1` = **NOT-REPRODUCED**(重試耗盡仍未命中,屬反證,報告須完整保留)或 harness 自身失敗(兩者在 log 中以明確前綴區分:`NOT-REPRODUCED:` vs `HARNESS-FAIL:`)

### 4.3 共用機制

**注入格式** — 走完整路徑(central stream 進入),沿用 `labs/robustness-test/scripts/lib.sh`
的 XADD 形式,擴充一個 `xadd_event <op> <type> <kv_key> [old_key new_key] [body]` helper:

```
# hash 部分欄位寫入(type=hash → sink 走 HSET flatten 分支)
XADD app.events * event_id <ks>-<runid>-<i> op create type hash \
     kv_key 'lb:ordlab:<sc>:{e:<runid>:<i>}' ts <ms> body '{"f1":"v1"}'

# rename(不帶 body;old/new 共用 {e:<runid>:<i>} hash tag → 同 slot,Lua 原子)
XADD app.events * event_id <ks>-<runid>-<i>-rn op rename \
     old_key 'lb:ordlab:<sc>:{e:<runid>:<i>}' \
     new_key 'lb:ordlab:<sc>:{e:<runid>:<i>}:r' ts <ms> body ''
```

Key 命名:`lb:ordlab:<scenario>:{e:<runid>:<i>}`(rename 目標加 `:r` 尾綴)。
`runid = date +%s%3N`,保證跨 run 不碰撞;oracle 用 `--scan --pattern` 掃描。

**Gate 模擬(不改任何程式碼)** — Approach A 的 gate 用部署操作等效模擬:

```
kubectl -n $NS delete pod <sink-leader> --grace-period=0 --force   # SIGKILL
kubectl -n $NS scale deploy/${PREFIX}connect-sink --replicas=0     # 阻止立即接手
kubectl -n $NS wait --for=delete pod/<sink-leader> --timeout=60s   # kill 證明(robustness-test 慣例)
sleep $(( ACKWAIT_S + 5 ))                                         # gate:所有 ack timer 必已到期
kubectl -n $NS scale deploy/${PREFIX}connect-sink --replicas=3     # 新 leader 的首次 pull 必在 gate 之後
```

「無 gate」對照組 = 只做第一、三行(維持 3 replicas,standby 立即接手)。

**縮短 ackWait 加速實驗** — 對 lab namespace 用 `--set` 覆寫(nats-init Job 會偵測 drift
並重建 consumer,`chart/templates/nats-init-job.yaml:97-166`),例如
`--set nats.stream.consumer.ackWait=5s`。**只准 `--set`,不准改 `chart/values.yaml` 預設值**
(consumer 參數是 `rules/05-invariants.md` 的敏感區;改預設會觸發 L4 failover 全套要求)。

**threads 開關** — `cdc-reverse.yaml:43` 寫死 `threads: 4`。lab 需要 threads:1(S1/S2/S6 要
排除同批並行的干擾、把損壞歸因到重放)。實作方式:新增 values knob
`connect.sink.pipelineThreads`(預設 4,行為不變),模板化該行。這是本 lab 唯一的 chart
變更;變更後須跑 `helm lint chart/ && helm template chart/ >/dev/null` + L0/L1,並在 lab
namespace 以 `--set connect.sink.pipelineThreads=1` 使用。

**arm 偵測 / 證據收集** — 比照 `poison-metrics.sh` 從 sink leader `:4195/metrics` 抓
`cdc_apply` 計數:
- `applies_total > injected_total` ⇒ 發生過 duplicate apply(S1/S2/S3 的 arm 證據)
- 每情境結束把下列證據存進 `reports/<ts>/`:相關 key 的 `HGETALL`/`GET`/`EXISTS` dump、
  `cdc_apply`/`cdc_unprocessable` 前後值、`nats consumer info cdc_sink` 輸出、sink pod logs。

**quiescence 判定** — oracle 只在系統靜止後執行:`nats consumer info` 的
num_pending==0 且 num_ack_pending==0,或 timeout(預設 120s;S4/S6 的 nack 迴圈屬例外,
其 oracle 在迴圈仍活著時就要驗,見各情境)。

## 5. 各情境重現設計

### S0 — 前提驗證(必跑,失敗則全 lab 中止)

1. **pull batch 大小**:注入 100 筆 string create(單一 entity 序列無關),從 Connect debug
   log(`connect.contentLog.enabled=true`)或 delivered 節奏推定實際 fetch 批量;記入報告。
   若 ≠10,後續情境的批次設計參數(每 entity 對數、注入節奏)按實測值調整。
2. **redelivery 先於新訊息、依 seq 排序**(Approach A 的立論前提):注入 5 筆 string
   create → SIGKILL leader(無 gate 對照組流程)→ 立刻再注入 5 筆新訊息 → 觀察 region
   寫入順序(用 `cdc:latency` sidecar stream 的 sink_ts 排序,或 contentLog)。預期:
   前 5 筆(redelivery)先完成。此項結果**無論真偽都寫進報告** — 若為偽,Approach A 連
   「乾淨中斷」都protect不了,結論升級。

### S1 — 已 apply、未 ack 的 suffix 重放(`HSET → RENAME`)

- 配置:threads=1(`--set connect.sink.pipelineThreads=1`)、gate 模擬 ON、ackWait=30s(預設)。
- 注入:N 個 entity(預設 N=200),每個 entity 依序三筆:
  `HSET k {"f1":"v1"}` → `HSET k {"f2":"v2"}` → `RENAME k→k:r`,連續灌入使 kill 時刻有
  大量 pair 處於 in-flight。
- 觸發:監看 `cdc_apply` 開始上升且 `region_count < 全量` 時 SIGKILL sink leader
  (arm 條件同 `kill-sink-leader.sh:20-29`:0 < applied < total,否則 exit 3);
  然後執行 gate 模擬(scale 0 → sleep 35 → scale 3)。
- Oracle(quiescence 後,逐 entity):
  - 損壞 = `EXISTS k == 1`(ghost)**或** `HGETALL k:r` 缺 `f1` 或 `f2`
  - arm 證據:`cdc_apply` 總數 > 3N(有 duplicate)。若無 duplicate 且無損壞 → exit 3 重試(上限 5)。
- 預期:部分 entity 的 `k:r` 只剩 f2(或 f1),且/或 ghost `k` 存在 → exit 0。

### S2 — `RENAME → SET`(key 重用)suffix 重放

- 配置同 S1。
- 注入:每 entity 三筆:`SET k v1` → `RENAME k→k:r` → `SET k w`(key 重用新世代)。
- 觸發:同 S1(mid-flight SIGKILL + gate 模擬)。
- Oracle:損壞 = `GET k:r != v1`(預期錯值為 `w`);正確終態應為 `k:r=v1`、`k=w`。
- arm/重試/上限同 S1。

### S3 — 批次處理時間 > ackWait(pod 全程存活)

- 配置:threads=1、**ackWait=5s**(`--set` 覆寫)、不 kill、不 gate。
- 注入:每 entity `HSET f1` → `HSET f2` → `RENAME`,一次灌 ≥ 3×(實測批量)筆。
- 觸發:注入後立刻對 region Redis 執行 `CLIENT PAUSE <8000> WRITE`(rr helper),使
  in-flight 批次的 apply 阻塞 8s > ackWait=5s → server 對未 ack 訊息重投給**同一個活著的
  leader** 的後續 pull。pause 結束後原始命令續行 + 複本亦 apply → duplicate 與後續訊息交錯。
- 注意:若 Connect redis processor 的 client timeout < 8s,阻塞會轉為錯誤(nack 路徑)—
  此時損壞仍會發生但屬 S4 機制;報告須依 log 區分實際走了哪條路(兩者都算 REPRODUCED,
  但要標注機制)。timing 敏感 → INCONCLUSIVE + 重試(上限 5),每次重試可增加 pause 時長。
- Oracle:同 S1(ghost `k` 或 `k:r` 缺欄位),外加 `cdc_apply > injected` 佐證 duplicate。

### S4 — WRONGTYPE 誘發的確定性 nack 重排(無 kill、無 timing)

本情境用 WRONGTYPE 當「暫時性失敗」,**完全確定性**,應優先實作:

1. 直接在 region 預埋 string:`rr SET k s0`(繞過 CDC,只為製造型別衝突)。
2. 注入 `HSET k {"f2":"v2"}`(type=hash)→ sink HSET 遇 string → WRONGTYPE → nack 迴圈。
3. 注入 `RENAME k→k:r` → guarded Lua 看到 k(string)存在 → RENAME 成功,`k:r`=s0,k 消失。
4. k 消失後,步驟 2 的 HSET 在下次重投時**成功** → 在原位置復活 ghost hash `k={f2}`。
- Oracle(等 ackWait+ε 讓重投發生):損壞 = `EXISTS k == 1 且 TYPE k == hash` 且
  `HGETALL k:r` 不含 f2(k:r 是 string s0)。
- 變體(同腳本第二段,DEL 誤刪):預埋 hash `k`(直接 rr HSET)→ 注入 type=hash 的
  create(WRONGTYPE 不適用於 hash-on-hash,改用注入 `DEL k` 前先以 CLIENT PAUSE 讓 DEL
  timeout-nack、後續 create 成功、DEL 重投誤刪)— 此變體 timing 敏感,標 optional。

### S5 — threads:4 同批並行亂序(現行設定,不需任何故障)

- 配置:**threads=4(預設,不覆寫)**、無 kill、無 pause。
- 注入:N=500 entity,每 entity `HSET f1` → `HSET f2` → `RENAME` 三筆**緊鄰**注入
  (單一 XADD pipeline 連續灌,最大化同批共存機率)。
- Oracle:同 S1 逐 entity 檢查;統計損壞率(count/N)寫入報告。屬機率型:單輪 0 損壞
  → exit 3 重試(上限 10 輪);全部輪次 0 損壞才判 NOT-REPRODUCED。
- 對照組:同樣流量在 threads=1 下跑一輪,預期 0 損壞(證明歸因正確)。

### S6 — gate 後 redelivery 排空中再 nack

- 配置:threads=1、gate 模擬 ON、ackWait=30s。
- 注入(單一 entity 鏈 + 大量陪跑訊息):
  1. 預埋 string `rr SET k s0`(WRONGTYPE 地雷,同 S4)。
  2. 注入 `HSET k {"f2":"v2"}`(將 WRONGTYPE nack)→ 緊接 `RENAME k→k:r` 與 ~50 筆其他
     entity 的 string create(陪跑,拉開 redelivery 佇列)。
  3. 在陪跑訊息 in-flight 時 SIGKILL leader + gate 模擬 → 新 leader 排空 redelivery 佇列:
     HSET 重投仍 WRONGTYPE(k 還是 string)→ 再 nack;**佇列中它後面的 rename 與陪跑訊息
     照常先 apply** → rename 把 string 搬走 → 下一輪重投 HSET 成功 → ghost。
- Oracle:同 S4(ghost hash `k` + `k:r`=s0 缺 f2),外加陪跑訊息全數到齊(排空未整體卡住
  的證據)。timing 敏感 → 重試上限 5。

## 6. 規範與安全(實作 session 必讀)

1. 遵守 `CLAUDE.md`「Always follow」:先讀 `rules/00-diagnostic.md`、`rules/05-invariants.md`。
   本 lab **不改** INV-1 load-bearing 行;唯一 chart 變更是 `pipelineThreads` values knob
   (預設 4,渲染結果與現狀 bit-for-bit 相同 — 用 `helm template` diff 證明),完成後跑
   `SKIP_L2=1 SKIP_L3=1 scripts/run-all-tests.sh` 並貼 exit status。
2. consumer 參數(ackWait 等)只透過 lab namespace 的 `--set` 覆寫;結束後
   `helm upgrade` 還原預設並確認 nats-init 把 consumer 重建回 30s(drift reconcile)。
3. 所有 kill 都要 `kubectl wait --for=delete` 的 kill 證明(robustness-test 學到的教訓,
   `rules/50-lessons.md`)。
4. 報告不得只寫結論:每個 REPRODUCED 都要附 redis dump + metrics delta + 消費者狀態;
   每個 NOT-REPRODUCED 都要寫重試次數與 arm 證據,不許靜默降級。
5. 完整 run 之後 `nats stream purge KV_CDC` + 100 筆 good-traffic sanity(比照
   `poison-metrics.sh`)確認叢集恢復乾淨,再交還環境。

## 7. 完成標準(Definition of Done)

- [ ] `labs/order-corruption-repro/` 依 §4.1 結構存在,`run-all-scenarios.sh` 單一進入點
- [ ] S0 兩項前提驗證有實測結果(pull 批量實際值、redelivery 順序真偽)
- [ ] S1–S6 每個腳本可獨立執行,exit code 符合 §4.2,INCONCLUSIVE 自動重試
- [ ] `reports/<ts>/report.md` 含逐情境 verdict 表(REPRODUCED / NOT-REPRODUCED / INCONCLUSIVE)
      與損壞率統計(S5)
- [ ] S5 的 threads=1 對照組跑過且 0 損壞(歸因證明)
- [ ] chart 變更(pipelineThreads knob)通過 helm lint/template + L0/L1,預設渲染不變
- [ ] 環境清理:consumer 還原 30s、KV_CDC purge、good-traffic sanity 通過
- [ ] 結果回寫:在本文件末尾新增「實測結果」章節,對照 §3 表格逐列標注實測 verdict

## 8. 附錄 — 每情境參數速查

| 情境 | threads | ackWait | kill | gate 模擬 | 確定性 | 重試上限 |
|---|---|---|---|---|---|---|
| S0 | 4(預設) | 30s | S0.2 要 | 否 | 高 | 3 |
| S1 | 1 | 30s | 是 | 是 | 機率(arm 檢查) | 5 |
| S2 | 1 | 30s | 是 | 是 | 機率(arm 檢查) | 5 |
| S3 | 1 | **5s** | 否 | 否 | timing 敏感 | 5 |
| S4 | 1 | 30s | 否 | 否 | **確定性** | 1 |
| S5 | **4** | 30s | 否 | 否 | 機率(統計) | 10 |
| S6 | 1 | 30s | 是 | 是 | timing 敏感 | 5 |
