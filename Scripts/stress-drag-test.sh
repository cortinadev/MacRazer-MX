#!/usr/bin/env bash
# Times the extra-button drags that go through MacRazer MX's event tap, at rest and under load,
# to see whether a busy app makes middle-drag panning stutter (in Blender, say). The running
# app does the timing (`DragTiming`, a hidden switch this script turns on and back off); the
# script loads the machine, tells you what to do meanwhile, and prints what the app measured.
#
#   ./Scripts/stress-drag-test.sh baseline   # no load: the numbers to compare the others with
#   ./Scripts/stress-drag-test.sh busy       # the app's main thread blocked 20 ms in every 50 ms
#   ./Scripts/stress-drag-test.sh cpu        # every core kept busy, two loops per logical core
#   ./Scripts/stress-drag-test.sh both       # busy and cpu at once
#   ./Scripts/stress-drag-test.sh cpu-only   # only the CPU load: no flag changed, nothing measured
#
# Options, after the mode:
#   --seconds N         how long the run lasts, 5 to 300 (default 60)
#   --busy BLOCK/EVERY  the busy main thread in ms, block 1 to 500 (default 20/50)
#   --workers N         busy loops for cpu and both, 1 to 256 (default two per logical core)
#
# MacRazer MX must be running, a build that has the drag timing (Sources/MacRazer/DragTiming.swift):
# an older one doesn't answer when the timing is turned on, and the script stops there. Nothing
# needs a relaunch. The lines land in ~/Library/Logs/MacRazer MX/gesture.log, numbers only.
#
# Nothing it starts outlives it. The busy main thread is the app's `dragTimingBusy` key, which
# the app drops by itself after the run's seconds and on every launch. Each CPU loop ends by
# itself two seconds after the run, even if this script is killed outright. Ctrl-C stops both
# at once, puts `dragTimingLog` back as it was, and prints what was measured so far.
set -euo pipefail

DOMAIN="com.cortinadev.macrazer-mx"
TIMING_KEY="dragTimingLog"
BUSY_KEY="dragTimingBusy"
LOG="${HOME}/Library/Logs/MacRazer MX/gesture.log"
APP_EXECUTABLE="MacRazer MX.app/Contents/MacOS/MacRazer"

usage() {
    cat <<'EOF'
Usage: Scripts/stress-drag-test.sh baseline|busy|cpu|both|cpu-only
           [--seconds N] [--busy BLOCK/EVERY] [--workers N]

  baseline  no load, to compare with
  busy      MacRazer MX's main thread blocked BLOCK ms in every EVERY ms (default 20/50)
  cpu       every core kept busy (--workers loops, default two per logical core)
  both      busy and cpu at once
  cpu-only  only the CPU load: changes no flag and measures nothing

  --seconds N  how long the run lasts, 5 to 300 (default 60)
EOF
}

die() {
    echo "✗ $*" >&2
    exit 1
}

is_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

MODE="${1:-}"
case "${MODE}" in
    baseline | busy | cpu | both | cpu-only) shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
esac

CORES="$(sysctl -n hw.logicalcpu)"
DURATION=60
BUSY="20/50"
WORKERS=$((2 * CORES))
while [ "$#" -gt 0 ]; do
    if [ "$#" -lt 2 ]; then
        usage >&2
        exit 64
    fi
    case "$1" in
        --seconds) DURATION="$2" ;;
        --busy) BUSY="$2" ;;
        --workers) WORKERS="$2" ;;
        *) usage >&2; exit 64 ;;
    esac
    shift 2
done

# The same limits the app holds the busy main thread to (`MainThreadBusy.Plan`), checked here
# so a typo is caught before anything starts. 10# so a leading zero isn't read as octal.
is_number "${DURATION}" && [ "${DURATION}" -ge 5 ] && [ "${DURATION}" -le 300 ] \
    || die "--seconds takes a whole number from 5 to 300"
DURATION=$((10#${DURATION}))
is_number "${WORKERS}" && [ "${WORKERS}" -ge 1 ] && [ "${WORKERS}" -le 256 ] \
    || die "--workers takes a whole number from 1 to 256"
WORKERS=$((10#${WORKERS}))
BLOCK="${BUSY%%/*}"
EVERY="${BUSY#*/}"
is_number "${BLOCK}" && is_number "${EVERY}" && [ "${BLOCK}" -ge 1 ] && [ "${BLOCK}" -le 500 ] \
    && [ "${EVERY}" -gt "${BLOCK}" ] && [ "${EVERY}" -le 10000 ] \
    || die "--busy takes BLOCK/EVERY in ms: block 1 to 500, every longer than block and at most 10000"
BLOCK=$((10#${BLOCK}))
EVERY=$((10#${EVERY}))

# What this run has changed, so the traps undo exactly that.
WORKER_PIDS=()
BUSY_SET=0
TIMING_CHANGED=0
TIMING_BEFORE=""
RUN_STARTED=0
FINISHED=0
START_BYTES=0

# Stops the CPU loops and the busy main thread. Safe to call more than once.
stop_load() {
    if [ "${#WORKER_PIDS[@]}" -gt 0 ]; then
        kill "${WORKER_PIDS[@]}" 2>/dev/null || true
        wait "${WORKER_PIDS[@]}" 2>/dev/null || true
        WORKER_PIDS=()
    fi
    if [ "${BUSY_SET}" -eq 1 ]; then
        BUSY_SET=0
        # Gone already if the app finished it: it drops the key itself.
        defaults delete "${DOMAIN}" "${BUSY_KEY}" 2>/dev/null || true
    fi
}

# Puts `dragTimingLog` back as it was before the run. Safe to call more than once.
restore_timing() {
    [ "${TIMING_CHANGED}" -eq 1 ] || return 0
    TIMING_CHANGED=0
    case "${TIMING_BEFORE}" in
        1) defaults write "${DOMAIN}" "${TIMING_KEY}" -bool true ;;
        0) defaults write "${DOMAIN}" "${TIMING_KEY}" -bool false ;;
        "") defaults delete "${DOMAIN}" "${TIMING_KEY}" 2>/dev/null || true ;;
        *) defaults write "${DOMAIN}" "${TIMING_KEY}" -string "${TIMING_BEFORE}" ;;
    esac
}

log_size() {
    if [ -f "${LOG}" ]; then stat -f %z "${LOG}"; else echo 0; fi
}

# The app's DRAGTIMING lines written since this run began.
new_lines() {
    [ -f "${LOG}" ] || return 0
    tail -c +"$((START_BYTES + 1))" "${LOG}" | grep ' DRAGTIMING ' || true
}

# Waits up to $2 tenths of a second for a new line containing $1. Read into a variable, not
# piped to `grep -q`: that can end the pipe early, which pipefail reports as a failure.
wait_for_line() {
    local tries=0 lines
    while [ "${tries}" -lt "$2" ]; do
        lines="$(new_lines)"
        case "${lines}" in *"$1"*) return 0 ;; esac
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

start_cpu_load() {
    local i=0
    while [ "${i}" -lt "${WORKERS}" ]; do
        # Each loop also ends by itself two seconds after the run, so none outlives the script
        # for longer than that even when it is killed outright and no trap runs.
        (
            stop_at=$((SECONDS + DURATION + 2))
            while [ "${SECONDS}" -lt "${stop_at}" ]; do :; done
        ) &
        WORKER_PIDS+=("$!")
        i=$((i + 1))
    done
    echo "▸ CPU load: ${WORKERS} busy loops on ${CORES} logical cores."
}

start_busy() {
    defaults write "${DOMAIN}" "${BUSY_KEY}" -string "${BLOCK}/${EVERY}/${DURATION}"
    BUSY_SET=1
    if wait_for_line "DRAGTIMING busy on" 30; then
        echo "▸ MacRazer MX's main thread is blocked ${BLOCK} ms in every ${EVERY} ms."
    else
        echo "⚠ MacRazer MX didn't say its main thread went busy; the numbers will show whether it did." >&2
    fi
}

# Sleeps out the run, a second at a time so Ctrl-C is answered at once.
wait_out() {
    local waited=0
    while [ "${waited}" -lt "${DURATION}" ]; do
        sleep 1
        waited=$((waited + 1))
        if [ $((waited % 10)) -eq 0 ] && [ "${waited}" -lt "${DURATION}" ]; then
            echo "  ${waited} s of ${DURATION}…"
        fi
    done
}

report() {
    local lines
    lines="$(new_lines)"
    echo
    echo "What MacRazer MX measured (a line a second while drags came, times in ms):"
    if [ -n "${lines}" ]; then
        printf '%s\n' "${lines}" | sed 's/^/  /'
    else
        echo "  nothing"
    fi
    echo
    if ! printf '%s\n' "${lines}" | awk '
        / DRAGTIMING n=/ {
            delete v
            for (i = 1; i <= NF; i++) if (split($i, kv, "=") == 2) v[kv[1]] = kv[2]
            windows++
            events += v["n"]
            untimed += v["untimed"]
            if (v["delay_p50_ms"] != "-") {
                p50 = v["delay_p50_ms"] + 0
                if (!timed || p50 < low50) low50 = p50
                if (!timed || p50 > high50) high50 = p50
                if (v["delay_p95_ms"] + 0 > p95) p95 = v["delay_p95_ms"] + 0
                if (v["delay_max_ms"] + 0 > longest) longest = v["delay_max_ms"] + 0
                timed = 1
            }
            if (v["callback_max_ms"] + 0 > callback) callback = v["callback_max_ms"] + 0
            if (v["per_s"] != "-" && v["per_s"] + 0 > rate) rate = v["per_s"] + 0
        }
        / DRAGTIMING tap disabled/ { disabled++ }
        END {
            if (windows == 0) exit 1
            printf "Over the run: %d drags in %d one-second windows, up to %d a second.\n", events, windows, rate
            if (timed) printf "Delay: p50 from %.2f to %.2f ms, highest p95 %.2f ms, longest %.2f ms.\n",
                low50, high50, p95, longest
            printf "Longest time inside the tap callback: %.3f ms.\n", callback
            if (untimed > 0) printf "%d drags had no usable timestamp and are left out of the delays.\n", untimed
            if (disabled > 0) printf "macOS turned the tap off %d times for answering too slowly.\n", disabled
        }'; then
        echo "No drag was timed. Was the wheel held and dragged during the run, and is some button"
        echo "other than the wheel a Gesture? The 'DRAGTIMING on' line above says whether drags"
        echo "go through the tap."
        return 0
    fi
    cat <<'EOF'

How to read it:
  delay     from when macOS stamped a drag to when MacRazer MX's tap took it. The tap holds
            each drag, for every app, until it answers, so this is the lag a busy MacRazer MX
            adds to a middle drag in Blender. Compare with a baseline run. A p95 or longest
            near a display frame (16.7 ms at 60 Hz, 8.3 ms at 120 Hz) or above can show as
            stutter; one under a millisecond can't.
  callback  time inside the tap itself. A busy main thread shows in delay, not here.
  per_s     drags a second: about 1000 at 1000 Hz on the dongle or cable, about 125 over
            Bluetooth. Fewer means the wheel wasn't dragged for that whole second.
EOF
}

# Stops the load, lets the app write its last window, puts the flags back and reports. Once.
finish() {
    [ "${FINISHED}" -eq 0 ] || return 0
    FINISHED=1
    stop_load
    if [ "${RUN_STARTED}" -eq 1 ] && [ "${TIMING_CHANGED}" -eq 1 ]; then
        echo "▸ Collecting the last numbers…"
        # The app writes the last window within two seconds of the last drag.
        sleep 2.5
        restore_timing
        if [ "${TIMING_BEFORE}" != "1" ]; then wait_for_line "DRAGTIMING off" 30 || true; fi
        report
    fi
    restore_timing
}

on_signal() {
    trap - INT TERM HUP
    echo
    echo "▸ Stopped early."
    finish
    exit 130
}

trap 'stop_load; restore_timing' EXIT
trap on_signal INT TERM HUP

if [ "${MODE}" = "cpu-only" ]; then
    echo "▸ CPU load only, for ${DURATION} s. No flag is changed and nothing is measured."
    start_cpu_load
    wait_out
    stop_load
    echo "✓ Load stopped."
    exit 0
fi

pgrep -f "${APP_EXECUTABLE}" >/dev/null 2>&1 \
    || die "MacRazer MX isn't running. Open it, then run this again."

START_BYTES="$(log_size)"
TIMING_BEFORE="$(defaults read "${DOMAIN}" "${TIMING_KEY}" 2>/dev/null || true)"
TIMING_CHANGED=1
if [ "${TIMING_BEFORE}" = "1" ]; then
    # Already on: off and on again, so the app answers and the check below can see it.
    defaults write "${DOMAIN}" "${TIMING_KEY}" -bool false
    sleep 0.5
fi
defaults write "${DOMAIN}" "${TIMING_KEY}" -bool true
wait_for_line "DRAGTIMING on" 30 \
    || die "MacRazer MX didn't answer. The running build has no drag timing: build one that has
  it (Scripts/build-app.sh) and run that. Nothing was left changed."
ON_LINE="$(new_lines | grep 'DRAGTIMING on' | tail -n 1)"
echo "▸ Drag timing on (${ON_LINE#*DRAGTIMING on, })."
case "${ON_LINE}" in
    *"tap: no"*)
        echo "⚠ No drag goes through the tap yet. Make a button other than the wheel a Gesture"
        echo "  (Configure Buttons › Gesture…, on Back or Forward, say) before you start." ;;
esac

case "${MODE}" in
    baseline) LOAD="no load" ;;
    busy) LOAD="MacRazer MX's main thread blocked ${BLOCK} ms in every ${EVERY} ms" ;;
    cpu) LOAD="${WORKERS} busy loops on ${CORES} logical cores" ;;
    both) LOAD="the main thread blocked ${BLOCK}/${EVERY} ms and ${WORKERS} busy loops" ;;
esac
cat <<EOF

Run: ${MODE}, ${DURATION} s, ${LOAD}.

What to do:
  1. For the test that matters, connect the mouse by its USB dongle or cable at 1000 Hz.
     Over Bluetooth the Cobra HyperSpeed reports about 125 times a second, a gentler test.
  2. Some button other than the wheel must be a Gesture (Configure Buttons › Gesture…):
     only then does the tap ask for drags. A gesture on the DPI button doesn't count, and
     the wheel itself must not be one, or its drags become the gesture.
  3. Once the run starts, hold the wheel button down and drag, on and off, for the whole
     run: pan or orbit in Blender's viewport, or anywhere a middle drag pans. Watch for stutter.

EOF
if [ -t 0 ]; then
    printf 'Press Return to start, then you have 3 seconds to get to the app. '
    read -r _ || true
fi
for left in 3 2 1; do
    echo "  ${left}…"
    sleep 1
done

RUN_STARTED=1
case "${MODE}" in busy | both) start_busy ;; esac
case "${MODE}" in cpu | both) start_cpu_load ;; esac
echo "▸ Go: hold the wheel and drag. ${DURATION} s."
wait_out
echo "▸ Run over."
finish
