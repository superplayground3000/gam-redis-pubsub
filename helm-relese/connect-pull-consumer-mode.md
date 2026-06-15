# NATS JetStream — 刪除 Consumer 與權限確認(creds 認證)參考

> 適用情境:用 **creds file(JWT-based 去中心化授權)** 認證,需要從 command line 刪除 JetStream consumer,並在動手前確認自己有刪除權限。
> 所有指令與 subject 均經官方來源(natscli DeepWiki、NATS JetStream wire API、nsc 範例)確認。

---

## TL;DR — 快速指令

```bash
# 1) 建議先把 creds 存成 context,後續不用每次帶旗標
nats context save kv-admin \
  --creds /path/to/user.creds \
  --server nats://nats-1:4222
nats context select kv-admin

# 2) 刪除 consumer(--force 跳過 y/n 確認,適合腳本/CI)
nats consumer rm <STREAM> <CONSUMER> --force

# 例:
nats consumer rm APP_EVENTS kv_sink_p0 --force
```

- 指令:`nats consumer rm STREAM CONSUMER`
- `rm` 別名:`delete` / `del`;`consumer` 別名:`con` / `c`
- 不帶 context 時等同:`nats --creds /path/to/user.creds -s nats://nats-1:4222 consumer rm STREAM CONSUMER`

---

## 刪除 consumer 需要的權限

JetStream 的管理操作是「對特定 `$JS.API.*` subject 發 request / 收 reply」。刪 consumer 需要:

| 動作 | 權限類型 | Subject |
|---|---|---|
| 刪除 consumer | **publish** | `$JS.API.CONSUMER.DELETE.<stream>.<consumer>` |
| 收取刪除結果 | **subscribe** | `_INBOX.>` |
| (順帶)查 consumer | publish | `$JS.API.CONSUMER.INFO.<stream>.<consumer>` |

你的 user JWT 只要 `pub.allow` 有以下**任一**能涵蓋目標、且未被 `pub.deny` 擋掉即可:

```
$JS.API.CONSUMER.DELETE.<stream>.<consumer>   # 精確
$JS.API.CONSUMER.DELETE.*.*                    # 常見寫法
$JS.API.CONSUMER.>
$JS.API.>
$JS.>
```

並且 `sub.allow` 要含 `_INBOX.>`。

> ⚠️ 限制:consumer DELETE 的授權**無法用 subject filter 細分**(不像 CREATE 可到 `.filter` 層),最細只能到 `<stream>.<consumer>`。

---

## 如何確認「我有刪除權限」

三種方法,由靜態(不會誤刪)到動態:

### 方法 A — 解碼 user JWT 直接看(最確定)

```bash
# 從 creds 抽出 user JWT
JWT=$(sed -n '/-----BEGIN NATS USER JWT-----/{n;p}' /path/to/user.creds)

# 解碼 JWT payload,印出 nats 權限區塊
echo "$JWT" | cut -d. -f2 | python3 -c \
"import sys,base64,json; s=sys.stdin.read().strip(); s+='='*(-len(s)%4); \
print(json.dumps(json.loads(base64.urlsafe_b64decode(s)).get('nats',{}), indent=2))"
```

判讀輸出:
- `pub.allow` 要能涵蓋 `$JS.API.CONSUMER.DELETE.<stream>.<consumer>`,且 `pub.deny` 沒擋到。
- `sub.allow` 要有 `_INBOX.>`。
- **若整份 JWT 沒有 `pub`/`sub` 限制區塊 → 預設 allow-all,代表你有完整權限。**

### 方法 B — 用 nsc(帳號由 nsc 管理時)

```bash
nsc describe user <user_name>   # 表格列出 Pub Allow / Sub Allow
```

### 方法 C — 直接試 + 看錯誤(動態)

刪除是破壞性操作、**不能 dry-run**。可先用唯讀的 INFO 當煙霧測試(注意 INFO 與 DELETE 是不同 verb,過了不保證能刪):

```bash
nats consumer info <STREAM> <CONSUMER>   # 需要 CONSUMER.INFO 的 pub 權限
```

真正執行 `consumer rm` 時若無權限,會是 **permissions violation** 或 JS API request **timeout**(視伺服器設定),而不是「consumer 不存在」。見下方對照表。

---

## 錯誤對照(troubleshooting)

| 現象 | 最可能原因 | 處置 |
|---|---|---|
| `Permissions Violation for Publication to "$JS.API.CONSUMER.DELETE..."` | user JWT 缺 pub 權限 | 補 `--allow-pub '$JS.API.CONSUMER.DELETE.*.*'` 後重簽 user |
| request 無回覆 / timeout | 缺 pub 權限(被靜默丟棄)或缺 `_INBOX.>` sub 權限 | 同上,並確認 `--allow-sub '_INBOX.>'` |
| `consumer not found` | consumer 名稱錯、stream 錯,或已被刪 | `nats consumer ls <STREAM>` 確認名稱 |
| JetStream 相關 API 全部失敗 | 該 **account 未啟用 JetStream** | 啟用 account 的 JetStream 限額 |
| subject 對不上(有 domain) | 用了 JetStream **domain** 前綴 | CLI 加 `--js-domain <domain>`;授權改 `$JS.<domain>.API.CONSUMER.DELETE.*.*` |

---

## 給本專案(Redis→rpconnect→NATS JS→Redis KV)的注意事項

- 被 Redpanda Connect 以 `bind: true` 綁定的 durable **pull** consumer(例:`kv_sink_p0`),刪掉後該 `nats_jetstream` input 重連時會報 `consumer ... does not exist for bind mode`。
- 要重建時,**所有 consumer 參數必須在伺服器端建立時指定**(pull 模式下 input YAML 的 `ack_wait` / `max_ack_pending` / `deliver` 會被忽略):

  ```bash
  nats consumer add APP_EVENTS kv_sink_p0 \
    --pull \
    --filter 'app.events.p0' \
    --ack explicit \
    --max-pending 1 \
    --wait 30s \
    --deliver all \
    --max-deliver=-1
  ```

- 重建完成後,讓 Redpanda Connect instance 重連即可自動 re-bind。

---

## Redpanda Connect config 範例(bind 到 pull consumer)

> 重點:Redpanda Connect 的 `nats_jetstream` input **不會幫你建立 pull consumer**。
> 它只在 `bind: true` + `stream` + `durable` 且該 consumer 在伺服器端是 pull(無 DeliverSubject)時,才走 `PullSubscribe`。
> 因此 consumer 必須先用前面的 `nats consumer add ... --pull` 建好。
> 版本下限:input 支援 pull consumer 自 **Redpanda Connect / Benthos 4.0.0**(元件本身自 3.46.0)。

### Sink 階段:NATS JetStream(pull)→ Redis KV(LWW CAS)

```yaml
# kv-sink-p0.yaml
input:
  label: js_source_p0
  nats_jetstream:
    urls: [ nats://nats-1:4222, nats://nats-2:4222, nats://nats-3:4222 ]
    stream: APP_EVENTS
    durable: kv_sink_p0          # 必須是「已存在」的 pull consumer
    bind: true                   # ★ 缺這個只會變成 durable PUSH,不是 pull
    # subject: 可省略;bind 時會自動從 consumer 的 FilterSubject 帶出
    auth:
      user_credentials_file: /run/secrets/nats.creds   # 與本文件權限確認用的同一份 creds
    # ⚠️ pull(bind)模式下,下列 YAML 欄位會被忽略,一律以伺服器端 consumer 設定為準:
    #     ack_wait / max_ack_pending / deliver
    #     要改這些 → 改 `nats consumer add/edit`,不是改這裡

pipeline:
  threads: 1                     # 嚴格排序分區:單執行緒;LWW CAS 變體可調高並行
  processors:
    - mapping: |
        meta kv_key  = meta("kv_key")
        meta version = meta("version")
        meta op      = meta("op")

output:
  label: redis_kv_sink
  redis_script:                  # sink 端原子 LWW CAS fence(version 比較後才套用)
    url: redis://redis.internal:6379
    command: EVALSHA
    # 載入你的 LWW CAS Lua;KEYS[1]=kv_key,ARGV=val/ver/op/now
    args_mapping: |
      root = [ meta("kv_key") ]    # KEYS
      root = root.concat([ content().string(), meta("version"), meta("op"), now().ts_unix() ])  # ARGV
    max_in_flight: 1             # 嚴格排序;LWW CAS 變體可放大

metrics:
  prometheus:
    use_histogram_timing: true
```

### 多 instance 共享同一 pull consumer(水平擴展 / HA)

pull consumer 的優勢:**多個 instance 可同時 `bind: true` 綁到同一個 durable**,NATS 會把 pull 請求在它們之間負載平衡,**不需要 queue group**,也避開 push+queue+durable 的
`cannot create a queue subscription for a consumer without a deliver group` 經典錯誤。

```yaml
# 每個 pod 用同一份 input 設定即可(stream + durable 相同),不必設 client_id / queue
input:
  nats_jetstream:
    urls: [ nats://nats-1:4222, nats://nats-2:4222, nats://nats-3:4222 ]
    stream: APP_EVENTS
    durable: kv_sink_shared
    bind: true
    auth:
      user_credentials_file: /run/secrets/nats.creds
```

> 嚴格排序需求請改用 per-partition 各自的 durable(`kv_sink_p0` / `kv_sink_p1` …)
> 並各自 `--filter` 到對應 subject + `--max-pending 1`;此時每分區單一 instance。

### 對應的 consumer 重建指令(與上面 config 配套)

```bash
nats consumer add APP_EVENTS kv_sink_p0 \
  --pull --filter 'app.events.p0' \
  --ack explicit --max-pending 1 --wait 30s \
  --deliver all --max-deliver=-1
```

### pull consumer 的 production 監控(配合本 config)

| 訊號 | 來源 | 門檻 / 意義 |
|---|---|---|
| `num_pending` | `nats consumer info` / `jetstream_consumer_num_pending` | 積壓 = 管線 lag;持續升 → sink 跟不上 |
| `num_ack_pending` | 同上 / `jetstream_consumer_num_ack_pending` | 應 ≤ 伺服器端 `--max-pending`;貼上限 → sink 是瓶頸 |
| `num_redelivered` | `jetstream_consumer_num_redelivered` | 上升 → `ack_wait` 到期(sink 太慢/crash) |
| `num_waiting` | `nats consumer info` | pull 特有:目前掛著的 pull 請求數;掉 0 = 沒 instance 在抓 |
| `input_received` / `input_connection_up` | Redpanda Connect Prometheus(:4195) | 歸零但 JS 有 pending = input 卡住 |

---

## 來源

- 刪除指令 / `--force`:natscli Consumer Management(`cli/consumer_command.go`)
- DELETE subject 與 `_INBOX.>` 授權:NATS JetStream wire API Reference;nsc `--allow-pub '$JS.API.CONSUMER.DELETE.*.*'` 官方範例
- DELETE 無法用 filter 細分:nats-server issue #4155
