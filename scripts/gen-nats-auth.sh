#!/usr/bin/env bash
# Mints the lab's operator/account/user JWTs + creds files via nsc.
# Output lands in chart/files/nats-auth/ (committed lab fixtures).
# Re-runnable; refuses to overwrite without --force.
#
# Env overrides (defaults match chart/values.yaml):
#   STREAM_NAME=APP_EVENTS        DURABLE_NAME=region-writer
#   SUBJECT_PREFIX=app.events     (publisher --allow-pub is "<prefix>.>")
#   OPERATOR_NAME=RRCS-OP         ACCOUNT_NAME=APP
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1;;
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
    # awk walks the YAML hierarchy under `nats:` to find the requested key.
    # `key` is one of: nats.stream.name, nats.stream.subjectPrefix,
    # nats.stream.consumer.durable
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
    esac
    [[ -n "$val" ]] && { echo "$val"; return; }
  fi
  echo "$default"
}

STREAM_NAME="${STREAM_NAME:-$(parse_values nats.stream.name APP_EVENTS)}"
SUBJECT_PREFIX="${SUBJECT_PREFIX:-$(parse_values nats.stream.subjectPrefix app.events)}"
DURABLE_NAME="${DURABLE_NAME:-$(parse_values nats.stream.consumer.durable region-writer)}"
OPERATOR_NAME="${OPERATOR_NAME:-RRCS-OP}"
ACCOUNT_NAME="${ACCOUNT_NAME:-APP}"

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
# The sink (cdc-reverse) binds to a server-side PULL consumer (bind:true), so it
# must publish pull requests to $JS.API.CONSUMER.MSG.NEXT.<stream>.<durable>.
# CONSUMER.*CREATE.* remain only for back-compat with non-bind (push) configs;
# in pull/bind mode the consumer is created by the nats-init Job (admin creds).
nsc add user --account "${ACCOUNT_NAME}" --name subscriber \
  --allow-pub '$JS.ACK.'"${STREAM_NAME}"'.'"${DURABLE_NAME}"'.>' \
  --allow-pub '$JS.API.STREAM.INFO.'"${STREAM_NAME}" \
  --allow-pub '$JS.API.CONSUMER.DURABLE.CREATE.'"${STREAM_NAME}"'.'"${DURABLE_NAME}" \
  --allow-pub '$JS.API.CONSUMER.CREATE.'"${STREAM_NAME}"'.'"${DURABLE_NAME}" \
  --allow-pub '$JS.API.CONSUMER.CREATE.'"${STREAM_NAME}"'.'"${DURABLE_NAME}"'.>' \
  --allow-pub '$JS.API.CONSUMER.INFO.'"${STREAM_NAME}"'.'"${DURABLE_NAME}" \
  --allow-pub '$JS.API.CONSUMER.MSG.NEXT.'"${STREAM_NAME}"'.'"${DURABLE_NAME}" \
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

To rotate or change stream/durable/prefix: rerun with --force.

In production, signing keys live in a secret manager (Vault / External
Secrets / SealedSecrets) and user creds are provisioned into K8s Secrets
out-of-band — that's exactly what the chart's external-mode consumes.
EOF

echo "[done] artifacts in ${OUT}/"
ls "${OUT}"
