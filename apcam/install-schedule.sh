#!/bin/sh
# APCAM - install-schedule.sh
#
# The Linux/macOS twin of install-task.ps1: keeps the dashboard fresh by running
# refresh.ps1 under pwsh on a schedule - twice daily at 09:00 and 21:00 by
# default, matching the Windows task.
#
#   Linux : writes a systemd *user* timer to ~/.config/systemd/user/
#           (apcam-refresh.service + .timer). Persistent=true catches a slot
#           missed while the machine was off. User timers only fire while you
#           are logged in unless you run `loginctl enable-linger`.
#   macOS : writes a launchd agent to ~/Library/LaunchAgents/
#           (com.apcam.refresh.plist). launchd runs a missed slot on wake.
#
# Usage:
#   ./install-schedule.sh                  install with the default times
#   ./install-schedule.sh -t 07:00,19:00   custom times, comma-separated HH:MM
#   ./install-schedule.sh -u               uninstall
set -eu

TIMES="09:00,21:00"
UNINSTALL=0
LABEL="com.apcam.refresh"
UNIT="apcam-refresh"

usage() {
    echo "usage: $0 [-t HH:MM[,HH:MM...]] [-u]"
    echo "  -t, --times      schedule times, comma-separated 24h HH:MM (default 09:00,21:00)"
    echo "  -u, --uninstall  remove the timer/agent"
    echo "  -h, --help       this text"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--times)
            [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }
            TIMES="$2"; shift 2 ;;
        -u|--uninstall)
            UNINSTALL=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# resolve the apcam directory this script lives in
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REFRESH="$ROOT/refresh.ps1"

OS=$(uname -s)
case "$OS" in
    Linux|Darwin) ;;
    *) echo "error: unsupported OS '$OS' - on Windows use install-task.ps1" >&2; exit 1 ;;
esac

# ---------------- uninstall ----------------
if [ "$UNINSTALL" = 1 ]; then
    if [ "$OS" = Linux ]; then
        UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        if [ -f "$UNIT_DIR/$UNIT.timer" ] || [ -f "$UNIT_DIR/$UNIT.service" ]; then
            systemctl --user disable --now "$UNIT.timer" 2>/dev/null || true
            rm -f "$UNIT_DIR/$UNIT.timer" "$UNIT_DIR/$UNIT.service"
            systemctl --user daemon-reload 2>/dev/null || true
            echo "removed $UNIT.timer"
        else
            echo "$UNIT.timer was not installed"
        fi
    else
        PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
        if [ -f "$PLIST" ]; then
            launchctl unload "$PLIST" 2>/dev/null || true
            rm -f "$PLIST"
            echo "removed $LABEL"
        else
            echo "$LABEL was not installed"
        fi
    fi
    exit 0
fi

# ---------------- preflight ----------------
[ -f "$REFRESH" ] || { echo "error: missing $REFRESH" >&2; exit 1; }
PWSH=$(command -v pwsh) || {
    echo "error: pwsh not found - refresh.ps1 needs PowerShell 7" >&2
    echo "  https://learn.microsoft.com/powershell/scripting/install/installing-powershell" >&2
    exit 1
}

# validate every time up front; 24h HH:MM only
OLDIFS=$IFS; IFS=','
for t in $TIMES; do
    case "$t" in
        [0-2][0-9]:[0-5][0-9]) ;;
        *) echo "error: bad time '$t' (want 24h HH:MM)" >&2; exit 2 ;;
    esac
    hh=${t%:*}
    [ "$hh" -le 23 ] || { echo "error: bad hour in '$t'" >&2; exit 2; }
done
IFS=$OLDIFS

# ---------------- install ----------------
if [ "$OS" = Linux ]; then
    command -v systemctl >/dev/null 2>&1 || { echo "error: no systemctl - install a cron entry by hand" >&2; exit 1; }
    UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$UNIT_DIR"

    cat > "$UNIT_DIR/$UNIT.service" <<EOF
[Unit]
Description=APCAM power metrics refresh

[Service]
Type=oneshot
WorkingDirectory=$ROOT
ExecStart="$PWSH" -NoProfile -File "$ROOT/refresh.ps1" -LogFile "$ROOT/refresh.log"
EOF

    {
        printf '[Unit]\nDescription=APCAM power metrics refresh schedule\n\n[Timer]\nPersistent=true\n'
        OLDIFS=$IFS; IFS=','
        for t in $TIMES; do printf 'OnCalendar=*-*-* %s:00\n' "$t"; done
        IFS=$OLDIFS
        printf '\n[Install]\nWantedBy=timers.target\n'
    } > "$UNIT_DIR/$UNIT.timer"

    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT.timer"

    echo "installed systemd user timer '$UNIT' at $TIMES"
    echo "run now:   systemctl --user start $UNIT.service"
    echo "status:    systemctl --user list-timers $UNIT.timer"
    echo "log:       journalctl --user -u $UNIT.service   (and $ROOT/refresh.log)"
    echo "remove:    $0 -u"
    echo "note: user timers fire only while you are logged in; 'loginctl enable-linger \$USER' lifts that."
else
    AGENT_DIR="$HOME/Library/LaunchAgents"
    PLIST="$AGENT_DIR/$LABEL.plist"
    mkdir -p "$AGENT_DIR"

    CAL=""
    OLDIFS=$IFS; IFS=','
    for t in $TIMES; do
        hh=${t%:*}; mm=${t#*:}
        # strip leading zeros so the plist holds clean integers
        hh=${hh#0}; mm=${mm#0}
        CAL="$CAL
    <dict><key>Hour</key><integer>$hh</integer><key>Minute</key><integer>$mm</integer></dict>"
    done
    IFS=$OLDIFS

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PWSH</string>
    <string>-NoProfile</string>
    <string>-File</string>
    <string>$ROOT/refresh.ps1</string>
    <string>-LogFile</string>
    <string>$ROOT/refresh.log</string>
  </array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>StartCalendarInterval</key>
  <array>$CAL
  </array>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
EOF

    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"

    echo "installed launchd agent '$LABEL' at $TIMES"
    echo "run now:   launchctl start $LABEL"
    echo "status:    launchctl list | grep $LABEL"
    echo "log:       $ROOT/refresh.log"
    echo "remove:    $0 -u"
fi
