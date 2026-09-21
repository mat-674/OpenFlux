#!/usr/bin/env bash
# Простой установщик OpenFlux: git clone -> установка Go -> сборка.
# Запуск:  bash install.sh
# Свой путь:  INSTALL_DIR=/opt/openflux bash install.sh
set -euo pipefail

REPO_URL="https://github.com/p1neappleXpress/OpenFlux.git"
INSTALL_DIR="${INSTALL_DIR:-$HOME/OpenFlux}"
GO_PARENT="$HOME/.local"            # Go ставится в ~/.local/go (sudo не нужен)
LOG="$(mktemp -t openflux-install.XXXXXX)"
TOTAL=5

# ---------- прогресс-бар ----------
draw() { # $1 = процент, $2 = подпись
  local pct=$1 label=$2 width=30 filled bar="" n
  filled=$(( pct * width / 100 ))
  for ((n = 0; n < width; n++)); do
    if (( n < filled )); then bar+="█"; else bar+="░"; fi
  done
  printf "\r\033[K%s %3d%%  %s" "$bar" "$pct" "$label"
}

run_step() { # $1 = номер шага, $2 = подпись, остальное = команда
  local idx=$1 label=$2; shift 2
  local start=$(( (idx - 1) * 100 / TOTAL )) end=$(( idx * 100 / TOTAL ))
  local spin='|/-\' i=0 pid

  echo "--- [$idx/$TOTAL] $label" >>"$LOG"
  "$@" >>"$LOG" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    draw "$start" "$label ${spin:i%4:1}"
    i=$((i + 1))
    sleep 0.15
  done

  if wait "$pid"; then
    draw "$end" "$label ✓"
    echo
  else
    echo
    echo "✗ Ошибка на шаге: $label" >&2
    echo "Последние строки лога ($LOG):" >&2
    tail -n 20 "$LOG" >&2
    exit 1
  fi
}

# ---------- вспомогательное ----------
find_go() {
  if [ -x "$GO_PARENT/go/bin/go" ]; then echo "$GO_PARENT/go/bin/go"
  elif command -v go >/dev/null 2>&1; then command -v go
  fi
}

required_go_version() { awk '/^go /{print $2; exit}' "$INSTALL_DIR/go.mod"; }

# 0 если установленный Go >= требуемого
go_is_ok() {
  local go_bin have req
  go_bin="$(find_go || true)"
  [ -n "$go_bin" ] || return 1
  have="$("$go_bin" version | awk '{print $3}' | sed 's/^go//')"
  req="$(required_go_version)"
  [ "$(printf '%s\n%s\n' "$req" "$have" | sort -V | head -n1)" = "$req" ]
}

# ---------- шаги ----------
step_check() {
  local missing=0 c
  for c in git curl tar; do
    command -v "$c" >/dev/null 2>&1 || { echo "Не найдено: $c" ; missing=1; }
  done
  return "$missing"
}

step_clone() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only
  else
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  fi
}

step_go() {
  if go_is_ok; then
    echo "Go уже установлен и подходит, пропускаю"
    return 0
  fi

  local os arch ver url tmp
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *) echo "Неподдерживаемая ОС: $(uname -s)"; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Неподдерживаемая архитектура: $(uname -m)"; return 1 ;;
  esac

  ver="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
  url="https://go.dev/dl/${ver}.${os}-${arch}.tar.gz"
  tmp="$(mktemp -t go-dl.XXXXXX)"

  echo "Скачиваю $url"
  curl -fSL "$url" -o "$tmp"
  rm -rf "$GO_PARENT/go"
  mkdir -p "$GO_PARENT"
  tar -C "$GO_PARENT" -xzf "$tmp"
  rm -f "$tmp"
}

step_deps() {
  local go_bin; go_bin="$(find_go)"
  ( cd "$INSTALL_DIR" && "$go_bin" mod tidy )
}

step_build() {
  local go_bin; go_bin="$(find_go)"
  ( cd "$INSTALL_DIR" && "$go_bin" build -o openflux . )
}

# ---------- запуск ----------
echo "OpenFlux installer  →  $INSTALL_DIR"
echo

run_step 1 "Проверка git/curl/tar"     step_check
run_step 2 "Клонирование репозитория"  step_clone
run_step 3 "Установка Go"              step_go
run_step 4 "Загрузка зависимостей"     step_deps
run_step 5 "Сборка"                    step_build

echo
echo "Готово ✓  Бинарник: $INSTALL_DIR/openflux"
echo "Пример:   $INSTALL_DIR/openflux --help"
if [ -x "$GO_PARENT/go/bin/go" ]; then
  echo "Go стоит в $GO_PARENT/go — чтобы пользоваться им, добавь в PATH:"
  echo "  export PATH=\"$GO_PARENT/go/bin:\$PATH\""
fi
rm -f "$LOG"
