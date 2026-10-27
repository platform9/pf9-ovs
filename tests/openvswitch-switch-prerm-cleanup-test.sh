#!/bin/bash
# Regression test for debian/openvswitch-switch.prerm's "remove" case: the
# real datapath cleanup it claims to do on package removal.
#
# Before this fix: prerm ran a plain "ovs-ctl stop", which bottoms out in
# ovs-lib.in's stop_daemon() sending "ovs-appctl ... exit" with NO
# --cleanup flag. Per vswitchd.c's exit unixctl command and bridge.c's
# bridge_exit()/bridge_destroy(), the kernel datapath is only deleted when
# --cleanup is passed - without it, exit behaves exactly like the graceful,
# state-preserving exit ExecStop already does for an ordinary restart. So
# the comment's claim ("runs ofproto's normal exit-time cleanup and tears
# the datapath down") was false: package removal left stale bridges/ports/
# flows behind, the exact garbage the comment said this was preventing.
#
# This extracts the literal "remove|deconfigure)" case body out of the real
# prerm script and runs it with a fake ovs-appctl/ovs-ctl, asserting that
# "exit --cleanup" is sent directly to the running vswitchd's control
# socket before ovs-ctl stop ever runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRERM="$SCRIPT_DIR/debian/openvswitch-switch.prerm"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

FAKEBIN="$WORKDIR/bin"
mkdir -p "$FAKEBIN"
CALL_LOG="$WORKDIR/calls.log"
: > "$CALL_LOG"

write_fake() {
    local name="$1" body="$2"
    cat > "$FAKEBIN/$name" <<EOF
#!/bin/bash
echo "$name \$*" >> "$CALL_LOG"
$body
EOF
    chmod +x "$FAKEBIN/$name"
}

write_fake ovs-appctl 'exit 0'
write_fake ovs-ctl 'exit 0'
write_fake update-alternatives 'exit 0'

RUNDIR="$WORKDIR/run/openvswitch"
mkdir -p "$RUNDIR"
echo $$ > "$RUNDIR/ovs-vswitchd.pid"   # kill -0 on our own PID always succeeds.

# prerm hardcodes /run/openvswitch and /usr/share/openvswitch/scripts/ovs-ctl
# rather than taking them as parameters, so point those exact paths at the
# fakes instead of overriding via PATH alone.
sed -e "s#/run/openvswitch#$RUNDIR#g" \
    -e "s#/usr/share/openvswitch/scripts/ovs-ctl#$FAKEBIN/ovs-ctl#g" \
    -e "s#/usr/lib/openvswitch-switch/ovs-vswitchd-dpdk#$WORKDIR/nonexistent-dpdk#g" \
    "$PRERM" > "$WORKDIR/prerm"
chmod +x "$WORKDIR/prerm"

PATH="$FAKEBIN:/bin:/usr/bin" "$WORKDIR/prerm" remove

echo "--- calls ---"
cat "$CALL_LOG"
echo "-------------"

if ! grep -q -- '--cleanup' "$CALL_LOG"; then
    echo "FAIL: prerm never asked the running daemon to exit --cleanup -" \
         "the kernel datapath is left behind as garbage on removal." >&2
    exit 1
fi
echo "PASS: prerm asked ovs-vswitchd to exit --cleanup."

cleanup_line=$(grep -n -- '--cleanup' "$CALL_LOG" | head -1 | cut -d: -f1)
ctl_stop_line=$(grep -n '^ovs-ctl stop' "$CALL_LOG" | head -1 | cut -d: -f1)
if [ -z "$ctl_stop_line" ]; then
    echo "FAIL: ovs-ctl stop never ran (ovsdb-server would be left running)" >&2
    exit 1
fi
if [ "$cleanup_line" -ge "$ctl_stop_line" ]; then
    echo "FAIL: exit --cleanup ran at or after ovs-ctl stop - the real" \
         "cleanup must happen while the daemon is still addressable over" \
         "its own control socket, before anything else stops it." >&2
    exit 1
fi
echo "PASS: exit --cleanup ran before the general ovs-ctl stop."
