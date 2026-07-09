// elector: a fail-closed client-go leader-election controller (research Method A, §3.1-3.3).
//
// Default state = NO stream. POST the consuming pipeline only while leading; on any
// uncertainty DELETE or exit so the stream dies with the process. Order/uniqueness must
// NOT depend on this — it is best-effort active-gating, not fencing.
package elector

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/leaderelection"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envDur(k string, def time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
		log.Printf("WARN: %s=%q not a duration, using %s", k, os.Getenv(k), def)
	}
	return def
}

func Run(args []string) {
	var (
		podName     = env("POD_NAME", "")
		namespace   = env("LEASE_NAMESPACE", "default")
		leaseName   = env("LEASE_NAME", "connect-elector")
		connectAddr = env("CONNECT_ADDR", "http://localhost:4195")
		streamID    = env("STREAM_ID", "source_leg")
		pipePath    = env("PIPELINE_PATH", "/etc/elector/pipeline.yaml")
		healthAddr  = env("HEALTH_ADDR", ":8090")
		leaseDur    = envDur("LEASE_DURATION", 6*time.Second)
		renewDl     = envDur("RENEW_DEADLINE", 4*time.Second)
		retryPd     = envDur("RETRY_PERIOD", 1*time.Second)
		postDelay   = envDur("POST_DELAY", 0)
	)
	if podName == "" {
		log.Fatal("POD_NAME is required (downward API)")
	}

	raw, err := os.ReadFile(pipePath)
	if err != nil {
		log.Fatalf("read pipeline %s: %v", pipePath, err)
	}
	pipelineYAML := renderPipeline(string(raw), podName)

	sc := newStreamsClient(connectAddr)

	var (
		leading       atomic.Int32
		postOK, postE atomic.Int64
		delOK, delE   atomic.Int64
		postAbort     atomic.Int64
	)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		writeMetric(w, "elector_leading", float64(leading.Load()))
		writeMetric(w, "elector_post_total{result=\"ok\"}", float64(postOK.Load()))
		writeMetric(w, "elector_post_total{result=\"err\"}", float64(postE.Load()))
		writeMetric(w, "elector_post_total{result=\"aborted_before_post\"}", float64(postAbort.Load()))
		writeMetric(w, "elector_delete_total{result=\"ok\"}", float64(delOK.Load()))
		writeMetric(w, "elector_delete_total{result=\"err\"}", float64(delE.Load()))
	})
	ln, err := net.Listen("tcp", healthAddr)
	if err != nil {
		log.Fatalf("health server listen %s: %v", healthAddr, err)
	}
	go func() {
		log.Printf("elector health/metrics on %s", healthAddr)
		if err := http.Serve(ln, mux); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("health server: %v", err)
		}
	}()

	cfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("in-cluster config: %v", err)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("k8s client: %v", err)
	}

	// FAIL-CLOSED BOOT: ensure no residual stream before joining election. The generous
	// timeout tolerates the connect sidecar still warming up; on genuine failure we exit
	// so kubelet restarts us rather than entering election in an unknown state.
	bootCtx, bootCancel := context.WithTimeout(context.Background(), 45*time.Second)
	if err := retry(bootCtx, 40, retryPd, func() error { return sc.delete(bootCtx, streamID) }); err != nil {
		bootCancel()
		log.Fatalf("boot DELETE failed (%v) -> exiting fail-closed; kubelet will restart", err)
	}
	bootCancel()
	log.Printf("boot: ensured no local stream; entering election as %q", podName)

	lock := &resourcelock.LeaseLock{
		LeaseMeta:  metav1.ObjectMeta{Name: leaseName, Namespace: namespace},
		Client:     client.CoordinationV1(),
		LockConfig: resourcelock.ResourceLockConfig{Identity: podName},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
		Lock:            lock,
		ReleaseOnCancel: true,
		LeaseDuration:   leaseDur,
		RenewDeadline:   renewDl,
		RetryPeriod:     retryPd,
		Callbacks: leaderelection.LeaderCallbacks{
			OnStartedLeading: func(c context.Context) {
				if postDelay > 0 {
					log.Printf("OnStartedLeading: won lease; delaying POST of %q by %s so the previous leader's un-acked deliveries pass their ackWait", streamID, postDelay)
					if !waitPostDelay(c, postDelay) {
						postAbort.Add(1)
						log.Printf("leadership lost during POST delay -> staying fail-closed (no POST)")
						return
					}
				}
				log.Printf("OnStartedLeading: POST stream %q", streamID)
				if err := retry(c, 10, retryPd, func() error { return sc.post(c, streamID, pipelineYAML) }); err != nil {
					postE.Add(1)
					log.Printf("POST kept failing (%v) -> releasing leadership, staying fail-closed", err)
					cancel()
					return
				}
				postOK.Add(1)
				leading.Store(1)
			},
			OnStoppedLeading: func() {
				leading.Store(0)
				log.Printf("OnStoppedLeading: DELETE stream %q", streamID)
				dc, dcl := context.WithTimeout(context.Background(), 8*time.Second)
				defer dcl()
				if err := retry(dc, 8, retryPd, func() error { return sc.delete(dc, streamID) }); err != nil {
					delE.Add(1)
					log.Printf("DELETE kept failing (%v) -> os.Exit(1) so kubelet restarts the pod and the stream dies with it", err)
					os.Exit(1)
				}
				delOK.Add(1)
			},
			OnNewLeader: func(id string) {
				if id != podName {
					log.Printf("new leader: %s", id)
				}
			},
		},
	})
	log.Printf("election loop exited; bye")
}

func writeMetric(w http.ResponseWriter, name string, v float64) {
	_, _ = w.Write([]byte(name + " " + strconv.FormatFloat(v, 'f', -1, 64) + "\n"))
}

// waitPostDelay blocks for d (the post-election settle delay) unless the
// leadership context is cancelled first. false = lost leadership mid-wait:
// the caller must return without POSTing (fail-closed).
func waitPostDelay(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return true
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
