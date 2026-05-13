# Redis Fan-out Validation Stack

驗證「central Redis → N 個獨立 edge Redis 」event-driven 資料同步架構的最小可運行環境。
A minimal but realistic stack to validate central → N edge Redis event-driven data sync.

---

## 1. Pub/Sub vs Streams — 你該用哪個?

| 特性 Feature           | `PUBLISH/SUBSCRIBE`              | `XADD/XREADGROUP` (Streams)        |
| ---------------------- | -------------------------------- | ---------------------------------- |
| 持久化 Persistence     | ❌ fire-and-forget                | ✅ append-only log                  |
| 訂閱者離線 Offline sub | 訊息直接丟失 lost                | 上線後可繼續消費 catch-up          |
| ACK / 重試 Retry       | ❌                                | ✅ XACK + XPENDING                  |
| Consumer group         | ❌                                | ✅ 多 consumer 分片消費             |
| Replay 重播            | ❌                                | ✅ 從任意 offset 重讀               |
| 延遲 Latency           | 最低                             | 微高一些(寫 AOF + ack overhead)  |
| 適用 Use case          | cache invalidate、即時通知       | **資料同步、event sourcing、ETL**  |

**結論**:你的場景(central → N clusters 同步資料)**必須用 Streams**。Pub/Sub 在 relay 重啟、edge 短暫 down、網路抖動的情況下會直接掉資料。本 stack 預設使用 Streams,relay.py 底部保留 pub/sub 變體供對照。

---

## 2. 架構元件 Components

```
loadgen ─XADD→ redis-central [Stream: events] ─XREADGROUP→ relay ─pipeline→ redis-edge-{1,2,3}
                                                                            ↑
                                                            validator ──────┘
```

- **redis-central**: 寫入端,持有 `events` Stream
- **redis-edge-{1,2,3}**: 三個獨立 Redis 實例,代表 N 個 edge clusters
- **relay**: 用 consumer group 從 central 拉事件,pipeline fan-out 到每個 edge,XACK
- **loadgen**: pipelined XADD 產生負載
- **validator**: 等所有 edge `DBSIZE` 達標 + 隨機抽樣比對值

---

## 3. 起動 Quickstart

```bash
docker compose up -d redis-central redis-edge-1 redis-edge-2 redis-edge-3 relay
docker compose logs -f relay
```

各 Redis 對外 port:
- central: `6380`
- edge-1: `6381` / edge-2: `6382` / edge-3: `6383`

可用 `redis-cli -p 6380` 從 host 連入觀察。

---

## 4. 分量級驗證 Tiered validation

```bash
./scripts/run-tier.sh smoke    # 1 萬筆 — 約數秒
./scripts/run-tier.sh stress   # 10 萬筆 — 數十秒
./scripts/run-tier.sh scale    # 100 萬筆 — 數分鐘
```

每個 tier 會自動:
1. 啟動 stack
2. `FLUSHALL` 所有 edge + 清空 central stream(乾淨起點)
3. 重啟 relay
4. 用 loadgen 推 N 筆事件
5. validator 等收斂並抽樣比對

### 預期觀察指標 What to look at

| 量級       | 預期 loadgen 速率        | 預期收斂時間          | 注意點                                  |
| ---------- | ------------------------ | --------------------- | --------------------------------------- |
| 1 萬       | ~50k–100k/s              | < 5s                  | 純粹確認 pipeline 正確                  |
| 10 萬      | ~50k–100k/s              | 10–30s                | relay 是否單核飽和?觀察 CPU            |
| 100 萬     | ~50k–100k/s 持續         | 1–5 分鐘              | 記憶體:central stream 約 200–400 MB    |

對 1M 量級,實測時請 `docker stats` 觀察 relay 容器 CPU,若單核打滿就是 relay 已成 bottleneck,水平擴(下方第 6 節)。

---

## 5. 故意製造失敗來驗證可靠性 Failure injection

驗證 Streams 真的不丟資料:

```bash
# 在 loadgen 進行到一半時殺掉 relay
docker compose --profile tools run --rm loadgen python loadgen.py --count 100000 &
sleep 2
docker compose kill relay
sleep 5
docker compose up -d relay
# 之後跑 validator 應該還是 100,000 筆全部到齊
```

對比:把 relay 改成 pub/sub 模式做同樣實驗,validator 一定會 timeout 或回報 count 不足。

其他可測情境:
- `docker compose stop redis-edge-2` 然後寫入,啟回後該 edge 仍會 catch up(因為 relay 會重試直到 pipeline 成功)
- 用 `redis-cli -p 6380 XLEN events` 觀察 stream 長度
- 用 `XPENDING events relay-group` 看有沒有未 ack 的事件堆積

---

## 6. 擴展到真正的 cluster mode

目前每個 "cluster" 是單節點。要切到真 Redis Cluster:

**每個 edge 改為 3 master + 3 replica**

關鍵調整:
- image 啟用 `--cluster-enabled yes --cluster-config-file nodes.conf`
- 6 個容器 + 用 `redis-cli --cluster create` 一次性 bootstrap
- relay 端的 client 換成 `RedisCluster.from_url(...)` 而不是 `Redis.from_url(...)`(`redis-py` 內建支援)
- 注意 cluster mode 下 pipeline 必須同 hash slot,跨 slot 寫入需用 `cluster_pipeline` 或自行 group by slot

通常 edge cluster 升級到 cluster mode 比 central 重要(讀寫擴展性),central 可以維持 sentinel 即可(寫入單點瓶頸由 stream 自然消化)。

**水平擴 relay**:在 docker-compose 加 `relay-2`、`relay-3`,共用同一個 `CONSUMER_GROUP=relay-group`,Redis 會自動把 stream entries 分給不同 consumer。讓總 fan-out 吞吐線性提升。

---

## 7. 進階觀察 Useful redis-cli queries

```bash
# 看 stream 長度
docker exec rf-central redis-cli XLEN events

# 看 consumer group 進度
docker exec rf-central redis-cli XINFO GROUPS events

# 看是否有未 ack 的 pending entries
docker exec rf-central redis-cli XPENDING events relay-group

# 看 keyspace notification(pub/sub 變體用)
docker exec rf-central redis-cli PSUBSCRIBE '__keyevent@0__:*'
```

---

## 8. 已知限制 Limitations

- 單一 relay 是 SPOF;production 必須水平擴 + 健康檢查
- Stream 沒有自動 trim,長跑會吃記憶體 → loadgen 已有 `--trim` 參數,production 用 `XADD ... MAXLEN ~ 1000000`
- 沒有處理 schema evolution、事件去重、跨 region 延遲
- Edge 是 standalone,未驗證真 cluster mode 的 slot 路由行為(見第 6 節)
