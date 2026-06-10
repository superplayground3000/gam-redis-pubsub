# General Requirements for all LWW Labs


## Key naming pattern & sharding
1. A server periodically updates KV in central Redis
  - 3 key patterns, generates 3 key for each pattern
  - pattern 1: lb:company:active:{employees:55688}
  - pattern 2: lb:funtions:active:{groups:89889}
  - pattern 3: lb:general:active:{items:9123}

## Key update behavior

- A user is deleted
  - delete user's lb:company:active:{employees:55688}
- A user info is added but not enabled yet
  - set lb:company:standby:{employees:55688}
  - when ready, rename the key, change "standy" into "active"
    - a delete followed by set might do the trick
- A new group/item/employee is added
  - set a new key for new group/item/employee
- All keys are going to be updated from time to time
  - show real time key changes in dashboard

## Other Requirements

- multi writers and they can write to same key
- single redpanda source and sink
- a html report generator which can visualize lab result
- fork from labs/redis-connect-lww-multi-k8s/
- portable helm chart to deploy on different k8s clusters
- binary builds must provide local build scripts
- commandline scripts that provides methods to manually insert msgs, the scripts must just form commands, user need to copy and run output commands manually 
