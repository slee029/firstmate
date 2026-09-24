#!/usr/bin/env bash
# Choose the first quota-eligible candidate from a ranked list.
#
# Usage:
#   fm-quota-choose.sh [--snapshot <path>] [--candidate <harness:model>]...
#
# Reads one already-captured quota-axi default TOON or JSON snapshot from the
# provided file, or from stdin when --snapshot is omitted.
# bin/fm-quota-axi-lib.sh owns schema compatibility and the shared row join.
# For each --candidate in order, it maps <harness> to its primary provider
# family, then applies the matched row's provider-wide scopes and exact model
# or product scopes for <model>. A candidate is eligible only when no
# applicable runway is `exhausted_now` and its known
# effective percent remaining is greater than zero. The first eligible
# candidate is printed as "<harness> <model>" and the script exits 0.
# If no candidate is quota-eligible, it prints "none" and exits 1.
#
# Candidates are accepted as `--candidate <harness:model>` or as positional
# colon-separated arguments, with earlier candidates preferred.
# This script is deterministic and safe: it performs no side effects and exits
# nonzero when the environment would lead to an unsafe dispatch.
#
# The helper is the canonical worker-side selection used after the agent has
# already run `quota-axi` for its model selection. It never replaces the agent's
# reasoning-class or runway-feasibility gates; it only answers which ordered
# candidate remains eligible under the captured quota evidence.
#
# Quota mapping: each candidate is resolved through the shared availability
# owner (fm_quota_effective_for_provider_model in bin/fm-quota-axi-lib.sh),
# which returns a measured-or-unmeasured verdict with a rank. A supported
# harness with no established quota binding - a multi-provider route without
# a declared provider, or an omp model outside its mapped prefixes - is
# unmeasured uncertainty that stays eligible behind every measured-eligible
# candidate, never a rejection; only an unsupported harness fails argument
# validation. omp keeps its established quota routes: an openai-codex/<id>
# candidate checks the codex row and a claude-bridge/<id> candidate checks the
# claude row, each against the bare <id> for model: and product: scopes.
# quota-axi reports Codex quota unavailable on this host because omp carries
# its own Codex login, so an openai-codex candidate reads as unmeasured quota
# here; its runway is disclosed uncertainty for the agent-side gates, not
# measured headroom.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

CANDIDATES=()
SNAPSHOT_SOURCE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot)
      [ -n "${2-}" ] || die "--snapshot needs a path"
      SNAPSHOT_SOURCE=$2
      shift 2
      ;;
    --candidate)
      [ -n "${2-}" ] || die "--candidate needs a value"
      CANDIDATES+=("$2")
      shift 2
      ;;
    -h|--help|help) usage ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) CANDIDATES+=("$1") ; shift ;;
  esac
done

# Positional args after an explicit -- are also candidates.
while [ "$#" -gt 0 ]; do
  CANDIDATES+=("$1"); shift
done

[ "${#CANDIDATES[@]}" -gt 0 ] || die "no candidates supplied"

# A candidate is <harness>:<model>. A bare harness with no colon means the
# default model. Reject empty harnesses and characters that cannot form a safe
# token. A colon-separated model is legal (e.g. model:codex_bengalfox).
for c in "${CANDIDATES[@]}"; do
  case "$c" in
    ''|:*|*[!A-Za-z0-9._/:-]*) die "invalid candidate: $c" ;;
  esac
done

if [ -n "$SNAPSHOT_SOURCE" ]; then
  [ -f "$SNAPSHOT_SOURCE" ] && [ ! -L "$SNAPSHOT_SOURCE" ] || die "snapshot is not a regular file: $SNAPSHOT_SOURCE"
  QUOTA_SNAPSHOT=$(cat -- "$SNAPSHOT_SOURCE") || die "cannot read snapshot: $SNAPSHOT_SOURCE"
else
  [ ! -t 0 ] || die "quota snapshot is required on stdin or with --snapshot"
  QUOTA_SNAPSHOT=$(cat) || die "cannot read quota snapshot from stdin"
fi
[ -n "$QUOTA_SNAPSHOT" ] || die "empty quota snapshot"

QUOTA_JSON=$(printf '%s\n' "$QUOTA_SNAPSHOT" | fm_quota_snapshot_json) || die "$QUOTA_JSON"

# A malformed snapshot is an input error with the snapshot owner's own
# diagnostic, before any candidate is examined.
QUOTA_JSON=$(printf '%s\n' "$QUOTA_JSON" | fm_quota_snapshot_json) || die "$QUOTA_JSON"

# An unsupported harness fails here; a supported harness with unmeasured
# quota stays eligible through the shared rank below.
for c in "${CANDIDATES[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  [ "$model" = "$c" ] && model="default"
  [ -n "$model" ] || die "invalid candidate: $c"
  fm_control_harness_supported "$harness" || die "unknown harness: $harness"
done

# Each candidate is resolved once through the shared availability owner with
# no declared provider; the exhausted verdict is skipped and the generic
# minimum of returned ranks wins, preserving listed order within a rank, so
# an earlier unmeasured candidate never outranks a measured-eligible one.
chosen="none"
best_rank=3
for c in "${CANDIDATES[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  [ "$model" = "$c" ] && model="default"
  availability=$(printf '%s\n' "$QUOTA_JSON" |
    fm_quota_effective_for_provider_model "$harness" "$model" "") || {
    printf 'error: quota availability could not be resolved for %s\n' "$harness:$model" >&2
    exit 2
  }
  verdict=${availability%%$'\t'*}
  rest=${availability#*$'\t'}
  rank=${rest%%$'\t'*}
  case "$verdict:$rank" in
    eligible:0|unmeasured:1) ;;
    exhausted:2) continue ;;
    *) die "quota availability could not be resolved for $harness:$model" ;;
  esac
  if [ "$rank" -lt "$best_rank" ]; then
    best_rank=$rank
    chosen="$harness $model"
  fi
done

printf '%s\n' "$chosen"
[ "$chosen" != "none" ]
