#!/bin/sh
# unix/alerts.sh
#
# Desktop notifications for Git Security Hooks, for Linux and macOS.
# Tails logs/watch-log.txt and raises a notification for each detection.
# No tray icon, no window.
#
# Why a separate process: the watcher runs as a system service (root), which
# has no access to your desktop session. This runs as YOU, so notifications
# actually appear.
#
#   ./alerts.sh                 tail the log (blocks)
#   ./alerts.sh --test          send one sample notification and exit
#   ./alerts.sh --install       start now + start at every login
#   ./alerts.sh --remove        stop and disable
#   ./alerts.sh --ensure        start only if not already running
#   ./alerts.sh --status        show whether it is running
#
# Read-only. Never touches scanned files.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/logs/watch-log.txt"
OS="$(uname -s)"
NAME="gitsecurity-alerts"

# ---------------------------------------------------------------------------
# notify TITLE BODY [urgency]
# ---------------------------------------------------------------------------
notify() {
    _title="$1"; _body="$2"; _urgency="${3:-critical}"

    if [ "$OS" = "Darwin" ]; then
        if command -v terminal-notifier >/dev/null 2>&1; then
            terminal-notifier -title "$_title" -message "$_body" -sound default
        else
            # osascript is always present on macOS. It cannot show a sound for
            # every style, but it needs no extra install.
            /usr/bin/osascript -e "display notification \"$(printf '%s' "$_body" | sed 's/"/\\"/g')\" with title \"$(printf '%s' "$_title" | sed 's/"/\\"/g')\""
        fi
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send -u "$_urgency" "$_title" "$_body"
    else
        # No notification daemon - do not lose the alert.
        echo ""
        echo "  !! $_title"
        echo "     $_body"
        echo ""
        echo "  (install libnotify-bin for desktop popups: sudo apt install libnotify-bin)"
    fi
}

# ---------------------------------------------------------------------------
running_pid() {
    # Match our tail loop, not this invocation
    pgrep -f "alerts.sh --tail" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
case "$1" in

--test)
    notify "Malware detected (TEST)" \
           "/home/example/project/admin.routes.js
Original NOT modified - see logs/watch-log.txt"
    echo "Test notification sent."
    echo "If nothing appeared:"
    [ "$OS" = "Darwin" ] \
        && echo "  macOS: System Settings > Notifications > Script Editor / Terminal must be allowed." \
        || echo "  Linux: sudo apt install libnotify-bin   (and check Do Not Disturb is off)"
    exit 0
    ;;

--status)
    _pid="$(running_pid)"
    echo ""
    echo "  running : ${_pid:-no}"
    echo "  log     : $LOG"
    if [ "$OS" = "Darwin" ]; then
        echo "  autostart: $( [ -f "$HOME/Library/LaunchAgents/com.gitsecurity.alerts.plist" ] && echo installed || echo 'not installed' )"
    else
        echo "  autostart: $(systemctl --user is-enabled $NAME.service 2>/dev/null || echo 'not installed')"
    fi
    echo ""
    exit 0
    ;;

--remove)
    _pid="$(running_pid)"; [ -n "$_pid" ] && kill "$_pid" 2>/dev/null

    if [ "$OS" = "Darwin" ]; then
        _plist="$HOME/Library/LaunchAgents/com.gitsecurity.alerts.plist"
        launchctl unload "$_plist" 2>/dev/null
        rm -f "$_plist"
    else
        systemctl --user disable --now $NAME.service 2>/dev/null
        rm -f "$HOME/.config/systemd/user/$NAME.service"
        systemctl --user daemon-reload 2>/dev/null
    fi
    echo "Alerts removed."
    exit 0
    ;;

--install|--ensure)
    if [ "$1" = "--install" ]; then

        if [ "$OS" = "Darwin" ]; then
            # launchd keeps it alive and independent of any terminal.
            mkdir -p "$HOME/Library/LaunchAgents"
            _plist="$HOME/Library/LaunchAgents/com.gitsecurity.alerts.plist"
            cat > "$_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.gitsecurity.alerts</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$ROOT/unix/alerts.sh</string>
        <string>--tail</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST
            launchctl unload "$_plist" 2>/dev/null
            launchctl load "$_plist" 2>/dev/null
            echo "Alerts installed - they will start at every login."
            exit 0
        fi

        # Linux: a user systemd unit, so it survives closing the terminal.
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$HOME/.config/systemd/user/$NAME.service" <<UNIT
[Unit]
Description=Git Security Hooks - desktop notifications

[Service]
Type=simple
ExecStart=/bin/sh $ROOT/unix/alerts.sh --tail
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable --now $NAME.service 2>/dev/null \
            && { echo "Alerts installed - they will start at every login."; exit 0; }

        echo "systemd --user unavailable, falling back to a background process."
    fi

    # --ensure, or the systemd fallback
    if [ -n "$(running_pid)" ]; then
        echo "Alerts already running."
    else
        nohup /bin/sh "$ROOT/unix/alerts.sh" --tail >/dev/null 2>&1 &
        echo "Alerts started."
    fi
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Default / --tail : watch the log
# ---------------------------------------------------------------------------

# At login the service may still be starting - do not cry wolf.
_i=0
while [ $_i -lt 12 ]; do
    if pgrep -f watcher-service >/dev/null 2>&1; then break; fi
    sleep 5
    _i=$((_i + 1))
done

if pgrep -f watcher-service >/dev/null 2>&1 && [ -n "$(git config --global core.hooksPath)" ]; then
    notify "Git Security: protection active" \
           "Real-time watcher running. Commit/push blocking enabled." normal
else
    notify "Git Security: NOT fully protected" \
           "Run ./RUN-LINUX-MAC.sh to fix." critical
fi

# Wait for the log to exist rather than exiting - a login race would otherwise
# leave notifications permanently off.
_i=0
while [ ! -f "$LOG" ] && [ $_i -lt 60 ]; do sleep 5; _i=$((_i + 1)); done
[ -f "$LOG" ] || exit 0

tail -n 0 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *"DETECTED: "*)
            _f="${line#*DETECTED: }"
            notify "Malware detected: $(basename "$_f")" \
                   "$_f
Original NOT modified - see logs/watch-log.txt"
            ;;
        *"GIT BLOCKED "*)
            _what="$(printf '%s' "$line" | sed -n 's/.*GIT BLOCKED (\([^)]*\)).*/\1/p')"
            _where="${line#*GIT BLOCKED (*): }"
            notify "Git $_what BLOCKED" \
                   "Malware markers found in: $_where
Nothing was committed or pushed."
            ;;
        *"GIT WARNING "*)
            _where="${line#*GIT WARNING (*): }"
            notify "Malware arrived after pull" \
                   "$_where
Already on disk. Clean it before building or running."
            ;;
    esac
done
