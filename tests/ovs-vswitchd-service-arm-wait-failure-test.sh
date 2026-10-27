#!/bin/bash
# Regression test for openvswitch-switch.ovs-vswitchd.service's ExecStart:
# failing to arm flow-restore-wait must abort the start, not continue
# unprotected.
#
# Before this fix: "ovs-vsctl ... set open_vswitch . other_config:
# flow-restore-wait=true" had no "|| exit 1" - if that command failed (e.g.
# ovsdb-server not yet reachable, a transient timeout), execution fell
# straight through to starting ovs-vswitchd anyway. Without the guard
# actually armed, the new daemon does its normal startup (flush the
# datapath, come up live, start accepting controller connections) before
# the saved-flows replay that follows ever runs - exactly the packet-loss
# window this whole mechanism exists to close, and silently so: nothing
# about the failed ovs-vsctl call stopped anything or was even logged.
#
# This extracts the literal ExecStart= command out of the real .service
# file and runs it with a saved-flows file present (so the arming branch is
# taken) and a fake ovs-vsctl that fails specifically on the
# flow-restore-wait "set" call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_FILE="$SCRIPT_DIR/debian/openvswitch-switch.ovs-vswitchd.service"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

exec_start=$(sed -n '/^ExecStart=/,/[^\\]$/p' "$SERVICE_FILE" | sed '1s/^ExecStart=//')
if [ -z "$exec_start" ]; then
    echo "FAIL: could not extract ExecStart= from $SERVICE_FILE" >&2
    exit 1
fi

FAKEBIN="$WORKDIR/bin"
mkdir -p "$FAKEBIN"
write_fake() {
    local name="$1" body="$2"
    cat > "$FAKEBIN/$name" <<EOF
#!/bin/bash
$body
EOF
    chmod +x "$FAKEBIN/$name"
}

CTL_CALLED="$WORKDIR/ctl-called"
write_fake ovs-ctl 'touch "'"$CTL_CALLED"'"; exit 0'

VSCTL_LOG="$WORKDIR/vsctl.log"
: > "$VSCTL_LOG"
# Fails specifically on the flow-restore-wait "set" call - matched tightly
# enough to not also catch the unrelated "remove ... flow-restore-wait=true"
# clear-the-guard call at the end of a successful run, which shares the
# same "flow-restore-wait=true" substring.
write_fake ovs-vsctl '
echo "$*" >> "'"$VSCTL_LOG"'"
case "$*" in
    *"set open_vswitch . other_config:flow-restore-wait=true"*) exit 1 ;;
    *) exit 0 ;;
esac'

LOGGER_LOG="$WORKDIR/logger.log"
: > "$LOGGER_LOG"
write_fake logger 'echo "$*" >> "'"$LOGGER_LOG"'"; exit 0'

RUNDIR="$WORKDIR/run/openvswitch"
mkdir -p "$RUNDIR"
SAVED_FLOWS="$RUNDIR/vswitchd-saved-flows.sh"
echo "echo this must never run" > "$SAVED_FLOWS"

exec_start=$(printf '%s' "$exec_start" \
    | sed -e "s#/usr/bin/ovs-vsctl#$FAKEBIN/ovs-vsctl#g" \
          -e "s#/usr/share/openvswitch/scripts/ovs-ctl#$FAKEBIN/ovs-ctl#g")

exec_start_rc=0
env \
    OVS_CTL_OPTS="" \
    OVS_SAVED_FLOWS="$SAVED_FLOWS" \
    PATH="$FAKEBIN:/bin:/usr/bin" \
    sh -c "$exec_start" || exec_start_rc=$?

echo "--- ovs-vsctl calls ---"
cat "$VSCTL_LOG"
echo "--- logger calls ---"
cat "$LOGGER_LOG"
echo "-----------------------"

if [ "$exec_start_rc" -eq 0 ]; then
    echo "FAIL: ExecStart exited 0 despite failing to arm flow-restore-wait -" \
         "the new daemon can now start unprotected before flows are replayed." >&2
    exit 1
fi
echo "PASS: ExecStart aborted (exit $exec_start_rc) rather than continuing unprotected."

if [ -e "$CTL_CALLED" ]; then
    echo "FAIL: ovs-ctl start ran despite flow-restore-wait never being" \
         "successfully armed - the daemon can come up live before any" \
         "flow replay happens." >&2
    exit 1
fi
echo "PASS: the daemon was never started without flow-restore-wait armed."

if ! grep -q 'flow-restore-wait' "$LOGGER_LOG"; then
    echo "FAIL: no diagnostic logged for the arming failure" >&2
    exit 1
fi
echo "PASS: the arming failure was logged."

# --- Sanity check the inverse: when arming succeeds, start proceeds. ---
: > "$VSCTL_LOG"
write_fake ovs-vsctl 'echo "$*" >> "'"$VSCTL_LOG"'"; exit 0'
rm -f "$CTL_CALLED"
cat > "$SAVED_FLOWS" <<'EOF'
set -e
echo "restore step ran"
EOF

happy_rc=0
env \
    OVS_CTL_OPTS="" \
    OVS_SAVED_FLOWS="$SAVED_FLOWS" \
    PATH="$FAKEBIN:/bin:/usr/bin" \
    sh -c "$exec_start" || happy_rc=$?

if [ "$happy_rc" -ne 0 ]; then
    echo "FAIL: ExecStart exited $happy_rc even though arming and the" \
         "restore both succeeded" >&2
    exit 1
fi
if [ ! -e "$CTL_CALLED" ]; then
    echo "FAIL: ovs-ctl start never ran even though arming succeeded" >&2
    exit 1
fi
echo "PASS: start proceeds normally once flow-restore-wait is armed successfully."
