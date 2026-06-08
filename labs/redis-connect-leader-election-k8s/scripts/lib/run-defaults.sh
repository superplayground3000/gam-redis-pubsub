# Run-window defaults for the leader-election lab (env-overridable).
: "${RATE:=2000}"           # writer msg/s during the proofs
: "${SETTLE_S:=15}"         # wait for a leader to win + consumption to ramp / reconverge
: "${OBS_WINDOW_S:=6}"      # pure steady-state observation window for Proof A
: "${OVERLAP_WAIT_S:=12}"   # how long to keep the leader's elector SIGSTOPped (>= lease + buffer)
: "${GAP_WAIT_S:=12}"       # how long to observe after force-kill (>= lease + buffer)
