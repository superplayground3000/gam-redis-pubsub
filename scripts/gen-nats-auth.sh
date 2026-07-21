#!/usr/bin/env bash
# Mints the lab's operator/account/user JWTs + creds files via nsc.
# Output lands in chart/files/nats-auth/ (committed lab fixtures).
# Re-runnable; refuses to overwrite without --force.
#
# Env overrides (defaults match chart/values.yaml):
#   STREAM_NAME=APP_EVENTS        DURABLE_NAME=region-writer
#   SUBJECT_PREFIX=app.events     (publisher --allow-pub is "<prefix>.>")
#   DLQ_SEGMENT (default: connect.deadLetter.segment in values.yaml, else empty)
#                                 In-prefix DLQ mode: when non-empty the ACTIVE DLQ
#                                 root becomes "<SUBJECT_PREFIX>.<DLQ_SEGMENT>"
#                                 (mirrors the rrcs.nats.dlqRoot chart helper).
#   DLQ_SUBJECT (default: mode-aware — <SUBJECT_PREFIX>.<DLQ_SEGMENT> when DLQ_SEGMENT
#                is set, else connect.deadLetter.subject in values.yaml, else dlq.cdc)
#   OPERATOR_NAME=RRCS-OP         ACCOUNT_NAME=APP
#
# The subscriber is granted DLQ pub on a SUPERSET of BOTH layouts — the legacy
# out-of-prefix root (dlq.cdc.>) AND the in-prefix root (<SUBJECT_PREFIX>.dlq.>) —
# so ONE committed creds set serves legacy and segment-mode installs alike. Only the
# sink ever publishes DLQ, so the extra grant is harmless (design §5).
#
# --dry-run: print the resolved stream/subject/DLQ config (including the computed
#            DLQ_SUBJECT and the superset DLQ pub grants) and exit WITHOUT invoking
#            nsc — use it to confirm mode resolution before minting creds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1;;
    --dry-run) DRY_RUN=1;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

OUT="chart/files/nats-auth"
NSC_STORE_DIR="${OUT}/.nsc-store"
# Resolve from chart/values.yaml unless an explicit env var overrides.
# Fall back to built-in defaults only if values.yaml is missing or unparseable.
parse_values() {
  local key="$1" default="$2"
  if [[ -f chart/values.yaml ]]; then
    # awk walks the YAML hierarchy under `nats:` (or `connect:`) to find the
    # requested key. `key` is one of: nats.stream.name, nats.stream.subjectPrefix,
    # nats.stream.consumer.durable, connect.deadLetter.subject
    local val
    case "$key" in
      nats.stream.name)
        # shellcheck disable=SC2016
        # SC2016: awk program is single-quoted intentionally — $0/etc are awk
        # field refs, not shell variables.
        val="$(awk '
          /^nats:/{in_nats=1; next}
          /^[a-zA-Z]/{in_nats=0}
          in_nats && /^  stream:/{in_stream=1; next}
          in_nats && /^  [a-zA-Z]/{in_stream=0}
          in_stream && /^    name:/{
            gsub(/^    name:[[:space:]]*/,"")
            gsub(/^"|"$/,"")
            print
            exit
          }
        ' chart/values.yaml)"
        ;;
      nats.stream.subjectPrefix)
        # shellcheck disable=SC2016
        val="$(awk '
          /^nats:/{in_nats=1; next}
          /^[a-zA-Z]/{in_nats=0}
          in_nats && /^  stream:/{in_stream=1; next}
          in_nats && /^  [a-zA-Z]/{in_stream=0}
          in_stream && /^    subjectPrefix:/{
            gsub(/^    subjectPrefix:[[:space:]]*/,"")
            gsub(/^"|"$/,"")
            print
            exit
          }
        ' chart/values.yaml)"
        ;;
      nats.stream.consumer.durable)
        # shellcheck disable=SC2016
        # SC2016: awk program is single-quoted intentionally — $0/etc are awk
        # field refs, not shell variables.
        val="$(awk '
          /^nats:/{in_nats=1; next}
          /^[a-zA-Z]/{in_nats=0}
          in_nats && /^  stream:/{in_stream=1; next}
          in_nats && /^  [a-zA-Z]/{in_stream=0}
          in_stream && /^    consumer:/{in_consumer=1; next}
          in_stream && /^    [a-zA-Z]/{in_consumer=0}
          in_consumer && /^      durable:/{
            gsub(/^      durable:[[:space:]]*/,"")
            gsub(/^"|"$/,"")
            print
            exit
          }
        ' chart/values.yaml)"
        ;;
      connect.deadLetter.subject)
        # shellcheck disable=SC2016
        # SC2016: awk program is single-quoted intentionally — $0/etc are awk
        # field refs, not shell variables.
        val="$(awk '
          /^connect:/{in_connect=1; next}
          /^[a-zA-Z]/{in_connect=0}
          in_connect && /^  deadLetter:/{in_dlq=1; next}
          in_connect && /^  [a-zA-Z]/{in_dlq=0}
          in_dlq && /^    subject:/{
            gsub(/^    subject:[[:space:]]*/,"")
            gsub(/[[:space:]]*#.*$/,"")
            gsub(/^"|"$/,"")
            print
            exit
          }
        ' chart/values.yaml)"
        ;;
      connect.deadLetter.segment)
        # In-prefix DLQ segment (opt-in; default empty = legacy out-of-prefix mode).
        # Mirrors the rrcs.nats.dlqRoot helper's segment lookup so the creds this
        # script mints stay in sync with the chart's computed DLQ root.
        # shellcheck disable=SC2016
        # SC2016: awk program is single-quoted intentionally — $0/etc are awk
        # field refs, not shell variables.
        val="$(awk '
          /^connect:/{in_connect=1; next}
          /^[a-zA-Z]/{in_connect=0}
          in_connect && /^  deadLetter:/{in_dlq=1; next}
          in_connect && /^  [a-zA-Z]/{in_dlq=0}
          in_dlq && /^    segment:/{
            gsub(/^    segment:[[:space:]]*/,"")
            gsub(/[[:space:]]*#.*$/,"")
            gsub(/^"|"$/,"")
            print
            exit
          }
        ' chart/values.yaml)"
        ;;
    esac
    [[ -n "$val" ]] && { echo "$val"; return; }
  fi
  echo "$default"
}

STREAM_NAME="${STREAM_NAME:-$(parse_values nats.stream.name APP_EVENTS)}"
SUBJECT_PREFIX="${SUBJECT_PREFIX:-$(parse_values nats.stream.subjectPrefix app.events)}"
DURABLE_NAME="${DURABLE_NAME:-$(parse_values nats.stream.consumer.durable region-writer)}"
# DLQ root subject, mode-aware — mirrors the rrcs.nats.dlqRoot chart helper so the
# creds this script mints can never disagree with the pipeline's park subject:
#   - LEGACY  (connect.deadLetter.segment empty):  connect.deadLetter.subject (dlq.cdc)
#   - IN-PREFIX (segment set):  <SUBJECT_PREFIX>.<segment>  (e.g. kv.cdc.dlq)
# Precedence for each input stays env override > values.yaml > built-in default.
DLQ_LEGACY_SUBJECT="${DLQ_LEGACY_SUBJECT:-$(parse_values connect.deadLetter.subject dlq.cdc)}"
DLQ_SEGMENT="${DLQ_SEGMENT:-$(parse_values connect.deadLetter.segment "")}"
if [[ -n "${DLQ_SEGMENT}" ]]; then
  DLQ_SUBJECT="${DLQ_SUBJECT:-${SUBJECT_PREFIX}.${DLQ_SEGMENT}}"
else
  DLQ_SUBJECT="${DLQ_SUBJECT:-${DLQ_LEGACY_SUBJECT}}"
fi

# Superset DLQ pub grants for the subscriber. The sink publishes permanently-
# unprocessable messages to "<root>.<reason>" using these SAME subscriber creds
# (there is no separate DLQ-publisher identity). To let ONE committed creds set
# serve BOTH layouts (kind e2e always fresh-installs), grant pub on the union of:
#   - the legacy out-of-prefix root   (dlq.cdc.>)
#   - the in-prefix root              (<SUBJECT_PREFIX>.<segment>.> — segment defaults
#                                      to "dlq" for grant purposes even when the chart
#                                      default leaves it empty)
#   - the ACTIVE root                 (covers a custom DLQ_SUBJECT/DLQ_SEGMENT override)
# Only the sink publishes DLQ, so the broader-than-active grant is harmless (design §5).
DLQ_INPREFIX_SUBJECT="${SUBJECT_PREFIX}.${DLQ_SEGMENT:-dlq}"
declare -a DLQ_PUB_SUBTREES=()
add_dlq_subtree() {
  local subtree="$1.>" existing
  for existing in ${DLQ_PUB_SUBTREES[@]+"${DLQ_PUB_SUBTREES[@]}"}; do
    [[ "$existing" == "$subtree" ]] && return 0
  done
  DLQ_PUB_SUBTREES+=("$subtree")
}
add_dlq_subtree "${DLQ_LEGACY_SUBJECT}"
add_dlq_subtree "${DLQ_INPREFIX_SUBJECT}"
add_dlq_subtree "${DLQ_SUBJECT}"

OPERATOR_NAME="${OPERATOR_NAME:-RRCS-OP}"
ACCOUNT_NAME="${ACCOUNT_NAME:-APP}"

if (( DRY_RUN )); then
  echo "[dry-run] resolved config (no nsc invoked):"
  echo "  STREAM_NAME          = ${STREAM_NAME}"
  echo "  SUBJECT_PREFIX       = ${SUBJECT_PREFIX}   (publisher --allow-pub ${SUBJECT_PREFIX}.>)"
  echo "  DURABLE_NAME         = ${DURABLE_NAME}"
  echo "  DLQ_SEGMENT          = ${DLQ_SEGMENT:-<empty> (legacy out-of-prefix mode)}"
  echo "  DLQ_LEGACY_SUBJECT   = ${DLQ_LEGACY_SUBJECT}"
  echo "  DLQ_INPREFIX_SUBJECT = ${DLQ_INPREFIX_SUBJECT}"
  echo "  DLQ_SUBJECT (active) = ${DLQ_SUBJECT}"
  echo "  subscriber DLQ pub grants (superset):"
  for subtree in "${DLQ_PUB_SUBTREES[@]}"; do
    echo "    --allow-pub ${subtree}"
  done
  exit 0
fi

if [[ -f "${OUT}/operator.jwt" && "${FORCE}" -ne 1 ]]; then
  echo "error: ${OUT}/ already populated. Pass --force to regenerate." >&2
  exit 1
fi

# Isolate nsc state fully under the lab dir; do NOT touch the user's global nsc store.
# XDG_DATA_HOME controls the nsc stores + keys root (modern nsc 2.x).
# XDG_CONFIG_HOME controls the nsc config root.
export XDG_DATA_HOME="${PWD}/${NSC_STORE_DIR}/data"
export XDG_CONFIG_HOME="${PWD}/${NSC_STORE_DIR}/config"
mkdir -p "${OUT}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}"

if (( FORCE )); then
  # Wipe both the isolated nsc state AND any previously-emitted artifacts in OUT.
  # nsc generate config refuses to overwrite, so we must clear it on --force.
  rm -rf "${NSC_STORE_DIR}"
  rm -f "${OUT}"/*.jwt "${OUT}"/*.creds "${OUT}"/nats-server.conf "${OUT}"/README.md
  mkdir -p "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}"
fi

echo "[gen] operator ${OPERATOR_NAME}"
nsc add operator --name "${OPERATOR_NAME}" >/dev/null

# A NATS server running with operator-trust + JetStream REQUIRES a system
# account for its internal JS subscriptions. Add SYS and designate it on
# the operator JWT; `nsc generate config --mem-resolver` then includes SYS
# in the resolver_preload automatically.
echo "[gen] system account SYS"
nsc add account --name SYS >/dev/null
nsc edit operator --system-account SYS >/dev/null

echo "[gen] account ${ACCOUNT_NAME} (JetStream enabled, unlimited)"
nsc add account --name "${ACCOUNT_NAME}" >/dev/null
nsc edit account --name "${ACCOUNT_NAME}" \
  --js-streams -1 --js-consumer -1 \
  --js-mem-storage -1 --js-disk-storage -1 >/dev/null

echo "[gen] user publisher (allow-pub ${SUBJECT_PREFIX}.>)"
nsc add user --account "${ACCOUNT_NAME}" --name publisher \
  --allow-pub "${SUBJECT_PREFIX}.>" \
  --allow-pub '$JS.API.STREAM.INFO.'"${STREAM_NAME}" \
  --allow-sub '_INBOX.>' >/dev/null

echo "[gen] user subscriber"
# The sink (cdc-reverse) binds to server-side PULL consumers (bind:true), so it
# must ACK and publish pull requests ($JS.API.CONSUMER.MSG.NEXT / INFO) for the
# durable(s) it binds. Multi-subject support (design D3) splits the sink into N
# per-group durables named cdc_sink / cdc_sink_<group>, so the grant is scoped to
# ANY consumer on the stream via the single-token wildcard '*' (one token = the
# durable name) rather than the exact DURABLE_NAME.
#
# SECURITY TRADE-OFF (design §5.3): this is strictly BROADER — the subscriber can
# INFO / MSG.NEXT / ACK any consumer on ${STREAM_NAME}. Acceptable for this
# single-tenant CDC stream (every consumer belongs to the same sink role). For a
# SHARED / multi-tenant stream, prefer an enumerated per-group grant or a
# per-group creds user (one file per durable) so one group cannot pull another's.
#
# CONSUMER.*CREATE.* are dropped: in pull/bind mode the sink never CREATES a
# consumer — the nats-init Job (admin creds) provisions them. bind:true only
# attaches. (Re-add them here if you ever run a non-bind/push sink.)
#
# DLQ (design §4.4, §5): the sink also publishes permanently-unprocessable
# messages to "<root>.<reason>" using these SAME subscriber creds (there is no
# separate DLQ-publisher identity). The grant is the SUPERSET of both DLQ layouts
# (${DLQ_PUB_SUBTREES[*]}) so one committed creds set serves legacy AND segment-mode
# installs — see the DLQ_PUB_SUBTREES derivation above and the header note.
DLQ_PUB_ARGS=()
for subtree in "${DLQ_PUB_SUBTREES[@]}"; do
  DLQ_PUB_ARGS+=(--allow-pub "${subtree}")
done
nsc add user --account "${ACCOUNT_NAME}" --name subscriber \
  --allow-pub '$JS.ACK.'"${STREAM_NAME}"'.>' \
  --allow-pub '$JS.API.STREAM.INFO.'"${STREAM_NAME}" \
  --allow-pub '$JS.API.CONSUMER.INFO.'"${STREAM_NAME}"'.*' \
  --allow-pub '$JS.API.CONSUMER.MSG.NEXT.'"${STREAM_NAME}"'.*' \
  "${DLQ_PUB_ARGS[@]}" \
  --allow-sub '_INBOX.>' >/dev/null

echo "[gen] user admin"
nsc add user --account "${ACCOUNT_NAME}" --name admin \
  --allow-pub '$JS.API.>' \
  --allow-sub '_INBOX.>' >/dev/null

echo "[gen] resolver config (MEMORY)"
nsc generate config --mem-resolver --config-file "${OUT}/nats-server.conf"

echo "[gen] export public JWTs"
nsc describe operator --field jwt --raw > "${OUT}/operator.jwt"
nsc describe account --name "${ACCOUNT_NAME}" --field jwt --raw > "${OUT}/${ACCOUNT_NAME}.jwt"

echo "[gen] creds files"
nsc generate creds --account "${ACCOUNT_NAME}" --name publisher  > "${OUT}/publisher.creds"
nsc generate creds --account "${ACCOUNT_NAME}" --name subscriber > "${OUT}/subscriber.creds"
nsc generate creds --account "${ACCOUNT_NAME}" --name admin      > "${OUT}/admin.creds"
chmod 600 "${OUT}"/*.creds

cat > "${OUT}/README.md" <<EOF
# rrcs-k8s NATS lab fixtures

Generated by \`scripts/gen-nats-auth.sh\`. **These are lab-only fixture
identities with NO real privilege; do NOT reuse for any other deployment.**

Hierarchy:
- Operator: ${OPERATOR_NAME}
- Account:  ${ACCOUNT_NAME} (JetStream enabled, unlimited)
- Users:    publisher, subscriber, admin

Stream/durable/subject prefix bound into the user JWT permissions:
- Stream:         ${STREAM_NAME}
- Durable:        ${DURABLE_NAME}
- Subject prefix: ${SUBJECT_PREFIX}  (publisher --allow-pub ${SUBJECT_PREFIX}.>)

## DLQ pub grants (subscriber) — superset of BOTH layouts

The sink parks permanently-unprocessable messages using the **subscriber** creds
(there is no separate DLQ-publisher identity). There are two mutually-exclusive DLQ
layouts, and this committed creds set is minted to serve **both** so one fixture
works whether an install runs in legacy or in-prefix mode (kind e2e always
fresh-installs; only the sink publishes DLQ, so the broader grant is harmless):

- legacy out-of-prefix root:  \`${DLQ_LEGACY_SUBJECT}.>\`   (connect.deadLetter.subject)
- in-prefix root:             \`${DLQ_INPREFIX_SUBJECT}.>\`  (<subjectPrefix>.<segment>, segment defaults to "dlq")

Active DLQ root for this render: \`${DLQ_SUBJECT}\`.

The **publisher** grant is \`${SUBJECT_PREFIX}.>\`. In in-prefix mode this wildcard
now incidentally covers the DLQ subtree \`${DLQ_INPREFIX_SUBJECT}.>\` as well. That is
an accepted least-privilege wart: the source (publisher) never parks DLQ messages,
so the extra reach is unused, and narrowing it would require splitting the fixed
external prefix that the whole design deliberately keeps as a single \`${SUBJECT_PREFIX}.>\`
binding.

## R3 — never swap regenerated creds onto an existing release

Rerunning \`scripts/gen-nats-auth.sh --force\` rotates the **operator and account
identities**, not just the grants. Redeploying the regenerated creds in-place onto a
release that was installed with the previous identities orphans that release's
existing \`${STREAM_NAME}\` stream/consumer state (the server no longer trusts the old
account). Any regeneration therefore requires a **fresh NATS** — a new install or a
new namespace — never an in-place swap on a live release. See the CAUTION block at
\`chart/values.yaml\` connect.deadLetter (the "operator and account identities" note)
for the same warning on the values side.

To rotate or change stream/durable/prefix/DLQ segment: rerun with --force
(subject to the R3 fresh-NATS requirement above). Use \`--dry-run\` to preview the
resolved config and DLQ grants without invoking nsc.

In production, signing keys live in a secret manager (Vault / External
Secrets / SealedSecrets) and user creds are provisioned into K8s Secrets
out-of-band — that's exactly what the chart's external-mode consumes.
EOF

echo "[done] artifacts in ${OUT}/"
ls "${OUT}"
