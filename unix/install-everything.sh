#!/bin/sh
# unix/install-everything.sh
#
# One-shot full install for Linux and macOS:
#   1. Go
#   2. scanner            - detection engine
#   3. Git hooks          - blocks commit / merge / push
#   4. Hardening          - locks files, self-healing job
#   5. watcher-service    - real-time whole-machine detection (report-only)
#   6. Self-test
#
#   sudo ./install-everything.sh
#   sudo ./install-everything.sh --no-harden
#   sudo ./install-everything.sh --uninstall

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIX="$ROOT/unix"
HOOKS="$ROOT/hooks"
SRC="$ROOT/src"
OS="$(uname -s)"
REAL_USER="${SUDO_USER:-$(whoami)}"

NO_HARDEN=0
UNINSTALL=0
for a in "$@"; do
    [ "$a" = "--no-harden" ] && NO_HARDEN=1
    [ "$a" = "--uninstall" ] && UNINSTALL=1
done

PASS=""
FAIL=""

step() {
    echo ""
    echo "──────────────────────────────────────────────"
    echo " $1"
    echo "──────────────────────────────────────────────"
}

ok()   { echo "  OK"; PASS="$PASS\n  $1"; }
bad()  { echo "  FAILED: $2"; FAIL="$FAIL\n  $1 - $2"; }

# ===========================================================================
if [ "$UNINSTALL" = "1" ]; then
    echo "Removing everything..."
    "$UNIX/install-service.sh" --remove 2>/dev/null || true
    sudo -u "$REAL_USER" "$UNIX/alerts.sh" --remove 2>/dev/null || true
    git config --global --unset core.hooksPath 2>/dev/null || true
    if [ "$OS" = "Linux" ]; then
        systemctl disable --now git-hooks-guard.timer 2>/dev/null || true
        rm -f /etc/systemd/system/git-hooks-guard.*
        systemctl daemon-reload 2>/dev/null || true
        chattr -i "$HOOKS"/* 2>/dev/null || true
    else
        chflags nouchg "$HOOKS"/* 2>/dev/null || true
    fi
    echo "Uninstalled. Folder left in place."
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo:  sudo ./install-everything.sh"
    exit 1
fi

echo ""
echo "=============================================="
echo "   GIT SECURITY HOOKS - FULL INSTALL ($OS)"
echo "=============================================="
echo " Installing to: $ROOT"

# --- normalise line endings (files may come from Windows) -------------------
step "0/7  Preparing"
for f in "$HOOKS"/pre-commit "$HOOKS"/pre-merge-commit "$HOOKS"/pre-push \
         "$HOOKS"/post-merge "$HOOKS"/post-checkout "$HOOKS"/post-rewrite \
         "$UNIX"/*.sh; do
    [ -f "$f" ] && { tr -d '\r' < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
done
chmod +x "$UNIX"/*.sh "$HOOKS"/pre-* "$HOOKS"/post-* 2>/dev/null
mkdir -p "$ROOT/logs" "$ROOT/quarantine"
ok "0/7 Preparing"

# --- 1. Go -----------------------------------------------------------------
step "1/7  Go toolchain"
if command -v go >/dev/null 2>&1; then
    echo "  Already installed: $(go version)"
    ok "1/7 Go"
else
    echo "  Installing..."
    if [ "$OS" = "Darwin" ]; then
        if command -v brew >/dev/null 2>&1; then
            sudo -u "$REAL_USER" brew install go && ok "1/7 Go" || bad "1/7 Go" "brew install failed"
        else
            bad "1/7 Go" "install Homebrew or Go manually from https://go.dev/dl/"
        fi
    else
        if command -v apt >/dev/null 2>&1;    then apt update && apt install -y golang-go && ok "1/7 Go" || bad "1/7 Go" "apt failed"
        elif command -v dnf >/dev/null 2>&1;  then dnf install -y golang && ok "1/7 Go" || bad "1/7 Go" "dnf failed"
        elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm go && ok "1/7 Go" || bad "1/7 Go" "pacman failed"
        else bad "1/7 Go" "no known package manager - install from https://go.dev/dl/"
        fi
    fi
fi

command -v go >/dev/null 2>&1 || { echo ""; echo "Go is required. Stopping."; exit 1; }

# --- 2. Scanner ------------------------------------------------------------
step "2/7  Detection engine"
if (cd "$SRC" && go build -o "$HOOKS/scanner" scanner.go) && [ -f "$HOOKS/scanner" ]; then
    chmod +x "$HOOKS/scanner"
    ok "2/7 Scanner"
else
    bad "2/7 Scanner" "build failed"
fi

# --- 3. Git hooks ----------------------------------------------------------
step "3/7  Git hooks"
sudo -u "$REAL_USER" git config --global core.hooksPath "$HOOKS" && {
    echo "  core.hooksPath -> $HOOKS"; ok "3/7 Git hooks"
} || bad "3/7 Git hooks" "git config failed"

# --- 4. Hardening ----------------------------------------------------------
if [ "$NO_HARDEN" = "1" ]; then
    echo ""
    echo " 4/7  Hardening - SKIPPED"
else
    step "4/7  Hardening"
    "$UNIX/harden.sh" && ok "4/7 Hardening" || bad "4/7 Hardening" "see errors above"
fi

# --- 5. Watcher service ----------------------------------------------------
step "5/6  Real-time watcher service"
"$UNIX/install-service.sh" --all --quarantine && ok "5/6 Watcher service" \
    || bad "5/6 Watcher service" "see errors above"

# Notifications run as the logged-in user, not root - a root service has no
# access to the desktop session.
chmod +x "$UNIX/alerts.sh" 2>/dev/null
sudo -u "$REAL_USER" "$UNIX/alerts.sh" --install 2>/dev/null \
    || echo "  (desktop notifications could not be installed - run unix/alerts.sh --install yourself)"

# --- 6. Self-test ----------------------------------------------------------
step "6/6  Self-test"
T="/tmp/gsh-selftest"
rm -rf "$T"; mkdir -p "$T"
(
  cd "$T"
  sudo -u "$REAL_USER" git init >/dev/null 2>&1
  echo 'global.i="A10-*10610";self test payload' > t.js
  sudo -u "$REAL_USER" git add t.js >/dev/null 2>&1
  OUT="$(sudo -u "$REAL_USER" git commit -m 'self test' 2>&1)"
  echo "$OUT" | grep -q BLOCKED
) && { echo "  PASS - malicious commit was blocked."; ok "6/6 Self-test"; } \
  || bad "6/6 Self-test" "commit was NOT blocked"
rm -rf "$T"

# ===========================================================================
echo ""
echo "=============================================="
echo "   SUMMARY"
echo "=============================================="
[ -n "$PASS" ] && { echo "  Succeeded:"; printf "$PASS\n"; }
[ -n "$FAIL" ] && { echo ""; echo "  Failed:"; printf "$FAIL\n"; }
echo ""
if [ -z "$FAIL" ]; then
    echo "  Everything installed and verified."
    echo "  Detections are written to logs/watch-log.txt"
else
    echo "  Some steps failed - see above."
fi
echo ""
