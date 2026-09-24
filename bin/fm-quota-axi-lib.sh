# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic, the
# --json snapshot validator, and the provider-row join dispatch consumers use.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.
#
# Snapshot schemas: fm_quota_json_valid accepts quota-axi schema 5 (one row per
# provider, no accountKey) and schema 6 (every row carries accountKey, unique on
# provider + accountKey; quota-axi emits it once any provider expands to more
# than one account). Schema 5 keeps its exact pre-schema-6 rules so an older
# quota-axi keeps working unchanged. FM_QUOTA_ROW_JQ is the one join used to
# bind a candidate to its row under either schema.

FM_QUOTA_AXI_MIN=0.1.29
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

# The eligibility section of .agents/skills/quota-array-dispatch/SKILL.md
# owns the account-matching contract these jq definitions implement.
# Prepend them to a consumer's program:
#   quota_lane($harness; $model)   the candidate's account key, or "" when none
#                                  is identified by the contract.
#   quota_row($snapshot; $provider; $lane)
#                                  the one provider row the candidate binds to,
#                                  or null; schema 5 ignores $lane.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_ROW_JQ='
  def quota_lane($harness; $model):
    if $harness == "codex" then "codex-home"
    elif ($harness == "pi" or $harness == "pi-signed") and (($model // "") | contains("/"))
    then ($model | split("/") | first | if . == "codex-native" then "codex-home" else . end)
    else "" end;
  def quota_row($snapshot; $provider; $lane):
    ([$snapshot.providers[]? | select(.provider == $provider)]) as $rows |
    if $snapshot.schemaVersion == 6 then
      (([$rows[] | select(.accountKey == $lane)] | first) //
       ([$rows[] | select(.accountKey == "default")] | first) // null)
    else ($rows | first) // null
    end;
'

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_json_valid() {
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      (.providers | type) == "array" and
      (if .schemaVersion == 5 then
         (([.providers[].provider] | length) == ([.providers[].provider] | unique | length))
       elif .schemaVersion == 6 then
         all(.providers[];
           (.accountKey | type) == "string" and
           (.accountKey | length) > 0 and
           ((.accountKey | test("\\s")) | not)) and
         (([.providers[] | [.provider, .accountKey]] | length) ==
          ([.providers[] | [.provider, .accountKey]] | unique | length))
       else false
       end) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test($provider_re)) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'agy agy' \
    'muse meta'
}

fm_quota_single_provider_for_harness() {
  local harness provider
  while read -r harness provider; do
    if [ "$harness" = "$1" ]; then
      printf '%s\n' "$provider"
      return 0
    fi
  done < <(fm_quota_single_provider_table)
  return 1
}

# fm_quota_provider_for_harness <harness> [<model>] is the sole public
# resolver for the author/identity family of a harness plus model spelling.
# It prints one canonical family token and returns 0 when the spelling
# resolves, and prints nothing and returns 1 when it does not. It never
# substitutes the harness name on failure: an unresolved identity fails
# closed in every consumer. A native single-family harness resolves its known
# family for a bare or default model and for an explicit model that resolves
# to the same family; a contradictory or unrecognized explicit model is
# unresolved. The multi-provider harnesses (pi, pi-signed, omp, opencode)
# and the runtime-named harnesses (cursor, agy, rovo) resolve only through an
# explicit recognized provider/model spelling: a broker prefix (openrouter/,
# cliproxyapi/, antigravity/) is skipped to the underlying segment, and an
# opaque broker alias is unresolved. This is author-family identity, not
# quota account routing: fm_quota_single_provider_for_harness stays the
# quota provider default owner for typed dispatch.
_fm_quota_family_segment() {
  case "$1" in
    anthropic|claude|claude-*) printf 'claude\n' ;;
    openai-codex|codex-native|openai*|codex*|gpt*|astra*) printf 'codex\n' ;;
    gemini*|google*|vertex*) printf 'gemini\n' ;;
    xai*|grok*) printf 'grok\n' ;;
    kimi*|moonshot*) printf 'kimi\n' ;;
    meta*|muse*|llama*) printf 'meta\n' ;;
    z-ai|zai) printf 'zai\n' ;;
    *) return 1 ;;
  esac
}
_fm_quota_family_broker() {
  case "$1" in
    openrouter|cliproxyapi|antigravity) return 0 ;;
    *) return 1 ;;
  esac
}
_fm_quota_family_model() {
  local rest first
  rest=${1#model:}
  [ -n "$rest" ] || return 1
  rest=$(printf '%s\n' "$rest" | tr '[:upper:]' '[:lower:]')
  case "$rest" in
    ''|default) return 1 ;;
  esac
  first=${rest%%/*}
  while _fm_quota_family_broker "$first"; do
    case "$rest" in
      */*) rest=${rest#*/} ;;
      *) return 1 ;;
    esac
    first=${rest%%/*}
  done
  _fm_quota_family_segment "$first"
}
fm_quota_provider_for_harness() {
  local harness=${1:-} model=${2:-} native resolved
  [ -n "$harness" ] || return 1
  case "$harness" in
    claude) native=claude ;;
    codex) native=codex ;;
    gemini) native=gemini ;;
    grok) native=grok ;;
    kimi) native=kimi ;;
    muse) native=meta ;;
    pi|pi-signed|omp|opencode|cursor|agy|rovo) native= ;;
    *) return 1 ;;
  esac
  case "$model" in
    ''|default)
      [ -n "$native" ] || return 1
      printf '%s\n' "$native"
      return 0
      ;;
  esac
  resolved=$(_fm_quota_family_model "$model") || return 1
  if [ -n "$native" ]; then
    [ "$resolved" = "$native" ] || return 1
    printf '%s\n' "$native"
    return 0
  fi
  printf '%s\n' "$resolved"
}

# fm_quota_snapshot_json reads one quota-axi default TOON or schema-5/6 JSON
# snapshot on stdin and prints the validated JSON on stdout. On a
# rejected snapshot it prints the rejection reason on stdout instead and
# returns 1, so a caller can report it verbatim.
fm_quota_snapshot_json() {
  local snapshot json schema
  snapshot=$(cat)
  if printf '%s\n' "$snapshot" | jq -e 'type == "object"' >/dev/null 2>&1; then
    json=$snapshot
    schema=$(printf '%s\n' "$json" | jq -r '.schemaVersion // empty' 2>/dev/null) || schema=
    case "$schema" in
      5|6) ;;
      '') { printf 'quota-axi json missing schemaVersion\n'; return 1; } ;;
      *) { printf 'unsupported quota-axi schema version: %s\n' "$schema"; return 1; } ;;
    esac
  else
    json=$(printf '%s\n' "$snapshot" | jq -Rse '
      def valid_preamble:
        ((length == 2) and
         (.[0] | test("^bin: (quota-axi|.*/quota-axi)$")) and
         (.[1] | test("^generatedAt: .+$"))) or
        ((length == 3) and
         (.[0] | test("^bin: (quota-axi|.*/quota-axi)$")) and
         (.[1] | test("^description: .+$")) and
         (.[2] | test("^generatedAt: .+$")));
      def valid_zero_head:
        (length == 0) or valid_preamble;
      def valid_help_tail:
        if length == 0 then true
        else
          (.[0] | capture("^help\\[(?<count>[0-9]+)\\]:$").count | tonumber) as $count |
          (.[1:] | length) == $count and all(.[1:][]; startswith("  "))
        end;
      def decoded_fields:
        def parse($remaining; $fields):
          if $remaining == "" then $fields
          elif ($remaining | startswith("\"")) then
            ($remaining | capture("^(?<field>\"(?:\\\\.|[^\"])*\")(?<rest>,.*|)$")) as $match |
            ($match.field | fromjson) as $field |
            if $match.rest == "," then $fields + [$field, ""]
            else parse(($match.rest | sub("^,"; "")); $fields + [$field])
            end
          else
            ($remaining | capture("^(?<field>[^,\"]*)(?<rest>,.*|)$")) as $match |
            if $match.rest == "," then $fields + [$match.field, ""]
            else parse(($match.rest | sub("^,"; "")); $fields + [$match.field])
            end
          end;
        parse(.; []);
      def decoded_row:
        sub("^  "; "") | decoded_fields;
      def valid_rows($field_count):
        all(.[];
          startswith("  ") and
          ((decoded_row | length) == $field_count) and
          all(decoded_row[]; length > 0)
        );
      # Schema 6 TOON adds accountKey right after provider in every block; $k is
      # that column offset (0 or 1) and keyed_row folds it into the record.
      def key_col($k): if $k == 1 then "accountKey," else "" end;
      def keyed_row($k): if $k == 1 then {provider: .[0], accountKey: .[1]} else {provider: .[0]} end;
      def account_of: if has("accountKey") then {accountKey} else {} end;
      def schema_of($k): if $k == 1 then 6 else 5 end;
      def valid_attention_entries:
        type == "array" and
        all(.[];
          type == "object" and
          (.provider | type) == "string" and
          (.provider | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
          ((has("accountKey") | not) or
           ((.accountKey | type) == "string" and (.accountKey | length) > 0 and ((.accountKey | test("\\s")) | not))) and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          (.kind | type) == "string" and (.kind | length) > 0 and
          (.detail | type) == "string" and (.detail | length) > 0 and
          (.remedy | type) == "string" and (.remedy | length) > 0
        );
      def attention_availability:
        if .kind == "headroom_unknown" and (.detail | contains("exhausted_now")) then
          if (.detail | test("(^| · )exhausted_now limited by .+$")) then
            {scope: .scope, status: "unknown", runway: {status: "exhausted_now"}}
          else error("invalid exhausted headroom attention")
          end
        else empty
        end;
      def unknown_providers($entries):
        $entries |
        group_by([.provider, .accountKey]) |
        map((.[0] | {provider} + account_of) + {
          quotaSemantics: {
            status: "unknown",
            effectiveAvailability: [.[] | attention_availability]
          }
        });
      def unknown_snapshot($entries):
        {schemaVersion: (if any($entries[]; has("accountKey")) then 6 else 5 end), providers: unknown_providers($entries)};
      def exhaustion_count($k):
        if . == "exhaustion[0]:" or . == "exhaustion: []" then 0
        else
          capture("^exhaustion\\[(?<count>[1-9][0-9]*)\\]\\{provider," + key_col($k) + "scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId\\}:$").count |
          tonumber
        end;
      def attention_count($k):
        if . == "attention[0]:" or . == "attention: []" then 0
        else
          capture("^attention\\[(?<count>[1-9][0-9]*)\\]\\{provider," + key_col($k) + "scope,kind,detail,remedy\\}:$").count |
          tonumber
        end;
      def attention_entries($k):
        map(decoded_row | keyed_row($k) + {
          scope: .[1 + $k], kind: .[2 + $k], detail: .[3 + $k], remedy: .[4 + $k]
        });
      (split("\n") | map(select(length > 0))) as $lines |
      ($lines | map(. == "quota[0]:" or . == "quota: []") | index(true)) as $zero_index |
      if $zero_index != null then
        ($lines[:$zero_index]) as $head |
        if ($head | valid_zero_head) then
          ($lines[($zero_index + 1):]) as $tail |
          if ($tail | length) >= 2 and
               ($tail[0] == "exhaustion[0]:" or $tail[0] == "exhaustion: []") then
            if ($tail[1] == "attention[0]:" or $tail[1] == "attention: []") and
               ($tail[2:] | valid_help_tail) then
              {schemaVersion: 5, providers: []}
            elif ($tail[1] | test("^attention\\[[1-9][0-9]*\\]\\{provider,(accountKey,)?scope,kind,detail,remedy\\}:$")) then
              (if ($tail[1] | contains("{provider,accountKey,")) then 1 else 0 end) as $k |
              ($tail[1] | attention_count($k)) as $attention_count |
              ($tail[2:(2 + $attention_count)]) as $attention_rows |
              if ($attention_rows | length) == $attention_count and
                 ($attention_rows | valid_rows(5 + $k)) and
                 ($tail[(2 + $attention_count):] | valid_help_tail) then
                ($attention_rows | attention_entries($k)) as $entries |
                if ($entries | valid_attention_entries) then
                  unknown_snapshot($entries)
                else error("invalid zero-row attention identities")
                end
              else error("invalid zero-row attention section")
              end
            elif ($tail[1] | startswith("attention: ")) then
              ($tail[1] | sub("^attention: "; "") | fromjson) as $entries |
              if ($entries | valid_attention_entries) and
                 ($tail[2:] | valid_help_tail) then
                unknown_snapshot($entries)
              else error("invalid zero-row attention array")
              end
            else error("invalid zero-row attention section")
            end
          else error("invalid zero-row quota sections")
          end
        else error("invalid zero-row quota header")
        end
      else
        ($lines | map(test("^quota\\[[1-9][0-9]*\\]\\{provider,(accountKey,)?scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt\\}:$")) | index(true)) as $quota_index |
        if $quota_index == null then error("missing quota section")
        else
          (if ($lines[$quota_index] | contains("{provider,accountKey,")) then 1 else 0 end) as $k |
          ($lines[:$quota_index]) as $head |
          ($lines[$quota_index] | capture("^quota\\[(?<count>[1-9][0-9]*)\\]").count | tonumber) as $quota_count |
          ($lines[($quota_index + 1):($quota_index + 1 + $quota_count)]) as $quota_lines |
          ($quota_index + 1 + $quota_count) as $exhaustion_index |
          ($lines[$exhaustion_index] | exhaustion_count($k)) as $exhaustion_count |
          ($lines[($exhaustion_index + 1):($exhaustion_index + 1 + $exhaustion_count)]) as $exhaustion_rows |
          ($exhaustion_index + 1 + $exhaustion_count) as $attention_index |
          ($lines[$attention_index] | attention_count($k)) as $attention_count |
          ($lines[($attention_index + 1):($attention_index + 1 + $attention_count)]) as $attention_rows |
          ($lines[($attention_index + 1 + $attention_count):]) as $tail |
          if (($head | valid_preamble) | not) or
             ($quota_lines | length) != $quota_count or
             (($quota_lines | valid_rows(8 + $k)) | not) or
             ($exhaustion_rows | length) != $exhaustion_count or
             (($exhaustion_rows | valid_rows(5 + $k)) | not) or
             ($attention_rows | length) != $attention_count or
             (($attention_rows | valid_rows(5 + $k)) | not) or
             (($tail | valid_help_tail) | not) then
            error("invalid quota-axi TOON envelope")
          else
            ($quota_lines | map(decoded_row)) as $rows |
            ($attention_rows | attention_entries($k)) as $attention_entries |
            if (($attention_entries | valid_attention_entries) | not) then error("invalid attention identities")
            elif any($rows[]; length != 8 + $k) then error("invalid quota rows")
            else
              {
                schemaVersion: schema_of($k),
                providers: (($rows |
                  map(keyed_row($k) + {
                    availability: {
                      scope: .[1 + $k],
                      status: "known",
                      effectivePercentRemaining: (.[2 + $k] | tonumber),
                      runway: {status: .[4 + $k]}
                    }
                  })) +
                  ($attention_entries | map(. as $entry | ($entry | {provider} + account_of) + {
                    availability: ([$entry | attention_availability] | first // null)
                  })) |
                  group_by([.provider, .accountKey]) |
                  map((.[0] | {provider} + account_of) + {
                    quotaSemantics: {
                      status: (if any(.[]; .availability.status == "known") then "known" else "unknown" end),
                      effectiveAvailability: [.[].availability | select(. != null)]
                    }
                  })
                )
              }
            end
          end
        end
      end
    ' 2>/dev/null) || { printf 'invalid quota-axi snapshot\n'; return 1; }
  fi

  printf '%s\n' "$json" | fm_quota_json_valid || { printf 'invalid quota-axi provider data\n'; return 1; }
    printf '%s\n' "$json"
}

# fm_quota_effective_for_provider_model <harness> <model-or-default>
# <declared-provider-or-empty> is the single availability owner for one
# candidate. It reads one quota-axi snapshot on stdin, revalidates it through
# fm_quota_snapshot_json (a rejected snapshot is an input error, never
# unmeasured), and prints one tab-separated record
# "<verdict>\t<rank>\t<reason>" with no tabs or newlines inside the reason:
# eligible (rank 0) for applicable known remaining above zero with no
# applicable exhausted-now runway; unmeasured (rank 1) when no measured
# applicable evidence or no justified quota mapping applies; exhausted
# (rank 2) for applicable measured zero or any applicable exhausted-now
# runway, including unknown headroom beside known exhaustion. Consumers
# exclude the exhausted verdict and take the generic minimum of returned
# ranks; the measured-before-unmeasured preference lives only here. A
# declared provider is used directly after identifier validation, keeping
# the original candidate lane from quota_lane. Without one, the established
# native single-provider mapping applies (keeping the omp openai-codex and
# claude-bridge quota routes); a multi-provider route without an established
# binding is unmeasured, never bound to an arbitrary primary. Model and
# product scope matching uses the normalized spelling inside this function.
fm_quota_effective_for_provider_model() {
  local harness=${1:-} model=${2:-default} declared=${3:-}
  local snapshot validated provider scope_model lane
  [ -n "$harness" ] || return 1
  snapshot=$(cat) || return 1
  validated=$(printf '%s\n' "$snapshot" | fm_quota_snapshot_json) || return 1
  case "$declared" in
    '') ;;
    -*|*-|*--*|*[!a-z0-9-]*) return 1 ;;
  esac
  if [ -n "$declared" ]; then
    provider=$declared
  else
    case "$harness" in
      omp)
        case "${model#model:}" in
          openai-codex/*) provider=codex ;;
          claude-bridge/*) provider=claude ;;
          *)
            printf 'unmeasured\t1\tunmeasured\n'
            return 0 ;;
        esac ;;
      *)
        provider=$(fm_quota_single_provider_for_harness "$harness") || {
          printf 'unmeasured\t1\tunmeasured\n'
          return 0
        } ;;
    esac
  fi
  scope_model=${model#model:}
  [ "$harness" != omp ] || scope_model=${scope_model#*/}
  lane=$(jq -rn --arg h "$harness" --arg m "$model" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)') || return 1
  printf '%s\n' "$validated" |
  jq -r --arg provider "$provider" --arg model "$scope_model" --arg lane "$lane" "$FM_QUOTA_ROW_JQ"'
    ($model | sub("^model:"; "")) as $model_token |
    quota_row(.; $provider; $lane) as $p |
    if ($p // null) == null then "unmeasured\t1\tunmeasured"
    else ($p.quotaSemantics.effectiveAvailability // []) |
    map(select(.scope as $scope |
      $scope == "all_models" or $scope == "all_products" or
      ($model_token != "" and $model_token != "default" and
       (($scope | startswith("model:")) or ($scope | startswith("product:"))) and
       ($model_token == ($scope | sub("^(model|product):"; ""))))
    )) as $applicable |
    ($applicable | map(select(.status == "known"))) as $known |
    if ($applicable | length) == 0 then "unmeasured\t1\tunmeasured"
    elif any($applicable[]; (.runway.status // "") == "exhausted_now") then "exhausted\t2\texhausted-runway"
    elif ($known | length) == 0 then "unmeasured\t1\tunmeasured"
    elif any($known[]; .effectivePercentRemaining == 0) then "exhausted\t2\tzero-remaining"
    else "eligible\t0\tremaining=\(($known | map(.effectivePercentRemaining) | min | tostring))"
    end
    end
  ' 2>/dev/null
}
