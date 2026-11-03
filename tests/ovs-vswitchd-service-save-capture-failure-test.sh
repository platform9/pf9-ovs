#!/bin/bash
# Regression test for openvswitch-switch.ovs-vswitchd.service's ExecStop:
# a failed/partial flow capture must not be published as a usable snapshot.
#
# Before this fix: ExecStop redirected ovs-save's output straight into the
# live $OVS_SAVED_FLOWS path ("ovs-save save-flows ... > $OVS_SAVED_FLOWS"),
# with no check on ovs-save's own exit status. ovs-save has no "set -e"/
# pipefail of its own, so a mid-capture failure (a dropped vconn, a
# dump-flows subprocess error partway through the bridge list) can leave a
# file that is truncated but syntactically valid up to the point it
# stopped. ExecStart's "[ -s "$OVS_SAVED_FLOWS" ]" only checks non-empty,
# not complete, and a script that is valid-but-partial runs to completion
# and exits 0 on the next start - silently restoring less than what was
# actually there, with no error anywhere to say so.
#
# This extracts the literal ExecStop= command out of the real .service file
# and runs it with a fake ovs-save that writes some real-looking output and
# then fails, the way a capture that died partway through would.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_FILE="$SCRIPT_DIR/debian/openvswitch-switch.ovs-vswitchd.service"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

extract_directive() {
    # $1: the "ExecFoo=" directive name. Pulls out its value, joining the
    # backslash-continued lines the same way systemd does before executing,
    # so this exercises the directive as actually written, not retyped here.
    sed -n "/^$1=/,/[^\\\\]\$/p" "$SERVICE_FILE" | sed "1s/^$1=//"
}

exec_stop=$(extract_directive "ExecStop")
if [ -z "$exec_stop" ]; then
    echo "FAIL: could not extract ExecStop= from $SERVICE_FILE" >&2
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

RUNDIR="$WORKDIR/run/openvswitch"
mkdir -p "$RUNDIR"
PIDFILE="$RUNDIR/ovs-vswitchd.pid"
echo $$ > "$PIDFILE"   # kill -0 on our own PID always succeeds - "running".
SAVED_FLOWS="$RUNDIR/vswitchd-saved-flows.sh"

write_fake ovs-vsctl 'if [ "$*" = "-- --real list-br" ]; then echo br0; else exit 0; fi'
LOGGER_LOG="$WORKDIR/logger.log"
: > "$LOGGER_LOG"
write_fake logger 'echo "$*" >> "'"$LOGGER_LOG"'"; exit 0'
write_fake ovs-ctl 'exit 0'

# Stands in for a capture that gets partway through a real bridge before
# dying - the kind of output that would pass "[ -s ... ]" and parse/run
# fine up to the point it stops, which is exactly what makes a partial
# capture dangerous: nothing about it looks wrong from outside.
write_fake ovs-save '
echo "set -e"
echo "ovs-ofctl -O OpenFlow13 add-tlv-map br0 '"'"''"'"'"
exit 1
'

exec_stop=$(printf '%s' "$exec_stop" \
    | sed -e "s#/usr/bin/ovs-vsctl#$FAKEBIN/ovs-vsctl#g" \
          -e "s#/usr/share/openvswitch/scripts/ovs-save#$FAKEBIN/ovs-save#g" \
          -e "s#/usr/share/openvswitch/scripts/ovs-ctl#$FAKEBIN/ovs-ctl#g" \
          -e "s#/run/openvswitch/ovs-vswitchd.pid#$PIDFILE#g")

exec_stop_rc=0
env \
    OVS_CTL_OPTS="" \
    OVS_SAVED_FLOWS="$SAVED_FLOWS" \
    PATH="$FAKEBIN:/bin:/usr/bin" \
    sh -c "$exec_stop" || exec_stop_rc=$?

echo "--- logger calls ---"
cat "$LOGGER_LOG"
echo "---------------------"

if [ -e "$SAVED_FLOWS" ]; then
    echo "FAIL: a failed/partial ovs-save capture was published to" \
         "$SAVED_FLOWS - the next start will treat it as a complete," \
         "usable snapshot and may silently restore less than was there." >&2
    cat "$SAVED_FLOWS" >&2
    exit 1
fi
echo "PASS: a failed capture was not published to the live saved-flows path."

if [ -e "$SAVED_FLOWS.tmp" ]; then
    echo "FAIL: the .tmp capture file was left behind instead of being" \
         "cleaned up on failure." >&2
    exit 1
fi
echo "PASS: the temporary capture file was cleaned up."

if ! grep -q 'ovs-save failed' "$LOGGER_LOG"; then
    echo "FAIL: no diagnostic logged for the capture failure" >&2
    exit 1
fi
echo "PASS: the capture failure was logged."

# --- Sanity check the inverse: a capture that succeeds IS published. ---
write_fake ovs-save 'echo "set -e"; echo "echo restored"; exit 0'
env \
    OVS_CTL_OPTS="" \
    OVS_SAVED_FLOWS="$SAVED_FLOWS" \
    PATH="$FAKEBIN:/bin:/usr/bin" \
    sh -c "$exec_stop"

if [ ! -s "$SAVED_FLOWS" ]; then
    echo "FAIL: a successful capture was not published to $SAVED_FLOWS" >&2
    exit 1
fi
echo "PASS: a successful capture is published to the live saved-flows path."
