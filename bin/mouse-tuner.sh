#!/usr/bin/env bash
# Mouse Tuner - per-device pointer tuning for Hyprland.
#
# Every subcommand prints exactly one JSON object on stdout. Errors are JSON
# too ({"ok":false,"error":"..."}) so the bar widget can always parse a reply.
#
#   devices                                  list pointing devices (with battery)
#   status                                   list devices + managed entries
#   battery --device N                       battery level for one device
#   set --device N [flags]                   upsert one entry
#   remove --device N                        delete one entry
#   reset                                    delete the whole managed block
#
#   gestures                                 list managed gestures + the catalog
#   gesture-set --fingers N --direction D [--action A] [extras]
#                                            upsert one gesture (owns its own block)
#   gesture-unset --fingers N --direction D [--mods M]
#                                            remove one gesture
#   gestures-reset                           delete the whole gestures block
#   gestures-import                          take over hl.gesture lines defined
#                                            outside the managed block
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
#
# Hyprland keeps the FIRST definition of a gesture and ignores later ones. A
# hand-written hl.gesture(...) outside this tool's block (usually above it)
# therefore shadows the managed line: the panel looks dead and Hyprland logs
# "Gesture will be overshadowed by a previous gesture". The helper reports such
# lines as `unmanaged` and `gestures-import` moves them inside the block so
# there is a single source of truth.
set -euo pipefail

CONFIG="${HOME}/.config/hypr/input.lua"
LOCK="${HOME}/.config/hypr/.mouse-tuner.lock"
START_MARKER='-- [[ MOUSE_TUNER_START ]]'
END_MARKER='-- [[ MOUSE_TUNER_END ]]'
GESTURE_START_MARKER='-- [[ MOUSE_TUNER_GESTURES_START ]]'
GESTURE_END_MARKER='-- [[ MOUSE_TUNER_GESTURES_END ]]'
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

# --- battery discovery ------------------------------------------------------
#
# Root-free battery reporting. The kernel exposes a HID device's battery as a
# power_supply of its own, named after the device's Bluetooth/USB unique id:
#
#   /sys/class/power_supply/hid-<uniq-lowercased>-battery-<n>/capacity
#   /sys/class/power_supply/hid-<uniq-lowercased>-battery-<n>/status
#
# /proc/bus/input/devices is the bridge between a kernel device name and that
# uniq, and Hyprland's device name is the kernel name lowercased with spaces
# turned into dashes. Devices the kernel does not expose a battery for simply
# get `null`: this never guesses or invents a level.

# Kernel device name -> Hyprland device name.
hypr_name_from_kernel() {
  local n=${1-}
  printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

# uniq -> JSON battery object, or the literal `null`.
battery_json_for_uniq() {
  local uniq_lc dir cand capacity status
  uniq_lc="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')"
  [[ -n $uniq_lc ]] || { printf 'null'; return 0; }

  dir=''
  for cand in "/sys/class/power_supply/hid-${uniq_lc}-battery" \
              /sys/class/power_supply/hid-${uniq_lc}-battery-*; do
    if [[ -d $cand ]]; then dir=$cand; break; fi
  done
  [[ -n $dir ]] || { printf 'null'; return 0; }

  capacity="$(cat "$dir/capacity" 2>/dev/null || true)"
  status="$(cat "$dir/status" 2>/dev/null || true)"
  capacity="${capacity//[$'\r\n\t ']/}"
  status="${status//[$'\r\n']/}"
  # An unreadable or non-numeric capacity is not a battery reading.
  [[ $capacity =~ ^[0-9]+$ ]] || { printf 'null'; return 0; }
  [[ -n $status ]] || status="Unknown"

  printf '{"percent":%s,"state":"%s"}' "$capacity" "$(json_escape "$status")"
}

# device name -> uniq, taken from /proc/bus/input/devices (blocks separated by
# blank lines). Blocks without a uniq cannot be matched and are skipped.
declare -A BATTERY_MAP=()
BATTERY_BY_NAME_JSON='{}'

build_battery_map() {
  BATTERY_MAP=()
  BATTERY_BY_NAME_JSON='{}'
  [[ -r /proc/bus/input/devices ]] || return 0

  local name='' uniq='' line pair
  local -a pairs=()
  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in
      'N: Name='*)
        name="${line#N: Name=}"
        name="${name#\"}"; name="${name%\"}"
        ;;
      'U: Uniq='*)
        uniq="${line#U: Uniq=}"
        ;;
      '')
        if [[ -n $name && -n $uniq ]]; then
          pairs+=("$(hypr_name_from_kernel "$name")|$uniq")
        fi
        name=''; uniq=''
        ;;
    esac
  done < /proc/bus/input/devices
  # A final block that has no trailing blank line.
  if [[ -n $name && -n $uniq ]]; then
    pairs+=("$(hypr_name_from_kernel "$name")|$uniq")
  fi

  local key val out='{' first=1
  for pair in "${pairs[@]:-}"; do
    [[ -n $pair ]] || continue
    key="${pair%%|*}"
    uniq="${pair#*|}"
    val="$(battery_json_for_uniq "$uniq")"
    [[ $val == null ]] && continue
    BATTERY_MAP["$key"]="$val"
    [[ $first -eq 1 ]] || out+=','
    first=0
    out+="\"$(json_escape "$key")\":$val"
  done
  BATTERY_BY_NAME_JSON="$out}"
  return 0
}

# --- device discovery -------------------------------------------------------

DEVICES_JSON='[]'
PRIMARY_NAME=''

collect_devices() {
  local raw
  build_battery_map
  raw="$(hyprctl devices -j 2>/dev/null || true)"
  if [[ -z $raw ]]; then
    DEVICES_JSON='[]'
    PRIMARY_NAME=''
    return 0
  fi

  # The battery comes from the same batched `hyprctl devices` read above: every
  # device carries its own `battery` (or `null`), so the widget never has to
  # call the helper once per device.
  DEVICES_JSON="$(jq -c --argjson bat "$BATTERY_BY_NAME_JSON" '
    def titlecase:
      split(" ")
      | map(if length > 0 then (.[0:1] | ascii_upcase) + .[1:] else . end)
      | join(" ");
    def is_trackpad: ((.name // "") | test("touchpad|trackpad"; "i"));
    [ (.mice // [])[]
      | select(((.name // "") | test("consumer-control|system-control|fake")) | not)
      | { name: (.name // ""),
          label: ((.name // "") | gsub("[-_]"; " ") | titlecase),
          touchpad: is_trackpad,
          battery: ($bat[(.name // "")] // null) } ]
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
  local start="${1:-$START_MARKER}" end="${2:-$END_MARKER}"
  [[ -f $CONFIG ]] || return 0
  awk -v s="$start" -v e="$end" '
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
# is empty). Lines outside the markers are copied through unchanged. An optional
# 4th argument reads from another file instead of CONFIG (used by
# gestures-import, which first filters out the lines it is taking over). Returns
# non-zero instead of exiting so the caller can clean up first.
write_managed() {
  local body=${1-} start="${2:-$START_MARKER}" end="${3:-$END_MARKER}" src="${4-}"
  local dir input tmp
  dir="$(dirname "$CONFIG")"
  mkdir -p "$dir"
  input="${src:-$CONFIG}"
  [[ -f $input ]] || input=/dev/null

  tmp="$(mktemp "$dir/.input.lua.mouse-tuner.XXXXXX")" || return 1
  if ! awk -v s="$start" -v e="$end" -v body="$body" -v comment="$BLOCK_COMMENT" '
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
  local body="$1" start="${2:-$START_MARKER}" end="${3:-$END_MARKER}" src="${4-}"
  local dir prev prev_existed=0 tmp errs reload_out
  dir="$(dirname "$CONFIG")"
  mkdir -p "$dir"

  prev="$(mktemp "$dir/.mouse-tuner.prev.XXXXXX")" || fail_json "cannot create a config backup"
  if [[ -f $CONFIG ]]; then
    cp -- "$CONFIG" "$prev" || { rm -f "$prev"; fail_json "cannot back up $CONFIG"; }
    prev_existed=1
  fi

  if ! write_managed "$body" "$start" "$end" "$src"; then
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

# --- gesture management ------------------------------------------------------
#
# Gestures live in their own managed region, so `reset` (devices) and
# `gestures-reset` stay independent. Each rendered line is exactly what
# Hyprland's Lua API accepts:
#
#   hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
#
# Hyprland refuses the whole config on an unknown field or action, so every
# value is validated here before it reaches the file and the same
# rollback-on-configerror safety as `set` applies.

G_DIRECTIONS='horizontal vertical left right up down swipe pinch pinchin pinchout'
G_ACTIONS='workspace move resize special close fullscreen float cursor_zoom scroll_move none'
G_MODES='maximize float tile mult live'

G_FIELD_ORDER=(
  fingers
  direction
  mods
  scale
  action
  workspace_name
  mode
  zoom_level
  disable_inhibit
)

g_is_string_field() {
  case "${1-}" in
    direction|mods|action|workspace_name|mode) return 0 ;;
    *) return 1 ;;
  esac
}

in_list() { # value, space separated list
  local v="${1-}" list="${2-}" item
  for item in $list; do [[ $item == "$v" ]] && return 0; done
  return 1
}

g_key() { printf '%s|%s|%s' "${1-}" "${2-}" "${3-}"; }

declare -a G_ORDER=()
declare -A G_FIELDS=()

GESTURE_RE='^hl\.gesture\(\{[[:space:]]*(.*)[[:space:]]*\}\)$'
G_PAIR_RE='^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$'

load_gestures() {
  G_ORDER=()
  G_FIELDS=()
  local line inner pair f v key
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    [[ $line =~ $GESTURE_RE ]] || continue
    inner="${BASH_REMATCH[1]}"
    [[ -n $inner ]] || continue

    local key_f='' key_d='' key_m=''
    local -a tmp_f=() tmp_v=()
    local IFS=','
    for pair in $inner; do
      pair="$(trim "$pair")"
      [[ $pair =~ $G_PAIR_RE ]] || continue
      f="${BASH_REMATCH[1]}"
      v="$(trim "${BASH_REMATCH[2]}")"
      case "$f" in
        fingers|direction|mods|scale|action|workspace_name|mode|zoom_level|disable_inhibit) ;;
        *) continue ;;
      esac
      if [[ $v == \"*\" ]]; then
        v="${v#\"}"
        v="${v%\"}"
      fi
      case "$v" in ''|*'"'*|*$'\n'*|*$'\r'*|*,*) continue ;; esac
      tmp_f+=("$f")
      tmp_v+=("$v")
      case "$f" in
        fingers) key_f="$v" ;;
        direction) key_d="$v" ;;
        mods) key_m="$v" ;;
      esac
    done
    unset IFS
    [[ -n $key_f && -n $key_d ]] || continue
    key="$(g_key "$key_f" "$key_d" "$key_m")"
    local seen=0 o
    for o in "${G_ORDER[@]:-}"; do [[ $o == "$key" ]] && seen=1; done
    (( seen )) || G_ORDER+=("$key")
    local i
    for i in "${!tmp_f[@]}"; do
      G_FIELDS["${key}|${tmp_f[$i]}"]="${tmp_v[$i]}"
    done
  done < <(read_block_lines "$GESTURE_START_MARKER" "$GESTURE_END_MARKER")
}

g_get() { printf '%s' "${G_FIELDS[$(g_key "$1" "$2" "$3")|$4]-}"; }
g_has() { [[ -n ${G_FIELDS[$(g_key "$1" "$2" "$3")|$4]+x} ]]; }
g_put() { G_FIELDS["$(g_key "$1" "$2" "$3")|$4"]="$5"; }
g_drop() { unset "G_FIELDS[$(g_key "$1" "$2" "$3")|$4]" 2>/dev/null || true; }

split_g_key() { # key -> sets G_F G_D G_M
  local IFS='|'
  local -a parts=()
  read -r -a parts <<<"${1-}"
  G_F="${parts[0]-}"
  G_D="${parts[1]-}"
  G_M="${parts[2]-}"
}

render_gesture() { # key
  local key="$1"
  split_g_key "$key"
  local line="hl.gesture({ fingers = $G_F, direction = \"$G_D\""
  local v
  [[ -n $G_M ]] && line+=", mods = \"$G_M\""
  v="$(g_get "$G_F" "$G_D" "$G_M" scale)"
  [[ -n $v ]] && line+=", scale = $v"
  v="$(g_get "$G_F" "$G_D" "$G_M" action)"
  [[ -n $v ]] && line+=", action = \"$v\""
  v="$(g_get "$G_F" "$G_D" "$G_M" workspace_name)"
  [[ -n $v ]] && line+=", workspace_name = \"$v\""
  v="$(g_get "$G_F" "$G_D" "$G_M" mode)"
  [[ -n $v ]] && line+=", mode = \"$v\""
  v="$(g_get "$G_F" "$G_D" "$G_M" zoom_level)"
  [[ -n $v ]] && line+=", zoom_level = $v"
  v="$(g_get "$G_F" "$G_D" "$G_M" disable_inhibit)"
  [[ -n $v ]] && line+=", disable_inhibit = $v"
  printf '%s\n' "$line })"
}

render_gestures_body() {
  local key
  for key in "${G_ORDER[@]:-}"; do
    [[ -n $key ]] || continue
    render_gesture "$key"
  done
}

# --- unmanaged gestures ------------------------------------------------------
#
# Every hl.gesture(...) line that is NOT between the gestures markers belongs to
# the user, and the first one in the file wins. The panel must know about them:
# `gestures` and `status` report them as `unmanaged`, gesture-set/unset refuse
# to fight them, and `gestures-import` takes them over.

# Print "<line number>\t<raw line>" for each unmanaged hl.gesture(...) line.
unmanaged_gesture_lines() {
  [[ -f $CONFIG ]] || return 0
  awk -v s="$GESTURE_START_MARKER" -v e="$GESTURE_END_MARKER" '
    $0 == s { inblock = 1; next }
    inblock && $0 == e { inblock = 0; next }
    inblock { next }
    /^[[:space:]]*hl\.gesture\(/ { printf "%d\t%s\n", NR, $0 }
  ' "$CONFIG"
}

# Best-effort parse of one raw line into the U_* globals. Only the fields the
# docs promise are extracted (fingers, direction, mods, action); the raw line is
# always kept. Returns non-zero when the line is not a usable gesture (no
# fingers or direction), so callers can skip it safely.
U_LINE=''; U_RAW=''; U_F=''; U_D=''; U_M=''; U_ACTION=''
parse_unmanaged_gesture() {
  local lineno="$1" raw="$2" line
  line="$(trim "$raw")"
  [[ $line =~ $GESTURE_RE ]] || return 1

  local inner="${BASH_REMATCH[1]}" pair f v
  local kf='' kd='' km='' ka=''
  local IFS=','
  for pair in $inner; do
    pair="$(trim "$pair")"
    [[ $pair =~ $G_PAIR_RE ]] || continue
    f="${BASH_REMATCH[1]}"
    v="$(trim "${BASH_REMATCH[2]}")"
    if [[ $v == \"*\" ]]; then v="${v#\"}"; v="${v%\"}"; fi
    case "$f" in
      fingers) kf="$v" ;;
      direction) kd="$v" ;;
      mods) km="$v" ;;
      action) ka="$v" ;;
    esac
  done
  [[ -n $kf && -n $kd ]] || return 1

  U_LINE="$lineno"; U_RAW="$raw"; U_F="$kf"; U_D="$kd"; U_M="$km"; U_ACTION="$ka"
  return 0
}

# JSON array of the unmanaged gestures, in file order.
unmanaged_gestures_json() {
  local lineno raw first=1 fingers_json
  printf '['
  while IFS=$'\t' read -r lineno raw; do
    [[ -n ${lineno-} ]] || continue
    parse_unmanaged_gesture "$lineno" "$raw" || continue
    [[ $first -eq 1 ]] || printf ','
    first=0
    if [[ $U_F =~ ^[0-9]+$ ]]; then fingers_json="$U_F"
    else fingers_json="\"$(json_escape "$U_F")\""
    fi
    printf '{"line":%s,"raw":"%s","fingers":%s,"direction":"%s"' \
      "$U_LINE" "$(json_escape "$U_RAW")" "$fingers_json" "$(json_escape "$U_D")"
    [[ -n $U_M ]] && printf ',"mods":"%s"' "$(json_escape "$U_M")"
    [[ -n $U_ACTION ]] && printf ',"action":"%s"' "$(json_escape "$U_ACTION")"
    printf '}'
  done < <(unmanaged_gesture_lines)
  printf ']'
}

# True when an unmanaged gesture already occupies the given slot
# (fingers|direction|mods), in which case it shadows the managed one. On success
# the U_* globals describe the offending line.
find_unmanaged_slot() {
  local tf="$1" td="$2" tm="${3-}" lineno raw
  while IFS=$'\t' read -r lineno raw; do
    [[ -n ${lineno-} ]] || continue
    parse_unmanaged_gesture "$lineno" "$raw" || continue
    [[ $U_F == "$tf" && $U_D == "$td" && $U_M == "$tm" ]] && return 0
  done < <(unmanaged_gesture_lines)
  return 1
}

gesture_json() { # key
  local key="$1" f
  split_g_key "$key"
  printf '{"fingers":%s,"direction":"%s"' "$G_F" "$(json_escape "$G_D")"
  [[ -n $G_M ]] && printf ',"mods":"%s"' "$(json_escape "$G_M")"
  for f in "${G_FIELD_ORDER[@]}"; do
    case "$f" in fingers|direction|mods) continue ;; esac
    g_has "$G_F" "$G_D" "$G_M" "$f" || continue
    local v
    v="$(g_get "$G_F" "$G_D" "$G_M" "$f")"
    if g_is_string_field "$f"; then
      printf ',"%s":"%s"' "$f" "$(json_escape "$v")"
    else
      printf ',"%s":%s' "$f" "$v"
    fi
  done
  printf '}'
}

gestures_json() {
  local key first=1
  printf '['
  for key in "${G_ORDER[@]:-}"; do
    [[ -n $key ]] || continue
    [[ $first -eq 1 ]] || printf ','
    first=0
    gesture_json "$key"
  done
  printf ']'
}

g_catalog_json() {
  local out='{"fingers":[2,3,4,5],"directions":[' first=1 item
  for item in $G_DIRECTIONS; do
    [[ $first -eq 1 ]] || out+=','
    first=0
    out+="\"$item\""
  done
  out+='],"actions":['
  first=1
  for item in $G_ACTIONS; do
    [[ $first -eq 1 ]] || out+=','
    first=0
    out+="\"$item\""
  done
  out+='],"modes":['
  first=1
  for item in $G_MODES; do
    [[ $first -eq 1 ]] || out+=','
    first=0
    out+="\"$item\""
  done
  out+=']}'
  printf '%s' "$out"
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
  load_gestures
  printf '{"ok":true,"configPath":"%s","entries":%s,"devices":%s,"primary":"%s","catalog":%s,"gestures":%s,"unmanaged":%s}\n' \
    "$(json_escape "$CONFIG")" "$(entries_json)" "$DEVICES_JSON" "$(json_escape "$PRIMARY_NAME")" \
    "$(g_catalog_json)" "$(gestures_json)" "$(unmanaged_gestures_json)"
}

# Read-only lookup, so unlike `set`/`remove` it accepts any name (a missing or
# odd one simply reports `null`) instead of refusing it.
cmd_battery() {
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
  build_battery_map
  printf '{"ok":true,"device":"%s","battery":%s}\n' \
    "$(json_escape "$dev")" "${BATTERY_MAP[$dev]:-null}"
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

cmd_gestures() {
  load_gestures
  printf '{"ok":true,"catalog":%s,"gestures":%s,"unmanaged":%s}\n' \
    "$(g_catalog_json)" "$(gestures_json)" "$(unmanaged_gestures_json)"
}

parse_g_fingers() {
  [[ -n ${1-} ]] || fail_json "--fingers is required"
  [[ $1 =~ ^[0-9]+$ ]] || fail_json "fingers must be a number"
  (( $1 >= 2 && $1 <= 9 )) || fail_json "fingers must be between 2 and 9"
}

cmd_gesture_set() {
  local fingers='' direction='' mods='' action='' scale='' workspace_name='' mode='' zoom_level='' disable_inhibit=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fingers)
        [[ $# -ge 2 ]] || fail_json "--fingers requires a value"
        parse_g_fingers "$2"
        fingers="$2"; shift 2 ;;
      --direction)
        [[ $# -ge 2 ]] || fail_json "--direction requires a value"
        in_list "$2" "$G_DIRECTIONS" || fail_json "unknown direction: $2"
        direction="$2"; shift 2 ;;
      --mods)
        [[ $# -ge 2 ]] || fail_json "--mods requires a value"
        local mods_re='^[A-Z0-9 ]+$'
        [[ $2 =~ $mods_re ]] || fail_json "mods must be uppercase words, e.g. ALT or SUPER SHIFT"
        mods="$2"; shift 2 ;;
      --action)
        [[ $# -ge 2 ]] || fail_json "--action requires a value"
        in_list "$2" "$G_ACTIONS" || fail_json "unknown action: $2"
        action="$2"; shift 2 ;;
      --scale)
        [[ $# -ge 2 ]] || fail_json "--scale requires a value"
        [[ $2 =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail_json "scale must be a positive number"
        scale="$2"; shift 2 ;;
      --workspace-name)
        [[ $# -ge 2 ]] || fail_json "--workspace-name requires a value"
        [[ $2 =~ ^[A-Za-z0-9_.-]+$ ]] \
          || fail_json "workspace name may only use letters, digits, dash, underscore or dot"
        workspace_name="$2"; shift 2 ;;
      --mode)
        [[ $# -ge 2 ]] || fail_json "--mode requires a value"
        in_list "$2" "$G_MODES" || fail_json "unknown mode: $2"
        mode="$2"; shift 2 ;;
      --zoom-level)
        [[ $# -ge 2 ]] || fail_json "--zoom-level requires a value"
        [[ $2 =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail_json "zoom level must be a positive number"
        zoom_level="$2"; shift 2 ;;
      --disable-inhibit)
        [[ $# -ge 2 ]] || fail_json "--disable-inhibit requires a value"
        [[ $2 == true || $2 == false ]] || fail_json "--disable-inhibit must be true or false"
        disable_inhibit="$2"; shift 2 ;;
      *)
        fail_json "unknown argument: $1" ;;
    esac
  done

  parse_g_fingers "$fingers"
  [[ -n $direction ]] || fail_json "--direction is required"

  load_gestures

  # An unmanaged gesture on the same slot wins (Hyprland keeps the first
  # definition), so writing the managed one would silently do nothing. Fail with
  # the fix instead of letting Hyprland's cryptic "overshadowed" error surface.
  if find_unmanaged_slot "$fingers" "$direction" "$mods"; then
    fail_json "this gesture is also defined outside Mouse Tuner's block ($(basename "$CONFIG") line $U_LINE) and would shadow the panel; run 'bin/mouse-tuner.sh gestures-import' to take it over"
  fi

  # Merge: keep what the slot already had, then apply what was passed.
  [[ -n $action ]] && g_put "$fingers" "$direction" "$mods" action "$action"
  [[ -n $scale ]] && g_put "$fingers" "$direction" "$mods" scale "$scale"
  [[ -n $workspace_name ]] && g_put "$fingers" "$direction" "$mods" workspace_name "$workspace_name"
  [[ -n $mode ]] && g_put "$fingers" "$direction" "$mods" mode "$mode"
  [[ -n $zoom_level ]] && g_put "$fingers" "$direction" "$mods" zoom_level "$zoom_level"
  [[ -n $disable_inhibit ]] && g_put "$fingers" "$direction" "$mods" disable_inhibit "$disable_inhibit"

  g_has "$fingers" "$direction" "$mods" action \
    || fail_json "this gesture has no action yet; pass --action"

  local key
  key="$(g_key "$fingers" "$direction" "$mods")"
  local seen=0 o
  for o in "${G_ORDER[@]:-}"; do [[ $o == "$key" ]] && seen=1; done
  (( seen )) || G_ORDER+=("$key")

  local reload_out
  if ! reload_out="$(apply_block "$(render_gestures_body)" "$GESTURE_START_MARKER" "$GESTURE_END_MARKER")"; then
    abort_with "$reload_out"
  fi

  printf '{"ok":true,"applied":%s,"configPath":"%s","reload":"%s","gestures":%s}\n' \
    "$(gesture_json "$key")" "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")" "$(gestures_json)"
}

cmd_gesture_unset() {
  local fingers='' direction='' mods=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fingers)
        [[ $# -ge 2 ]] || fail_json "--fingers requires a value"
        parse_g_fingers "$2"
        fingers="$2"; shift 2 ;;
      --direction)
        [[ $# -ge 2 ]] || fail_json "--direction requires a value"
        in_list "$2" "$G_DIRECTIONS" || fail_json "unknown direction: $2"
        direction="$2"; shift 2 ;;
      --mods)
        [[ $# -ge 2 ]] || fail_json "--mods requires a value"
        mods="$2"; shift 2 ;;
      *)
        fail_json "unknown argument: $1" ;;
    esac
  done

  parse_g_fingers "$fingers"
  [[ -n $direction ]] || fail_json "--direction is required"

  load_gestures
  # Removing only the managed line would leave the unmanaged one in place, so
  # the gesture would keep firing. Take it over first.
  if find_unmanaged_slot "$fingers" "$direction" "$mods"; then
    fail_json "this gesture is also defined outside Mouse Tuner's block ($(basename "$CONFIG") line $U_LINE); removing only the managed copy would not disable it — run 'bin/mouse-tuner.sh gestures-import' to take it over first"
  fi
  local key
  key="$(g_key "$fingers" "$direction" "$mods")"
  local removed=false o
  local -a kept=()
  for o in "${G_ORDER[@]:-}"; do
    if [[ $o == "$key" ]]; then removed=true; else [[ -n $o ]] && kept+=("$o"); fi
  done
  G_ORDER=("${kept[@]:-}")

  local reload_out
  if ! reload_out="$(apply_block "$(render_gestures_body)" "$GESTURE_START_MARKER" "$GESTURE_END_MARKER")"; then
    abort_with "$reload_out"
  fi

  printf '{"ok":true,"removed":%s,"configPath":"%s","reload":"%s","gestures":%s}\n' \
    "$removed" "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")" "$(gestures_json)"
}

cmd_gestures_reset() {
  local reload_out
  if ! reload_out="$(apply_block "" "$GESTURE_START_MARKER" "$GESTURE_END_MARKER")"; then
    abort_with "$reload_out"
  fi
  printf '{"ok":true,"reset":true,"configPath":"%s","reload":"%s","gestures":[]}\n' \
    "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")"
}

# Take over every hl.gesture(...) line that lives outside the managed block.
# The managed copy wins on a slot collision; the unmanaged duplicate is still
# removed from the file so only one definition remains. This is the only
# operation that deletes lines outside the managed regions, and only the
# gesture lines it is taking over.
cmd_gestures_import() {
  load_gestures

  # Snapshot the unmanaged lines first: the file changes below.
  local -a u_lines=() u_f=() u_d=() u_m=() u_action=()
  local lineno raw
  while IFS=$'\t' read -r lineno raw; do
    [[ -n ${lineno-} ]] || continue
    parse_unmanaged_gesture "$lineno" "$raw" || continue
    u_lines+=("$U_LINE"); u_f+=("$U_F"); u_d+=("$U_D"); u_m+=("$U_M"); u_action+=("$U_ACTION")
  done < <(unmanaged_gesture_lines)

  local imported=0 skipped=0 i key seen o
  local -a drop=()
  for i in "${!u_lines[@]}"; do
    key="$(g_key "${u_f[$i]}" "${u_d[$i]}" "${u_m[$i]}")"
    seen=0
    for o in "${G_ORDER[@]:-}"; do [[ $o == "$key" ]] && seen=1; done
    if (( seen )); then
      # Already managed: the managed entry is authoritative.
      skipped=$((skipped + 1))
    else
      G_ORDER+=("$key")
      [[ -n ${u_action[$i]} ]] \
        && g_put "${u_f[$i]}" "${u_d[$i]}" "${u_m[$i]}" action "${u_action[$i]}"
      imported=$((imported + 1))
    fi
    drop+=("${u_lines[$i]}")
  done

  local reload_out="ok"
  if (( ${#drop[@]} > 0 )); then
    # Filter the taken-over lines into a temp copy, then run the normal managed
    # write + reload + rollback against it. Everything else is copied through.
    local dir filtered
    dir="$(dirname "$CONFIG")"
    filtered="$(mktemp "$dir/.mouse-tuner.import.XXXXXX")" || fail_json "cannot create a temporary file"
    if ! awk -v drop="${drop[*]}" '
      BEGIN { n = split(drop, D, " "); for (i = 1; i <= n; i++) del[D[i] + 0] = 1 }
      !del[NR]
    ' "$CONFIG" >"$filtered"; then
      rm -f "$filtered"
      fail_json "failed to rewrite $CONFIG"
    fi
    if ! reload_out="$(apply_block "$(render_gestures_body)" "$GESTURE_START_MARKER" "$GESTURE_END_MARKER" "$filtered")"; then
      rm -f "$filtered"
      abort_with "$reload_out"
    fi
    rm -f "$filtered"
  fi

  printf '{"ok":true,"imported":%d,"skipped":%d,"configPath":"%s","reload":"%s","gestures":%s,"unmanaged":%s}\n' \
    "$imported" "$skipped" "$(json_escape "$CONFIG")" "$(json_escape "$reload_out")" \
    "$(gestures_json)" "$(unmanaged_gestures_json)"
}

usage() {
  cat <<'EOF'
Mouse Tuner helper

Usage:
  mouse-tuner.sh devices
  mouse-tuner.sh status
  mouse-tuner.sh battery --device <name>
  mouse-tuner.sh set --device <name> [flags]
  mouse-tuner.sh remove --device <name>
  mouse-tuner.sh reset

  mouse-tuner.sh gestures
  mouse-tuner.sh gesture-set --fingers <2..9> --direction <dir> [flags]
  mouse-tuner.sh gesture-unset --fingers <2..9> --direction <dir> [--mods M]
  mouse-tuner.sh gestures-reset
  mouse-tuner.sh gestures-import        take over hl.gesture lines defined outside
                                        the managed block (they shadow the panel)

gesture-set flags (only what you pass is written):
  --action <workspace|move|resize|special|close|fullscreen|float|cursor_zoom|scroll_move|none>
  --mods <"ALT"|"SUPER"|"SUPER SHIFT"|...>
  --scale <number>
  --workspace-name <name>        for --action special
  --mode <maximize|float|tile|mult|live>
  --zoom-level <number>          for --action cursor_zoom
  --disable-inhibit <true|false>

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
    battery) cmd_battery "$@" ;;
    set) with_lock cmd_set "$@" ;;
    remove) with_lock cmd_remove "$@" ;;
    reset) with_lock cmd_reset "$@" ;;
    gestures) cmd_gestures "$@" ;;
    gesture-set) with_lock cmd_gesture_set "$@" ;;
    gesture-unset) with_lock cmd_gesture_unset "$@" ;;
    gestures-reset) with_lock cmd_gestures_reset "$@" ;;
    gestures-import) with_lock cmd_gestures_import "$@" ;;
    ''|-h|--help) usage ;;
    *) fail_json "unknown subcommand: $cmd" ;;
  esac
}

main "$@"
