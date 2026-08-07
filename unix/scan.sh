#!/bin/sh
# unix/scan.sh
# Targeted or full-machine malware scan.
#
#   ./scan.sh                    -> interactive prompt
#   ./scan.sh -path /home/me     -> one folder
#   ./scan.sh -all               -> every mounted filesystem, no prompt

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER="$ROOT/hooks/scanner"

if [ ! -f "$SCANNER" ]; then
    echo "scanner not found. Run unix/install.sh first."
    exit 1
fi

TARGET=""
ALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        -path) TARGET="$2"; shift 2 ;;
        -all)  ALL=1; shift ;;
        *)     shift ;;
    esac
done

OS="$(uname -s)"

list_mounts() {
    if [ "$OS" = "Darwin" ]; then
        echo "/"
        df -h 2>/dev/null | awk 'NR>1 && $NF ~ /^\/Volumes/ {print $NF}'
    else
        df -h --output=target 2>/dev/null | tail -n +2 | grep -vE '^/(proc|sys|dev|run|snap)'
    fi
}

if [ -n "$TARGET" ]; then
    [ ! -e "$TARGET" ] && { echo "Path not found: $TARGET"; exit 1; }
    TARGETS="$TARGET"
elif [ "$ALL" = "1" ]; then
    TARGETS="$(list_mounts)"
else
    echo "What do you want to scan?"
    echo "  [A] All mounted filesystems"
    echo "  [P] A specific folder"
    printf "Enter A or P: "
    read choice
    case "$(echo "$choice" | tr '[:lower:]' '[:upper:]')" in
        P)
            printf "Folder path: "
            read p
            [ ! -e "$p" ] && { echo "Path not found."; exit 1; }
            TARGETS="$p"
            ;;
        *) TARGETS="$(list_mounts)" ;;
    esac
fi

LOG="$ROOT/scan-log-$(date +%Y-%m-%d_%H-%M-%S).txt"

{
    echo "===== Malware Scan ====="
    echo "Started: $(date)"
    echo "Targets: $TARGETS"
    echo ""
} > "$LOG"

echo ""
echo "=== Scan started: $(date) ==="

echo "$TARGETS" | while IFS= read -r t; do
    [ -z "$t" ] && continue
    echo "Scanning $t ..."
    echo "---- $t ----" >> "$LOG"
    RES="$("$SCANNER" -tree "$t" 2>&1)"
    if [ -n "$RES" ]; then
        echo "$RES"
        echo "$RES" >> "$LOG"
    fi
    echo "" >> "$LOG"
done

MATCHES=$(grep -c '\[MATCH\]' "$LOG" 2>/dev/null || echo 0)

echo "===== Complete: $(date) =====" >> "$LOG"

if [ "$MATCHES" -eq 0 ]; then
    VERDICT="VERDICT: CLEAN - no malware markers found."
else
    VERDICT="VERDICT: INFECTED - $MATCHES match(es) found."
fi

echo ""
echo "$VERDICT"

# Put the verdict at the top of the log (portable: rewrite the file)
{
    echo "$VERDICT"
    echo ""
    cat "$LOG"
} > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

echo "Log: $LOG"
