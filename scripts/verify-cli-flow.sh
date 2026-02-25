#!/usr/bin/env bash
set -u -o pipefail

shot_bin=""
display_name="LG ULTRAFINE"
display_id=""
out_path="$HOME/Downloads/lg-ultrafine-verify.png"

usage() {
  cat <<'USAGE'
Usage: verify-cli-flow.sh [--shot <path>] [--display-name <name>] [--display-id <id>] [--out <path>]

Examples:
  scripts/verify-cli-flow.sh
  scripts/verify-cli-flow.sh --display-id 4 --out ~/Downloads/lg-test.png
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shot)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --shot" >&2; exit 2; }
      shot_bin="$1"
      ;;
    --display-name)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --display-name" >&2; exit 2; }
      display_name="$1"
      ;;
    --display-id)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --display-id" >&2; exit 2; }
      display_id="$1"
      ;;
    --out)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --out" >&2; exit 2; }
      out_path="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$shot_bin" ]]; then
  shot_bin=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/ShotCli-*/Build/Products/Debug/ShotCli.app/Contents/MacOS/shot 2>/dev/null | head -n1)
  if [[ -z "$shot_bin" && -x "/Applications/ShotCli.app/Contents/MacOS/shot" ]]; then
    shot_bin="/Applications/ShotCli.app/Contents/MacOS/shot"
  fi
fi

if [[ -z "$shot_bin" || ! -x "$shot_bin" ]]; then
  echo "Unable to find shot binary. Install ShotCli.app or build Debug first." >&2
  exit 10
fi

out_path="${out_path/#\~/$HOME}"
mkdir -p "$(dirname "$out_path")"

tmp_displays=$(mktemp)
tmp_doctor=$(mktemp)
tmp_capture=$(mktemp)
trap 'rm -f "$tmp_displays" "$tmp_doctor" "$tmp_capture"' EXIT

echo "[1/4] shot binary: $shot_bin"
"$shot_bin" version || exit $?

echo "[2/4] doctor"
"$shot_bin" doctor --pretty >"$tmp_doctor" 2>&1
rc_doctor=$?
cat "$tmp_doctor"
echo "doctor_exit=$rc_doctor"
if grep -q '"endpoint" : "xpc"' "$tmp_doctor"; then
  echo "doctor output still reports endpoint=xpc; expected pure CLI in-process mode." >&2
  exit 10
fi
if ! grep -q '"mode" : "in_process"' "$tmp_doctor"; then
  echo "doctor output missing service.mode=in_process; verify you are using a pure CLI build." >&2
  exit 10
fi

echo "[3/4] displays"
"$shot_bin" displays --pretty >"$tmp_displays" 2>&1
rc_displays=$?
cat "$tmp_displays"
echo "displays_exit=$rc_displays"
if [[ $rc_displays -ne 0 ]]; then
  echo "displays failed; cannot continue." >&2
  exit $rc_displays
fi

if [[ -z "$display_id" ]]; then
  if grep -q "\"name\" : \"$display_name\"" "$tmp_displays"; then
    display_id=$(awk -v target="$display_name" '
      /^    \{/ {
        in_display=1
        block=$0 ORS
        next
      }
      in_display {
        block=block $0 ORS
        if ($0 ~ /^    \},?$/) {
          if (index(block, "\"name\" : \"" target "\"") > 0) {
            if (block ~ /"displayId"[[:space:]]*:[[:space:]]*[0-9][0-9]*/) {
              id = block
              sub(/.*"displayId"[[:space:]]*:[[:space:]]*/, "", id)
              sub(/[^0-9].*$/, "", id)
              print id
              exit
            }
          }
          in_display=0
          block=""
        }
      }
    ' "$tmp_displays")
  fi
fi

if [[ -z "$display_id" ]]; then
  echo "Unable to resolve displayId for '$display_name'. Provide --display-id manually." >&2
  exit 13
fi

echo "Resolved display_id=$display_id"

echo "[4/4] capture"
"$shot_bin" capture --display "$display_id" --out "$out_path" --pretty >"$tmp_capture" 2>&1
rc_capture=$?
cat "$tmp_capture"
echo "capture_exit=$rc_capture"

if [[ $rc_capture -eq 0 ]]; then
  if [[ -f "$out_path" ]]; then
    bytes=$(wc -c <"$out_path" | tr -d '[:space:]')
    echo "capture_ok path=$out_path bytes=$bytes"
    exit 0
  fi
  echo "capture returned 0 but file not found: $out_path" >&2
  exit 15
fi

if [[ $rc_capture -eq 11 ]]; then
  echo "capture blocked by missing Screen Recording permission for this terminal app." >&2
fi

exit $rc_capture
