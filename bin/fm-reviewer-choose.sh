#!/usr/bin/env bash
# Refresh the global no-mistakes reviewer pin from the bound review rule.
#
# Usage:
#   FM_HOME=<owning-home> bin/fm-reviewer-choose.sh [--snapshot <regular-file>] [--record <path>]
#
# This is a serialized global pin refresh, not a per-lane candidate chooser.
# It reads the one review rule carrying `"reviewer": true` in the routing
# configuration, one quota-axi snapshot, and the union of author families
# across every still-present lane record carrying `mode=no-mistakes` in this
# daemon's homes, then rewrites only the reviewer block (`agent`, `model`,
# `effort`) of the global no-mistakes config when the current pin is
# ineligible. Every other byte of that file is preserved. The switch is
# recorded, success exits 0. When no candidate survives, one truthful park
# line naming each candidate and its reason goes to stderr and the script
# exits 1. An eligible current pin is left untouched: no config write and no
# switch-record append. All writers serialize under one global lock.
#
# Inputs: without --snapshot, exactly one quota-axi default TOON result is
# captured after taking the global lock and validated through the existing
# snapshot owner; --snapshot is an explicit deterministic file-input seam
# that never reads stdin and suppresses the live capture. --record defaults
# to <canonical NM_HOME>/firstmate-reviewer-switches.log so a successful
# switch is always recorded. No candidate or author command-line inputs
# exist: candidates come only from the bound rule in listed order, and
# authors only from lane metadata. --help describes this contract.
#
# Candidate gates, in order of authority: effective rule/profile `approval`
# present means needs-approval (presence, not value; neither false, null,
# nor an old grant bypasses it); an unresolvable candidate family means
# unresolved-family; a family in the active-author union means
# author-family:<family> (family tokens only, never harness names); a
# library exhausted verdict means quota-exhausted. Survivors keep the
# library-issued rank, the lowest wins, and listed order breaks rank ties,
# so an earlier unmeasured candidate never outranks a measured-eligible one.
# A measured-eligible, non-author, approval-free current pin that the bound
# rule still lists stays unchanged even when an earlier candidate is also
# healthy; an unmeasured current pin stays only when no measured-eligible
# survivor exists; a current pin the bound rule no longer lists is
# not-in-review-rule and must move when a survivor exists.
#
# The active-author union covers every still-present lane record with
# exactly `mode=no-mistakes`, including stopped, parked, validating, and
# ready-but-uncleaned lanes: terminal liveness and a last done event never
# retire authorship, and only the owning normal lifecycle removes records.
# Scouts without that mode, secondmate records, and direct-PR or local-only
# records never contribute. Identity comes only from the recorded harness
# and model fields through the one quota-library family resolver; effort
# never changes family identity. A `model=default` record is not a concrete
# model, and any unresolved active author parks the entire refresh before a
# pin change, because excluding only the known subset could permit
# self-review. The config is daemon-global, so a secondary home resolves
# its local parent binding and scans that primary plus its registered local
# secondmate homes; a remote-parent route treats its own operational home as
# the local root and never traverses SSH.
#
# Outputs: an unchanged eligible pin exits 0 silently. A changed pin prints
# one `reviewer-refresh: switched to=<agent>:<model>:<effort>` line on
# stdout (empty model or effort renders as `default`) after the new bytes
# and the switch record are both published. All park lines go to stderr,
# once, so a caller suppressing stdout still sees the refusal. The switch
# record names the previous pin, the new pin, the old pin's reason, and the
# new pin's measured state; an unchanged pin never looks like a switch, and
# unmeasured selection is explicit, never recorded as measured capacity.
# Malformed input, an unusable snapshot, an unsupported config shape, an
# unknown option, or failed file or record I/O prints one `error: ...`
# diagnostic on stderr and exits 2. A record-write failure after the pin
# changed says so explicitly instead of claiming success, and no broad
# rollback over a possible subsequent write is attempted.
#
# Accepted limits, recorded rather than closed here: the refresh guarantees
# the pin for runs constructed after it, not for runs already holding a
# reviewer; there is one global pin, so a consumed union parks every lane;
# quota and authors can change after the snapshot; unmeasured quota is
# fallback uncertainty, not proof a review will complete; registered local
# homes are covered while unregistered independent homes sharing NM_HOME
# are a stated deployment limitation; and same-user writers outside the
# cooperative lock stay outside it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
park() { printf 'park: %s\n' "$1" >&2; exit 1; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

SNAPSHOT_SOURCE=
RECORD_ARG=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot)
      [ -n "${2-}" ] || die "--snapshot needs a path"
      SNAPSHOT_SOURCE=$2
      shift 2
      ;;
    --record)
      [ -n "${2-}" ] || die "--record needs a path"
      RECORD_ARG=$2
      shift 2
      ;;
    -h|--help|help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "${FM_HOME:-}" ] || die "FM_HOME is required"
FM_HOME=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is not a directory: $FM_HOME"
NM_HOME=${NM_HOME:-$HOME/.no-mistakes}
NM_HOME=$(cd "$NM_HOME" 2>/dev/null && pwd -P) || die "no-mistakes home is not a directory: $NM_HOME"
NM_CONFIG=$NM_HOME/config.yaml
[ -f "$NM_CONFIG" ] && [ ! -L "$NM_CONFIG" ] || die "no-mistakes config is not a regular file: $NM_CONFIG"
NM_LOCK=$NM_HOME/config.yaml.firstmate-reviewer.lock
if [ -n "$RECORD_ARG" ]; then
  RECORD=$RECORD_ARG
else
  RECORD=$NM_HOME/firstmate-reviewer-switches.log
fi
command -v jq >/dev/null 2>&1 || die "jq is required for reviewer refresh"
command -v python3 >/dev/null 2>&1 || die "python3 is required for reviewer refresh"

fm_lock_acquire_wait "$NM_LOCK"
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup_refresh() {
  [ -n "${STAGE:-}" ] && rm -f "$STAGE"
  fm_lock_release "$NM_LOCK" >/dev/null 2>&1
}
trap 'cleanup_refresh' EXIT

# Resolve the daemon-local root whose routing config and lane records this
# refresh covers: a local secondmate route supplies its primary, every other
# home is its own machine-local root.
ROOT=$FM_HOME
PARENT_BINDING=$FM_HOME/.fm-secondmate-parent
if [ -e "$PARENT_BINDING" ]; then
  if fm_secondmate_parent_record_parse "$PARENT_BINDING" 2>/dev/null; then
    case "$FM_SECONDMATE_PARENT_ROUTE" in
      local) ROOT=$FM_SECONDMATE_PARENT_HOME ;;
      remote) ROOT=$FM_HOME ;;
      *) park "active lane records unavailable (home=$FM_HOME, reason=parent binding route unreadable)" ;;
    esac
  else
    park "active lane records unavailable (home=$FM_HOME, reason=parent binding unreadable)"
  fi
fi
ROOT=$(cd "$ROOT" 2>/dev/null && pwd -P) ||
  park "active lane records unavailable (home=$FM_HOME, reason=root home unreadable)"
if [ "$ROOT" = "$FM_HOME" ] && [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
  CONFIG_DIR=$FM_CONFIG_OVERRIDE
else
  CONFIG_DIR=$ROOT/config
fi
ROUTING=$CONFIG_DIR/crew-dispatch.json

# Bind the single reviewer-marked rule. Absent file or marker parks; several
# markers park; a present non-true marker is malformed input, never an
# opt-out that falls back elsewhere.
if [ ! -e "$ROUTING" ]; then
  park "reviewer rule binding missing (config=$ROUTING, selector=rules[].reviewer=true)"
fi
[ -f "$ROUTING" ] && [ ! -L "$ROUTING" ] || die "routing file is not a regular file: $ROUTING"
ROUTING_JSON=$(cat -- "$ROUTING" 2>/dev/null) || die "routing file unreadable: $ROUTING"
printf '%s\n' "$ROUTING_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 ||
  die "routing file is malformed: $ROUTING"
RULES_TYPE=$(printf '%s\n' "$ROUTING_JSON" | jq -r 'if has("rules") then (.rules | type) else "absent" end' 2>/dev/null) ||
  die "routing file is malformed: $ROUTING"
case "$RULES_TYPE" in
  absent|array) ;;
  *) die "routing file is malformed: $ROUTING" ;;
esac
BAD_MARKER=$(printf '%s\n' "$ROUTING_JSON" |
  jq '[.rules[]? | select(has("reviewer") and .reviewer != true)] | length' 2>/dev/null) ||
  die "routing file is malformed: $ROUTING"
[ "$BAD_MARKER" = 0 ] || die "reviewer rule binding is malformed (config=$ROUTING, selector=rules[].reviewer=true)"
MARKED=$(printf '%s\n' "$ROUTING_JSON" |
  jq -c '[.rules[]? | select(.reviewer == true)]' 2>/dev/null) ||
  die "routing file is malformed: $ROUTING"
MARKED_COUNT=$(printf '%s\n' "$MARKED" | jq 'length' 2>/dev/null) ||
  die "routing file is malformed: $ROUTING"
[ "$MARKED_COUNT" -gt 0 ] ||
  park "reviewer rule binding missing (config=$ROUTING, selector=rules[].reviewer=true)"
[ "$MARKED_COUNT" -eq 1 ] ||
  park "reviewer rule binding ambiguous (config=$ROUTING, matches=$MARKED_COUNT)"
RULE=$(printf '%s\n' "$MARKED" | jq -c '.[0]') || die "routing file is malformed: $ROUTING"
RULE_APPROVAL=0
printf '%s\n' "$RULE" | jq -e 'has("approval")' >/dev/null 2>&1 && RULE_APPROVAL=1
USE_COUNT=$(printf '%s\n' "$RULE" |
  jq 'if has("use") then (if (.use | type) == "array" then (.use | length) else 1 end) else 0 end' 2>/dev/null) ||
  die "routing file is malformed: $ROUTING"
[ "$USE_COUNT" -gt 0 ] || die "reviewer rule has no candidates (config=$ROUTING)"

# Normalize the bound rule's object-or-array use into ordered profile lists.
# Approval presence (rule or profile, any value) excludes; every other field
# is validated here so malformed bindings fail before any pin changes.
CAND_HARNESS=()
CAND_MODEL=()
CAND_EFFORT=()
CAND_PROVIDER=()
CAND_APPROVAL=()
i=0
while [ "$i" -lt "$USE_COUNT" ]; do
  profile=$(printf '%s\n' "$RULE" |
    jq -c '(.use | if type == "array" then .['"$i"'] else . end)' 2>/dev/null) ||
    die "routing file is malformed: $ROUTING"
  [ "$(printf '%s\n' "$profile" | jq -r 'type' 2>/dev/null)" = object ] ||
    die "reviewer rule has a malformed profile (config=$ROUTING)"
  harness=$(printf '%s\n' "$profile" | jq -r '.harness // empty' 2>/dev/null)
  case "$harness" in
    ''|*[!A-Za-z0-9._-]*) die "reviewer rule has a malformed profile (config=$ROUTING)" ;;
  esac
  fm_control_harness_supported "$harness" ||
    die "reviewer rule names an unsupported harness: $harness (config=$ROUTING)"
  model=$(printf '%s\n' "$profile" | jq -r '.model // empty' 2>/dev/null)
  case "$model" in
    ''|*[!A-Za-z0-9._/:-]*) [ -z "$model" ] || die "reviewer rule has a malformed profile (config=$ROUTING)" ;;
  esac
  effort=$(printf '%s\n' "$profile" | jq -r '.effort // empty' 2>/dev/null)
  case "$effort" in
    ''|*[!A-Za-z0-9-]*) [ -z "$effort" ] || die "reviewer rule has a malformed profile (config=$ROUTING)" ;;
  esac
  provider=$(printf '%s\n' "$profile" | jq -r '.provider // empty' 2>/dev/null)
  if [ -n "$provider" ]; then
    case "$provider" in
      ''|-*|*-|*--*|*[!a-z0-9-]*) die "reviewer rule has a malformed profile (config=$ROUTING)" ;;
    esac
  fi
  approval=0
  if [ "$RULE_APPROVAL" -eq 1 ]; then
    approval=1
  elif printf '%s\n' "$profile" | jq -e 'has("approval")' >/dev/null 2>&1; then
    approval=1
  fi
  CAND_HARNESS+=("$harness")
  CAND_MODEL+=("$model")
  CAND_EFFORT+=("$effort")
  CAND_PROVIDER+=("$provider")
  CAND_APPROVAL+=("$approval")
  i=$((i + 1))
done

# meta_display <meta-file> <key> prints the single non-empty value or
# "missing" for park diagnostics; it never fails the refresh itself.
meta_display() {
  local value
  value=$(fm_backend_meta_exact_value "$1" "$2" 2>/dev/null) || value=
  [ -n "$value" ] || value=missing
  printf '%s\n' "$value"
}

# scan_home_authors <home> folds every still-present mode=no-mistakes lane
# record into AUTHOR_FAMILIES. A record without exactly one mode field is
# not a modal lane and contributes nothing; a duplicated mode field is a
# corrupt record that parks rather than silently dropping a lane. A
# mode=no-mistakes record whose harness, model, or family cannot be
# established parks the entire refresh naming that lane, because excluding
# only the known subset could permit self-review.
scan_home_authors() {
  local home=$1 meta mode_count mode harness model family task
  [ -d "$home/state" ] ||
    park "active lane records unavailable (home=$home, reason=state directory unreadable)"
  for meta in "$home"/state/*.meta; do
    [ -e "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] ||
      park "active lane records unavailable (home=$home, reason=task record unreadable)"
    mode_count=$(grep -c '^mode=' "$meta" 2>/dev/null || true)
    case "$mode_count" in
      0) continue ;;
      1) ;;
      *) park "active lane records unavailable (home=$home, reason=task record has a duplicated mode field)" ;;
    esac
    mode=$(fm_backend_meta_exact_value "$meta" mode 2>/dev/null) || continue
    [ "$mode" = no-mistakes ] || continue
    task=$(basename "$meta" .meta)
    harness=$(fm_backend_meta_exact_value "$meta" harness 2>/dev/null) || harness=
    model=$(fm_backend_meta_exact_value "$meta" model 2>/dev/null) || model=
    if [ -z "$harness" ] || [ -z "$model" ]; then
      park "unresolved author family (lane=$home/$task, harness=$(meta_display "$meta" harness), model=$(meta_display "$meta" model))"
    fi
    case "$model" in
      default)
        park "unresolved author family (lane=$home/$task, harness=$harness, model=default)" ;;
    esac
    family=$(fm_quota_provider_for_harness "$harness" "$model" 2>/dev/null) || family=
    [ -n "$family" ] ||
      park "unresolved author family (lane=$home/$task, harness=$harness, model=$model)"
    case " $AUTHOR_FAMILIES_STR " in
      *" $family "*) ;;
      *) AUTHOR_FAMILIES_STR="$AUTHOR_FAMILIES_STR $family" ;;
    esac
  done
}

AUTHOR_FAMILIES_STR=
# Without nullglob a home with no .meta files would scan the literal
# pattern; skip it explicitly instead.
shopt -s nullglob
scan_home_authors "$ROOT"
REGISTRY=$ROOT/data/secondmates.md
if [ -e "$REGISTRY" ]; then
  [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] ||
    park "active lane records unavailable (home=$ROOT, reason=secondmate registry unreadable)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- '*)
        secondmate_registry_parse_line "$line" 2>/dev/null ||
          park "active lane records unavailable (home=$ROOT, reason=secondmate registry line unreadable)"
        [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || scan_home_authors "$SECONDMATE_REGISTRY_HOME"
        ;;
    esac
  done < "$REGISTRY"
fi
shopt -u nullglob

# Read the current reviewer pin through the same bounded block spans the
# writer below edits; any ambiguous or unsupported shape is a safe refusal,
# never a guess, and never a silent creation of a missing block.
PIN_TSV=$(python3 - "$NM_CONFIG" <<'PYEOF'
import sys
path = sys.argv[1]
try:
    with open(path, 'rb') as handle:
        raw = handle.read()
except OSError as exc:
    sys.stderr.write('error: cannot read no-mistakes config: %s\n' % exc)
    sys.exit(2)
try:
    text = raw.decode('utf-8')
except UnicodeDecodeError:
    sys.stderr.write('error: no-mistakes config is not UTF-8\n')
    sys.exit(2)
lines = text.split('\n')
def fail(message):
    sys.stderr.write('error: %s\n' % message)
    sys.exit(2)
blocks = [n for n, line in enumerate(lines)
          if line == 'review_agents:' or line.startswith('review_agents: ')]
if len(blocks) != 1:
    fail('reviewer block is missing or ambiguous in no-mistakes config')
start = blocks[0]
if lines[start] != 'review_agents:':
    fail('reviewer block has an unsupported shape in no-mistakes config')
span_end = len(lines)
for n in range(start + 1, len(lines)):
    line = lines[n]
    stripped = line.strip()
    if stripped == '' or stripped.startswith('#'):
        continue
    if len(line) - len(line.lstrip()) == 0:
        span_end = n
        break
reviews = [n for n in range(start + 1, span_end)
           if lines[n].strip().startswith('reviewer:')]
reviews = [n for n in reviews
           if lines[n] == (' ' * (len(lines[n]) - len(lines[n].lstrip()))) + 'reviewer:']
if len(reviews) != 1:
    inline = [n for n in range(start + 1, span_end)
              if len(lines[n]) - len(lines[n].lstrip()) > 0
              and lines[n].strip().startswith('reviewer:')
              and lines[n].strip() != 'reviewer:']
    if inline:
        fail('reviewer block has an unsupported shape in no-mistakes config')
    fail('reviewer block is missing or ambiguous in no-mistakes config')
rstart = reviews[0]
rindent = len(lines[rstart]) - len(lines[rstart].lstrip())
if rindent == 0:
    fail('reviewer block has an unsupported shape in no-mistakes config')
for n in range(start + 1, rstart):
    line = lines[n]
    stripped = line.strip()
    if stripped == '' or stripped.startswith('#'):
        continue
    indent = len(line) - len(line.lstrip())
    if indent < rindent:
        fail('reviewer block has an unsupported shape in no-mistakes config')
scalars = {}
for n in range(rstart + 1, len(lines)):
    line = lines[n]
    stripped = line.strip()
    if stripped == '' or stripped.startswith('#'):
        continue
    indent = len(line) - len(line.lstrip())
    if indent <= rindent:
        break
    if stripped.startswith('review_agents:'):
        fail('reviewer block has an unsupported shape in no-mistakes config')
    if ':' not in stripped:
        fail('reviewer block has an unsupported shape in no-mistakes config')
    key, _, value = stripped.partition(':')
    key = key.strip()
    value = value.strip()
    if key not in ('agent', 'model', 'effort'):
        fail('reviewer block has an unsupported shape in no-mistakes config')
    if key in scalars:
        fail('reviewer block has an unsupported shape in no-mistakes config')
    if value == '' or value in ('|', '>'):
        fail('reviewer block has an unsupported shape in no-mistakes config')
    if value[0] in '*&!{[':
        fail('reviewer block has an unsupported shape in no-mistakes config')
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        value = value[1:-1].replace("''", "'")
    elif len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            value = value[1:-1].encode('utf-8').decode('unicode_escape')
        except ValueError:
            fail('reviewer block has an unsupported shape in no-mistakes config')
    scalars[key] = value
if 'agent' not in scalars:
    fail('reviewer block is missing the agent scalar in no-mistakes config')
agent = scalars.get('agent', '')
model = scalars.get('model', '')
effort = scalars.get('effort', '')
sys.stdout.write('%s\t%s\t%s\n' % (agent, model, effort))
PYEOF
) || exit $?
CUR_AGENT=${PIN_TSV%%$'\t'*}
PIN_REST=${PIN_TSV#*$'\t'}
CUR_MODEL=${PIN_REST%%$'\t'*}
CUR_EFFORT=${PIN_REST#*$'\t'}

# Capture exactly one quota snapshot under the lock, or read the explicit
# deterministic file seam; a rejected snapshot is an input error, never a
# park and never unmeasured fallback.
if [ -n "$SNAPSHOT_SOURCE" ]; then
  [ -f "$SNAPSHOT_SOURCE" ] && [ ! -L "$SNAPSHOT_SOURCE" ] ||
    die "snapshot is not a regular file: $SNAPSHOT_SOURCE"
  SNAPSHOT_RAW=$(cat -- "$SNAPSHOT_SOURCE" 2>/dev/null) || die "snapshot unreadable: $SNAPSHOT_SOURCE"
else
  command -v quota-axi >/dev/null 2>&1 || die "quota-axi not installed"
  SNAPSHOT_RAW=$(quota-axi 2>/dev/null) || die "quota-axi snapshot capture failed"
fi
[ -n "$SNAPSHOT_RAW" ] || die "empty quota snapshot"
QUOTA_JSON=$(printf '%s\n' "$SNAPSHOT_RAW" | fm_quota_snapshot_json) ||
  die "quota snapshot rejected: $QUOTA_JSON"

# Evaluate every candidate once against the cached evidence, in listed
# order, keeping the first failing gate per candidate. Family exclusion is
# a token-membership test on resolved families only; the reviewer carries
# no quota-snapshot jq and no provider re-derivation of its own.
CAND_LABEL=()
CAND_REASON=()
CAND_RANK=()
CAND_ELIGIBLE=()
CAND_QUOTA_STATE=()
i=0
while [ "$i" -lt "$USE_COUNT" ]; do
  harness=${CAND_HARNESS[$i]}
  model=${CAND_MODEL[$i]}
  provider=${CAND_PROVIDER[$i]}
  if [ -n "$model" ]; then
    label="$harness:$model"
    qmodel=$model
  else
    label="$harness:default"
    qmodel=default
  fi
  family=$(fm_quota_provider_for_harness "$harness" "$model" 2>/dev/null) || family=
  author_hit=0
  case " $AUTHOR_FAMILIES_STR " in
    *" $family "*) author_hit=1 ;;
  esac
  if [ "${CAND_APPROVAL[$i]}" = 1 ]; then
    reason=needs-approval
    eligible=0
    rank=3
    qstate=unmeasured
  elif [ -z "$family" ]; then
    reason=unresolved-family
    eligible=0
    rank=3
    qstate=unmeasured
  elif [ "$author_hit" = 1 ]; then
    reason="author-family:$family"
    eligible=0
    rank=3
    qstate=unmeasured
  else
    availability=$(printf '%s\n' "$QUOTA_JSON" |
      fm_quota_effective_for_provider_model "$harness" "$qmodel" "$provider") || {
      printf 'error: quota availability could not be resolved for %s\n' "$label" >&2
      exit 2
    }
    verdict=${availability%%$'\t'*}
    rest=${availability#*$'\t'}
    arank=${rest%%$'\t'*}
    case "$verdict:$arank" in
      eligible:0|unmeasured:1)
        reason=
        eligible=1
        rank=$arank
        qstate=$verdict
        ;;
      exhausted:2)
        reason=quota-exhausted
        eligible=0
        rank=3
        qstate=unmeasured
        ;;
      *)
        printf 'error: quota availability could not be resolved for %s\n' "$label" >&2
        exit 2
        ;;
    esac
  fi
  CAND_LABEL+=("$label")
  CAND_REASON+=("$reason")
  CAND_RANK+=("$rank")
  CAND_ELIGIBLE+=("$eligible")
  CAND_QUOTA_STATE+=("$qstate")
  i=$((i + 1))
done

# Choose the lowest library-issued rank, preserving listed order within a
# rank; then assess the current pin against the same cached results.
# Retention wins over rank: a measured-eligible, non-author, approval-free
# current pin the rule still lists stays put even when an earlier candidate
# is also healthy, while an unmeasured current pin yields to a measured
# survivor and a pin outside the rule must move when one exists.
BEST=-1
BEST_RANK=3
i=0
while [ "$i" -lt "$USE_COUNT" ]; do
  if [ "${CAND_ELIGIBLE[$i]}" = 1 ] && [ "${CAND_RANK[$i]}" -lt "$BEST_RANK" ]; then
    BEST=$i
    BEST_RANK=${CAND_RANK[$i]}
  fi
  i=$((i + 1))
done
CUR_INDEX=-1
i=0
while [ "$i" -lt "$USE_COUNT" ]; do
  [ "${CAND_HARNESS[$i]}" = "$CUR_AGENT" ] || { i=$((i + 1)); continue; }
  if [ -n "${CAND_MODEL[$i]}" ]; then
    [ "${CAND_MODEL[$i]}" = "$CUR_MODEL" ] || { i=$((i + 1)); continue; }
  else
    case "$CUR_MODEL" in
      ''|default) ;;
      *) i=$((i + 1)); continue ;;
    esac
  fi
  CUR_INDEX=$i
  break
done
CUR_REASON=not-in-review-rule
CUR_STATE=unmeasured
if [ "$CUR_INDEX" -ge 0 ]; then
  if [ -n "${CAND_REASON[$CUR_INDEX]}" ]; then
    CUR_REASON=${CAND_REASON[$CUR_INDEX]}
  else
    CUR_REASON=
  fi
  CUR_STATE=${CAND_QUOTA_STATE[$CUR_INDEX]}
fi
UNCHANGED=0
if [ -z "$CUR_REASON" ]; then
  if [ "$CUR_INDEX" -ge 0 ] && [ "$BEST" = "$CUR_INDEX" ]; then
    UNCHANGED=1
  elif [ "$CUR_STATE" = eligible ]; then
    UNCHANGED=1
  elif [ "$BEST" -lt 0 ] || [ "$BEST_RANK" -gt 0 ]; then
    UNCHANGED=1
  fi
fi
if [ "$UNCHANGED" = 1 ]; then
  exit 0
fi
[ "$BEST" -ge 0 ] || {
  summary=
  i=0
  while [ "$i" -lt "$USE_COUNT" ]; do
    [ -z "$summary" ] || summary="$summary, "
    summary="$summary${CAND_LABEL[$i]}=${CAND_REASON[$i]}"
    i=$((i + 1))
  done
  park "no eligible reviewer ($summary)"
}

# A changed pin: prepare the record destination before writing config,
# publish the new bytes atomically, then require the record append.
NEW_AGENT=${CAND_HARNESS[$BEST]}
NEW_MODEL=${CAND_MODEL[$BEST]}
NEW_EFFORT=${CAND_EFFORT[$BEST]}
case "$NEW_AGENT" in
  ''|*[!A-Za-z0-9._-]*) die "selected reviewer agent is not a safe token" ;;
esac
case "$NEW_MODEL" in
  ''|*[!A-Za-z0-9._/:-]*) [ -z "$NEW_MODEL" ] || die "selected reviewer model is not a safe token" ;;
esac
case "$NEW_EFFORT" in
  ''|*[!A-Za-z0-9-]*) [ -z "$NEW_EFFORT" ] || die "selected reviewer effort is not a safe token" ;;
esac
RECORD_DIR=$(dirname "$RECORD")
[ -d "$RECORD_DIR" ] || die "switch record directory is missing: $RECORD_DIR"
: >>"$RECORD" 2>/dev/null || die "switch record is not writable: $RECORD"
STAGE_DIGEST_BEFORE=$(sha256sum "$NM_CONFIG" 2>/dev/null | awk '{print $1}')
[ -n "$STAGE_DIGEST_BEFORE" ] || STAGE_DIGEST_BEFORE=$(shasum -a 256 "$NM_CONFIG" 2>/dev/null | awk '{print $1}')
[ -n "$STAGE_DIGEST_BEFORE" ] || die "cannot digest no-mistakes config"
STAGE=$(mktemp "$NM_HOME/.config.yaml.refresh.XXXXXX") || die "cannot stage no-mistakes config"
cp -p "$NM_CONFIG" "$STAGE" || die "cannot stage no-mistakes config"
python3 - "$STAGE" "$NEW_AGENT" "$NEW_MODEL" "$NEW_EFFORT" <<'PYEOF' || exit 2
import sys
path, agent, model, effort = sys.argv[1:5]
def fail(message):
    sys.stderr.write('error: %s\n' % message)
    sys.exit(2)
try:
    with open(path, 'rb') as handle:
        raw = handle.read()
except OSError as exc:
    fail('cannot stage no-mistakes config: %s' % exc)
try:
    text = raw.decode('utf-8')
except UnicodeDecodeError:
    fail('no-mistakes config is not UTF-8')
ending = '\r\n' if '\r\n' in text else '\n'
lines = text.split('\n')
blocks = [n for n, line in enumerate(lines) if line == 'review_agents:']
if len(blocks) != 1:
    fail('reviewer block is missing or ambiguous in no-mistakes config')
start = blocks[0]
reviews = [n for n in range(start + 1, len(lines))
           if lines[n] == (' ' * (len(lines[n]) - len(lines[n].lstrip()))) + 'reviewer:']
if len(reviews) != 1:
    fail('reviewer block is missing or ambiguous in no-mistakes config')
rstart = reviews[0]
rindent = len(lines[rstart]) - len(lines[rstart].lstrip())
found = {}
for n in range(rstart + 1, len(lines)):
    line = lines[n]
    stripped = line.strip()
    if stripped == '' or stripped.startswith('#'):
        continue
    indent = len(line) - len(line.lstrip())
    if indent <= rindent:
        break
    key, _, _ = stripped.partition(':')
    key = key.strip()
    if key not in ('agent', 'model', 'effort'):
        fail('reviewer block has an unsupported shape in no-mistakes config')
    if key in found:
        fail('reviewer block has an unsupported shape in no-mistakes config')
    found[key] = n
agent_line = found.get('agent')
if agent_line is None:
    fail('reviewer block is missing the agent scalar in no-mistakes config')
indent = lines[agent_line][:len(lines[agent_line]) - len(lines[agent_line].lstrip())]
updates = {'agent': agent, 'model': model, 'effort': effort}
for key in ('agent', 'model', 'effort'):
    value = updates[key]
    rendered = '""' if value == '' else value
    if key in found:
        lines[found[key]] = '%s%s: %s' % (indent, key, rendered)
    elif key != 'agent':
        insert_at = agent_line + 1
        lines[insert_at:insert_at] = ['%s%s: %s' % (indent, key, rendered)]
        agent_line = agent_line + 1
        found[key] = insert_at
with open(path, 'wb') as handle:
    handle.write(ending.join(lines).encode('utf-8'))
PYEOF
STAGE_DIGEST_AFTER=$(sha256sum "$NM_CONFIG" 2>/dev/null | awk '{print $1}')
[ -n "$STAGE_DIGEST_AFTER" ] || STAGE_DIGEST_AFTER=$(shasum -a 256 "$NM_CONFIG" 2>/dev/null | awk '{print $1}')
[ "$STAGE_DIGEST_BEFORE" = "$STAGE_DIGEST_AFTER" ] ||
  die "no-mistakes config changed during refresh; refusing to publish"
mv -f "$STAGE" "$NM_CONFIG" || die "cannot publish no-mistakes config"
render_default() {
  [ -n "$1" ] && printf '%s' "$1" || printf 'default'
}
FROM_DISPLAY="$CUR_AGENT:$(render_default "$CUR_MODEL"):$(render_default "$CUR_EFFORT")"
TO_DISPLAY="$NEW_AGENT:$(render_default "$NEW_MODEL"):$(render_default "$NEW_EFFORT")"
[ -n "$CUR_REASON" ] || CUR_REASON=unmeasured-upgrade
epoch=$(date +%s)
if ! printf 'reviewer-refresh %s switched from=%s to=%s reason=%s quota=%s\n' \
  "$epoch" "$FROM_DISPLAY" "$TO_DISPLAY" "$CUR_REASON" "${CAND_QUOTA_STATE[$BEST]}" >>"$RECORD"; then
  printf 'error: reviewer pin changed to %s but the switch record failed: %s\n' \
    "$TO_DISPLAY" "$RECORD" >&2
  exit 2
fi
printf 'reviewer-refresh: switched to=%s\n' "$TO_DISPLAY"
