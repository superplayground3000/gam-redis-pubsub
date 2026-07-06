用kind驗證hpdevelop/connect:v4.92.0-batch-nats 能否做到這些事: 
1. 在redis & nats always 正常運行的情況下, 這個版本的connect能確保msg在三個pod以上的情況下並且有leader election,pod force kill的情況下都能保證msg沒有遺漏. 
2. count of msgs that can't be processed is tracked in metrics
