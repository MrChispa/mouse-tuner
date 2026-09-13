#!/usr/bin/env bash
# Mouse Tuner - per-device mouse/trackball configuration for Hyprland.
#
# Every subcommand prints exactly one JSON object on stdout. Errors are JSON
# too ({"ok":false,"error":"..."}) so the bar widget can always parse a reply.
#
#   devices                                  list pointing devices
#   status                                   list devices + managed entries
#   set --device N [--profile P] [--sensitivity S]   upsert one entry
#   remove --device N                        delete one entry
#   reset                                    delete the whole managed block
#
# The tool owns one managed region inside ~/.config/hypr/input.lua. Every
# other byte of that file, and every other block in it, is left untouched.
set -euo pipefail

CONFIG="${HOME}/.config/hypr/input.lua"
LOCK="${HOME}/.config/hypr/.mouse-tuner.lock"
START_MARKER='-- [[ MOUSE_TUNER_START ]]'
END_MARKER='-- [[ MOUSE_TUNER_END ]]'
BLOCK_COMMENT='-- Managed by Mouse Tuner. Edit from the bar widget, not by hand.'

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

fail_json() {
  printf '{"ok":false,"error":"%s"}\n' "$(json_escape "${1:-unknown error}")"
  exit 1
}

# --- device discovery -------------------------------------------------------

DEVICES_JSON='[]'
PRIMARY_NAME=''

collect_devices() {
  local raw
  raw="$(hyprctl devices -j 2>/dev/null || true)"
  if [[ -z $raw ]]; then
    DEVICES_JSON='[]'
    PRIMARY_NAME=''
    return 0
  fi

  DEVICES_JSON="$(jq -c '
    def titlecase:
      split(" ")
      | map(if length > 0 then (.[0:1] | ascii_upcase) + .[1:] else . end)
      | join(" ");
    [ (.mice // [])[]
      | select(((.name // "") | test("consumer-control|system-control|fake")) | not)
      | { name: (.name // ""),
          label: ((.name // "") | gsub("[-_]"; " ") | titlecase),
          touchpad: ((.name // "") | test("touchpad")) } ]
  ' <<<"$raw" 2>/dev/null)" || DEVICES_JSON='[]'

  PRIMARY_NAME="$(jq -r '
    [ (.mice // [])[]
      | select(((.name // "") | test("consumer-control|system-control|fake")) | not)
      | { name: (.name // ""), touchpad: ((.name // "") | test("touchpad")) } ]
    | (map(select(.touchpad | not)) | .[0].name) // (.[0].name) // ""
  ' <<<"$raw" 2>/dev/null)" || PRIMARY_NAME=''
}

device_exists() {
  jq -e --arg d "$1" 'any(.[]; .name == $d)' <<<"$DEVICES_JSON" >/dev/null 2>&1
}

is_safe_name() {
  local n=${1-}
  [[ -n $n ]] || return 1
  [[ $n != *"/"* ]] || return 1
  [[ $n != *'"'* ]] || return 1
  [[ $n != *"'"* ]] || return 1
  [[ $n != *'\'* ]] || return 1
  [[ $n != *".."* ]] || return 1
  [[ $n != *[[:space:]]* ]] || return 1
  [[ $n != *$'\n'* && $n != *$'\r'* ]] || return 1
  return 0
}

# --- managed block parsing --------------------------------------------------

read_block_lines() {
  [[ -f $CONFIG ]] || return 0
  awk -v s="$START_MARKER" -v e="$END_MARKER" '
    $0 == s { inblock = 1; next }
    inblock && $0 == e { inblock = 0; next }
    inblock { print }
  ' "$CONFIG"
}

parse_entry_line() {
  local line=${1-}
  local re='^hl\.device\(\{ name = "([^"\\]*)", accel_profile = "(flat|adaptive)", sensitivity = (-?[0-9]+(\.[0-9]+)?) \}\)$'
  if [[ $line =~ $re ]]; then
    printf '%s|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  fi
}

declare -a ENT_ORDER=()
declare -A ENT_PROFILE=()
declare -A ENT_SENS=()

load_entries() {
  ENT_ORDER=()
  ENT_PROFILE=()
  ENT_SENS=()
  local line parsed d p s
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    parsed="$(parse_entry_line "$line")"
    [[ -n $parsed ]] || continue
    IFS='|' read -r d p s <<<"$parsed"
    if [[ -z ${ENT_PROFILE[$d]+x} ]]; then
      ENT_ORDER+=("$d")
    fi
    ENT_PROFILE["$d"]="$p"
    ENT_SENS["$d"]="$s"
  done < <(read_block_lines)
}

render_body() {
  local d
  for d in "${ENT_ORDER[@]:-}"; do
    [[ -n $d ]] || continue
    printf 'hl.device({ name = "%s", accel_profile = "%s", sensitivity = %s })\n' \
      "$d" "${ENT_PROFILE[$d]}" "${ENT_SENS[$d]}"
  done
}

entries_json() {
  local d first=1
  printf '['
  for d in "${ENT_ORDER[@]:-}"; do
    [[ -n $d ]] || continue
    [[ $first -eq 1 ]] || printf ','
    first=0
    jq -jcn --arg d "$d" --arg p "${ENT_PROFILE[$d]}" \
      --argjson s "${ENT_SENS[$d]}" \
      '{device:$d, accel_profile:$p, sensitivity:$s}'
  done
  printf ']'
}

# Rewrite CONFIG so the managed region contains `body` (or is removed when
# body is empty). Lines outside the markers are copied through unchanged.
write_managed() {
  local body=${1-}
  local dir input tmp
  dir="$(dirname "$CONFIG")"
  mkdir -p "$dir"
  input="$CONFIG"
  [[ -f $CONFIG ]] || input=/dev/null

  tmp="$(mktemp "$dir/.input.lua.mouse-tuner.XXXXXX")"
  if ! awk -v s="$START_MARKER" -v e="$END_MARKER" -v body="$body" -v comment="$BLOCK_COMMENT" '
    $0 == s {
      if (body != "") {
        print s
        print comment
        n = split(body, L, "\n")
        for (i = 1; i <= n; i++) print L[i]
        print e
      }
      inblock = 1
      seen = 1
      next
    }
    inblock { if ($0 == e) inblock = 0; next }
    { print }
    END {
      if (!seen && body != "") {
        print s
        print comment
        n = split(body, L, "\n")
        for (i = 1; i <= n; i++) print L[i]
        print e
      }
    }
  ' "$input" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail_json "failed to rewrite $CONFIG"
  fi

  if [[ -f $CONFIG ]]; then
    chmod --reference="$CONFIG" "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$CONFIG"
}

# --- locking ----------------------------------------------------------------

with_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    flock -x 9
    "$@"
    return $?
  fi

  local d="${LOCK}.d" tries=0
  while ! mkdir "$d" 2>/dev/null; do
    tries=$((tries + 1))
    [[ $tries -gt 400 ]] && fail_json "timed out waiting for the config lock"
    sleep 0.05
  done
  trap 'rmdir "$d" 2>/dev/null || true' EXIT
  "$@"
  local rc=$?
  rmdir "$d" 2>/dev/null || true
  trap - EXIT
  return $rc
}

run_reload() {
  local out
  if out="$(hyprctl reload 2>&1)"; then
    printf '%s' "${out:-ok}"
  else
    printf 'failed: %s' "${out:-unknown error}"
  fi
}

# --- subcommands ------------------------------------------------------------

cmd_devices() {
  collect_devices
  printf '{"ok":true,"devices":%s,"primary":"%s"}\n' \
    "$DEVICES_JSON" "$(json_escape "$PRIMARY_NAME")"
}

cmd_status() {
  collect_devices
  load_entries
  printf '{"ok":true,"configPath":"%s","entries":%s,"devices":%s,"primary":"%s"}\n' \
    "$(json_escape "$CONFIG")" "$(entries_json)" "$DEVICES_JSON" "$(json_escape "$PRIMARY_NAME")"
}

cmd_set() {
  local dev='' profile='' sens=''
  local have_profile=0 have_sens=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        [[ $# -ge 2 ]] || fail_json "--device requires a value"
        dev="$2"; shift 2 ;;
      --profile)
        [[ $# -ge 2 ]] || fail_json "--profile requires a value"
        profile="$2"; have_profile=1; shift 2 ;;
      --sensitivity)
        [[ $# -ge 2 ]] || fail_json "--sensitivity requires a value"
        sens="$2"; have_sens=1; shift 2 ;;
      *)
        fail_json "unknown argument: $1" ;;
    esac
  done

  [[ -n $dev ]] || fail_json "--device is required"
  is_safe_name "$dev" || fail_json "refusing unsafe device name: $dev"
  (( have_profile || have_sens )) || fail_json "provide --profile and/or --sensitivity"

  if (( have_profile )) && [[ $profile != flat && $profile != adaptive ]]; then
    fail_json "profile must be 'flat' or 'adaptive'"
  fi

  local sens_fmt=''
  if (( have_sens )); then
    [[ $sens =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || fail_json "sensitivity must be a number"
    awk -v x="$sens" 'BEGIN { exit !(x >= -1 && x <= 1) }' \
      || fail_json "sensitivity must be between -1.00 and 1.00"
    sens_fmt="$(printf '%.2f' "$sens")"
  fi

  collect_devices
  device_exists "$dev" || fail_json "unknown device: $dev (not present in hyprctl devices)"

  load_entries

  local eff_profile eff_sens
  if (( have_profile )); then
    eff_profile="$profile"
  elif [[ -n ${ENT_PROFILE[$dev]+x} ]]; then
    eff_profile="${ENT_PROFILE[$dev]}"
  else
    eff_profile='adaptive'
  fi

  if (( have_sens )); then
    eff_sens="$sens_fmt"
  elif [[ -n ${ENT_SENS[$dev]+x} ]]; then
    eff_sens="${ENT_SENS[$dev]}"
  else
    eff_sens='0.00'
  fi

  if [[ -z ${ENT_PROFILE[$dev]+x} ]]; then
    ENT_ORDER+=("$dev")
  fi
  ENT_PROFILE["$dev"]="$eff_profile"
  ENT_SENS["$dev"]="$eff_sens"

  write_managed "$(render_body)"
  local reload_out
  reload_out="$(run_reload)"

  printf '{"ok":true,"applied":{"device":"%s","accel_profile":"%s","sensitivity":%s},"configPath":"%s","reload":"%s","entries":%s}\n' \
    "$(json_escape "$dev")" "$(json_escape "$eff_profile")" "$eff_sens" \
    "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")" "$(entries_json)"
}

cmd_remove() {
  local dev=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        [[ $# -ge 2 ]] || fail_json "--device requires a value"
        dev="$2"; shift 2 ;;
      *)
        fail_json "unknown argument: $1" ;;
    esac
  done

  [[ -n $dev ]] || fail_json "--device is required"
  is_safe_name "$dev" || fail_json "refusing unsafe device name: $dev"

  load_entries
  if [[ -n ${ENT_PROFILE[$dev]+x} ]]; then
    unset 'ENT_PROFILE[$dev]' 'ENT_SENS[$dev]'
    local -a kept=()
    local d
    for d in "${ENT_ORDER[@]:-}"; do
      [[ -n $d && $d != "$dev" ]] && kept+=("$d")
    done
    ENT_ORDER=("${kept[@]:-}")
  fi

  write_managed "$(render_body)"
  local reload_out
  reload_out="$(run_reload)"

  printf '{"ok":true,"removed":"%s","configPath":"%s","reload":"%s","entries":%s}\n' \
    "$(json_escape "$dev")" "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")" "$(entries_json)"
}

cmd_reset() {
  write_managed ""
  local reload_out
  reload_out="$(run_reload)"
  printf '{"ok":true,"reset":true,"configPath":"%s","reload":"%s","entries":[]}\n' \
    "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")"
}

usage() {
  cat <<'EOF'
Mouse Tuner helper

Usage:
  mouse-tuner.sh devices
  mouse-tuner.sh status
  mouse-tuner.sh set --device <name> [--profile <flat|adaptive>] [--sensitivity <-1..1>]
  mouse-tuner.sh remove --device <name>
  mouse-tuner.sh reset

Every command prints one JSON object on stdout.
EOF
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift

  case "$cmd" in
    devices) cmd_devices "$@" ;;
    status) cmd_status "$@" ;;
    set) with_lock cmd_set "$@" ;;
    remove) with_lock cmd_remove "$@" ;;
    reset) with_lock cmd_reset "$@" ;;
    ''|-h|--help) usage ;;
    *) fail_json "unknown subcommand: $cmd" ;;
  esac
}

main "$@"
