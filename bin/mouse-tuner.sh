#!/usr/bin/env bash
# Mouse Tuner - per-device pointer tuning for Hyprland.
#
# Every subcommand prints exactly one JSON object on stdout. Errors are JSON
# too ({"ok":false,"error":"..."}) so the bar widget can always parse a reply.
#
#   devices                                  list pointing devices
#   status                                   list devices + managed entries
#   set --device N [flags]                   upsert one entry
#   remove --device N                        delete one entry
#   reset                                    delete the whole managed block
#
# `set` flags (all optional; unspecified fields keep their stored value):
#   --profile <flat|adaptive>                acceleration profile
#   --sensitivity <float>                    -1.00 .. 1.00
#   --natural-scroll <true|false>
#   --clickfinger <true|false>               clickfinger_behavior
#   --disable-while-typing <true|false>
#   --left-handed <true|false>
#   --middle-button-emulation <true|false>
#   --scroll-factor <float>                  clamped to 0.1 .. 8.0
#   --drag-lock <0|1>
#   --drag-3fg <0|1|2>
#   --unset <field>                          repeatable; drop a stored field
#
# `tap-to-click` and `tap-and-drag` are deliberately absent: Hyprland only
# accepts them globally under input:touchpad, never per device, and writing an
# unsupported field makes Hyprland reject the whole config.
#
# The tool owns one managed region inside ~/.config/hypr/input.lua. Every other
# byte of that file, and every other block in it, is left untouched. After each
# write it reloads Hyprland; if Hyprland reports any config error it restores
# the previous file byte for byte and fails rather than leaving a broken config.
set -euo pipefail

CONFIG="${HOME}/.config/hypr/input.lua"
LOCK="${HOME}/.config/hypr/.mouse-tuner.lock"
START_MARKER='-- [[ MOUSE_TUNER_START ]]'
END_MARKER='-- [[ MOUSE_TUNER_END ]]'
BLOCK_COMMENT='-- Managed by Mouse Tuner. Edit from the bar widget, not by hand.'

# The only fields Hyprland accepts inside hl.device({...}). Anything else is
# rejected before it can reach the config, because an unknown field makes
# Hyprland refuse the whole input block. Alphabetical order keeps the rendered
# lines deterministic no matter which flags were passed.
FIELD_ORDER=(
  accel_profile
  clickfinger_behavior
  disable_while_typing
  drag_3fg
  drag_lock
  left_handed
  middle_button_emulation
  natural_scroll
  scroll_button
  scroll_factor
  scroll_method
  sensitivity
  tap_button_map
)

is_allowed_field() {
  local f
  for f in "${FIELD_ORDER[@]}"; do [[ $f == "${1-}" ]] && return 0; done
  return 1
}

is_bool_field() {
  case "${1-}" in
    clickfinger_behavior|disable_while_typing|left_handed|middle_button_emulation|natural_scroll) return 0 ;;
    *) return 1 ;;
  esac
}

is_string_field() {
  case "${1-}" in
    accel_profile|scroll_method|tap_button_map) return 0 ;;
    *) return 1 ;;
  esac
}

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

# 0.80 -> 0.8, 1.00 -> 1.0, 0.05 -> 0.05. Always keeps a decimal point so the
# value reads as a Lua float.
fmt_float() {
  awk -v x="$1" 'BEGIN {
    s = sprintf("%.2f", x)
    sub(/0+$/, "", s)
    sub(/\.$/, ".0", s)
    print s
  }'
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
    def is_trackpad: ((.name // "") | test("touchpad|trackpad"; "i"));
    [ (.mice // [])[]
      | select(((.name // "") | test("consumer-control|system-control|fake")) | not)
      | { name: (.name // ""),
          label: ((.name // "") | gsub("[-_]"; " ") | titlecase),
          touchpad: is_trackpad } ]
  ' <<<"$raw" 2>/dev/null)" || DEVICES_JSON='[]'

  PRIMARY_NAME="$(jq -r '
    def is_trackpad: ((.name // "") | test("touchpad|trackpad"; "i"));
    [ (.mice // [])[]
      | select(((.name // "") | test("consumer-control|system-control|fake")) | not)
      | { name: (.name // ""), touchpad: is_trackpad } ]
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

# Entry state: ENT_ORDER holds device order, ENT_FIELDS is a "$device|$field"
# -> raw value map. Raw means unquoted for strings, bare for numbers/booleans.
declare -a ENT_ORDER=()
declare -A ENT_FIELDS=()

ent_key() { printf '%s|%s' "$1" "$2"; }

ent_has() { [[ -n ${ENT_FIELDS[$(ent_key "$1" "$2")]+x} ]]; }

trim() {
  local s=${1-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Matches the lines this tool writes, with or without fields.
ENTRY_RE='^hl\.device\(\{ name = "([^"]*)",[[:space:]]*(.*)[[:space:]]*\}\)$'
EMPTY_ENTRY_RE='^hl\.device\(\{ name = "([^"]*)"[[:space:]]*\}\)$'
PAIR_RE='^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$'

load_entries() {
  ENT_ORDER=()
  ENT_FIELDS=()
  local line d rest pair f v key
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    d=''
    rest=''
    if [[ $line =~ $ENTRY_RE ]]; then
      d="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
    elif [[ $line =~ $EMPTY_ENTRY_RE ]]; then
      d="${BASH_REMATCH[1]}"
      rest=''
    else
      continue
    fi
    [[ -n $d ]] || continue

    local seen=0 o
    for o in "${ENT_ORDER[@]:-}"; do [[ $o == "$d" ]] && seen=1; done
    (( seen )) || ENT_ORDER+=("$d")

    if [[ -n $rest ]]; then
      local IFS=','
      for pair in $rest; do
        pair="$(trim "$pair")"
        [[ $pair =~ $PAIR_RE ]] || continue
        f="${BASH_REMATCH[1]}"
        v="$(trim "${BASH_REMATCH[2]}")"
        is_allowed_field "$f" || continue
        if is_string_field "$f"; then
          [[ $v == \"*\" ]] || continue
          v="${v#\"}"
          v="${v%\"}"
        fi
        # Values we write never contain quotes, commas or control characters;
        # anything that does is a hand edit we refuse to feed back into Lua.
        case "$v" in ''|*'"'*|*,*|*$'\n'*|*$'\r'*) continue ;; esac
        key="$(ent_key "$d" "$f")"
        ENT_FIELDS["$key"]="$v"
      done
    fi
  done < <(read_block_lines)
}

render_body() {
  local d f key v line
  for d in "${ENT_ORDER[@]:-}"; do
    [[ -n $d ]] || continue
    line="hl.device({ name = \"$d\""
    for f in "${FIELD_ORDER[@]}"; do
      key="$(ent_key "$d" "$f")"
      [[ -n ${ENT_FIELDS[$key]+x} ]] || continue
      v="${ENT_FIELDS[$key]}"
      if is_string_field "$f"; then
        line+=", $f = \"$v\""
      else
        line+=", $f = $v"
      fi
    done
    line+=" })"
    printf '%s\n' "$line"
  done
}

# One JSON object per device entry, every field currently stored.
entry_json() {
  local d="$1" f key v
  printf '{"device":"%s"' "$(json_escape "$d")"
  for f in "${FIELD_ORDER[@]}"; do
    key="$(ent_key "$d" "$f")"
    [[ -n ${ENT_FIELDS[$key]+x} ]] || continue
    v="${ENT_FIELDS[$key]}"
    if is_string_field "$f"; then
      printf ',"%s":"%s"' "$f" "$(json_escape "$v")"
    else
      printf ',"%s":%s' "$f" "$v"
    fi
  done
  printf '}'
}

entries_json() {
  local d first=1
  printf '['
  for d in "${ENT_ORDER[@]:-}"; do
    [[ -n $d ]] || continue
    [[ $first -eq 1 ]] || printf ','
    first=0
    entry_json "$d"
  done
  printf ']'
}

# Rewrite CONFIG so the managed region contains `body` (or is removed when body
# is empty). Lines outside the markers are copied through unchanged. Returns
# non-zero instead of exiting so the caller can clean up first.
write_managed() {
  local body=${1-}
  local dir input tmp
  dir="$(dirname "$CONFIG")"
  mkdir -p "$dir"
  input="$CONFIG"
  [[ -f $CONFIG ]] || input=/dev/null

  tmp="$(mktemp "$dir/.input.lua.mouse-tuner.XXXXXX")" || return 1
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
    return 1
  fi

  if [[ -f $CONFIG ]]; then
    chmod --reference="$CONFIG" "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$CONFIG" || { rm -f "$tmp"; return 1; }
  return 0
}

# --- locking ----------------------------------------------------------------

with_lock() {
  if command -v flock >/dev/null 2>&1; then
    mkdir -p "$(dirname "$LOCK")"
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

# Print an error JSON captured from a failed apply and exit. Used because the
# failure travels back through a command substitution, where `set -e` would
# otherwise end the script before the message could reach stdout.
abort_with() {
  local out="${1-}"
  [[ -n $out ]] || out='{"ok":false,"error":"failed to apply the configuration"}'
  printf '%s\n' "$out"
  exit 1
}

# Write the managed block, reload Hyprland, and verify the config still parses.
# On any config error the previous file is restored byte for byte, Hyprland is
# reloaded again, and the command fails with the Hyprland error text. On
# success it prints the reload result.
apply_block() {
  local body="$1"
  local dir prev prev_existed=0 tmp errs reload_out
  dir="$(dirname "$CONFIG")"
  mkdir -p "$dir"

  prev="$(mktemp "$dir/.mouse-tuner.prev.XXXXXX")" || fail_json "cannot create a config backup"
  if [[ -f $CONFIG ]]; then
    cp -- "$CONFIG" "$prev" || { rm -f "$prev"; fail_json "cannot back up $CONFIG"; }
    prev_existed=1
  fi

  if ! write_managed "$body"; then
    rm -f "$prev"
    fail_json "failed to rewrite $CONFIG"
  fi

  reload_out="$(run_reload)"

  errs="$(hyprctl configerrors 2>/dev/null | sed -e 's/\r$//' -e '/^[[:space:]]*$/d' || true)"
  if [[ -n $errs ]]; then
    if (( prev_existed )); then
      tmp="$(mktemp "$dir/.mouse-tuner.restore.XXXXXX")" || tmp=''
      if [[ -n $tmp ]] && cat -- "$prev" >"$tmp"; then
        chmod --reference="$CONFIG" "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$CONFIG" || rm -f "$tmp"
      else
        [[ -n $tmp ]] && rm -f "$tmp"
        # Last resort: restore in place.
        cat -- "$prev" >"$CONFIG"
      fi
    else
      rm -f "$CONFIG"
    fi
    run_reload >/dev/null 2>&1 || true
    rm -f "$prev"
    fail_json "Hyprland rejected the config and it was rolled back: $errs"
  fi

  rm -f "$prev"
  printf '%s' "$reload_out"
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
  local dev=''
  local -A set_fields=()
  local -a unset_fields=()
  local have_action=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        [[ $# -ge 2 ]] || fail_json "--device requires a value"
        dev="$2"; shift 2 ;;
      --profile)
        [[ $# -ge 2 ]] || fail_json "--profile requires a value"
        [[ $2 == flat || $2 == adaptive ]] || fail_json "profile must be 'flat' or 'adaptive'"
        set_fields[accel_profile]="$2"; have_action=1; shift 2 ;;
      --sensitivity)
        [[ $# -ge 2 ]] || fail_json "--sensitivity requires a value"
        [[ $2 =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || fail_json "sensitivity must be a number"
        awk -v x="$2" 'BEGIN { exit !(x >= -1 && x <= 1) }' \
          || fail_json "sensitivity must be between -1.00 and 1.00"
        set_fields[sensitivity]="$(printf '%.2f' "$2")"; have_action=1; shift 2 ;;
      --natural-scroll)
        [[ $# -ge 2 ]] || fail_json "--natural-scroll requires a value"
        [[ $2 == true || $2 == false ]] || fail_json "--natural-scroll must be true or false"
        set_fields[natural_scroll]="$2"; have_action=1; shift 2 ;;
      --clickfinger)
        [[ $# -ge 2 ]] || fail_json "--clickfinger requires a value"
        [[ $2 == true || $2 == false ]] || fail_json "--clickfinger must be true or false"
        set_fields[clickfinger_behavior]="$2"; have_action=1; shift 2 ;;
      --disable-while-typing)
        [[ $# -ge 2 ]] || fail_json "--disable-while-typing requires a value"
        [[ $2 == true || $2 == false ]] || fail_json "--disable-while-typing must be true or false"
        set_fields[disable_while_typing]="$2"; have_action=1; shift 2 ;;
      --left-handed)
        [[ $# -ge 2 ]] || fail_json "--left-handed requires a value"
        [[ $2 == true || $2 == false ]] || fail_json "--left-handed must be true or false"
        set_fields[left_handed]="$2"; have_action=1; shift 2 ;;
      --middle-button-emulation)
        [[ $# -ge 2 ]] || fail_json "--middle-button-emulation requires a value"
        [[ $2 == true || $2 == false ]] || fail_json "--middle-button-emulation must be true or false"
        set_fields[middle_button_emulation]="$2"; have_action=1; shift 2 ;;
      --scroll-factor)
        [[ $# -ge 2 ]] || fail_json "--scroll-factor requires a value"
        [[ $2 =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || fail_json "scroll factor must be a number"
        local clamped
        clamped="$(awk -v x="$2" 'BEGIN { if (x < 0.1) x = 0.1; if (x > 8.0) x = 8.0; printf "%.2f", x }')"
        set_fields[scroll_factor]="$(fmt_float "$clamped")"; have_action=1; shift 2 ;;
      --drag-lock)
        [[ $# -ge 2 ]] || fail_json "--drag-lock requires a value"
        [[ $2 =~ ^[0-9]+$ ]] || fail_json "drag lock must be an integer"
        (( $2 <= 1 )) || fail_json "drag lock must be 0 or 1"
        set_fields[drag_lock]="$2"; have_action=1; shift 2 ;;
      --drag-3fg)
        [[ $# -ge 2 ]] || fail_json "--drag-3fg requires a value"
        [[ $2 =~ ^[0-9]+$ ]] || fail_json "drag-3fg must be an integer"
        (( $2 <= 2 )) || fail_json "drag-3fg must be 0, 1 or 2"
        set_fields[drag_3fg]="$2"; have_action=1; shift 2 ;;
      --unset)
        [[ $# -ge 2 ]] || fail_json "--unset requires a field name"
        is_allowed_field "$2" || fail_json "unknown field: $2"
        unset_fields+=("$2"); have_action=1; shift 2 ;;
      *)
        fail_json "unknown argument: $1" ;;
    esac
  done

  [[ -n $dev ]] || fail_json "--device is required"
  is_safe_name "$dev" || fail_json "refusing unsafe device name: $dev"
  (( have_action )) || fail_json "provide at least one setting flag or --unset"

  collect_devices
  device_exists "$dev" || fail_json "unknown device: $dev (not present in hyprctl devices)"

  load_entries

  # Effective state: start from what is stored, drop unsets, then apply sets.
  local -A eff=()
  local f key
  for f in "${FIELD_ORDER[@]}"; do
    key="$(ent_key "$dev" "$f")"
    [[ -n ${ENT_FIELDS[$key]+x} ]] && eff["$f"]="${ENT_FIELDS[$key]}"
  done
  for f in "${unset_fields[@]}"; do unset "eff[$f]"; done
  for f in "${!set_fields[@]}"; do eff["$f"]="${set_fields[$f]}"; done

  # Fold the effective state back into the shared store.
  local any=0
  for f in "${FIELD_ORDER[@]}"; do
    key="$(ent_key "$dev" "$f")"
    if [[ -n ${eff[$f]+x} ]]; then
      ENT_FIELDS["$key"]="${eff[$f]}"
      any=1
    else
      unset "ENT_FIELDS[$key]"
    fi
  done

  local in_order=0 d
  for d in "${ENT_ORDER[@]:-}"; do [[ $d == "$dev" ]] && in_order=1; done
  if (( any )); then
    (( in_order )) || ENT_ORDER+=("$dev")
  else
    local -a kept=()
    for d in "${ENT_ORDER[@]:-}"; do
      [[ -n $d && $d != "$dev" ]] && kept+=("$d")
    done
    ENT_ORDER=("${kept[@]:-}")
  fi

  local reload_out
  if ! reload_out="$(apply_block "$(render_body)")"; then abort_with "$reload_out"; fi

  printf '{"ok":true,"applied":%s,"configPath":"%s","reload":"%s","entries":%s}\n' \
    "$(entry_json "$dev")" "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")" "$(entries_json)"
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
  local f key d
  for f in "${FIELD_ORDER[@]}"; do
    unset "ENT_FIELDS[$(ent_key "$dev" "$f")]" 2>/dev/null || true
  done
  local -a kept=()
  for d in "${ENT_ORDER[@]:-}"; do
    [[ -n $d && $d != "$dev" ]] && kept+=("$d")
  done
  ENT_ORDER=("${kept[@]:-}")

  local reload_out
  if ! reload_out="$(apply_block "$(render_body)")"; then abort_with "$reload_out"; fi

  printf '{"ok":true,"removed":"%s","configPath":"%s","reload":"%s","entries":%s}\n' \
    "$(json_escape "$dev")" "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")" "$(entries_json)"
}

cmd_reset() {
  local reload_out
  if ! reload_out="$(apply_block "")"; then abort_with "$reload_out"; fi
  printf '{"ok":true,"reset":true,"configPath":"%s","reload":"%s","entries":[]}\n' \
    "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")"
}

usage() {
  cat <<'EOF'
Mouse Tuner helper

Usage:
  mouse-tuner.sh devices
  mouse-tuner.sh status
  mouse-tuner.sh set --device <name> [flags]
  mouse-tuner.sh remove --device <name>
  mouse-tuner.sh reset

set flags (all optional; only what you pass is written):
  --profile <flat|adaptive>
  --sensitivity <-1..1>
  --natural-scroll <true|false>
  --clickfinger <true|false>
  --disable-while-typing <true|false>
  --left-handed <true|false>
  --middle-button-emulation <true|false>
  --scroll-factor <0.1..8.0>
  --drag-lock <0|1>
  --drag-3fg <0|1|2>
  --unset <field>            repeatable

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
