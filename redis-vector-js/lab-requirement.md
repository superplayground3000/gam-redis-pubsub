# Redis Stream to Vector to NATS Stream

The goal of this lab is to create a complete set to simulate the architecture of below:
1. A server periodically updates KV in central Redis
  - 3 key patterns, generates 3 key for each pattern
  - pattern 1: lb:company:employees:id:55688
  - pattern 2: lb:funtions:groups:id:89889
  - pattern 3: lb:general:items:id:9123
2. Vector captures changes by central Redis Stream and propogate the content to the NATS JetStream
3. Another Vector listens to JetStream, and propogate changes to region Redis
4. If 3 is not feasible, write a golang to do it

Their must be a visualized way to see realtime changes and propogation delay in region Redis, for demo and validation