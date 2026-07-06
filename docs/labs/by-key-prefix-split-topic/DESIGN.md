# Design: `labs/by-key-prefix-split-topic/` — key-prefix 分流 × sink 延遲下的 8000 msg/s 吞吐驗證(kind-based lab)

日期:2026-07-06
狀態:設計完成,待另一 session 執行
來源需求:`docs/labs/by-key-prefix-split-topic/request.md`
產出目錄:`labs/by-key-prefix-split-topic/`(lab 本體)、`docs/superpowers/specs/`(交付物 D3)
撰寫者:Fable 5(本文件把設計判斷全部前置固定,執行 session 可由 Opus/Sonnet 完成)
風格先例:`docs/superpowers/specs/2026-07-06-robustness-test-lab-design.md`、
`docs/superpowers/specs/2026-07-06-approach-a-order-corruption-repro-lab-design.md`

---

## §0 給執行模型的操作準則(先讀,全程遵守)

這一節是本文件作者的思考與決策方式,已固化成可遵循的規則。**每一條都是硬性的。**

1. **先讀 rules。** 開工前依序讀 `CLAUDE.md`、`rules/00-diagnostic.md`、`rules/05-invariants.md`、
   `rules/10-model-dispatch.md`、`rules/20-judgment-rubric.md`。本文件多處直接引用它們。
2. **引用即事實、事實必附出處。** 本文件 §2 的事實表每列都有 file:line。檔案可能被移動:
   引用前先確認該行還在;不在就以 grep 找到新位置,更新你的工作筆記,不要憑記憶行動。
3. **量測,不要假設。** §6 的吞吐上限公式是「假說」(H1–H3),不是結論。你的工作是用真實
   量測資料驗證或推翻它們,兩種結果都要寫進報告。
4. **禁止調 oracle 讓測試變綠。** 通過準則(§1)固定。跑不到 8000 msg/s 是「發現」(finding),
   照實記錄;harness 自身的問題(部署失敗、collector 掉資料)才是要修的 bug。兩者在報告中
   必須明確區分(先例:robustness lab 的 PASS/FAIL/INCONCLUSIVE 三值退出碼)。
5. **報告中的每個數字都來自工具輸出。** 圖表只能由本次執行寫出的 CSV 產生。**嚴禁**手寫、
   內插、或憑印象填數字(request 明文要求「根據真實資料」)。
6. **改 Go code 用 TDD。** writer 的 `KEY_PREFIXES` 變更(§5.1)先寫失敗測試再實作,
   預設值必須保持既有行為 bit-for-bit 不變。
7. **驗證階梯照表跑**(§9 有本 lab 的對照表)。宣告完成前,貼出指令 + exit status + 關鍵結果行
   (`rules/05-invariants.md` §Reporting rule)。
8. **卡住兩次就換策略。** 同一子任務同一方法失敗兩次,停下來寫失敗軌跡,換分解方式或升級
   (`rules/20-judgment-rubric.md` §1、§4;`rules/10-model-dispatch.md` C5)。
9. **子代理與模型路由**照 `rules/10-model-dispatch.md` 與使用者全域規則:Go diff 的 code
   quality review 交叉供應商(Codex);repo 掃描用 read-only Explore;bash script 小改不必派工。
10. **不碰 chart/。** 本 lab 對 chart 的所有客製都經由 `helm --set`(§4.3)或 lab 自有
    manifests。`chart/files/connect/*`、`chart/templates/*`、`chart/values.yaml` 一行都不改
    ——多 subject 的 chart 原生支援是另一份設計文件(交付物 D3,§10)在下一個 session 做的事。
11. **開始實作前**,依 `superpowers:writing-plans` 把本設計展開成 implementation plan(本 lab
    有 6+ 種服務角色,超過 research-lab skill 的 escalation 門檻)。執行時使用
    `research-lab` skill 的 kind 模式(`references/kind-mode.md`)。

---

## §1 目的與通過準則

### 目的(一句話)

在 kind 叢集中,以恆速 8000–10000 msg/s 的 Go writer 流量,證明:當 sink 端 Connect 與
NATS 之間存在 170–200 ms 的網路延遲(pull 與 ack 都經過延遲)時,**以 key 第一個冒號前的
prefix 將訊息切到多組 subject × Connect pod 群(1:1)可以讓聚合吞吐達到 ≥8000 msg/s**,
並以真實量測資料產出視覺化報告。

### 通過準則(固定,不得調整)

| 條件 | 準則 |
|---|---|
| C-0 harness 健全 | S0(經 proxy、0 ms toxic)聚合 apply 速率 ≥ 8000 msg/s 且量測窗結束後 backlog 可歸零 —— 不達標是 harness 問題(rc 3),先修 harness |
| C-1 主要目標 | 至少一個「prefix 分流 + 170–200 ms 延遲」情境(S3/S4)於 ≥300 s 量測窗內,聚合 apply 速率持續 ≥ 8000 msg/s,且各 consumer `num_pending` 無單調增長 |
| C-2 高速目標 | 通過 C-1 的組態再以 10000 msg/s 重跑(S5),結果照實記錄(通過與否都是 finding) |
| C-3 報告 | `reports/<ts>/report.md` + PNG 圖表全部由本次 run 的 CSV 生成 |
| C-4 無訊息異常 | 量測期間 `cdc_unprocessable` 增量 = 0;drain 後抽樣 key 的 central/region 值一致(§7 P3) |

Lab 整體退出碼:`0` = C-0 ∧ C-1 ∧ C-3 ∧ C-4;`3` = harness INCONCLUSIVE;
`1` = harness 正常但沒有任何分流組態達到 8000(報告仍必須產出——這是有效的負面結果)。
S1(單 sink + 延遲)**預期失敗**,它失敗不影響整體退出碼,它意外通過也照實記錄。

---

## §2 被測系統事實表(執行前逐列再驗證)

| # | 事實 | 出處 |
|---|---|---|
| F1 | Stream 綁定萬用 subject `<subjectPrefix>.>`(預設 `kv.cdc.>`),publisher 的 --allow-pub 同源推導 → 發佈 `kv.cdc.<prefix>.<op>` 不需改 stream 或權限 | `chart/templates/_helpers.tpl:240-243`、`chart/values.yaml:78` |
| F2 | Forward leg 發佈 subject 為 `<subjectPrefix>.${! meta("op") }`,Helm 期展開 | `chart/templates/_helpers.tpl:250-253`、`chart/files/connect/cdc-forward.yaml:109` |
| F3 | Forward leg:write-then-ack(`commit_period: 200ms`)、`Nats-Msg-Id: meta("event_id")` 去重、fallback 失敗子項 `reject` | `chart/files/connect/cdc-forward.yaml:39,111,119` |
| F4 | Sink leg 以 `bind: true` 綁定預建 durable pull consumer `cdc_sink`;bind 模式下 YAML 的 deliver/ack_wait/max_ack_pending 被忽略,以 server 端 consumer 設定為準 | `chart/files/connect/cdc-reverse.yaml:33-40`、`chart/values.yaml:80-91` |
| F5 | Consumer 預設:`ackWait: 30s`、`maxAckPending: 1024`、`maxDeliver: -1` | `chart/values.yaml:86-91` |
| F6 | nats-init Job 建 stream(`--max-bytes 256MB --max-age 1h --dupe-window 5m`)與 pull consumer(`--filter <subjects> --ack explicit --max-pending ...`),且會偵測漂移重建 | `chart/templates/nats-init-job.yaml:73-84,124-169`、`chart/values.yaml:92-95` |
| F7 | Sink pipeline 在 SET 前 best-effort XADD `cdc:latency`(`writer_ts`=body 內 writer 蓋章、`sink_ts`=apply 當下),latency-calculator 以此算 p50/p95/p99,輸出 `:8082/metrics` 的 `cdc_latency_seconds{op,quantile}` 與 JSON 報告 | `chart/files/connect/cdc-reverse.yaml:132-159`、`internal/latency/`(stream.go:11-25、metrics.go:36-63) |
| F8 | latency 側車 stream `MAXLEN ~ 50000`,註解要求 ≥ 2× 每 interval 的 XADD 峰值 → 8000 msg/s × 10 s 遠超過,**必須調大** | `chart/values.yaml:231-237` |
| F9 | Writer:token-bucket 限速(`x/time/rate`),`POST /rate {"Rate":N}` 執行期調整、上限 `MAX_RATE`(預設 20000);`INITIAL_RATE` 預設 0 | `internal/writer/limiter.go:33-42`、`http.go:50-66`、`main.go:19-36` |
| F10 | Writer key 全部以 `lb:` 開頭:`lb:<pattern>:{active,standby}:{<entity>:%d}`,hash-tag 保持 rename 同 slot;每 op 同時寫 central KV + XADD `app.events` | `internal/writer/patterns.go:25-29`、`worker.go:82,195-209` |
| F11 | Writer metrics:`cdc_writer_sent_total`、`cdc_writer_ops_total{op}`、`cdc_writer_rate_target`、`cdc_writer_inflight`(`GET /metrics`);另有 `/healthz`、`/reset`、`/state` | `internal/writer/http.go:37-48` |
| F12 | Chart writer Deployment 的 env 是**白名單模板**(`KEY_PREFIXES` 無法以 `--set writer.env.*` 注入),且 initContainer 硬等 `<prefix>connect-source:4195/ready` | `chart/templates/writer.yaml:29-36,42-72` |
| F13 | Chart connect 兩腿 = streams-mode 空 boot + elector 側車,當選才 POST pipeline;pipeline 內容來自 `.Files.Get`,**無法用 values 覆寫** | `chart/templates/connect-sink.yaml:56-59`、`internal/elector/main.go:131-153` |
| F14 | 每個 chart 元件都有 `enabled:` 開關:`connect.source.enabled`、`connect.sink.enabled`、`writer.enabled`、`latencyCalculator.enabled` 等 | `rules/05-invariants.md` §INV-3、`chart/values.yaml` |
| F15 | 既有 kind 腳本:`scripts/build-images.sh --kind --kind-name=X`(apps 映像)、`verify-cdc.sh` / `verify-failover.sh` 皆吃 `RRCS_NS/RRCS_RELEASE/RRCS_VALUES/RRCS_SET` | `scripts/build-images.sh:36-47`、`scripts/verify-cdc.sh:20-37` |
| F16 | 本機 docker image store 已有 `hpdevelop/connect:4.92.0-claudefix`(chart 預設)與 `ghcr.io/shopify/toxiproxy:2.9.0`(2026-07-06 驗證) | `docker images`(執行期 preflight 再驗) |
| F17 | `chart/values-dev.yaml`:pullPolicy Never(本地 apps 映像)、`bodyEncoding: gzip:base64`;不覆寫 replicas/subject/consumer 參數 | `chart/values-dev.yaml:1-21` |
| F18 | repo 內目前**沒有任何**網路延遲注入工具(netem/toxiproxy/pumba 均無) | 全 repo grep(2026-07-06) |

---

## §3 需求解讀與已決策事項

Request 逐條對應:R1 8000 msg/s Go 產流、R2 sink 170–200 ms(pull+ack)下 ≥8000 並提案
延遲工具、R3 by-prefix 切 pod 群×topic 1:1、R4 第一個冒號前字串→subject、R5 恆速
8000–10000、R6 image `hpdevelop/connect:4.92.0-claudefix`、R7 based on chart/ + 真實資料
視覺化報告 + 另寫 chart 改造設計文件。

| # | 決策 | 理由 / 被否決的替代方案 |
|---|---|---|
| D1 | **延遲工具:toxiproxy 2.9.0**(TCP proxy + latency toxic),部署為 in-cluster Deployment,sink 的 NATS URL 指向它 | 映像已在本機(F16);容器化、免 NET_ADMIN、有 jitter、HTTP API 可執行期開關,且可先以 0 ms toxic 驗證 proxy 本身不是瓶頸(S0)。否決:tc/netem side­car(要 NET_ADMIN、動 kind node 核心)、chaos-mesh(裝 CRD,過重)、pumba(docker 層,非 k8s pod 粒度)、istio fault injection(僅 HTTP,NATS 是裸 TCP) |
| D2 | **延遲語義:每方向 latency=185 ms、jitter=15 ms(170–200),upstream 與 downstream 各掛一個 latency toxic** | 直譯 request「pull msg 與 ack msg 都有 170–200 ms」:訊息下行 185 ms、ack/fetch 上行 185 ms。副作用是 fetch 完整 RTT ≈ 370–400 ms,測試因此**更嚴格**,通過即更強的證據。knob `TOXIC_LAT_MS/TOXIC_JITTER_MS` 可改;若 owner 之後澄清是「RTT 共 170–200」,改成每向 92±8 重跑即可,harness 不變。實測 RTT 必須寫進報告(§7 P2) |
| D3 | **subject 方案:單一 stream `KV_CDC`,per-prefix subject `kv.cdc.<prefix>.<op>` + per-prefix durable(FilterSubject `kv.cdc.<prefix>.>`)** | F1:stream 綁 `kv.cdc.>`,新 subject 天然被收,stream/權限零改動。否決:per-prefix 獨立 stream(隔離更強但要動 nats-init 與帳權,屬 D3 交付物在 chart 原生化時的選項之一,把取捨寫進該文件) |
| D4 | **chart 完全不動;兩條 connect 腿、writer、toxiproxy 都由 lab 自有 manifests 部署**。chart 只負責基礎設施:redis central/region、NATS + nats-init、latency-calculator(`connect.source.enabled=false, connect.sink.enabled=false, writer.enabled=false, latencyCalculator.enabled=true`) | 三個硬事實逼出此路:F2(publish subject 是 Helm 期字串,無法插入 prefix)、F13(pipeline ConfigMap 不可 values 覆寫)、F12(writer env 白名單 + init gate)。lab 腿不用 elector(效能實驗不測 HA;pull consumer 本身允許多 pod 共享 durable)。pipeline 檔取得方式見 D6 |
| D5 | **writer 新增 `KEY_PREFIXES` env(逗號分隔;預設空=行為完全不變)**:設定時 key 變成 `<prefix>:<原 key>`,prefix 以 entity id 決定(`prefixes[id % N]`),保證同一 entity 的 create/update/delete/rename 全落同一 prefix(rename 的 old/new 同 id → 同 prefix,hash-tag 不變) | 產流必須是 Go(R1),writer 已有限速/多 worker/op 混合/metrics(F9–F11),lab 另寫產生器是重複造輪。同 entity 固定 prefix 是**正確性前提**:跨 subject 的同 key 操作會失去 per-subject 順序性 |
| D6 | **lab 的 pipeline 檔 = `helm template` 渲染輸出 + 明確列出的最小 diff**(§5.2/§5.3),不是手抄 | 渲染取得可消除 Helm 模板翻譯錯誤(gzip 分支、URL helper、Lua 內嵌);diff 最小化保住與正式 pipeline 的可比性 |
| D7 | **量測主 oracle:各 sink `:4195/metrics` 的 `cdc_apply` 計數速率(聚合)+ per-consumer `num_pending`**;E2E 延遲用 latency-calculator(F7) | `cdc_apply` 只在 region 寫成功後遞增(`rules/05-invariants.md` INV-2)= 最誠實的「完成」定義 |
| D8 | **視覺化:bash collector 每 5 s 寫 CSV → run 結束後用 docker 跑 `python:3.12-slim` + matplotlib 產 PNG + report.md** | 全程容器內、免 host 安裝(research-lab skill 硬性規定);CSV 是原始證據,圖表可重生 |
| D9 | **情境間 reset:writer rate→0 → 等 pending 歸零 → `nats stream purge KV_CDC`(admin creds)→ 下一情境** | stream 是 limits retention:訊息量 ~5 MB/s,不 purge 會在數分鐘內撞 `maxBytes` 開始丟舊訊息,污染量測(§11 R2 有算式) |
| D10 | prefix 集合預設 `prefix-a,prefix-b,prefix-c,prefix-d`(request 的命名),subject token 僅允許 `[A-Za-z0-9_-]+`;一般化的 sanitization 規則留給 D3 交付物 | NATS subject token 不能含 `.`/空白/萬用字元;lab 由 writer 控制 prefix,安全 |

---

## §4 架構

### 4.1 拓撲(S4,N=4 為例)

```
                        kind cluster "cdc" / namespace cdc-k8s
┌─────────────────────────────────────────────────────────────────────────────┐
│  [chart 管理]                                [lab 管理]                       │
│                                                                             │
│  redis-central ◄──XADD app.events──── lab-writer (KEY_PREFIXES=a,b,c,d,     │
│      │                                            POST /rate 控速)          │
│      │ XREADGROUP (無延遲)                                                   │
│      ▼                                                                      │
│  lab-src-connect ──publish──► lab-nats (KV_CDC, subjects kv.cdc.>)          │
│  (1 pod, 直連 NATS)              subject: kv.cdc.<prefix>.<op>              │
│                                   │                                         │
│                        ┌──────────┴─ nats-init Job [chart]:建 stream        │
│                        │             (cdc_sink durable → lab 刪除)           │
│                        ▼                                                    │
│                 lab-toxiproxy ── admin :8474;listeners :4223..:4226         │
│                 (latency toxic 185±15ms up+down, per-prefix proxy)           │
│                   │        │        │        │                              │
│                   ▼        ▼        ▼        ▼                              │
│              lab-sink-a lab-sink-b lab-sink-c lab-sink-d   (pod 群×topic 1:1)│
│              bind durable cdc_sink_prefix-a..d (filter kv.cdc.prefix-a.>..) │
│                   │  SET/DEL/EVAL + XADD cdc:latency                        │
│                   └────────►  redis-region ◄── latency-calculator [chart]   │
│                                                  (:8082 p50/p95/p99)        │
│  lab-toolbox (nats-box):nats CLI + curl,一切 in-cluster 控制/刮取由此進行   │
└─────────────────────────────────────────────────────────────────────────────┘
   scripts/verify-prefix-split.sh(host):部署→情境迴圈→collector CSV→python 繪圖
```

### 4.2 元件歸屬表

| 元件 | 來源 | 說明 |
|---|---|---|
| redis-central / redis-region / NATS / nats-init / latency-calculator | chart(`helm upgrade --install`) | 既有元件原樣使用;latency-calculator 開啟 |
| lab-writer | lab manifest | apps 映像 `command: ["app","writer"]`,加 `KEY_PREFIXES`,**不含** wait-connect-source init gate(F12);Service :8081 |
| lab-src-connect | lab manifest | `hpdevelop/connect:4.92.0-claudefix`,單 pod,config-file 模式跑 §5.2 的 forward 管線;直連 `lab-nats:4222`;掛 publisher creds Secret(chart 已渲染);Service :4195 |
| lab-sink-<prefix> ×N | lab manifest(模板生成) | 同映像,config-file 模式跑 §5.3 的 reverse 管線;NATS URL 指向 toxiproxy 對應 listener;掛 subscriber creds;每 prefix 一個 Deployment(replicas 預設 1,knob `SINK_REPLICAS` 可 >1 驗證 pull consumer 共享) |
| lab-toxiproxy | lab manifest | `ghcr.io/shopify/toxiproxy:2.9.0`,admin :8474,per-prefix listener :4223+i;Service 曝光全部埠 |
| lab-toolbox | lab manifest | `natsio/nats-box:0.14.5`(chart 同款,F16 preflight 確認本機有),長駐 sleep;所有 `nats`/`curl` 操作用 `kubectl exec` 進來打,避免 port-forward 在高載下不穩 |

### 4.3 chart 安裝參數(唯一與 chart 的接觸面)

```bash
helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
  -f chart/values-dev.yaml \
  --set connect.source.enabled=false \
  --set connect.sink.enabled=false \
  --set writer.enabled=false \
  --set latencyCalculator.enabled=true \
  --set latencyCalculator.streamMaxLen=400000 \
  --set nats.stream.maxBytes=2GB \
  --set nats.stream.dupeWindow=1m \
  --set nats.persistence.size=8Gi \
  --set resources.nats.limits.memory=2Gi
```

偏離 chart 預設的每一項都要在報告「偏離表」照§11 的理由抄錄。注意:`rules/05-invariants.md`
INV-1 row 5 要求 dupeWindow ≥ 實際 replay 窗;本 lab 無 kill、replay 窗 ≈ `commit_period`
200 ms,1m 綽綽有餘——這是合規偏離,不是違規(理由必須進報告)。

---

## §5 元件詳細設計

### 5.1 writer:`KEY_PREFIXES`(repo Go code 變更,唯一的 repo 程式碼修改)

- 規格:env `KEY_PREFIXES`(例 `prefix-a,prefix-b`)。空/未設 → 行為與現在 **完全相同**。
  非空 → 每個 entity 的所有 key 變成 `<prefix>:<原 key>`,`prefix = prefixes[entityID % len(prefixes)]`。
- 實作落點:`internal/writer/patterns.go`(或 worker 的 key 組裝處 `worker.go:82,96-127`)。
  維持 hash-tag 段不變;rename 的 active/standby 兩個 key 由同一 entity id 派生 → 同 prefix。
- 驗證 prefix 字元集 `[A-Za-z0-9_-]+`,不合法直接 fatal(fail-loud,啟動即死)。
- **TDD**:先寫表驅測試——(a) 未設時 key 與現行完全一致(golden);(b) 設定時第一個冒號前
  等於預期 prefix;(c) 同 id 跨 op/跨 pattern prefix 一致;(d) 非法 prefix fatal。
- **必跑階梯**(`rules/05-invariants.md` §change-type 表,writer 行為變更):
  `go test ./...`(L0)→ `helm lint chart/ && helm template chart/ >/dev/null`(L1,證明沒動到 chart)
  → `scripts/build-images.sh --kind --kind-name=cdc` + `RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh`
  (L3,`KEY_PREFIXES` 未設,證明預設路徑零回歸,`verdict.pass=true` 貼進 VALIDATION.md)。
- Go diff 完成後派 **Codex** 做 code quality review(使用者全域路由規則;宣告切換)。

### 5.2 lab forward 管線(渲染 + diff)

取得基底:
```bash
helm template lab ./chart -f chart/values-dev.yaml -s templates/connect-configmaps.yaml
```
抽出 forward 管線與 `observability.yaml` 段(http/metrics/logger),合併成單一 config 檔
`pipelines/forward.yaml`(config-file 模式;P0 先以 `docker run --rm hpdevelop/connect:4.92.0-claudefix --help`
確認執行子命令與旗標,**不要假設**)。對渲染結果施加且僅施加以下 diff:

1. mapping 末尾追加 prefix 萃取(rename 事件 `kv_key` 可能為空,fallback 到 `new_key`):
   ```
   meta kv_prefix = meta("kv_key").or("").split(":").index(0)
   # 若 kv_key 為空(rename):
   #   meta kv_prefix = 取 meta("new_key") 的第一段;兩者皆空 → "unknown"(會落在無人訂閱的
   #   subject 上;collector 監看 stream 內 kv.cdc.unknown.> 的量,>0 即 harness bug)
   ```
   (確切 Bloblang 寫法由執行者以 `connect blobl` 或單元 config 驗證後定案——語法先驗證再上。)
2. output subject 改為 `kv.cdc.${! meta("kv_prefix") }.${! meta("op") }`。
3. `client_id` / label 的 `__POD__` token 換成固定字串 `lab_src`(lab 無 elector 做替換,F13)。

**不得更動**(保持與正式管線同語義,量測才有代表性):`commit_period`、`Nats-Msg-Id` header、
fallback 失敗子項 `reject`、gzip:base64 編碼分支、`auto_replay_nacks`。
吞吐 knob(僅 S0 不達標時才動,動了要記進報告):`readLimit`(渲染值 50)、`threads`、`maxInFlight`。

### 5.3 lab reverse 管線(渲染 + diff)

同法渲染 reverse 管線 → `pipelines/reverse.tpl.yaml`,以 `__PREFIX__`/`__NATS_URL__` 佔位:

1. input `nats_jetstream.urls` → `nats://lab-toxiproxy:__PORT__`(per-prefix listener)。
2. `durable` → `cdc_sink___PREFIX__`(實名如 `cdc_sink_prefix-a`);`bind: true` **保持**。
3. 其餘全部保持:op-gated decode、`reject_errored`+`drop` 輸出、`cdc:latency` XADD 區塊(F7,
   E2E 延遲量測靠它)、`cdc_apply`/`cdc_unprocessable` metrics(collector 靠它)。

生成:`scripts/gen-sink-configs.sh` 以 sed 對每個 prefix 產出實體檔,連同 Deployment manifest
一起 `kubectl apply`。creds 掛載沿用 chart 渲染出的 Secret(`lab-subscriber-creds` 等,名稱以
`helm template` 輸出為準)。

### 5.4 per-prefix durable consumer

鏡射 nats-init 的旗標(F6),經 toolbox 執行;`maxAckPending` 是情境參數:

```bash
nats consumer add KV_CDC "cdc_sink_${p}" --pull \
  --filter "kv.cdc.${p}.>" --ack explicit --deliver all --replay instant \
  --wait 30s --max-pending "${MAX_ACK_PENDING}" --max-deliver=-1 --defaults
```

部署後**刪除** chart nats-init 建的 `cdc_sink`(無人 bind,pending 只會空長,干擾讀數):
`nats consumer rm KV_CDC cdc_sink -f`。注意 nats-init 有漂移重建邏輯(F6)但只在 Job 重跑時
發生;同一 release 內不重跑,若 helm upgrade 觸發了 Job,重刪一次即可(寫進 lib.sh 的
`ensure_consumers()`,冪等)。

### 5.5 toxiproxy 佈建

```bash
# per prefix i=0..N-1(經 toolbox curl)
curl -sf -X POST lab-toxiproxy:8474/proxies -d \
  '{"name":"nats-'"$p"'","listen":"0.0.0.0:'"$((4223+i))"'","upstream":"lab-nats:4222"}'
# 情境開關(S0 不掛 toxic;S1-S5 掛):
curl -sf -X POST lab-toxiproxy:8474/proxies/nats-$p/toxics -d \
  '{"name":"lat_down","type":"latency","stream":"downstream","attributes":{"latency":185,"jitter":15}}'
curl -sf -X POST lab-toxiproxy:8474/proxies/nats-$p/toxics -d \
  '{"name":"lat_up","type":"latency","stream":"upstream","attributes":{"latency":185,"jitter":15}}'
```

情境切換 = 刪/建 toxics(`DELETE /proxies/<n>/toxics/<toxic>`),**不重啟** sink pod
(NATS 重連自動發生;若觀察到 consumer 卡死,`kubectl rollout restart` 該 sink 並在報告註記)。

### 5.6 collector(bash,每 5 s 一列 CSV)

經 toolbox `kubectl exec` 刮取;counter 存**累計值**,速率由繪圖端做差分:

```
ts_epoch,scenario,writer_sent,writer_rate_target,
apply_a,apply_b,apply_c,apply_d,          # sum(cdc_apply{...}) per sink;缺席填空
pending_a,pending_b,pending_c,pending_d,  # nats consumer info -j 的 num_pending
ack_pending_a,...,                        # num_ack_pending(在途量,驗 H1 的關鍵欄位)
p50_ms,p95_ms,p99_ms,                     # latency-calculator :8082(seconds→ms)
unproc_total,source_lag                   # sum(cdc_unprocessable);XINFO GROUPS app.events 的 lag
```

實作要點:單一 `scrape_once()` 函式輸出一列;任何欄位刮取失敗填 `NA` 並繼續(collector
永不中斷量測);每情境獨立檔 `reports/<ts>/S<k>.csv`。

---

## §6 情境矩陣與假說

所有情境:恆速輸入(writer `POST /rate`)、warmup 60 s、量測窗 300 s、drain(rate→0,等
pending 歸零,上限 300 s)、purge、下一個。統一 `PAYLOAD_BYTES=200`、op 混合走 chart 預設。

| # | prefixes N | toxic | maxAckPending/consumer | rate | 預期 | 目的 |
|---|---|---|---|---|---|---|
| S0 | 1 | **無**(仍經 proxy) | 1024 | 8000 | PASS(C-0) | 證 harness+proxy 裸吞吐 ≥8000,否則 rc 3 修 harness |
| S1 | 1 | 185±15 雙向 | 1024 | 8000 | **FAIL**(finding) | 重現問題:單 sink 撞在途上限 |
| S2 | 1 | 同上 | 8192 | 8000 | 記錄 | 對照組:只調參不分流,行不行? |
| S3 | 2 | 同上 | 1024 | 8000 | 邊際 | 分流×2 |
| S4 | 4 | 同上 | 1024 | 8000 | PASS(C-1 主證) | 分流×4 |
| S5 | 承 C-1 通過組態 | 同上 | 同上 | 10000 | 記錄(C-2) | 高速端點 |

**假說(報告必須逐條對照實測)**

- **H1(在途上限)**:pull consumer 穩態吞吐 ≈ `min(maxAckPending, 實際在途) / T_unack`,
  `T_unack` ≈ 下行單向延遲 + 處理 + 上行 ack 單向延遲 ≈ 0.4 s(D2 的雙向 185 ms)。
  S1 預估上限 ≈ 1024/0.4 ≈ **2500–5500 msg/s < 8000**(區間寬是因為 connect 的 fetch
  批次行為未知——用 `ack_pending_*` 欄位實測回填)。
- **H2(水平分流)**:聚合在途窗 = N × maxAckPending → S4 上限 ≈ 4× S1,應 >8000。
- **H3(垂直調參)**:S2 若也達 8000,則分流的論證重心移到「隔離與線性擴展」而非唯一解——
  這個結論直接寫進 D3 交付物的取捨章節。

---

## §7 執行流程(`scripts/verify-prefix-split.sh`,單一進入點)

沿用 robustness lab 的骨架(`run_phase` 三值退出碼、`trap finish EXIT` 必寫報告、
`set -euo pipefail`、env knob 全部可覆寫、`kubectl wait` 證明每個狀態轉移)。

- **P0 preflight**:kind cluster 存在;`nproc ≥ 8`(不足 → 警告並記錄,量測結果可能受限);
  三個映像在本機(connect:4.92.0-claudefix、toxiproxy:2.9.0、apps dev——沒有就
  `build-images.sh --kind`);`kind load docker-image` 全部;
  `docker run --rm hpdevelop/connect:4.92.0-claudefix --help` 確認 config-file 執行方式;
  `connect lint` / dry-run 驗證 §5.2/§5.3 生成的管線檔語法。
- **P1 deploy**:§4.3 helm 安裝 → 等 nats-init Complete → §5.4 consumers(含刪 `cdc_sink`)
  → §5.5 proxies → `kubectl apply` lab manifests → 全部 rollout status ok →
  toolbox 內以 `nats bench` 或 `nats rtt` 經 proxy 實測 RTT,記進報告(D2 的證據)。
- **P2 S0**:寫入前先量 proxy RTT(0 toxic ≈ 本地);跑 S0;不達標 → rc 3,
  依 §5.2 的 knob 清單調 harness(不是調 oracle)後重跑,最多兩輪,仍不行照 §0-8 升級。
- **P3 S1–S5 迴圈**:每情境 = 設 toxics/consumers/sinks → warmup → 量測(collector 背景跑)
  → drain → 正確性抽查(隨機取 20 個 active key,`redis-cli GET/HGETALL` 比對 central vs
  region,delete 過的 key 允許雙邊皆無)→ `unproc` 增量斷言 =0 → purge(D9)。
- **P4 report**:§8 產圖與 report.md;`report.json`(機器可讀 per-scenario verdict)
  `jq . >/dev/null` 自檢;依 §1 規則決定退出碼。

預估總時長:部署 ~10 min + 6 情境 ×(1+5+≤5)min ≈ **60–80 min**。逐情境把「指令 + exit
status」落到 `reports/<ts>/commands.log`(§0-7 的證據義務)。

## §8 視覺化報告(交付物 D2)

繪圖:`report/plot.py`,在容器內執行(host 零安裝):

```bash
docker run --rm -v "$LAB_DIR:/lab" python:3.12-slim bash -c \
  'pip install --quiet matplotlib==3.9.* pandas==2.2.* && python /lab/report/plot.py /lab/reports/<ts>'
```

必產圖(每張:標題含情境參數、軸帶單位、8000 目標水平線、圖例):

1. `S<k>_throughput.png` — writer 目標/實際速率、各 sink apply 速率(counter 差分/5s)、聚合線。
2. `S<k>_backlog.png` — 各 consumer `num_pending` 與 `num_ack_pending` 時間線(H1 的直接證據)。
3. `S<k>_latency.png` — E2E p50/p95/p99 時間線(ms,log 尺度)。
4. `comparison.png` — 各情境穩態聚合吞吐長條圖(量測窗後半段中位數)vs 8000 目標線。

`report.md` 章節:執行環境(host/kind/映像 digest/實測 RTT)→ 情境總表(組態、穩態吞吐、
p95、verdict)→ 每情境圖 + 兩句解讀 → 假說 H1–H3 對照表 → 偏離表(§4.3/§11)→ 結論與
「餵給 D3 的數字」清單 → 附錄 commands.log 摘錄。若執行 harness 有 `dataviz` skill,繪圖前
先載入;沒有就遵守上述最低規格。**所有數列必須可溯源到 CSV 欄位**(§0-5)。

## §9 規範遵循對照表

| 變更 | 對應規範 | 必跑 |
|---|---|---|
| `internal/writer` 加 `KEY_PREFIXES` | INV-4 ladder「writer 行為」 | L0 + L3(§5.1;證據貼 VALIDATION.md) |
| chart:零檔案變更(僅 `--set`) | INV-1/INV-2/INV-3 載重行全數不觸碰 | L1 render 一次證明無 diff(`git status chart/` 乾淨) |
| lab 管線副本 | 非 chart 元件,INV-1 表不直接適用;但 §5.2/§5.3 的「不得更動」清單保住語義代表性 | `connect lint` + S0 |
| lab manifests(新增檔) | 不是 chart component → INV-3 的 toggle 義務不適用 | lab 進入點本身 |
| `rules/`、`CLAUDE.md` | 本 lab 不修改;若有教訓 → 追加 `rules/50-lessons.md`(先備份,Hard rule 2) | — |

## §10 交付物與 Definition of Done

**D1 lab 本體** `labs/by-key-prefix-split-topic/`:
```
RESEARCH.md  README.md  VALIDATION.md
manifests/   (writer/source/sink-template/toxiproxy/toolbox)
pipelines/   (forward.yaml, reverse.tpl.yaml + 生成腳本)
report/plot.py
scripts/     (verify-prefix-split.sh, lib.sh, gen-sink-configs.sh, ensure-consumers.sh, collect.sh, teardown.sh)
reports/     (gitignored)
```
**D2 視覺化報告**:一次完整真實 run 的 `reports/<ts>/`(report.md + PNG + CSV + commands.log),
並把 report.md 內嵌進 VALIDATION.md(robustness lab 慣例)。
**D3 chart 改造設計文件** `docs/superpowers/specs/<執行日>-multi-subject-connect-groups-chart-design.md`,
必含:values schema 草案(`connect.sinkGroups: [{name, filterSubject|prefixes, replicas, consumer 覆寫}]`
方向)、forward 管線 prefix 萃取的模板化方式(F2 的 helper 改法)、nats-init 迴圈建 consumer
與漂移重建、per-group Lease/elector、prefix sanitization 規則(D10)、INV-1/2/3 逐條影響分析
(每 group 的 consumer 參數都是載重的;每 group 必有 enabled/toggle;dashboard 面板 per group)、
向後相容(預設單 group ≡ 現狀)、必跑測試(L1 toggle 迴圈擴充、雙 group L3、per-group L4)、
**以及本 lab 實測數字**(單 sink 延遲下上限、建議的 maxAckPending 預設、N 的容量規劃公式)。

**DoD checklist**
- [ ] writer 變更:TDD 測試 + L0 綠 + L3 `verdict.pass=true`(指令+exit status 已貼)
- [ ] Codex 交叉 review Go diff 完成(或已記錄 fallback)
- [ ] `git status chart/` 乾淨(chart 零變更)
- [ ] `verify-prefix-split.sh` 完整跑過一次,退出碼與 §1 規則一致
- [ ] S0 通過;S1–S5 各有 verdict;C-4 抽查通過
- [ ] report.md + 全部 PNG 由本次 run 的 CSV 生成(無任何手填數字)
- [ ] H1–H3 對照實測寫入報告
- [ ] D3 設計文件完成且引用實測數字
- [ ] `reports/` 已 gitignore;teardown 後 kind 叢集無殘留 lab 資源
- [ ] 過程教訓(若有)已入 `rules/50-lessons.md`(含備份)

## §11 風險與已知陷阱(執行者必讀)

| # | 風險 | 緩解 |
|---|---|---|
| R1 | **toxiproxy 單點成為吞吐瓶頸**,把「延遲上限」誤判成「分流不足」 | S0 強制經 proxy 跑 0 ms toxic;S0 不到 8000 一律 rc 3 |
| R2 | **stream 撞 maxBytes 丟舊訊息污染量測**:~500 B/msg(200 B body gzip+b64+envelope)×10 k/s ≈ 5 MB/s → 256 MB 只撐 ~50 s;2 GB 也只撐 ~400 s | `--set nats.stream.maxBytes=2GB` + 每情境 purge(D9);collector 監看 stream msgs 數,逼近上限即在報告標紅 |
| R3 | **NATS 去重表記憶體**:dupeWindow 5 m × 10 k/s = 3 M ids | `--set nats.stream.dupeWindow=1m`(§4.3 已含合規理由) |
| R4 | **latency 側車 stream MAXLEN 50 k 蒸發樣本**(F8) | `--set latencyCalculator.streamMaxLen=400000`(≥2× 10 k/s × 10 s,含餘裕) |
| R5 | **writer 的 app.events MAXLEN 100 k ≈ 12.5 s @8 k/s**,source 若落後即掉資料 | lab-writer env `STREAM_MAXLEN=500000`;collector 的 `source_lag` 欄位全程監看,>0 且增長 → rc 3 |
| R6 | **kind 單機 CPU 不足**(writer+source+NATS+N sinks+2 redis ≈ 需 8–12 核) | P0 `nproc` 檢查;lab sink requests 1 CPU/limits 2;結果不穩時把量測窗中位數當穩態值並記錄 host 佔用 |
| R7 | **connect config-file 模式的執行旗標與 streams 模式不同**(chart 只用後者,F13) | P0 以 `--help` + `connect lint` 實證;不確定的旗標一律先驗證(§0-3) |
| R8 | **rename/delete 事件 `kv_key` 為空**,prefix 萃取 fallback 寫錯 → 訊息落到 `kv.cdc.unknown.>` 無人消費(pull 模型下不觸發 unprocessable,**默默堆積**) | §5.2 diff 1 的 fallback + collector 斷言 `kv.cdc.unknown.>` 訊息數 =0(`nats stream info`/subject 查詢);>0 → rc 3 |
| R9 | 時鐘偏斜使 E2E 延遲失真 | 全部在同一 kind node,偏斜 ≈0;latency-calculator 本就丟棄負值並計數(F7),`dropped_negative` 進報告 |
| R10 | 情境切換殘留(toxic 沒刪乾淨、consumer 參數沒重建) | 每情境開頭 `GET /proxies` + `nats consumer info` 快照落盤,列入 commands.log |

## §12 附錄:knob 速查

| Env | 預設 | 用途 |
|---|---|---|
| `KIND_NAME` / `NS` / `RELEASE` | `cdc` / `cdc-k8s` / `cdc` | 叢集/命名空間/release(對齊 repo 慣例) |
| `CONNECT_IMAGE` | `hpdevelop/connect:4.92.0-claudefix` | R6 指定;preflight 斷言存在 |
| `PREFIXES` | `prefix-a,prefix-b,prefix-c,prefix-d` | 情境按 N 取前綴子集 |
| `RATE` / `RATE_HIGH` | `8000` / `10000` | R5 恆速輸入 |
| `TOXIC_LAT_MS` / `TOXIC_JITTER_MS` | `185` / `15` | D2;改 92/8 即切換到「RTT 共 170–200」解讀 |
| `MAX_ACK_PENDING` / `MAX_ACK_PENDING_TUNED` | `1024` / `8192` | S1–S4 / S2 |
| `WARMUP_S` / `MEASURE_S` / `DRAIN_TIMEOUT_S` | `60` / `300` / `300` | 情境節奏 |
| `SCRAPE_INTERVAL_S` | `5` | collector 週期 |
| `SINK_REPLICAS` | `1` | 每 prefix pod 群大小(>1 驗證 pull 共享) |
