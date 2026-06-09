# Run-window defaults for the A-vs-C failover comparison (env-overridable).
: "${RATE:=2000}"            # writer msg/s during the run
: "${SETTLE_S:=20}"          # wait for the active consumer + consumption to ramp / reconverge
: "${OBS_WINDOW_S:=6}"       # clean steady-state observation window
: "${FAULT_WAIT_S:=20}"      # observe window after each fault (>= worst-case failover + buffer)
: "${METHODS:=A C}"          # which methods to compare
# SAMPLE_MS (observer sample interval, ms) is NOT defaulted here: the harness derives it
# from the chart's effective observer.sampleIntervalMs at run time so failover_time_s can
# never drift from the observer's real cadence. Export SAMPLE_MS to force an override.
