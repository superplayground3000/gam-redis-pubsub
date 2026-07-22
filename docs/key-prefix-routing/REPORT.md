# Key-Prefix 分流：消費拓撲設計報告

> 依 `master` / `master-backup-260705` 文件與本輪 chart 改動整理。
> 設計圖：[`key-prefix-routing.drawio`](./key-prefix-routing.drawio)。

---

## 1. 動機（為何改消費拓撲）

單一 CDC 管線在 **sink 端帶 170–200 ms（雙向）延遲**時，單一 pull consumer 被 in-flight
視窗（`maxAckPending`）卡死：穩態吞吐 ≈ `maxAckPending / RTT`，達不到目標。lab 驗證單 sink
撐不到 8000 msg/s，**依 key prefix 切成 N 群後恢復 ≥8000 msg/s**（總視窗放大為
`N × maxAckPending`，隨群組數近似線性）。所以核心改動是**把「一條流一個 consumer」拆成
「per-prefix 的 subject × consumer × sink」多群組拓撲**。

---

## 2. 消費拓撲：改動前後的 subject ↔ Connect 配對

### Before（`master-backup-260705`）— 單一配對

- Forward source 只依 **op** 發佈：`kv.cdc.<op>`（例 `kv.cdc.set`、`kv.cdc.del`）。**subject 不帶 key 前綴**。
- Sink 端只有 **一個 durable pull consumer**（filter = 整條 `kv.cdc.>`），由 **一個** cdc-reverse
  sink 部署綁定（leader 綁），吃下所有訊息。

```
所有 key ─▶ kv.cdc.<op> ─▶ 1 個 durable(filter kv.cdc.>) ─▶ 1 個 sink 部署 ─▶ region Redis
```

### After（`master`）— per-prefix 多群組 1:1

- Forward 依 key 前綴發佈：`kv.cdc.<token>.<op>`（token = 命中前綴，`:`→`.`；未命中為 `others`）。
- 每個啟用的 sinkGroup = **一組 1:1 配對**：`subject 家族 × durable × sink 部署`。

目前設計提供的完整 default 前綴群組（`tg:*` key families，即
`docs/requests/first-two-seg-routing.md` 的 canonical 設定 + others catch-all）如下——
每一列都是一組獨立的 subject × durable × sink 部署：

```
tg:caveat…         ─▶ kv.cdc.tg.caveat.<op>         ─▶ cdc_sink_caveat         (filter kv.cdc.tg.caveat.>)         ─▶ sink(caveat)         ─┐
tg:caveat_context… ─▶ kv.cdc.tg.caveat_context.<op> ─▶ cdc_sink_caveat-context (filter kv.cdc.tg.caveat_context.>) ─▶ sink(caveat-context) ─┤
tg:g2m…            ─▶ kv.cdc.tg.g2m.<op>            ─▶ cdc_sink_g2m            (filter kv.cdc.tg.g2m.>)            ─▶ sink(g2m)            ─┤
tg:m2g…            ─▶ kv.cdc.tg.m2g.<op>            ─▶ cdc_sink_m2g            (filter kv.cdc.tg.m2g.>)            ─▶ sink(m2g)            ─┼─▶ region Redis
tg:r2g…            ─▶ kv.cdc.tg.r2g.<op>            ─▶ cdc_sink_r2g            (filter kv.cdc.tg.r2g.>)            ─▶ sink(r2g)            ─┤
tg:uint32id…       ─▶ kv.cdc.tg.uint32id.<op>       ─▶ cdc_sink_uint32id       (filter kv.cdc.tg.uint32id.>)       ─▶ sink(uint32id)       ─┤
未命中(others)     ─▶ kv.cdc.others.<op>            ─▶ cdc_sink_others         (filter kv.cdc.others.>)            ─▶ sink(others)         ─┘
```

| 群組 name | 前綴 (prefixes) | publish subject | durable / filter |
|---|---|---|---|
| `caveat` | `tg:caveat` | `kv.cdc.tg.caveat.<op>` | `cdc_sink_caveat` / `kv.cdc.tg.caveat.>` |
| `caveat-context` | `tg:caveat_context` | `kv.cdc.tg.caveat_context.<op>` | `cdc_sink_caveat-context` / `kv.cdc.tg.caveat_context.>` |
| `g2m` | `tg:g2m` | `kv.cdc.tg.g2m.<op>` | `cdc_sink_g2m` / `kv.cdc.tg.g2m.>` |
| `m2g` | `tg:m2g` | `kv.cdc.tg.m2g.<op>` | `cdc_sink_m2g` / `kv.cdc.tg.m2g.>` |
| `r2g` | `tg:r2g` | `kv.cdc.tg.r2g.<op>` | `cdc_sink_r2g` / `kv.cdc.tg.r2g.>` |
| `uint32id` | `tg:uint32id` | `kv.cdc.tg.uint32id.<op>` | `cdc_sink_uint32id` / `kv.cdc.tg.uint32id.>` |
| `others` | `catchAll: true` | `kv.cdc.others.<op>` | `cdc_sink_others` / `kv.cdc.others.>` |

> 註：`_`（如 `caveat_context`）在 subject token 與 durable 名稱皆合法，故不轉換；群組 **name**
> 走 DNS-1123（`caveat-context` 用連字號）。**未帶參數的 chart 裸預設是 `sinkGroups: []`**——
> 會合成單一 `default` 群組（whole-stream，等同 Before）；上表是啟用 prefix 分流時的 default 前綴集。

### 配對差異對照

| 面向 | Before | After |
|---|---|---|
| **publish subject** | `kv.cdc.<op>`（僅依 op） | `kv.cdc.<token>.<op>`（token = key 前綴，`:`→`.`；未命中 `others`） |
| **subject ↔ consumer** | 全部 → 1 個 consumer（filter `kv.cdc.>`） | 每 subject 家族 `kv.cdc.<token>.*` ↔ 專屬 durable `cdc_sink_<name>`（filter `kv.cdc.<token>.>`），一對一 |
| **consumer ↔ sink 部署** | 1 consumer ↔ 1 sink 部署 | 每 durable ↔ 專屬 sink Deployment（各自 elector/leader） |
| **總 in-flight 視窗** | `1 × maxAckPending`（受 RTT 卡死） | `N × maxAckPending`（隨群組擴充） |
| **stream** | 綁 `kv.cdc.>` | 不變（仍 `kv.cdc.>`，任意深度）；**新前綴不需動 stream/權限** |
| **consumer 建立** | nats-init 建 1 個 durable | nats-init **冪等**逐群組建 `cdc_sink_<name>` |
| **相容性** | — | 未設 sinkGroups 時 render 位元相同；路由 gate 在 `prefixRouting`，關閉即回到 Before 行為 |

---

## 3. 改動後：一筆 msg 如何對應到 subject

Source leg（`cdc-forward.yaml`）逐筆計算，Helm 由 `sinkGroups[].prefixes` 渲染出
route map（raw 前綴 → subject token）注入 Bloblang：

1. 取 key（rename/delete 以新 key fallback），以 `:` 切段。
2. **最長匹配**：先用「前兩段」查 route map；沒中再用「前一段」查。
3. 命中 → 發 `kv.cdc.<token>.<op>`（token 把 `:` 換成 `.`）。
4. 沒中 → 發 `kv.cdc.others.<op>`。

「先兩段、再一段」保證一段前綴（`prefix-a`）與兩段前綴（`tg:caveat`）能並存且不衝突。

| 範例 key | 匹配 | subject | 落到哪個消費群組 |
|---|---|---|---|
| `tg:caveat:123` | 前兩段 `tg:caveat` | `kv.cdc.tg.caveat.<op>` | `cdc_sink_caveat` → sink(caveat) |
| `tg:g2m:9` | 前兩段 `tg:g2m` | `kv.cdc.tg.g2m.<op>` | `cdc_sink_g2m` → sink(g2m) |
| `prefix-a:77:k1` | 前兩段沒中、前一段 `prefix-a` | `kv.cdc.prefix-a.<op>` | `cdc_sink_prefix-a` → sink(prefix-a) |
| `tg:new_family:1` | 兩段/一段皆沒中 | `kv.cdc.others.<op>` | others（見 §4） |

> render 期 **fail-loud** 會擋掉會造成重複投遞或歧義的設定：一段與兩段前綴重疊
> （如 `tg` + `tg:caveat`）、跨群組重複前綴、保留字（`others`/`unknown`）、
> whole-stream consumer 與 prefix 群組並存。

---

## 4. 沒對應到 prefix 的 msg 怎麼處理

未命中分兩種，都會發到 **`kv.cdc.others.<op>`**，但計數與去處不同：

| 情況 | 意義 | subject | 計數 | 最終去處 |
|---|---|---|---|---|
| **no_match** | key 有前綴，但沒設對應群組 | `kv.cdc.others.<op>` | 有 catch-all → 計 others；無 → 計「未路由」 | 見下 |
| **empty_prefix** | 無可推導前綴（malformed 事件） | `kv.cdc.others.<op>` | **一律**計「未路由」 | 見下 |

去處取決於有沒有部署 **catch-all 群組**（`catchAll: true`）：

- **有 catch-all** → `cdc_sink_others`（filter `kv.cdc.others.>`）消費 → 寫入 region Redis。
  屬合法、已路由流量，不丟訊息。
- **無 catch-all** → 訊息 **park 在 `kv.cdc.others.<op>` 無人消費**（受 stream 保留上限保護），
  並觸發 **未路由告警**——這是「有 key 沒被任何群組接住」的明確警示，避免靜默遺失。

> 這也支撐再拆分閉環（G2）：儀表板逐群組看變更頻率，發現某段前綴過熱，就在 values 用
> 兩段前綴細分成新群組，最長匹配自動接手、流量分散到多個 consumer×pod，全程不動 stream。

---

## 5. 可觀測性（一句話）

Connect 兩條 leg / sink / elector 皆輸出 `/metrics`，dashboard 逐群組呈現 apply 吞吐、
others / 未路由、unprocessable(by reason)、publish 失敗、端到端延遲，並對「未路由 park」與
「unprocessable」掛告警——足以判斷每個消費群組現在的狀態。（細節見前版可觀測性章節／dashboard JSON。）

---

## 6. 驗證

L0 unit、L1 chart render + 兩段路由/fail-loud 斷言、L2 告警/儀表板 proof、
L3 kind e2e（first-two-seg + others catch-all）、L4 prefix 變體
（sinkGroups→nats-init consumer；settle window > ackWait horizon）。入口 `scripts/run-all-tests.sh`。
