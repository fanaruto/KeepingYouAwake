#!/bin/sh
# Embedded in KYAClamshellSession; never invoke this script through sudo manually.
# The app supplies a private session directory, owner PID and owner start time.
# An authorized root watchdog owns the write and restores it independently.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL
PMSET=/usr/bin/pmset
PS=/bin/ps
STAT=/usr/bin/stat
DATE=/bin/date
SLEEP=/bin/sleep
INTERVAL=2
HEARTBEAT_TIMEOUT=60
RESTORE_ATTEMPTS=30
LOCK_DIR=/var/run/com.webfooo.KeepingYouAwake.clamshell

[ "$#" -eq 3 ] || exit 64
session_dir=$1
owner_pid=$2
owner_start=$3
case "$owner_pid" in ''|*[!0-9]*) exit 64 ;; esac
[ -d "$session_dir" ] && [ ! -L "$session_dir" ] || exit 64
cd -P "$session_dir" || exit 64
umask 022
owned=0
lock_owned=0
lock_token="$session_dir:$$"
reason=error:initialization

marker() {
    # Noclobber refuses pre-existing files and symlinks in the user-owned directory.
    (set -C; printf '%s\n' "$2" > "$1") 2>/dev/null
}

read_state() {
    output=$("$PMSET" -g) || return 1
    state=$(printf '%s\n' "$output" | /usr/bin/awk '$1 == "SleepDisabled" && ($2 == "0" || $2 == "1") { print $2; exit }')
    case "$state" in 0|1) printf '%s\n' "$state" ;; *) return 1 ;; esac
}

cleanup() {
    trap '' HUP INT TERM
    if [ "$owned" -eq 1 ]; then
        attempt=0
        while [ "$attempt" -lt "$RESTORE_ATTEMPTS" ]; do
            "$PMSET" -a disablesleep 0 >/dev/null 2>&1 || :
            current=$(read_state) || current=unknown
            if [ "$current" = 0 ]; then
                owned=0
                break
            fi
            attempt=$((attempt + 1))
            "$SLEEP" 1
        done
        [ "$owned" -eq 0 ] || reason=error:restore
    fi
    if [ "$lock_owned" -eq 1 ] && [ "$(/bin/cat "$LOCK_DIR/owner" 2>/dev/null)" = "$lock_token" ]; then
        /bin/rm -f "$LOCK_DIR/owner"
        /bin/rmdir "$LOCK_DIR" 2>/dev/null || :
    fi
    marker done "$reason" || :
}
trap cleanup EXIT
trap 'reason=signal; exit 0' HUP INT TERM

if ! /bin/mkdir -m 700 "$LOCK_DIR" 2>/dev/null; then
    reason=already-running
    exit 1
fi
lock_owned=1
printf '%s\n' "$lock_token" > "$LOCK_DIR/owner" || { reason=error:lock; exit 1; }
marker lock-token "$lock_token" || { reason=error:lock; exit 1; }

current=$(read_state) || { reason=error:read-state; exit 1; }
if [ "$current" = 1 ]; then
    reason=already-disabled
    exit 0
fi

# Assume ownership before the command: even a failing command may have written.
owned=1
marker owned "$$" || { reason=error:ready; exit 1; }
if ! "$PMSET" -a disablesleep 1 >/dev/null 2>&1; then
    reason=error:enable
    exit 1
fi
current=$(read_state) || current=unknown
[ "$current" = 1 ] || { reason=error:verify; exit 1; }
marker ready "$$" || { reason=error:ready; exit 1; }
started=$("$DATE" +%s)

while :; do
    [ ! -e stop ] || { reason=stopped; break; }
    current=$(read_state) || { reason=error:read-state; break; }
    if [ "$current" = 0 ]; then
        owned=0
        reason=external-change
        break
    fi
    actual_start=$("$PS" -p "$owner_pid" -o lstart= 2>/dev/null) || actual_start=
    [ "$actual_start" = "$owner_start" ] || { reason=owner-gone; break; }
    now=$("$DATE" +%s)
    heartbeat=$("$STAT" -f %m heartbeat 2>/dev/null) || heartbeat=0
    case "$heartbeat" in ''|*[!0-9]*) heartbeat=0 ;; esac
    # Allow a full timeout from startup for a slow authorization round trip.
    if [ "$((now - started))" -ge "$HEARTBEAT_TIMEOUT" ] && [ "$((now - heartbeat))" -ge "$HEARTBEAT_TIMEOUT" ]; then
        reason=heartbeat-expired
        break
    fi
    battery=$("$PMSET" -g batt 2>/dev/null) || battery=
    case "$battery" in
        *"'Battery Power'"*)
            percent=$(printf '%s\n' "$battery" | /usr/bin/awk 'match($0, /[0-9]+%/) { print substr($0, RSTART, RLENGTH - 1); exit }')
            case "$percent" in
                ''|*[!0-9]*) ;;
                *) if [ "$percent" -le 10 ]; then reason=low-battery; break; fi ;;
            esac
            ;;
    esac
    "$SLEEP" "$INTERVAL"
done
