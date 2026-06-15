整理 repo, 在根目錄創建一個folder,裡面專門來維護 redpanda connect chart, 

- 以 labs/no-lww-simple-cdc 為base, 加上 labs/redis-connect-leader-election-k8s 的 k8s lease leader election機制, 
- redis template要預設加上 --protected-mode "no", 
- redpanda 要預設為pull consumer mode, 
- 要建立role grant權限給 leader elector, 才能做election
- pull consumer mode會需要提前建立好consumer, 提供command腳本建立 consumer
- 用縮排表示yaml,不要用大括號 

