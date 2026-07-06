目標 8000 msg/s，用golang程式generate traffic
測試 sink端的connect with 170-200ms latency (both pull msg and ack msg)的情況下要達到8000 msg/s以上，propose一個工具用來製造latency
測試by key prefix 切 connect pod & topic (pod 群搭配 topic 1:1)
用key的第一個冒號以前的字串當作prefix, 用來創建對應subject name
- prefix-a:foo:bar
- prefix-b:foo:bar
msg generating 先以恆速 8000~10000 msgs/s 作為測試輸入
redpanda connect image 使用 hpdevelop/connect:4.92.0-claudefix 這個版本
based on @chart/ ，測試完後根據真實資料提供visualized report，並且另外寫一份design doc用來在另一個session把chart改成可以支援多subject + connect pod 組合