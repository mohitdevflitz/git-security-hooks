#!/bin/sh
# unix/install.sh
# Builds the scanner and wires the hooks into git for every repo on this machine.
# Works on Ubuntu/Linux and macOS.
#
# Run:
#   chmod +x install.sh harden.sh scan.sh
#   ./install.sh

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$ROOT/hooks"
SRC="$ROOT/src"
OS="$(uname -s)"

echo "=== Git Security Hooks - Unix Install ($OS) ==="
echo "Root:  $ROOT"
echo "Hooks: $HOOKS"
echo ""

# --- 1. Go -----------------------------------------------------------------
if ! command -v go >/dev/null 2>&1; then
    echo "Go not found. Installing..."
    if [ "$OS" = "Darwin" ]; then
        if command -v brew >/dev/null 2>&1; then
            brew install go
        else
            echo "Install Homebrew (https://brew.sh) or Go (https://go.dev/dl/) first."
            exit 1
        fi
    else
        if command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y golang-go
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y golang
        elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -Sy --noconfirm go
        else
            echo "No known package manager. Install Go from https://go.dev/dl/"
            exit 1
        fi
    fi
else
    echo "Go already installed."
fi

# --- 2. Fix line endings ---------------------------------------------------
# These files may have been created on Windows (CRLF). Unix shells choke on
# that with "bad interpreter: /bin/sh^M", so strip carriage returns first.
echo "Normalising line endings..."
for f in "$HOOKS"/pre-commit "$HOOKS"/pre-merge-commit "$HOOKS"/pre-push \
         "$HOOKS"/post-merge "$HOOKS"/post-checkout "$HOOKS"/post-rewrite; do
    [ -f "$f" ] || continue
    tr -d '\r' < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
tr -d '\r' < "$SRC/scanner.go" > "$SRC/scanner.go.tmp" && mv "$SRC/scanner.go.tmp" "$SRC/scanner.go"

# --- 3. Build --------------------------------------------------------------
echo "Building scanner into hooks/ ..."
cd "$SRC"
go build -o "$HOOKS/scanner" scanner.go
chmod +x "$HOOKS/scanner"
chmod +x "$HOOKS"/pre-commit "$HOOKS"/pre-merge-commit "$HOOKS"/pre-push \
         "$HOOKS"/post-merge "$HOOKS"/post-checkout "$HOOKS"/post-rewrite
echo "scanner built."

# --- 3. Wire up git --------------------------------------------------------
git config --global core.hooksPath "$HOOKS"
echo "core.hooksPath -> $HOOKS"

# --- 4. Verify -------------------------------------------------------------
echo ""
echo "=== Verification ==="
echo "core.hooksPath = $(git config --global core.hooksPath)"
echo "Hooks present:"
ls -1 "$HOOKS" | sed 's/^/  /'
echo ""
echo "Install complete. Run: sudo ./harden.sh   to lock it down."
