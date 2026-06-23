{{/*
rrcs.redis.bundled — render the bundled redis-<side> workload (side: "central"
or "region"). Skipped entirely when redis.<side>.external.enabled (clients route
off-cluster via the url/hostPort helpers).

  mode=standalone → single-node Deployment + ClusterIP Service (the default;
                    render is byte-identical to the pre-cluster chart).
  mode=cluster    → minimal 3-master / 0-replica Redis Cluster: a headless
                    Service for stable per-pod DNS, the existing-named ClusterIP
                    Service as the client seed (keeps url/hostPort stable), a
                    3-replica StatefulSet with cluster-enabled redis, and a
                    one-shot cluster-init Job that runs `redis-cli --cluster
                    create` (idempotent — skips if the cluster is already ok).

Usage: {{ include "rrcs.redis.bundled" (dict "root" $ "side" "central") }}
*/}}
{{- define "rrcs.redis.bundled" -}}
{{- $root := .root -}}
{{- $side := .side -}}
{{- $cfg := index $root.Values.redis $side -}}
{{- $app := printf "redis-%s" $side -}}
{{- $fullname := include "rrcs.name" (dict "root" $root "base" $app) -}}
{{- include "rrcs.redis.validateMode" (dict "side" $side "mode" $cfg.mode) -}}
{{- if not $cfg.external.enabled -}}
{{- if eq $cfg.mode "cluster" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $fullname }}-hl
  labels:
    app: {{ $app }}
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: {{ $app }}
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
    - name: cluster-bus
      port: 16379
      targetPort: 16379
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $fullname }}
  labels:
    app: {{ $app }}
spec:
  selector:
    app: {{ $app }}
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ $fullname }}
  labels:
    app: {{ $app }}
spec:
  # Minimal Redis Cluster: 3 masters, 0 replicas (the cluster floor for full
  # slot coverage). Scaling/HA is an explicit non-goal of bundled cluster mode.
  replicas: 3
  serviceName: {{ $fullname }}-hl
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: {{ $app }}
  template:
    metadata:
      labels:
        {{- include "rrcs.podLabels" (dict "root" $root "app" $app) | nindent 8 }}
    spec:
      {{- include "rrcs.imagePullSecrets" $root | nindent 6 }}
      {{- include "rrcs.scheduling" $root | nindent 6 }}
      containers:
        - name: redis
          image: {{ include "rrcs.image" (dict "root" $root "ref" $root.Values.redis.image) }}
          imagePullPolicy: {{ $root.Values.images.pullPolicy }}
          args:
            - redis-server
            - --protected-mode
            - {{ $root.Values.redis.protectedMode | quote }}
            - --notify-keyspace-events
            - ""
            - --appendonly
            - "no"
            - --save
            - ""
            - --cluster-enabled
            - "yes"
            - --cluster-config-file
            - /data/nodes.conf
            - --cluster-node-timeout
            - "5000"
          ports:
            - name: redis
              containerPort: 6379
            - name: cluster-bus
              containerPort: 16379
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            exec:
              command:
                - redis-cli
                - ping
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 15
          livenessProbe:
            exec:
              command:
                - redis-cli
                - ping
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          resources:
            {{- toYaml $root.Values.resources.redis | nindent 12 }}
      # Ephemeral by design: nodes.conf lives in an emptyDir. A pod *delete*
      # wipes cluster identity and is out of scope (fresh-install lab); on
      # helm upgrade the cluster-init hook below reforms the cluster.
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $fullname }}-init
  labels:
    app: {{ $app }}-init
  annotations:
    # Run as a hook so `helm upgrade` re-executes it (a plain Job with an
    # immutable, already-completed pod template would otherwise fail the
    # upgrade). before-hook-creation deletes the prior hook Job first, so each
    # release gets a fresh run; the script exits 0 when the cluster is already
    # formed, and reforms it if an upgrade rolled the (ephemeral) nodes.
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "0"
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  backoffLimit: 20
  template:
    metadata:
      labels:
        {{- include "rrcs.podLabels" (dict "root" $root "app" (printf "%s-init" $app)) | nindent 8 }}
    spec:
      {{- include "rrcs.imagePullSecrets" $root | nindent 6 }}
      {{- include "rrcs.scheduling" $root | nindent 6 }}
      restartPolicy: Never
      containers:
        - name: cluster-init
          image: {{ include "rrcs.image" (dict "root" $root "ref" $root.Values.redis.image) }}
          imagePullPolicy: {{ $root.Values.images.pullPolicy }}
          command:
            - /bin/sh
            - -c
          args:
            - |
              set -eu
              NODES="{{ $fullname }}-0.{{ $fullname }}-hl {{ $fullname }}-1.{{ $fullname }}-hl {{ $fullname }}-2.{{ $fullname }}-hl"
              SEED="{{ $fullname }}-0.{{ $fullname }}-hl"
              # Wait for every node to answer PING (StatefulSet may still be rolling out).
              for n in $NODES; do
                until redis-cli -h "$n" ping 2>/dev/null | grep -q PONG; do
                  echo "waiting for $n"; sleep 1
                done
              done
              # Already healthy? (re-run on helm upgrade with the cluster intact) — done.
              if redis-cli -h "$SEED" cluster info 2>/dev/null | grep -q 'cluster_state:ok'; then
                echo "cluster already formed — nothing to do"; exit 0
              fi
              # Not healthy: first install, OR an upgrade that left the ephemeral
              # nodes in a stale/partial state (some retain old nodes.conf). A bare
              # `--cluster create` would abort with "node is not empty" and FAIL
              # the helm upgrade. Since cluster data is ephemeral, clear any
              # residual state first (flushall must precede reset — CLUSTER RESET
              # refuses on a master holding keys), then (re)form. This makes init
              # converge from any degraded state instead of erroring.
              for n in $NODES; do
                redis-cli -h "$n" flushall 2>/dev/null || true
                redis-cli -h "$n" cluster reset hard 2>/dev/null || true
              done
              SEEDS=""
              for n in $NODES; do SEEDS="$SEEDS $n:6379"; done
              echo "creating cluster:$SEEDS"
              redis-cli --cluster create $SEEDS --cluster-replicas 0 --cluster-yes
{{- else -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $fullname }}
  labels:
    app: {{ $app }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{ $app }}
  template:
    metadata:
      labels:
        {{- include "rrcs.podLabels" (dict "root" $root "app" $app) | nindent 8 }}
    spec:
      {{- include "rrcs.imagePullSecrets" $root | nindent 6 }}
      {{- include "rrcs.scheduling" $root | nindent 6 }}
      containers:
        - name: redis
          image: {{ include "rrcs.image" (dict "root" $root "ref" $root.Values.redis.image) }}
          imagePullPolicy: {{ $root.Values.images.pullPolicy }}
          args:
            - redis-server
            - --protected-mode
            - {{ $root.Values.redis.protectedMode | quote }}
            - --notify-keyspace-events
            - ""
            - --appendonly
            - "no"
            - --save
            - ""
          ports:
            - containerPort: 6379
          readinessProbe:
            exec:
              command:
                - redis-cli
                - ping
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 15
          livenessProbe:
            exec:
              command:
                - redis-cli
                - ping
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          resources:
            {{- toYaml $root.Values.resources.redis | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $fullname }}
  labels:
    app: {{ $app }}
spec:
  selector:
    app: {{ $app }}
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
{{- end }}
{{- end }}
{{- end -}}
