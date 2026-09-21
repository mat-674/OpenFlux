#!/usr/bin/env bash
# OpenFlux installer — clone, install deps, build, install binary.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/mat-674/OpenFlux/main/install.sh | bash
#
# Overridable via env:
#   OPENFLUX_REPO     git URL                  (default: https://github.com/mat-674/OpenFlux.git)
#   OPENFLUX_REF      branch/tag/commit        (default: main)
#   OPENFLUX_SRC      source checkout dir      (default: ~/.openflux/src)
#   OPENFLUX_PREFIX   install prefix dir       (default: /usr/local/bin if writable, else ~/.local/bin)
#   OPENFLUX_BIN      binary name              (default: openflux)
#   OPENFLUX_GO       path to an existing `go` (skips toolchain install)
#   OPENFLUX_GO_VER   Go version to install    (default: latest stable from go.dev)
#   OPENFLUX_VERBOSE  1 = stream every command's output instead of the spinner
#   OPENFLUX_LOG_DIR  where per-step logs go    (default: $TMPDIR/openflux-install-logs)

if [ -z "${BASH_VERSION:-}" ]; then
    echo "install.sh: this installer needs bash (run: bash install.sh)" >&2
    exit 1
fi

set -euo pipefail

REPO="${OPENFLUX_REPO:-https://github.com/mat-674/OpenFlux.git}"
REF="${OPENFLUX_REF:-main}"
SRC_DIR="${OPENFLUX_SRC:-$HOME/.openflux/src}"
PREFIX="${OPENFLUX_PREFIX:-}"
BIN_NAME="${OPENFLUX_BIN:-openflux}"
GO_VER="${OPENFLUX_GO_VER:-}"
VERBOSE="${OPENFLUX_VERBOSE:-0}"
LOG_DIR="${OPENFLUX_LOG_DIR:-${TMPDIR:-/tmp}/openflux-install-logs}"

# ------------------------------------------------------------------- output ---
TTY=0
[ -t 1 ] && TTY=1
[ "${OPENFLUX_FORCE_TTY:-0}" = 1 ] && TTY=1

if [ "$TTY" = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_YELLOW=$'\033[1;33m'; C_CYAN=$'\033[1;36m'
else
    C_RESET=''; C_DIM=''; C_BOLD=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''
fi

# Unicode niceties only when the locale looks like UTF-8.
if printf '%s' "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" | grep -qiE 'utf-?8'; then
    SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); BAR_FULL='█'; BAR_EMPTY='░'
else
    SPIN_FRAMES=('|' '/' '-' "\\"); BAR_FULL='#'; BAR_EMPTY='-'
fi
SPIN_N=${#SPIN_FRAMES[@]}

STEP=0
STEP_TOTAL=6
SPIN_PID=''

log()  { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

progress_bar() { # progress_bar <percent> -> 20-column bar
    local pct="${1:-0}" width=20 filled bar gap
    pct="${pct%%.*}"
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    filled=$(( pct * width / 100 ))
    printf -v bar '%*s' "$filled" ''
    printf -v gap '%*s' "$(( width - filled ))" ''
    printf '%s%s' "${bar// /$BAR_FULL}" "${gap// /$BAR_EMPTY}"
}

# Last non-empty line of a log, with git/curl carriage-return rewrites unwrapped.
last_line() {
    tail -c 40000 "$1" 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*$' | tail -n1
}

spinner_start() { # spinner_start <log> <start-epoch>
    local log="$1" start="$2"
    SPIN_PID=''
    (
        local i=0 cols="${COLUMNS:-0}" line pct now elapsed
        [ "$cols" -ge 40 ] 2>/dev/null || cols=80
        while :; do
            line="$(last_line "$log")"
            [ -n "$line" ] || line='working'
            now=$(date +%s); elapsed=$(( now - start ))
            if printf '%s' "$line" | grep -qE '[0-9]{1,3}(\.[0-9]+)?%'; then
                pct="$(printf '%s' "$line" | grep -oE '[0-9]{1,3}(\.[0-9]+)?%' | tail -n1)"
                pct="${pct//%/}"; pct="${pct%%.*}"
                printf '\r\033[K  %s %s[%ss]%s %s %s%%' \
                    "${SPIN_FRAMES[$i]}" "$C_CYAN" "$elapsed" "$C_RESET" \
                    "$(progress_bar "$pct")" "$pct" >&2
            else
                printf '\r\033[K  %s %s[%ss]%s %s' \
                    "${SPIN_FRAMES[$i]}" "$C_CYAN" "$elapsed" "$C_RESET" \
                    "${line:0:$((cols - 14))}" >&2
            fi
            i=$(( (i + 1) % SPIN_N ))
            sleep 0.2
        done
    ) &
    SPIN_PID=$!
}

spinner_stop() {
    [ -n "${SPIN_PID:-}" ] || return 0
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=''
    printf '\r\033[K' >&2
}
trap spinner_stop EXIT

stage_header() {
    STEP=$((STEP + 1))
    printf '\n%s[%d/%d]%s %s\n' "$C_CYAN" "$STEP" "$STEP_TOTAL" "$C_RESET" "$1"
}

# note <title> [detail] — a stage that needs no work.
note() {
    stage_header "$1"
    printf '      %s%s%s\n' "$C_DIM" "${2:-}" "$C_RESET"
}

# run <title> <command...> — numbered stage with spinner + live output line.
run() {
    local title="$1"; shift
    local start rc elapsed logfile
    start=$(date +%s)
    stage_header "$title"
    logfile="$LOG_DIR/step-$STEP-$(printf '%s' "$title" | tr -c '[:alnum:]' '-').log"
    : > "$logfile"

    set +e
    if [ "$TTY" = 1 ] && [ "$VERBOSE" != 1 ]; then
        spinner_start "$logfile" "$start"
        "$@" >"$logfile" 2>&1
        rc=$?
        spinner_stop
    else
        # No TTY (CI, piped logs) or OPENFLUX_VERBOSE=1: mirror output live.
        # Process substitution, not a pipe: the command must stay in this shell,
        # otherwise its variable assignments (GO_BIN) would die with the subshell.
        "$@" > >(tee "$logfile") 2>&1
        rc=$?
    fi
    set -e

    elapsed=$(( $(date +%s) - start ))
    if [ "$rc" -eq 0 ]; then
        printf '      %s✓%s %s %s(%ss)%s\n' \
            "$C_GREEN" "$C_RESET" "$title" "$C_DIM" "$elapsed" "$C_RESET"
    else
        printf '      %s✗ failed%s %s(%ss)%s\n' "$C_RED" "$C_RESET" "$C_DIM" "$elapsed" "$C_RESET"
        if [ -s "$logfile" ]; then
            printf '%s' "$C_DIM"
            # git/curl progress lines are \r-separated and useless in a failure
            # dump — unwrap them and drop the bare "Receiving objects: 42%" noise.
            tr '\r' '\n' < "$logfile" \
                | grep -v '^[[:space:]]*$' \
                | grep -vE ':[[:space:]]*[0-9]{1,3}(\.[0-9]+)?%' \
                | tail -n 20 | sed 's/^/      | /'
            printf '%s' "$C_RESET"
        fi
        printf '      full log: %s\n' "$logfile" >&2
        die "$title"
    fi
}

# ---------------------------------------------------------------- platform ---
case "$(uname -s)" in
    Linux)  OS=linux  ;;
    Darwin) OS=darwin ;;
    MINGW*|MSYS*|CYGWIN*)
        die "Windows detected. Use the PowerShell installer instead:
    irm https://raw.githubusercontent.com/mat-674/OpenFlux/main/install.ps1 | iex" ;;
    *) die "unsupported OS: $(uname -s)" ;;
esac

case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l|armv7)  ARCH=arm   ;;
    *) die "unsupported arch: $(uname -m)" ;;
esac

# ----------------------------------------------------------------- tooling ---
fetch() { # fetch <url> <out|-|  ("-" = stdout)
    if command -v curl >/dev/null 2>&1; then
        if [ "$2" = '-' ]; then curl -fsSL "$1"
        else curl -fSL -# -o "$2" "$1"; fi
    elif command -v wget >/dev/null 2>&1; then
        if [ "$2" = '-' ]; then wget -qO- "$1"
        else wget -qO "$2" "$1"; fi
    else die "need curl or wget"; fi
}

ensure_git() {
    command -v git >/dev/null 2>&1 && return 0
    die "git is required. Install it first (apt install git / brew install git)."
}

ensure_go() {
    if [ -n "${OPENFLUX_GO:-}" ]; then
        [ -x "$OPENFLUX_GO" ] || die "OPENFLUX_GO=$OPENFLUX_GO is not executable"
        GO_BIN="$OPENFLUX_GO"
    elif command -v go >/dev/null 2>&1; then
        GO_BIN="$(command -v go)"
    fi

    if [ -n "${GO_BIN:-}" ]; then
        printf 'found %s on PATH\n' "$( "$GO_BIN" version )"
        return 0
    fi

    # No Go on PATH — install a private toolchain under ~/.local/go.
    [ -n "$GO_VER" ] || {
        printf 'querying the latest stable Go version\n'
        GO_VER="$(fetch https://go.dev/VERSION?m=text - | head -n1)"
    }
    [ -n "$GO_VER" ] || die "could not resolve the latest Go version"

    local dir="$HOME/.local/go/$GO_VER" tarball
    local url="https://go.dev/dl/${GO_VER}.${OS}-${ARCH}.tar.gz"

    if [ -x "$dir/bin/go" ]; then
        printf 'reusing %s at %s\n' "$GO_VER" "$dir"
    else
        printf 'downloading %s (%s/%s)\n' "$GO_VER" "$OS" "$ARCH"
        mkdir -p "$HOME/.local/go"
        tarball="$(mktemp)"
        fetch "$url" "$tarball" || die "download failed: $url"
        printf 'unpacking into %s\n' "$dir"
        tar -C "$HOME/.local/go" -xzf "$tarball"
        rm -f "$tarball"
        mv "$HOME/.local/go/go" "$dir"
    fi
    GO_BIN="$dir/bin/go"
    export PATH="$dir/bin:$PATH"
    printf 'ready: %s\n' "$( "$GO_BIN" version )"
}

# ------------------------------------------------------------------ source ---
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

LOCAL_CHECKOUT=0
if [ -f "go.mod" ] && grep -q '^module openflux' go.mod; then
    SRC_DIR="$(pwd)"
    LOCAL_CHECKOUT=1
elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/go.mod" ] && grep -q '^module openflux' "$SCRIPT_DIR/go.mod"; then
    SRC_DIR="$SCRIPT_DIR"
    LOCAL_CHECKOUT=1
fi

clone_or_update() {
    if [ -d "$SRC_DIR/.git" ]; then
        printf 'updating %s at %s\n' "$REF" "$SRC_DIR"
        git -C "$SRC_DIR" fetch --depth 1 --progress origin "$REF"
        git -C "$SRC_DIR" checkout -q FETCH_HEAD
    else
        printf 'cloning %s -> %s\n' "$REF" "$SRC_DIR"
        mkdir -p "$(dirname "$SRC_DIR")"
        if ! git clone --depth 1 --progress --branch "$REF" "$REPO" "$SRC_DIR"; then
            # $REF is not a branch/tag (a commit sha, say) — full clone + checkout.
            rm -rf "$SRC_DIR"
            printf 'ref %s is not a branch/tag, doing a full clone\n' "$REF"
            git clone --progress "$REPO" "$SRC_DIR"
            git -C "$SRC_DIR" checkout -q "$REF"
        fi
    fi
}

# -------------------------------------------------------------------- main ---
SCRIPT_START=$(date +%s)
mkdir -p "$LOG_DIR"
printf '%sOpenFlux installer%s (%s/%s, ref %s)\n' "$C_BOLD" "$C_RESET" "$OS" "$ARCH" "$REF"
printf '%sstep logs: %s%s\n' "$C_DIM" "$LOG_DIR" "$C_RESET"

run "Checking prerequisites (git, curl/wget)" ensure_git
run "Preparing the Go toolchain" ensure_go

if [ "$LOCAL_CHECKOUT" = 1 ]; then
    note "Fetching sources" "using the checkout next to this script: $SRC_DIR"
else
    run "Fetching sources (git clone $REF)" clone_or_update
fi

run "Resolving dependencies (go mod download)" \
    "$GO_BIN" mod download -C "$SRC_DIR"
run "Compiling (go build -trimpath -ldflags='-s -w')" \
    env CGO_ENABLED=0 "$GO_BIN" build -C "$SRC_DIR" -trimpath -ldflags="-s -w" -o "$BIN_NAME" .

# ----------------------------------------------------------------- install ---
if [ -n "$PREFIX" ]; then
    DEST_DIR="$PREFIX"
elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    DEST_DIR=/usr/local/bin
else
    DEST_DIR="$HOME/.local/bin"
fi

install_binary() {
    mkdir -p "$DEST_DIR"
    install -m 0755 "$SRC_DIR/$BIN_NAME" "$DEST_DIR/$BIN_NAME" 2>/dev/null \
        || { cp "$SRC_DIR/$BIN_NAME" "$DEST_DIR/$BIN_NAME" && chmod 0755 "$DEST_DIR/$BIN_NAME"; }
    printf 'placed %s\n' "$DEST_DIR/$BIN_NAME"
}

run "Installing to $DEST_DIR" install_binary

TOTAL=$(( $(date +%s) - SCRIPT_START ))
printf '\n%s✓ installed in %ss:%s %s\n' "$C_GREEN" "$TOTAL" "$C_RESET" "$DEST_DIR/$BIN_NAME"

case ":$PATH:" in
    *":$DEST_DIR:"*) ;;
    *) warn "$DEST_DIR is not in PATH. Add it: export PATH=\"$DEST_DIR:\$PATH\"" ;;
esac

cat <<EOF

Done. Examples:

  # client (SOCKS5 on 127.0.0.1:1080)
  $BIN_NAME --role=client --inbound=socks5 --transport=yandex --url="YOUR_DOC_URL"

  # exit node on Linux, fastest mode (needs root)
  sudo $BIN_NAME --role=exit --mode=l3 --transport=yandex --url="YOUR_DOC_URL"

  # exit node anywhere, no root
  $BIN_NAME --role=exit --mode=l4 --transport=yandex --url="YOUR_DOC_URL"

  $BIN_NAME -h
EOF
