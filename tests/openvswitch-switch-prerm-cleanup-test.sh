#!/bin/bash
# Regression test for debian/openvswitch-switch.prerm's "remove" and
# "deconfigure" cases: real datapath cleanup only on an actual removal, not
# on a transient deconfigure.
#
# Before the first fix here: prerm ran a plain "ovs-ctl stop" for both
# "remove" and "deconfigure", which bottoms out in ovs-lib.in's
# stop_daemon() sending "ovs-appctl ... exit" with NO --cleanup flag. Per
# vswitchd.c's exit unixctl command and bridge.c's bridge_exit()/
# bridge_destroy(), the kernel datapath is only deleted when --cleanup is
# passed - without it, exit behaves exactly like the graceful,
# state-preserving exit ExecStop already does for an ordinary restart. So
# the comment's claim ("runs ofproto's normal exit-time cleanup and tears
# the datapath down") was false: package removal left stale bridges/ports/
# flows behind, the exact garbage the comment said this was preventing.
#
# Fixing that by requesting "exit --cleanup" directly then introduced a
# second issue: it ran for "deconfigure" too, lumped together with
# "remove" in a single case arm. Per Debian policy, "deconfigure" is
# transient - dpkg uses it to temporarily deconfigure a package (without
# removing it) to break a conflict/dependency cycle while resolving some
# other package's install, expecting to reconfigure it again shortly
# after. Tearing down the datapath there causes exactly the packet loss
# this whole mechanism exists to avoid, for an operation that was never
# an uninstall. "remove" and "deconfigure" are now separate case arms:
# only "remove" requests real cleanup; both still deregister the
# update-alternatives entry, the standard debhelper idiom for either.
#
# This extracts the real prerm script and runs it with fakes for both
# arguments, asserting each does the right thing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRERM="$SCRIPT_DIR/debian/openvswitch-switch.prerm"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

FAKEBIN="$WORKDIR/bin"
mkdir -p "$FAKEBIN"

write_fake() {
    local name="$1" body="$2" log="$3"
    cat > "$FAKEBIN/$name" <<EOF
#!/bin/bash
echo "$name \$*" >> "$log"
$body
EOF
    chmod +x "$FAKEBIN/$name"
}

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

run_prerm() {
    # $1: the prerm argument ("remove" or "deconfigure"). Returns the path
    # to that run's call log.
    local arg="$1" log="$WORKDIR/calls-$1.log"
    : > "$log"
    write_fake ovs-appctl 'exit 0' "$log"
    write_fake ovs-ctl 'exit 0' "$log"
    write_fake update-alternatives 'exit 0' "$log"
    PATH="$FAKEBIN:/bin:/usr/bin" "$WORKDIR/prerm" "$arg"
    echo "$log"
}

# --- "remove": the real teardown must happen. ---
remove_log=$(run_prerm remove)
echo "--- remove calls ---"
cat "$remove_log"
echo "---------------------"

if ! grep -q -- '--cleanup' "$remove_log"; then
    echo "FAIL: 'remove' never asked the running daemon to exit --cleanup -" \
         "the kernel datapath is left behind as garbage on removal." >&2
    exit 1
fi
echo "PASS: 'remove' asked ovs-vswitchd to exit --cleanup."

cleanup_line=$(grep -n -- '--cleanup' "$remove_log" | head -1 | cut -d: -f1)
ctl_stop_line=$(grep -n '^ovs-ctl stop' "$remove_log" | head -1 | cut -d: -f1)
if [ -z "$ctl_stop_line" ]; then
    echo "FAIL: 'remove' never ran ovs-ctl stop (ovsdb-server would be left" \
         "running)" >&2
    exit 1
fi
if [ "$cleanup_line" -ge "$ctl_stop_line" ]; then
    echo "FAIL: exit --cleanup ran at or after ovs-ctl stop - the real" \
         "cleanup must happen while the daemon is still addressable over" \
         "its own control socket, before anything else stops it." >&2
    exit 1
fi
echo "PASS: 'remove' ran exit --cleanup before the general ovs-ctl stop."

if [ "$(grep -c '^update-alternatives' "$remove_log")" -lt 1 ]; then
    echo "FAIL: 'remove' never deregistered the ovs-vswitchd alternative" >&2
    exit 1
fi
echo "PASS: 'remove' deregisters the update-alternatives entry."

# --- "deconfigure": transient - must NOT tear the datapath down. ---
deconfigure_log=$(run_prerm deconfigure)
echo "--- deconfigure calls ---"
cat "$deconfigure_log"
echo "--------------------------"

if grep -q -- '--cleanup' "$deconfigure_log"; then
    echo "FAIL: 'deconfigure' requested exit --cleanup - this is a" \
         "transient state dpkg uses to resolve a conflict, not an" \
         "uninstall, and will cause real, unnecessary packet loss when" \
         "the package is reconfigured right back afterward." >&2
    exit 1
fi
echo "PASS: 'deconfigure' does not request exit --cleanup."

if grep -q '^ovs-ctl stop' "$deconfigure_log"; then
    echo "FAIL: 'deconfigure' called ovs-ctl stop - it should leave the" \
         "running daemons alone entirely." >&2
    exit 1
fi
echo "PASS: 'deconfigure' does not stop the running daemons."

if [ "$(grep -c '^update-alternatives' "$deconfigure_log")" -lt 1 ]; then
    echo "FAIL: 'deconfigure' never deregistered the ovs-vswitchd" \
         "alternative - the standard debhelper idiom for this case too." >&2
    exit 1
fi
echo "PASS: 'deconfigure' still deregisters the update-alternatives entry."
