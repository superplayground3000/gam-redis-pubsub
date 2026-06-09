# Run-window defaults for the A-vs-C failover comparison (env-overridable).
: "${RATE:=2000}"            # writer msg/s during the run
: "${SETTLE_S:=20}"          # wait for the active consumer + consumption to ramp / reconverge
: "${OBS_WINDOW_S:=6}"       # clean steady-state observation window
: "${FAULT_WAIT_S:=20}"      # observe window after each fault (>= worst-case failover + buffer)
: "${SAMPLE_MS:=100}"        # observer sample interval (keep in sync with values observer.sampleIntervalMs)
: "${METHODS:=A C}"          # which methods to compare
