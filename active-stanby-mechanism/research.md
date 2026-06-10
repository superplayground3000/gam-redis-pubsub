# Redpanda Connect 「同時最多一個 consumer」佈署設計(修訂版)

> 本文修訂自前一版提案,依 peer review 收斂語義精準度與 production fail-closed 細節。
> **最重要的一句話**:本設計提供的是 **best-effort active-gating**,**不是** correctness-guaranteed single-active。
> 順序與唯一性**不得**依賴 Kubernetes Lease;correctness boundary 永遠落在
> **Redis consumer group + JetStream dedup + sink CAS/idempotency** 這三道下層防線。

---

## 0. 定位修正(全案前提)

| 舊說法 | 修訂後 |
|---|---|
| 「single-active」 | **best-effort active-gating**(盡力讓 input 只在一個 pod 上運轉) |
| 「方法 A 是唯一能保證只有一個 consumer 的乾淨做法」 | 「在 Redpanda Connect 內建能力範圍內,streams mode + leader-election 是最乾淨的 **active-gating** 做法;但**不是硬性 fencing**,數學上**不保證**同時只有一個 consumer」 |
| 把 single-active 當正確性邊界 | single-active **不能**作為 correctness boundary;它只降低雙主機率,不排除雙主 |

`client-go/tools/leaderelection` 官方明載:此實作**不保證只有一個 client 正在扮演 leader**(no fencing)。在 NTP 偏移、GC pause、網路分區、租約續約延遲的瞬間,舊 leader 尚未察覺失租、新 leader 已當選,**兩個 pod 會短暫同時 active**。這是設計上必須接受的前提,而非 bug。

```
Operational single-active / best-effort active-gating   ← 本設計提供的
≠
correctness-guaranteed single-active                    ← 本設計「不」提供
```

---

## 1. 不可動搖的前提:readiness 不能 gate input

Kubernetes readiness probe 只控制 Pod 是否在 Service endpoints 內(是否接流量);readiness 失敗時容器內**程序照跑**。Redpanda Connect 的 `redis_streams` input 透過 `XREADGROUP` 主動拉資料,只要 stream 已啟動,not ready **不會**阻止它消費。

**結論:要做到「只有一個 pod 在收」,機制必須真的能啟動/停止 input 本身,而不是調流量路由。**

---

## 2. 先做路線決策(再決定要不要做 active-gating)

| 設計路線 | 建議 | 理由 |
|---|---|---|
| **LWW CAS 變體** | **不要做 active-gating** | sink Lua CAS 已吸收 reorder/retry/duplicate;多 consumer 對正確性無害,反而更耐故障、吞吐更好。active-gating 只會降低恢復彈性。 |
| **Strict global ordering 變體** | **可做方法 A,但聲明 best-effort** | single-active 是嚴格排序的**必要條件,非充分條件**(見 §6)。 |
| **純省資源 / 最低維運** | **`StatefulSet replicas: 1`** | 最低複雜度(§5)。 |

---

## 3. 方法 A:Streams mode + **fail-closed** leader-election controller

核心:以 `rpk connect streams` 啟動一個**空的** Redpanda Connect(boot 時沒有任何 pipeline 在跑);由一個 **client-go leader-election controller**(自寫 sidecar,**不是**旁掛 shell watcher)在 leadership 轉換時,對本地 `:4195` 動態 POST/DELETE pipeline。

`POST /streams/{id}` 建立並啟動 stream、`DELETE /streams/{id}` 關閉並移除 stream——`DELETE` 會真正關閉該 stream 的 input 生命週期,`XREADGROUP` 即停止。

### 3.1 設計原則:fail-closed(預設不消費)

> **預設狀態 = 沒有 stream。只有在「有把握自己正在 leading」時才 POST;任何不確定 → DELETE 或讓整個 Pod 重啟。**

把 lifecycle 收進**單一 controller process**,用 leader-election callback 直接驅動,**避免** elector sidecar + watcher script 的三段式狀態同步(那會多一個故障面)。

```go
// 概念骨架(k8s.io/client-go/tools/leaderelection)
lec := leaderelection.LeaderElectionConfig{
    Lock:            leaseLock,        // coordination.k8s.io/v1 Lease
    ReleaseOnCancel: true,             // 程序退出時主動釋放租約,縮短雙主窗
    LeaseDuration:   15 * time.Second,
    RenewDeadline:   10 * time.Second, // 續約失敗超過此值 → 觸發 OnStoppedLeading
    RetryPeriod:     2 * time.Second,
    Callbacks: leaderelection.LeaderCallbacks{
        OnStartedLeading: func(ctx context.Context) {
            // 當選:把已模板化的 config POST 上去(帶重試)
            if err := postStreamWithRetry(ctx, streamID, configBytes); err != nil {
                // 當了 leader 卻起不來 stream → 釋放租約讓別人試,自己保持 fail-closed
                cancelLeadership()
            }
        },
        OnStoppedLeading: func() {
            // 失去 leadership:立刻 DELETE;DELETE 失敗 → 退出讓 kubelet 重啟整個 Pod
            if err := deleteStreamWithRetry(streamID); err != nil {
                os.Exit(1) // stream 隨程序一起死,杜絕殘留消費
            }
        },
    },
}
```

### 3.2 fail-closed 行為表(**必備設計,不是監控項**)

| 狀況 | 必須動作 |
|---|---|
| controller **啟動時** | **先 `DELETE` 本地 stream**(重啟後重新同步到「未確認 leading 前不消費」) |
| 無法連到 apiserver / 無法確認自己是 leader | 立刻 `DELETE` 本地 stream |
| 失去 leadership(`OnStoppedLeading`) | 立刻 `DELETE`;失敗則重試 |
| `DELETE` 持續失敗 | `os.Exit` → kubelet 重啟 Pod,stream 隨程序消滅 |
| controller 掛掉但 rpconnect 的 stream 還在 | liveness / supervisor 必須讓**整個 Pod** 進入重啟(見 §3.3) |

### 3.3 容器存活連動(把前一版的「監控項」升級成設計)

K8s 一般容器:同 Pod 內某容器掛掉只重啟該容器,Pod 仍在跑——這會造成「controller 重啟中、rpconnect 仍持有 stream」的殘留消費窗。對策(任一即可,建議 1+2):

1. **controller 啟動先 `DELETE`(§3.2 第一列)**——重啟後一定回到 fail-closed,自動消除殘留。
2. **Native sidecar(K8s 1.28+,init container 設 `restartPolicy: Always`)** 取得較佳 lifecycle 語義;controller 異常時更可控地連動主容器。
3. rpconnect 容器的 liveness 可加一條:「本地有 active stream 時,controller endpoint 必須可達」,否則判定不健康。

### 3.4 容器佈局(Deployment,replicas 全活著)

```yaml
spec:
  serviceAccountName: rpconnect-elector
  containers:
    - name: rpconnect
      image: docker.redpanda.com/redpandadata/connect
      args: ["streams", "-o", "/etc/rpc/observability.yaml"]  # 啟動不帶任何 stream 檔
      ports: [{ containerPort: 4195 }]
    - name: elector-controller          # 自寫 client-go controller(非旁掛 watcher)
      image: registry.example.com/rpc-elector-controller:1.0.0
      env:
        - name: POD_NAME
          valueFrom: { fieldRef: { fieldPath: metadata.name } }
        - name: STREAM_ID
          value: source_leg
        - name: RPC_ADDR
          value: http://localhost:4195
```

### 3.5 Streams mode 三個必踩坑(保留,已驗證)

1. **`POST /streams/{id}` 的 config 不吃環境變數插值**(function interpolation 仍可用)。所以 `client_id: ${HOSTNAME}` 這種 **env var** 不會被代換 → controller 在 POST **之前**先用 `POD_NAME` 模板化 config,或改用 Bloblang function interpolation。
2. **`/ready` 不能判斷「我是不是 active」**:zero active streams 時 `/ready` 仍回 **200 OK**。standby pod(0 stream)看起來健康卻沒在收。判斷誰 active 要看 `GET /streams`(leader 應恰好 1 個 stream)或 controller 的 leader 狀態。
3. **stream config 不能含 resources**:resource 要透過 `/resources/{type}/{id}` 或啟動時的 `-o`/`-r` 提供。NATS 的 `user_credentials_file` / `nkey_file` 是 file 參照,放 stream config 沒問題;共用 `cache`(如 dedup)要放 observability config。

### 3.6 deterministic `Nats-Msg-Id`(修訂重點)

雙主與重送場景能不能被擋住,**完全取決於 `Nats-Msg-Id` 是否 deterministic**。

```
Nats-Msg-Id 必須:同一筆業務事件,在任何 pod、任何重送、任何時間,都算出「同一個 id」
```

| 來源 | 可用? | 說明 |
|---|---|---|
| Producer 鑄造的 `event_id` 欄位 | ✅ **首選** | idempotency 契約;`${! meta("event_id") }` |
| body 的 content hash(SHA-256) | ✅ fallback | producer 未帶 `event_id` 時 `content().hash("sha256").encode("hex")` |
| `redis_stream_name + redis_entry_id` | ❌ **取不到** | `redis_streams` input **不暴露 entry id 為 metadata**(你 project 文件既有結論);此組合在當前架構無法取得 |
| pod name / processing timestamp / random UUID | ❌ **絕不可用** | 雙主或重送時會被算成不同訊息,dedup 失效 |

多 stream 共用同一 JetStream subject 命名空間時,建議前綴 stream 名以避免跨 stream 撞號:`app.events:${! meta("event_id") }`。

### 3.7 `duplicate_window` sizing(修訂重點)

```
duplicate_window ≥ 最大可能重送時間範圍
                 = max(PEL idle reclaim 年齡, connect downtime, NATS/Redis failover 時間)
```

反例:Redis PEL 裡有 30 分鐘前的訊息被 reclaim 重送,但 `duplicate_window` 只有預設 2 分鐘 → dedup **擋不住**,重複落地。

實務建議:
- `duplicate_window = 5m`(對應典型 MTTR);長 MTTR 需求要按比例放大,並注意 dedup index 記憶體 ≈ publish_rate × window。
- XAUTOCLAIM / reclaim 的 `min-idle-time` 設在 window 的一半以下(如 60s),確保重送一定落在 window 內。
- 窗外重送無法避免時,下游 consumer 必須自己 idempotent(你的 sink CAS 已滿足)。

---

## 4. RBAC(擴充)

不同 leader-election library / sidecar 對 Lease 的操作不一(部分需 `list`/`watch`/`patch`)。先給較寬集合,再依實際 audit log 收斂:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: rpconnect-elector, namespace: <ns> }
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
```

`coordination.k8s.io/v1` Lease 自 Kubernetes **v1.14** 起可用。

---

## 5. 方法 C:`StatefulSet replicas: 1` 的邊界

最誠實、運維成本最低的「平常同時只有一個 consumer」。StatefulSet 提供穩定 identity 與唯一性語義。但它**仍不是資料正確性的唯一防線**,須補:

- **不要 force delete Pod**(`--force --grace-period=0` 會繞過 graceful 終止,製造雙跑窗)。
- 設合理 `terminationGracePeriodSeconds`,讓 in-flight batch 收尾、XACK flush。
- 搭 **PodDisruptionBudget** 避免 voluntary disruption 造成中斷。
- sink 仍要 idempotent(CAS)。
- source 仍要處理 Redis PEL / JetStream pending(failover 後的 reclaim)。

> 收斂句:若只是要「平常同時只有一個 consumer」,`replicas: 1` 是最低複雜度解;若要容忍非預期中斷與資料重送,正確性仍靠下層 idempotency / dedup / CAS。

---

## 6. 嚴格排序:single-active 是**必要非充分**(補強)

走 strict global ordering 時,active-gating 只是其中一塊:

1. **不等於 global ordering**:多 consumer load-balance 後,完成順序仍可能不同。
2. **多 stream key**:Redis 只保證**各 stream 內部**順序,不保證跨 stream 全域順序。
3. 即使單 active consumer,Redpanda Connect 內部仍須:
   - `pipeline.threads: 1`
   - output `max_in_flight: 1`
   - 避免 batch / async output 造成 reorder
4. **failover 後 PEL reclaim 也可能讓舊訊息先於新訊息被處理** → 嚴格排序在 failover 邊界本身就脆弱,需配合 partition-by-key 與 sink fence 才穩。

> 結論:single-active 是嚴格排序的**必要條件**,但**不是充分條件**。

---

## 7. 正確性防線(三道)與設計文件聲明句

| 防線 | 擋住什麼 |
|---|---|
| Redis consumer group(`XREADGROUP >`) | 同 group 內新訊息不重複投遞;雙主期間 load-balance 不重發同一筆 |
| JetStream dedup(`Nats-Msg-Id` + `duplicate_window`) | 重送 / 瞬時雙主在目標端不重複落地(前提:deterministic id + window 夠大) |
| Sink Lua CAS / idempotency | 亂序、跨實例、重送一律吸收(`incoming_ver > stored_ver` 才套用) |

**請在設計文件中明列此句:**

> Leader election 僅用於降低並行消費機率;**順序與唯一性不得依賴 Lease**。本設計以 Redis consumer group、JetStream dedup、sink CAS 作為唯一的 correctness boundary。

---

## 8. 監控 / Production Readiness

| 訊號 | 來源 | 意義 / 門檻 |
|---|---|---|
| **active stream 數(全 cluster 加總)** | 各 pod `GET :4195/streams` | 應恆為 **1**;=0 → 無人收(P1);≥2 → 雙主(短暫可接受,持續則告警) |
| **`input_received` 速率 per pod** | Prometheus(逐 pod) | 應只有一個 pod 非零;多個非零 = 雙主進行中 |
| **Lease holderIdentity / renewTime** | `kubectl get lease -o yaml` | 任一時刻恰一 holder;renewTime 停滯 → 續約異常 |
| **`leaseTransitions` 速率** | Lease spec | 短時間飆高 = leader flapping(常因 `leaseDurationSeconds` 太短或節點抖動) |
| **controller ↔ rpconnect 存活落差** | container restart count + 自寫探針 | controller 掛但 stream 還在 → 殘留消費風險;應連動 Pod 重啟 |
| **fail-closed 動作計數**(POST/DELETE 成功/失敗) | controller 自暴露 metrics | DELETE 失敗率非零 → 殘留消費風險,檢查 §3.2 |
| **stale-reject 率(sink Lua 回 0)** | Redpanda Connect 指標(取 Lua 回傳) | 亂序下非零屬正常;恆為零可能漏帶 version |
| **JetStream `duplicate` PubAck 率** | NATS server / nats CLI | 重送被擋的可見度;突然歸零可能 id 非 deterministic |
| Redis 端實際 consumer 數 | `XINFO CONSUMERS <stream> <group>` | 驗證 source leg 真的只有一個活躍 consumer |
| Redis PEL / JetStream pending | redis_exporter / prometheus-nats-exporter | failover 期間短暫升正常,持續不降 = 卡住 |
| `output_error` / `output_connection_up` | Redpanda Connect Prometheus | sink/transport 健康 |

**兩條核心告警**:
- `sum(active_streams) == 0` 持續 → **管線停擺(最嚴重)**。
- `count(pods where input_received > 0) > 1` 持續 → **雙主未收斂**(短暫可被下層防線吸收,持續代表 fail-closed 失效)。

---

## 9. 版本需求

| 元件 | 最低版本 | 說明 |
|---|---|---|
| Kubernetes `Lease`(`coordination.k8s.io/v1`) | **1.14** | leader election Lease 物件 |
| Native sidecar(可選,§3.3) | **1.28** | init container `restartPolicy: Always` |
| Redpanda Connect streams mode + REST API | 你既有需求已遠高於此 | Benthos 時代既有功能 |
| Redpanda Connect `nats_jetstream` 元件 | **3.46.0** | input/output 引入 |
| Redpanda Connect output header interpolation | **4.1.0** | `Nats-Msg-Id` 動態插值前提 |
| client-go leaderelection | 隨叢集對應的 client-go | **不做 fencing**(設計前提) |

---

## 10. 兩條路線的最終建議

| 路線 | 建議 | active-gating |
|---|---|---|
| **LWW CAS** | 多 consumer;deterministic id + JetStream dedup + sink Lua CAS | **不做** |
| **Strict global ordering** | 方法 A(best-effort)+ `threads:1` + `max_in_flight:1` + deterministic id + sink CAS | 做,但**聲明 best-effort**,不得當硬保證 |
| **純省資源 / 最低維運** | `StatefulSet replicas: 1` + 不 force delete + PDB + graceful termination | 以 `replicas:1` 替代 |
