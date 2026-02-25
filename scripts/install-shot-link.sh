#!/usr/bin/env bash
set -euo pipefail

app_path="/Applications/ShotCli.app"
bin_dir="/usr/local/bin"
bin_dir_explicit=0
force=0

usage() {
  cat <<'EOF'
Usage: install-shot-link.sh [--app <ShotCli.app>] [--bin-dir <dir>] [--force]

Options:
  --app <path>      Path to ShotCli.app (default: /Applications/ShotCli.app)
  --bin-dir <dir>   Directory where `shot` symlink is created
                    (default: /usr/local/bin, fallback: ~/.local/bin)
  --force           Replace existing symlink/file
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --app" >&2; exit 2; }
      app_path="$1"
      ;;
    --bin-dir)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --bin-dir" >&2; exit 2; }
      bin_dir="$1"
      bin_dir_explicit=1
      ;;
    --force)
      force=1
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

app_path="${app_path/#\~/$HOME}"
bin_dir="${bin_dir/#\~/$HOME}"

if [[ ! -d "$app_path" ]]; then
  echo "ShotCli.app not found: $app_path" >&2
  exit 2
fi

shot_bin="$app_path/Contents/MacOS/shot"
fallback_bin="$app_path/Contents/MacOS/ShotCli"

if [[ -x "$shot_bin" ]]; then
  target_bin="$shot_bin"
elif [[ -x "$fallback_bin" ]]; then
  target_bin="$fallback_bin"
else
  echo "Executable not found in app bundle. Build or install ShotCli.app first." >&2
  exit 10
fi

if ! mkdir -p "$bin_dir" 2>/dev/null; then
  if [[ "$bin_dir_explicit" -eq 1 ]]; then
    echo "Cannot create bin directory: $bin_dir" >&2
    exit 15
  fi
  bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir"
fi

if [[ ! -w "$bin_dir" ]]; then
  if [[ "$bin_dir_explicit" -eq 1 ]]; then
    echo "Bin directory is not writable: $bin_dir" >&2
    exit 15
  fi
  bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir"
fi

link_path="$bin_dir/shot"

if [[ -e "$link_path" || -L "$link_path" ]]; then
  if [[ "$force" -eq 1 ]]; then
    rm -f "$link_path"
  else
    echo "$link_path already exists. Use --force to replace it." >&2
    exit 2
  fi
fi

ln -s "$target_bin" "$link_path"
echo "Installed: $link_path -> $target_bin"
echo "Try: shot version"
