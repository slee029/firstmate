#!/usr/bin/env bash
# Regression tests for bin/fm-reviewer-choose.sh, the serialized global
# reviewer-pin refresh. Every case runs against isolated fixture homes: its
# own FM_HOME (routing rule plus lane records), its own NM_HOME (global
# config plus lock plus switch record), and fixture quota snapshots. No
# case touches the real global config, daemon, account, or lane, and the
# fake quota-axi fails when the file-input seam should have been used.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
REFRESH="$BIN/fm-reviewer-choose.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-reviewer-choose.XXXXXX")
FAKEBIN="$LAB/fakebin"
mkdir -p "$FAKEBIN"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$1"
}

# fx_world <name> builds one isolated world: $W/fm is FM_HOME with a
# two-candidate review rule (Pi/Astra low provider codex, then
# Claude/Opus medium) and no lane records; $W/nm is NM_HOME with a global
# config pinning Pi/Astra low plus comments, a commented alternate, fixer
# settings, and unrelated agent configuration. Prints the world path.
fx_world() {
  local w=$LAB/$1
  mkdir -p "$w/fm/config" "$w/fm/state" "$w/fm/data" "$w/nm"
  cat > "$w/fm/config/crew-dispatch.json" <<'JSON'
{"rules": [{"when": "validation review", "reviewer": true, "why": "the author's family is excluded", "use": [{"harness": "pi", "model": "openai-codex/gpt-6-astra", "effort": "low", "provider": "codex"}, {"harness": "claude", "model": "claude-opus-5", "effort": "medium"}]}], "default": [{"harness": "pi", "model": "openai-codex/gpt-6-astra", "effort": "low"}]}
JSON
  cat > "$w/nm/config.yaml" <<'YAML'
# Fixture global config: comments and unrelated settings must survive.
# A commented alternative reviewer block:
# reviewer:
#   agent: claude
#   model: claude-opus-5
#   effort: medium
review_agents:
  reviewer:
    agent: pi
    model: openai-codex/gpt-6-astra
    effort: low
  fixer:
    agent: pi
    model: openai-codex/gpt-6-astra
agent_config:
  pi:
    setting: keepme
YAML
  printf '%s\n' "$w"
}

# fx_meta <world> <task> <harness> <model> [mode] records one lane.
fx_meta() {
  local w=$1 task=$2 harness=$3 model=$4 mode=${5:-no-mistakes}
  printf 'harness=%s\nkind=ship\nmode=%s\nmodel=%s\n' "$harness" "$mode" "$model" > "$w/fm/state/$task.meta"
}

# fx_quota5 <path> <codex-pct> <codex-runway> <claude-pct> <claude-runway>
# writes a schema-5 snapshot with codex and claude provider-wide rows.
fx_quota5() {
  local path=$1 codex_pct=$2 codex_runway=$3 claude_pct=$4 claude_runway=$5
  cat > "$path" <<JSON
{"generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
{"provider": "codex", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": $codex_pct, "runway": {"status": "$codex_runway"}}]}},
{"provider": "claude", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": $claude_pct, "runway": {"status": "$claude_runway"}}]}}
]}
JSON
}

# run_refresh <world> [args...] runs the refresh with the world pinned and
# the quota-axi that must never fire first on PATH. Stdout goes to
# $LAB/out, stderr to $LAB/err; prints the exit status.
run_refresh() {
  local w=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$w/fm" NM_HOME="$w/nm" \
    bash "$REFRESH" "$@" >"$LAB/out" 2>"$LAB/err"
  printf '%s' "$?"
}

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf 'quota-axi must not be called on the file-input seam\n' >&2
exit 99
SH
chmod +x "$FAKEBIN/quota-axi"

Q_EXH="$LAB/quota-exhausted.json"
Q_OK="$LAB/quota-healthy.json"
Q_ALLEXH="$LAB/quota-all-exhausted.json"
fx_quota5 "$Q_EXH" 0 exhausted_now 60 through_reset
fx_quota5 "$Q_OK" 90 through_reset 60 through_reset
fx_quota5 "$Q_ALLEXH" 0 exhausted_now 0 through_reset
printf '{"generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 4, "providers": []}' > "$LAB/bad-schema.json"
printf 'not json\n' > "$LAB/malformed.json"

if help=$(bash "$REFRESH" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'FM_HOME=<owning-home>' ||
  fail "help omitted the invocation contract"
printf '%s\n' "$help" | grep -Fq 'reviewer-refresh' ||
  fail "help omitted the switch record contract"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders the header contract only"

# An exhausted pin advances to the next eligible candidate, the switch is
# recorded with its reason, and every byte outside the three value spans
# survives, including comments and unrelated agent configuration.
W=$(fx_world w-switch)
fx_meta "$W" lane1 muse muse-spark
cp "$W/nm/config.yaml" "$W/nm/config.yaml.orig"
rc=$(run_refresh "$W" --snapshot "$Q_EXH")
[ "$rc" = 0 ] || fail "exhausted pin: expected exit 0, got $rc with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "exhausted pin: wrong success line '$(cat "$LAB/out")'"
[ "$(cat "$LAB/err")" = "" ] || fail "exhausted pin: success leaked to stderr"
diff "$W/nm/config.yaml.orig" "$W/nm/config.yaml" > "$LAB/cfg.diff" || true
[ "$(grep -c '^[<>]' "$LAB/cfg.diff")" = 6 ] ||
  fail "exhausted pin: more than the three value spans changed"
grep -Fq '<     agent: pi' "$LAB/cfg.diff" || fail "exhausted pin: agent span not replaced"
grep -Fq '>     agent: claude' "$LAB/cfg.diff" || fail "exhausted pin: agent span wrong"
grep -Fq '#   agent: claude' "$W/nm/config.yaml" || fail "exhausted pin: commented alternate lost"
grep -Fq 'setting: keepme' "$W/nm/config.yaml" || fail "exhausted pin: agent config lost"
grep -Fq 'fixer:' "$W/nm/config.yaml" || fail "exhausted pin: fixer block lost"
record=$(cat "$W/nm/firstmate-reviewer-switches.log")
case "$record" in
  reviewer-refresh*' switched from=pi:openai-codex/gpt-6-astra:low to=claude:claude-opus-5:medium reason=quota-exhausted quota=eligible')
    ;;
  *) fail "exhausted pin: wrong switch record '$record'" ;;
esac
ok "exhausted pin advances with a recorded switch and preserved bytes"

# A repeated identical refresh changes nothing: silent exit, same mtime,
# and no extra switch line.
BEFORE_MTIME=$(stat -c %Y "$W/nm/config.yaml")
BEFORE_DIGEST=$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')
BEFORE_LINES=$(wc -l < "$W/nm/firstmate-reviewer-switches.log")
rc=$(run_refresh "$W" --snapshot "$Q_EXH")
[ "$rc" = 0 ] || fail "idempotent repeat: expected exit 0, got $rc"
[ "$(cat "$LAB/out")" = "" ] || fail "idempotent repeat: unchanged pin printed '$(cat "$LAB/out")'"
[ "$(stat -c %Y "$W/nm/config.yaml")" = "$BEFORE_MTIME" ] || fail "idempotent repeat: config rewritten"
[ "$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')" = "$BEFORE_DIGEST" ] || fail "idempotent repeat: config bytes moved"
[ "$(wc -l < "$W/nm/firstmate-reviewer-switches.log")" = "$BEFORE_LINES" ] || fail "idempotent repeat: extra switch line"
ok "repeated refresh is silent and byte-identical"

# A healthy current pin with no authors stays untouched.
W=$(fx_world w-healthy)
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 0 ] || fail "healthy pin: expected exit 0, got $rc"
[ "$(cat "$LAB/out")" = "" ] || fail "healthy pin: printed '$(cat "$LAB/out")'"
[ ! -e "$W/nm/firstmate-reviewer-switches.log" ] || fail "healthy pin: switch record created"
ok "healthy pin stays untouched"

# An active Astra-authored lane excludes the whole Codex family with the
# author-family reason rather than an exhaustion label, even though the
# Codex row is also exhausted here.
W=$(fx_world w-author)
fx_meta "$W" writer pi openai-codex/gpt-6-astra
rc=$(run_refresh "$W" --snapshot "$Q_EXH")
[ "$rc" = 0 ] || fail "author exclusion: expected exit 0, got $rc"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "author exclusion: wrong selection '$(cat "$LAB/out")'"
case "$(cat "$W/nm/firstmate-reviewer-switches.log")" in
  *' reason=author-family:codex quota=eligible') ;;
  *) fail "author exclusion: wrong switch reason '$(cat "$W/nm/firstmate-reviewer-switches.log")'" ;;
esac
ok "active author family is excluded with its reason"

# The same exclusion holds when the incoming lane itself is Astra-authored:
# the newly published record participates before any worker starts.
W=$(fx_world w-incoming)
fx_meta "$W" newcomer pi openai-codex/gpt-6-astra
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 0 ] || fail "incoming author: expected exit 0, got $rc"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "incoming author: Astra pinned despite active Astra authorship"
ok "incoming Astra authorship participates in the union"

# A cross-runtime author of the same OpenAI family is excluded identically;
# changing only the runtime must not evade the union.
W=$(fx_world w-crossrt)
fx_meta "$W" writer codex codex_bengalfox
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 0 ] || fail "cross-runtime author: expected exit 0, got $rc"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "cross-runtime author: Codex family not excluded '$(cat "$LAB/out")'"
ok "cross-runtime author family is excluded"

# All candidates exhausted parks with the exact candidate-complete line,
# and neither the config nor the switch record moves.
W=$(fx_world w-park)
fx_meta "$W" lane1 muse muse-spark
cp "$W/nm/config.yaml" "$W/nm/config.yaml.orig"
rc=$(run_refresh "$W" --snapshot "$Q_ALLEXH")
[ "$rc" = 1 ] || fail "all exhausted: expected exit 1, got $rc"
[ "$(cat "$LAB/out")" = "" ] || fail "all exhausted: park leaked to stdout"
expected="park: no eligible reviewer (pi:openai-codex/gpt-6-astra=quota-exhausted, claude:claude-opus-5=quota-exhausted)"
[ "$(cat "$LAB/err")" = "$expected" ] || fail "all exhausted: wrong park line '$(cat "$LAB/err")'"
cmp -s "$W/nm/config.yaml.orig" "$W/nm/config.yaml" || fail "all exhausted: config changed on park"
[ ! -e "$W/nm/firstmate-reviewer-switches.log" ] || fail "all exhausted: switch record created on park"
ok "all exhausted parks with the exact candidate-complete line"

# Known zero with a calm runway and unknown headroom with an exhausted
# runway are both exhaustion, never unmeasured fallback.
cat > "$LAB/quota-zero-calm.json" <<'JSON'
{"generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
{"provider": "codex", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": {"status": "through_reset"}}]}},
{"provider": "claude", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": {"status": "through_reset"}}]}}
]}
JSON
cat > "$LAB/quota-unknown-exhausted.json" <<'JSON'
{"generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
{"provider": "codex", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "unknown"}, {"scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": {"status": "through_reset"}}]}},
{"provider": "claude", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "unknown"}, {"scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": {"status": "through_reset"}}]}}
]}
JSON
rc=$(run_refresh "$W" --snapshot "$LAB/quota-zero-calm.json")
[ "$rc" = 1 ] || fail "zero calm: expected park, got $rc"
grep -Fq 'quota-exhausted' "$LAB/err" || fail "zero calm: not labeled exhaustion"
rc=$(run_refresh "$W" --snapshot "$LAB/quota-unknown-exhausted.json")
[ "$rc" = 1 ] || fail "unknown plus exhaustion: expected park, got $rc"
grep -Fq 'quota-exhausted' "$LAB/err" || fail "unknown plus exhaustion: not labeled exhaustion"
ok "measured zero and exhausted runway both park as exhaustion"

# An active lane whose family cannot be resolved parks the whole refresh
# naming that lane, even with healthy candidates waiting.
W=$(fx_world w-unresauthor)
fx_meta "$W" ghost pi default
BEFORE_DIGEST=$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 1 ] || fail "unresolved author: expected exit 1, got $rc"
case "$(cat "$LAB/err")" in
  "park: unresolved author family (lane=$W/fm/ghost, harness=pi, model=default)") ;;
  *) fail "unresolved author: wrong park line '$(cat "$LAB/err")'" ;;
esac
[ "$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')" = "$BEFORE_DIGEST" ] ||
  fail "unresolved author: config touched"
[ ! -e "$W/nm/firstmate-reviewer-switches.log" ] || fail "unresolved author: switch record created"
ok "unresolved active author parks naming the lane"

# An opaque broker alias as an author model is equally unresolvable.
rm "$W/fm/state/ghost.meta"
printf 'harness=pi\nkind=ship\nmode=no-mistakes\nmodel=openrouter/mystery-9\n' > "$W/fm/state/shade.meta"
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 1 ] || fail "opaque author: expected exit 1, got $rc"
grep -Fq "lane=$W/fm/shade" "$LAB/err" || fail "opaque author: lane not named"
rm "$W/fm/state/shade.meta"
ok "opaque author model parks"

# An unresolvable candidate is skipped while a later resolved independent
# candidate succeeds; a bare native Claude candidate resolves its family
# while a bare multi-provider candidate cannot.
W=$(fx_world w-unrescand)
python3 - "$W/fm/config/crew-dispatch.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    doc = json.load(handle)
doc['rules'][0]['use'] = [
    {"harness": "pi"},
    {"harness": "claude", "model": "claude-opus-5", "effort": "medium"},
]
with open(path, 'w') as handle:
    json.dump(doc, handle)
PYEOF
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 0 ] || fail "unresolved candidate: expected exit 0, got $rc with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "unresolved candidate: later candidate did not succeed"
[ "$(awk '/^  reviewer:/{f=1;next} f&&/agent:/{print $2;exit} f&&/^  [a-z_]/{exit}' "$W/nm/config.yaml")" = claude ] ||
  fail "unresolved candidate: reviewer pin not rewritten"
python3 - "$W/fm/config/crew-dispatch.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    doc = json.load(handle)
doc['rules'][0]['use'] = [
    {"harness": "claude"},
    {"harness": "pi", "model": "openai-codex/gpt-6-astra", "effort": "low", "provider": "codex"},
]
with open(path, 'w') as handle:
    json.dump(doc, handle)
PYEOF
cat > "$W/nm/config.yaml" <<'YAML'
review_agents:
  reviewer:
    agent: muse
    model: muse-spark
    effort: low
YAML
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 0 ] || fail "bare native: expected exit 0, got $rc with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:default:default" ] ||
  fail "bare native: wrong selection '$(cat "$LAB/out")'"
grep -Fq 'model: ""' "$W/nm/config.yaml" || fail "bare native: model scalar not cleared to empty"
ok "unresolved candidates skip and bare native profiles resolve"

# Binding cuts: a missing marker parks even when the pin matches an
# unmarked prose rule, a duplicated marker parks, and a malformed marker
# is an input error.
W=$(fx_world w-binding)
cp "$W/fm/config/crew-dispatch.json" "$W/fm/config/crew-dispatch.json.good"
python3 - "$W/fm/config/crew-dispatch.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    doc = json.load(handle)
del doc['rules'][0]['reviewer']
with open(path, 'w') as handle:
    json.dump(doc, handle)
PYEOF
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 1 ] || fail "missing marker: expected exit 1, got $rc"
case "$(cat "$LAB/err")" in
  "park: reviewer rule binding missing (config=$W/fm/config/crew-dispatch.json, selector=rules[].reviewer=true)") ;;
  *) fail "missing marker: wrong park line '$(cat "$LAB/err")'" ;;
esac
python3 - "$W/fm/config/crew-dispatch.json.good" "$W/fm/config/crew-dispatch.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as handle:
    doc = json.load(handle)
doc['rules'].append(dict(doc['rules'][0], reviewer=True))
with open(sys.argv[2], 'w') as handle:
    json.dump(doc, handle)
PYEOF
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 1 ] || fail "ambiguous marker: expected exit 1, got $rc"
grep -Fq 'binding ambiguous' "$LAB/err" || fail "ambiguous marker: wrong park line"
grep -Fq 'matches=2' "$LAB/err" || fail "ambiguous marker: match count missing"
python3 - "$W/fm/config/crew-dispatch.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    doc = json.load(handle)
doc['rules'] = [dict(doc['rules'][0], reviewer=False)]
with open(path, 'w') as handle:
    json.dump(doc, handle)
PYEOF
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 2 ] || fail "false marker: expected exit 2, got $rc"
grep -Fq 'error: reviewer rule binding is malformed' "$LAB/err" || fail "false marker: wrong diagnostic"
ok "binding missing, ambiguous, and malformed cases refuse exactly"

# Approval presence excludes: a rule-level approval skips every candidate,
# and a profile-level approval skips that candidate even when it equals
# the current pin. Removed spellings are usage errors, not inputs.
W=$(fx_world w-approval)
python3 - "$W/fm/config/crew-dispatch.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    doc = json.load(handle)
doc['rules'][0]['approval'] = 'captain'
with open(path, 'w') as handle:
    json.dump(doc, handle)
PYEOF
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 1 ] || fail "rule approval: expected exit 1, got $rc"
expected="park: no eligible reviewer (pi:openai-codex/gpt-6-astra=needs-approval, claude:claude-opus-5=needs-approval)"
[ "$(cat "$LAB/err")" = "$expected" ] || fail "rule approval: wrong park line '$(cat "$LAB/err")'"
python3 - "$W/fm/config/crew-dispatch.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    doc = json.load(handle)
del doc['rules'][0]['approval']
doc['rules'][0]['use'][0]['approval'] = 'captain'
with open(path, 'w') as handle:
    json.dump(doc, handle)
PYEOF
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 0 ] || fail "profile approval: expected exit 0, got $rc with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "profile approval: wrong selection '$(cat "$LAB/out")'"
for flag in --author --candidate --needs-approval; do
  if FM_HOME="$W/fm" NM_HOME="$W/nm" bash "$REFRESH" "$flag" x --snapshot "$Q_OK" >"$LAB/out" 2>"$LAB/err"; then
    fail "removed spelling $flag unexpectedly accepted"
  fi
  grep -Fq 'error: unknown option' "$LAB/err" || fail "removed spelling $flag: wrong refusal"
done
if FM_HOME="$W/fm" NM_HOME="$W/nm" bash "$REFRESH" --snapshot "$Q_OK" extra >"$LAB/out" 2>"$LAB/err"; then
  fail "positional candidate unexpectedly accepted"
fi
ok "approval excludes and removed spellings refuse"

# Malformed envelopes are input errors, never parks and never unmeasured.
W=$(fx_world w-malformed)
rc=$(run_refresh "$W" --snapshot "$LAB/bad-schema.json")
[ "$rc" = 2 ] || fail "bad schema: expected exit 2, got $rc"
grep -Fq 'error: quota snapshot rejected' "$LAB/err" || fail "bad schema: wrong diagnostic"
rc=$(run_refresh "$W" --snapshot "$LAB/malformed.json")
[ "$rc" = 2 ] || fail "malformed snapshot: expected exit 2, got $rc"
printf '%s\n' "not json" > "$LAB/stdin.txt"
FM_HOME="$W/fm" NM_HOME="$W/nm" PATH="$FAKEBIN:$PATH" bash "$REFRESH" <"$LAB/stdin.txt" >"$LAB/out" 2>"$LAB/err"
rc=$?
[ "$rc" = 2 ] || fail "stdin snapshot: expected exit 2, got $rc"
grep -Fq 'quota-axi snapshot capture failed' "$LAB/err" || fail "stdin snapshot: live capture not attempted"
ok "malformed input fails as error, stdin is never a snapshot"

# Unsupported config shapes refuse without writing: a duplicated reviewer
# block, a flow-style reviewer, an unknown reviewer key, and a missing
# reviewer block each exit 2 with the config byte-identical.
W=$(fx_world w-shapes)
BEFORE_DIGEST=$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')
python3 - "$W/nm/config.yaml" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().split('\n')
for n, line in enumerate(lines):
    if line == '  reviewer:':
        lines[n] = '  reviewer: {agent: claude}'
        break
open(sys.argv[1], 'w').write('\n'.join(lines))
PYEOF
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 2 ] || fail "flow reviewer: expected exit 2, got $rc"
grep -Fq 'unsupported shape' "$LAB/err" || fail "flow reviewer: wrong diagnostic"
[ "$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')" != "$BEFORE_DIGEST" ] ||
  fail "flow reviewer: shape edit did not apply"
python3 - "$W/nm/config.yaml" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().split('\n')
for n, line in enumerate(lines):
    if line == '  reviewer: {agent: claude}':
        lines[n] = '  reviewer:'
        lines.insert(n + 1, '    retries: 3')
        break
open(sys.argv[1], 'w').write('\n'.join(lines))
PYEOF
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 2 ] || fail "unknown key: expected exit 2, got $rc"
grep -Fq 'unsupported shape' "$LAB/err" || fail "unknown key: wrong diagnostic"
W=$(fx_world w-dupblock)
printf '\nreview_agents:\n  reviewer:\n    agent: claude\n' >> "$W/nm/config.yaml"
BEFORE_DIGEST=$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 2 ] || fail "duplicated block: expected exit 2, got $rc"
[ "$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')" = "$BEFORE_DIGEST" ] ||
  fail "duplicated block: refresh wrote despite the duplicate"
grep -Fq 'missing or ambiguous' "$LAB/err" || fail "duplicated block: wrong diagnostic"
ok "unsupported config shapes refuse safely"

# A missing reviewer block is a safe refusal, and a missing record
# directory fails before any config write.
W=$(fx_world w-noblock)
python3 - "$W/nm/config.yaml" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().split('\n')
start = next(n for n, line in enumerate(lines) if line == 'review_agents:')
end = next(n for n in range(start + 1, len(lines)) if lines[n] and not lines[n].startswith(' '))
open(sys.argv[1], 'w').write('\n'.join(lines[:start] + lines[end:]))
PYEOF
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 2 ] || fail "missing block: expected exit 2, got $rc"
grep -Fq 'reviewer block is missing' "$LAB/err" || fail "missing block: wrong diagnostic"
W=$(fx_world w-recordfail)
BEFORE_DIGEST=$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')
rc=$(run_refresh "$W" --snapshot "$Q_EXH" --record "$W/nm/no-such-dir/record.log")
[ "$rc" = 2 ] || fail "missing record dir: expected exit 2, got $rc"
grep -Fq 'switch record directory is missing' "$LAB/err" || fail "missing record dir: wrong diagnostic"
[ "$(sha256sum "$W/nm/config.yaml" | awk '{print $1}')" = "$BEFORE_DIGEST" ] ||
  fail "missing record dir: config written before the record failed"
ok "missing block and record destination refuse before writing"

# Unmeasured quota is fallback, not rejection: with only unmeasured rows
# the first candidate is selected and recorded as unmeasured, while an
# unmeasured current pin yields to a measured-eligible survivor.
cat > "$LAB/quota-unmeasured.json" <<'JSON'
{"generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
{"provider": "codex", "quotaSemantics": {"status": "unknown", "effectiveAvailability": []}},
{"provider": "claude", "quotaSemantics": {"status": "unknown", "effectiveAvailability": []}}
]}
JSON
W=$(fx_world w-unmeasured)
cat > "$W/nm/config.yaml" <<'YAML'
review_agents:
  reviewer:
    agent: grok
    model: grok-4
    effort: low
YAML
rc=$(run_refresh "$W" --snapshot "$LAB/quota-unmeasured.json")
[ "$rc" = 0 ] || fail "unmeasured only: expected exit 0, got $rc with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=pi:openai-codex/gpt-6-astra:low" ] ||
  fail "unmeasured only: wrong selection '$(cat "$LAB/out")'"
grep -Fq 'quota=unmeasured' "$W/nm/firstmate-reviewer-switches.log" ||
  fail "unmeasured only: record hides the unmeasured state"
cat > "$LAB/quota-codex-unknown.json" <<'JSON'
{"generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
{"provider": "codex", "quotaSemantics": {"status": "unknown", "effectiveAvailability": []}},
{"provider": "claude", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 60, "runway": {"status": "through_reset"}}]}}
]}
JSON
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 0 ] || fail "measured pin stays: expected exit 0, got $rc"
[ "$(cat "$LAB/out")" = "" ] || fail "measured pin stays: rewrote to itself '$(cat "$LAB/out")'"
[ "$(wc -l < "$W/nm/firstmate-reviewer-switches.log")" = 1 ] || fail "measured pin stays: extra record"
rc=$(run_refresh "$W" --snapshot "$LAB/quota-codex-unknown.json")
[ "$rc" = 0 ] || fail "unmeasured upgrade: expected exit 0, got $rc with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "unmeasured upgrade: wrong selection '$(cat "$LAB/out")'"
case "$(tail -1 "$W/nm/firstmate-reviewer-switches.log")" in
  *' switched from=pi:openai-codex/gpt-6-astra:low to=claude:claude-opus-5:medium reason=unmeasured-upgrade quota=eligible') ;;
  *) fail "unmeasured upgrade: wrong record '$(tail -1 "$W/nm/firstmate-reviewer-switches.log")'" ;;
esac
ok "unmeasured quota falls back explicitly and yields to measured"

# A pin outside the bound rule moves when a survivor exists and parks
# naming its own staleness when none does.
W=$(fx_world w-outsider)
cat > "$W/nm/config.yaml" <<'YAML'
review_agents:
  reviewer:
    agent: grok
    model: grok-4
    effort: low
YAML
rc=$(run_refresh "$W" --snapshot "$Q_OK")
[ "$rc" = 0 ] || fail "outsider switch: expected exit 0, got $rc with '$(cat "$LAB/err")'"
case "$(cat "$W/nm/firstmate-reviewer-switches.log")" in
  *' switched from=grok:grok-4:low to=pi:openai-codex/gpt-6-astra:low reason=not-in-review-rule quota=eligible') ;;
  *) fail "outsider switch: wrong record '$(cat "$W/nm/firstmate-reviewer-switches.log")'" ;;
esac
rc=$(run_refresh "$W" --snapshot "$Q_ALLEXH")
[ "$rc" = 1 ] || fail "outsider park: expected exit 1, got $rc"
grep -Fq 'no eligible reviewer' "$LAB/err" || fail "outsider park: wrong park line"
ok "pin outside the rule switches or parks truthfully"

# A registered local secondary home contributes its authors through the
# primary: an Astra-authored lane in the secondary excludes Codex family
# candidates for a refresh invoked from that secondary.
W=$(fx_world w-union)
mkdir -p "$W/fm/sub/state" "$W/fm/sub/config" "$W/fm/sub/data"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$W/fm" > "$W/fm/sub/.fm-secondmate-parent"
printf 'harness=pi\nkind=ship\nmode=no-mistakes\nmodel=openai-codex/gpt-6-astra\n' > "$W/fm/sub/state/second.meta"
printf -- '- sub - Alpha scope (home: %s; scope: alpha; projects: none; added 2030-01-01)\n' "$W/fm/sub" > "$W/fm/data/secondmates.md"
FM_HOME="$W/fm/sub" NM_HOME="$W/nm" PATH="$FAKEBIN:$PATH" bash "$REFRESH" --snapshot "$Q_OK" >"$LAB/out" 2>"$LAB/err"
[ "$?" = 0 ] || fail "union: expected exit 0 with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "union: secondary author not excluded '$(cat "$LAB/out")'"
grep -Fq 'reason=author-family:codex' "$W/nm/firstmate-reviewer-switches.log" ||
  fail "union: wrong switch reason"
ok "secondary home authors join the union through the primary"

# The global lock serializes overlapping refreshes: while the first holds
# it inside its snapshot capture, the second writes nothing and starts no
# switch; after release the loser re-reads the winner's pin and stays
# silent instead of appending a duplicate switch.
W=$(fx_world w-lock)
cat > "$LAB/gate-quota-axi" <<SH
#!/usr/bin/env bash
if [ ! -e "$LAB/gate-entered" ]; then
  : > "$LAB/gate-entered"
  while [ ! -e "$LAB/gate-open" ]; do sleep 0.05; done
fi
cat "$Q_EXH"
SH
chmod +x "$LAB/gate-quota-axi"
GATEBIN="$LAB/gatebin"
mkdir -p "$GATEBIN"
cp "$LAB/gate-quota-axi" "$GATEBIN/quota-axi"
rm -f "$LAB/gate-entered" "$LAB/gate-open"
PATH="$GATEBIN:$PATH" FM_HOME="$W/fm" NM_HOME="$W/nm" bash "$REFRESH" >"$LAB/out-a" 2>"$LAB/err-a" &
A_PID=$!
for _ in $(seq 1 200); do
  [ -e "$LAB/gate-entered" ] && break
  sleep 0.05
done
[ -e "$LAB/gate-entered" ] || fail "lock: first refresh never reached capture"
PATH="$GATEBIN:$PATH" FM_HOME="$W/fm" NM_HOME="$W/nm" bash "$REFRESH" >"$LAB/out-b" 2>"$LAB/err-b" &
B_PID=$!
sleep 0.5
kill -0 "$B_PID" 2>/dev/null || fail "lock: second refresh exited while the first holds the lock"
[ ! -e "$W/nm/firstmate-reviewer-switches.log" ] || fail "lock: switch recorded while the first holds the lock"
: > "$LAB/gate-open"
wait "$A_PID"
A_RC=$?
wait "$B_PID"
B_RC=$?
[ "$A_RC" = 0 ] || fail "lock: first refresh failed with $A_RC"
[ "$B_RC" = 0 ] || fail "lock: second refresh failed with $B_RC"
[ "$(cat "$LAB/out-a")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "lock: first refresh did not switch"
[ "$(cat "$LAB/out-b")" = "" ] || fail "lock: loser appended a duplicate switch"
[ "$(wc -l < "$W/nm/firstmate-reviewer-switches.log")" = 1 ] || fail "lock: duplicate switch records"
ok "overlapping refreshes serialize under the global lock"

# Schema-6 account binding: a declared provider keeps the original
# candidate lane, so an exhausted account row selects away even when a
# healthy row for another account exists; and a lane with no row falls
# back to its default row rather than to another lane.
cat > "$LAB/quota6-accounts.json" <<'JSON'
{"generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 6, "providers": [
{"provider": "codex", "accountKey": "openai-codex", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": {"status": "exhausted_now"}}]}},
{"provider": "codex", "accountKey": "codex-home", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 80, "runway": {"status": "through_reset"}}]}},
{"provider": "claude", "accountKey": "default", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 60, "runway": {"status": "through_reset"}}]}}
]}
JSON
W=$(fx_world w-acct)
rc=$(run_refresh "$W" --snapshot "$LAB/quota6-accounts.json")
[ "$rc" = 0 ] || fail "account lane: expected exit 0, got $rc with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=claude:claude-opus-5:medium" ] ||
  fail "account lane: borrowed another account quota '$(cat "$LAB/out")'"
cat > "$LAB/quota6-default.json" <<'JSON'
{"generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 6, "providers": [
{"provider": "codex", "accountKey": "other", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": {"status": "exhausted_now"}}]}},
{"provider": "codex", "accountKey": "default", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 70, "runway": {"status": "through_reset"}}]}}
]}
JSON
rc=$(run_refresh "$W" --snapshot "$LAB/quota6-default.json")
[ "$rc" = 0 ] || fail "default fallback: expected exit 0, got $rc with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=pi:openai-codex/gpt-6-astra:low" ] ||
  fail "default fallback: default row not used '$(cat "$LAB/out")'"
case "$(tail -1 "$W/nm/firstmate-reviewer-switches.log")" in
  *' reason=unmeasured-upgrade quota=eligible') ;;
  *) fail "default fallback: wrong record '$(tail -1 "$W/nm/firstmate-reviewer-switches.log")'" ;;
esac
ok "schema-6 account binding keeps the original lane with default fallback"

# A schema-6 codex-native row binds the native lane while the rule keeps
# its declared spelling.
cat > "$LAB/quota6-native.json" <<'JSON'
{"generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 6, "providers": [
{"provider": "codex", "accountKey": "codex-home", "quotaSemantics": {"status": "known", "effectiveAvailability": [{"scope": "all_models", "status": "known", "effectivePercentRemaining": 80, "runway": {"status": "through_reset"}}]}}
]}
JSON
W=$(fx_world w-native)
python3 - "$W/fm/config/crew-dispatch.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    doc = json.load(handle)
doc['rules'][0]['use'] = [
    {"harness": "codex", "model": "codex_bengalfox", "effort": "low"},
]
with open(path, 'w') as handle:
    json.dump(doc, handle)
PYEOF
rc=$(run_refresh "$W" --snapshot "$LAB/quota6-native.json")
[ "$rc" = 0 ] || fail "native binding: expected exit 0, got $rc with '$(cat "$LAB/err")'"
[ "$(cat "$LAB/out")" = "reviewer-refresh: switched to=codex:codex_bengalfox:low" ] ||
  fail "native binding: wrong selection '$(cat "$LAB/out")'"
ok "schema-6 codex-native row binds the native lane"
