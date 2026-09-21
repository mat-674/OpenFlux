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

set -euo pipefail

REPO="${OPENFLUX_REPO:-https://github.com/mat-674/OpenFlux.git}"
REF="${OPENFLUX_REF:-main}"
SRC_DIR="${OPENFLUX_SRC:-$HOME/.openflux/src}"
PREFIX="${OPENFLUX_PREFIX:-}"
BIN_NAME="${OPENFLUX_BIN:-openflux}"
GO_VER="${OPENFLUX_GO_VER:-}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

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
fetch() { # fetch <url> <out>
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
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
        log "found $( "$GO_BIN" version )"
        return 0
    fi

    # No Go on PATH — install a private toolchain under ~/.local/go.
    [ -n "$GO_VER" ] || GO_VER="$(fetch https://go.dev/VERSION?m=text - | head -n1)"
    [ -n "$GO_VER" ] || die "could not resolve the latest Go version"

    local dir="$HOME/.local/go/$GO_VER" tarball
    local url="https://go.dev/dl/${GO_VER}.${OS}-${ARCH}.tar.gz"

    if [ ! -x "$dir/bin/go" ]; then
        log "installing $GO_VER ($OS/$ARCH) into $dir"
        mkdir -p "$HOME/.local/go"
        tarball="$(mktemp)"
        fetch "$url" "$tarball" || die "download failed: $url"
        tar -C "$HOME/.local/go" -xzf "$tarball"
        rm -f "$tarball"
        mv "$HOME/.local/go/go" "$dir"
    fi
    GO_BIN="$dir/bin/go"
    export PATH="$dir/bin:$PATH"
}

# ------------------------------------------------------------------ source ---
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

if [ -f "go.mod" ] && grep -q '^module openflux' go.mod; then
    # Run from inside the checkout: build what's here.
    SRC_DIR="$(pwd)"
    log "building current checkout: $SRC_DIR"
elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/go.mod" ] && grep -q '^module openflux' "$SCRIPT_DIR/go.mod"; then
    SRC_DIR="$SCRIPT_DIR"
    log "building local checkout: $SRC_DIR"
else
    ensure_git
    if [ -d "$SRC_DIR/.git" ]; then
        log "updating $SRC_DIR"
        git -C "$SRC_DIR" fetch --depth 1 origin "$REF"
        git -C "$SRC_DIR" checkout -q FETCH_HEAD
    else
        log "cloning $REPO ($REF) -> $SRC_DIR"
        mkdir -p "$(dirname "$SRC_DIR")"
        if ! git clone --depth 1 --branch "$REF" "$REPO" "$SRC_DIR" 2>/dev/null; then
            # $REF is not a branch/tag (e.g. a commit sha) — full clone then checkout.
            rm -rf "$SRC_DIR"
            git clone "$REPO" "$SRC_DIR"
            git -C "$SRC_DIR" checkout -q "$REF"
        fi
    fi
fi

# ------------------------------------------------------------------- build ---
ensure_go
cd "$SRC_DIR"

log "resolving dependencies"
"$GO_BIN" mod download

log "building"
CGO_ENABLED=0 "$GO_BIN" build -trimpath -ldflags="-s -w" -o "$BIN_NAME" .
[ -x "$BIN_NAME" ] || die "build produced no binary"

# ----------------------------------------------------------------- install ---
if [ -n "$PREFIX" ]; then
    DEST_DIR="$PREFIX"
elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    DEST_DIR=/usr/local/bin
else
    DEST_DIR="$HOME/.local/bin"
fi
mkdir -p "$DEST_DIR"
install -m 0755 "$BIN_NAME" "$DEST_DIR/$BIN_NAME" 2>/dev/null \
    || { cp "$BIN_NAME" "$DEST_DIR/$BIN_NAME" && chmod 0755 "$DEST_DIR/$BIN_NAME"; }

log "installed: $DEST_DIR/$BIN_NAME"

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
