#!/bin/sh
# unix/install-service.sh
# Builds the watcher and installs it as a background service:
# systemd on Linux, launchd on macOS.
#
#   sudo ./install-service.sh /path/to/watch [--quarantine]
#   sudo ./install-service.sh --remove

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$ROOT/hooks"
SRC="$ROOT/src/service"
BIN="$HOOKS/watcher-service"
OS="$(uname -s)"

SERVICE_NAME="gitsecurity-watcher"
PLIST="/Library/LaunchDaemons/com.gitsecurityhooks.watcher.plist"
UNIT="/etc/systemd/system/$SERVICE_NAME.service"

# --- remove ----------------------------------------------------------------
if [ "$1" = "--remove" ]; then
    if [ "$OS" = "Linux" ]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "$UNIT"
        systemctl daemon-reload
        echo "Service removed."
    else
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        echo "Service removed."
    fi
    exit 0
fi

WATCH_PATH=""
WATCH_ARGS=""
QUARANTINE=""

for arg in "$@"; do
    case "$arg" in
        --all)        WATCH_ARGS="-all" ;;
        --quarantine) QUARANTINE="-quarantine" ;;
        --*)          ;;
        *)            WATCH_PATH="$arg" ;;
    esac
done

if [ -z "$WATCH_ARGS" ]; then
    if [ -z "$WATCH_PATH" ]; then
        echo "Usage:"
        echo "  sudo ./install-service.sh --all [--quarantine]              # whole machine"
        echo "  sudo ./install-service.sh /path/to/watch [--quarantine]     # one folder"
        exit 1
    fi
    if [ ! -d "$WATCH_PATH" ]; then
        echo "Folder not found: $WATCH_PATH"
        exit 1
    fi
    WATCH_ARGS="-path \"$WATCH_PATH\""
    DESCRIBE="$WATCH_PATH"
else
    DESCRIBE="whole machine (all filesystems)"
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo:  sudo ./install-service.sh $WATCH_PATH $2"
    exit 1
fi

# --- build -----------------------------------------------------------------
if ! command -v go >/dev/null 2>&1; then
    echo "Go not found. Run ./install.sh first."
    exit 1
fi

echo "Building watcher..."
cd "$SRC"
go mod tidy
go build -o "$BIN" .
chmod +x "$BIN"
echo "Built: $BIN"

mkdir -p "$ROOT/logs" "$ROOT/quarantine"

# --- install ---------------------------------------------------------------
if [ "$OS" = "Linux" ]; then

    cat > "$UNIT" <<EOF
[Unit]
Description=$SERVICE_NAME - Git Security Hooks Malware Watcher
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh -c '$BIN run $WATCH_ARGS $QUARANTINE'
Restart=always
RestartSec=5
StandardOutput=append:$ROOT/logs/service.log
StandardError=append:$ROOT/logs/service.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"

    echo ""
    echo "Service installed and started."
    echo "  Status : sudo systemctl status $SERVICE_NAME"
    echo "  Logs   : $ROOT/logs/"
    echo "  Remove : sudo ./install-service.sh --remove"

elif [ "$OS" = "Darwin" ]; then

    # Build the <string> args for launchd
    if [ "$WATCH_ARGS" = "-all" ]; then
        PATH_ARGS="        <string>-all</string>"
    else
        PATH_ARGS="        <string>-path</string>
        <string>$WATCH_PATH</string>"
    fi
    QUAR_ARG=""
    [ -n "$QUARANTINE" ] && QUAR_ARG="        <string>-quarantine</string>"

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gitsecurityhooks.watcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>run</string>
$PATH_ARGS
$QUAR_ARG
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$ROOT/logs/service.log</string>
    <key>StandardErrorPath</key>
    <string>$ROOT/logs/service.log</string>
</dict>
</plist>
EOF

    chown root:wheel "$PLIST"
    chmod 644 "$PLIST"
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"

    echo ""
    echo "Service installed and started."
    echo "  Status : sudo launchctl list | grep gitsecurityhooks"
    echo "  Logs   : $ROOT/logs/"
    echo "  Remove : sudo ./install-service.sh --remove"

else
    echo "Unsupported OS: $OS"
    exit 1
fi
