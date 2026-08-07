#!/bin/sh
# ===========================================================
#   GIT SECURITY HOOKS - LINUX / MACOS LAUNCHER
#   Run:  chmod +x RUN-LINUX-MAC.sh && ./RUN-LINUX-MAC.sh
# ===========================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"
UNIX="$ROOT/unix"

chmod +x "$UNIX"/*.sh 2>/dev/null

show_status() {
    echo ""
    echo "--- Current status ---"

    HP="$(git config --global core.hooksPath 2>/dev/null)"
    if [ -n "$HP" ]; then echo "  core.hooksPath : $HP"
    else                  echo "  core.hooksPath : NOT SET"; fi

    if [ -f "$ROOT/hooks/scanner" ]; then echo "  scanner        : present"
    else                                  echo "  scanner        : MISSING (not installed yet)"; fi

    OS="$(uname -s)"
    if [ "$OS" = "Linux" ]; then
        if systemctl is-active git-hooks-guard.timer >/dev/null 2>&1; then
            echo "  guard timer    : active"
        else
            echo "  guard timer    : NOT ACTIVE"
        fi
    elif [ "$OS" = "Darwin" ]; then
        if launchctl list 2>/dev/null | grep -q gitsecurityhooks; then
            echo "  guard daemon   : loaded"
        else
            echo "  guard daemon   : NOT LOADED"
        fi
    fi

    MISSING=""
    for h in pre-commit pre-merge-commit pre-push post-merge post-checkout post-rewrite; do
        [ ! -f "$ROOT/hooks/$h" ] && MISSING="$MISSING $h"
    done
    if [ -n "$MISSING" ]; then echo "  hooks          : MISSING ->$MISSING"
    else                       echo "  hooks          : all 6 present"; fi
    echo ""
}

do_scan() {
    echo ""
    echo "=== SCAN ==="
    echo "  1) All mounted filesystems"
    echo "  2) A specific folder"
    echo "  3) Current git repo only"
    echo "  4) Back"
    echo ""
    printf "Choose 1-4: "
    read c
    case "$c" in
        1) "$UNIX/scan.sh" -all ;;
        2) printf "Folder path: "; read p; "$UNIX/scan.sh" -path "$p" ;;
        3)
            if [ -d ".git" ]; then "$UNIX/scan.sh" -path "$(pwd)"
            else echo "Not a git repo: $(pwd)"; fi
            ;;
        4) return ;;
        *) echo "Invalid choice." ;;
    esac
}

service_menu() {
    OS="$(uname -s)"

    while true; do
        echo ""
        echo "=== REAL-TIME WATCHER SERVICE ==="

        if [ "$OS" = "Linux" ]; then
            if systemctl is-active gitsecurity-watcher >/dev/null 2>&1; then
                echo "  Current state: running"
            elif [ -f /etc/systemd/system/gitsecurity-watcher.service ]; then
                echo "  Current state: installed but stopped"
            else
                echo "  Current state: NOT INSTALLED"
            fi
        else
            if launchctl list 2>/dev/null | grep -q gitsecurityhooks.watcher; then
                echo "  Current state: running"
            elif [ -f /Library/LaunchDaemons/com.gitsecurityhooks.watcher.plist ]; then
                echo "  Current state: installed but stopped"
            else
                echo "  Current state: NOT INSTALLED"
            fi
        fi

        echo ""
        echo "  1) Install - WHOLE MACHINE, auto-clean   [recommended]"
        echo "  2) Install - WHOLE MACHINE, alert only"
        echo "  3) Install - one folder only"
        echo "  4) Start"
        echo "  5) Stop"
        echo "  6) Remove"
        echo "  7) View recent log"
        echo "  8) Back"
        echo ""
        printf "Choose 1-8: "
        read c

        case "$c" in
            1)
                echo "Installing whole-machine watcher with auto-clean..."
                sudo "$UNIX/install-service.sh" --all --quarantine
                ;;
            2)
                echo "Installing whole-machine watcher (alert only)..."
                sudo "$UNIX/install-service.sh" --all
                ;;
            3)
                printf "Folder to watch (e.g. /home/me/projects): "
                read p
                [ ! -d "$p" ] && { echo "Not found."; continue; }
                sudo "$UNIX/install-service.sh" "$p" --quarantine
                ;;
            4)
                if [ "$OS" = "Linux" ]; then sudo systemctl start gitsecurity-watcher
                else sudo launchctl load /Library/LaunchDaemons/com.gitsecurityhooks.watcher.plist; fi
                echo "Started."
                ;;
            5)
                if [ "$OS" = "Linux" ]; then sudo systemctl stop gitsecurity-watcher
                else sudo launchctl unload /Library/LaunchDaemons/com.gitsecurityhooks.watcher.plist; fi
                echo "Stopped."
                ;;
            6)
                sudo "$UNIX/install-service.sh" --remove
                ;;
            7)
                LOG="$ROOT/logs/watch-log.txt"
                if [ -f "$LOG" ]; then
                    echo ""
                    tail -n 25 "$LOG"
                else
                    echo "No log yet at $LOG"
                fi
                ;;
            8) return ;;
            *) echo "Pick 1-8." ;;
        esac
    done
}

self_test() {
    echo ""
    echo "Testing... creating a throwaway repo with a fake payload."
    T="/tmp/hookselftest"
    rm -rf "$T"; mkdir -p "$T"; cd "$T" || return
    git init >/dev/null 2>&1
    echo 'global.i="A10-*10610";fake payload for testing' > test.js
    git add test.js >/dev/null 2>&1
    OUT="$(git commit -m "self test" 2>&1)"
    cd - >/dev/null || true
    rm -rf "$T"

    if echo "$OUT" | grep -q "BLOCKED"; then
        echo ""
        echo "  PASS - the commit was blocked as expected."
    else
        echo ""
        echo "  FAIL - not blocked. Run option 1 to install."
        echo "$OUT"
    fi
}

# ===========================================================================
while true; do
    echo ""
    echo "=============================================="
    echo "     GIT SECURITY HOOKS - MALWARE GUARD"
    echo "=============================================="
    echo ""
    echo "  1) INSTALL EVERYTHING  [start here]"
    echo "     hooks + service + self-test"
    echo "  2) Scan for malware"
    echo "  3) Real-time watcher service (install/start/stop/remove)"
    echo "  4) Check status"
    echo "  5) Test that blocking works"
    echo "  6) Advanced (install without lockdown / re-harden)"
    echo "  7) Exit"
    echo ""
    printf "Choose 1-7: "
    read choice

    case "$choice" in
        1)
            chmod +x "$UNIX"/*.sh 2>/dev/null
            sudo "$UNIX/install-everything.sh"
            ;;
        2) do_scan ;;
        3) service_menu ;;
        4) show_status ;;
        5) self_test ;;
        6)
            echo ""
            echo "  a) Install only (no lockdown)"
            echo "  b) Harden only"
            echo "  c) Back"
            printf "Choose a-c: "
            read adv
            case "$adv" in
                a|A) "$UNIX/install.sh"; show_status ;;
                b|B) sudo "$UNIX/harden.sh"; show_status ;;
                *) ;;
            esac
            ;;
        7) echo "Done."; exit 0 ;;
        *) echo "Pick 1-7." ;;
    esac
done
