#!/bin/bash
# Regression test for a normal OVS reload restoring flows twice.
#
# debian/ovs-systemd-reload's "restart" branch (sourced from the real
# ovs-lib.in) wraps stop_forwarding/start_forwarding with its own
# save_flows_if_required/flow_restore_wait/restore_flows/flow_restore_complete
# cycle. In ovs-systemd-reload specifically, those hooks are "systemctl
# stop/start ovs-vswitchd" - and openvswitch-switch.ovs-vswitchd.service's
# own ExecStop/ExecStart already run a complete save-stop/start-restore cycle
# of their own. Before this fix, both layers restored the same snapshot:
# start_forwarding's systemctl call replayed the unit's own saved flows
# (including add-meter/add-groups for anything the bridge had), then
# ovs-lib.in's restart() replayed its *own* separately-saved snapshot on top
# - re-adding the same meter/group IDs a second time, which OVS rejects
# (METER_EXISTS/GROUP_EXISTS), failing the whole reload with exit 1 despite
# the actual flow state having been correctly restored one layer down.
#
# This runs the real ovs-systemd-reload (sourcing the real ovs-lib.in) with
# "systemctl stop/start ovs-vswitchd" routed to the real, literal ExecStop/
# ExecStart extracted from openvswitch-switch.ovs-vswitchd.service - the same
# two layers interacting for real, just with fakes underneath both. Asserts
# the reload exits 0 *and*, decisively, that every add-meter/add-groups/
# replace-flows command the generated restore script contains runs exactly
# once, not twice - the call count is the real signal here, confirmed
# against this fixture to catch the regression even where the exit code
# alone wouldn't (these fakes don't simulate OVS actually rejecting a
# duplicate add with METER_EXISTS, so pre-fix, the second add-meter here
# just succeeds again instead of failing - but it still ran twice, which is
# the bug, and which a real switch would reject).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVS_LIB_IN="$SCRIPT_DIR/utilities/ovs-lib.in"
OVS_SAVE_SRC="$SCRIPT_DIR/utilities/ovs-save"
OVS_SYSTEMD_RELOAD="$SCRIPT_DIR/debian/ovs-systemd-reload"
SERVICE_FILE="$SCRIPT_DIR/debian/openvswitch-switch.ovs-vswitchd.service"

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
echo "\$0 \$*" >> "$CALL_LOG"
$body
EOF
    chmod +x "$FAKEBIN/$name"
}

# --- fakes for the real generated restore script's own dump/apply calls ---

write_fake ovs-appctl '
case "$*" in
    version) echo "ovs-vswitchd (Open vSwitch) 3.3.6" ;;
    *) exit 0 ;;
esac'

write_fake ovs-vsctl '
case "$*" in
    "get bridge br0 protocols") echo "[OpenFlow13]" ;;
    *"-- --real list-br") echo "br0" ;;
    *) exit 0 ;;
esac'

write_fake ovs-ofctl '
case "$*" in
    --version) echo "ovs-ofctl (Open vSwitch) 3.3.6" ;;
    *dump-tlv-map*) exit 0 ;;
    *dump-meters*)
        # Real multiline shape - see ovs-save-meters-test.sh.
        printf "OFPST_METER_CONFIG reply (OF1.3) (xid=0x2):\n"
        printf "meter=1 kbps bands=\n"
        printf "type=drop rate=1000 burst_size=100\n"
        ;;
    *dump-groups*)
        echo "group_id=1,type=all,bucket=actions=output:1"
        ;;
    *dump-flows*)
        echo "cookie=0x0, table=0, priority=100 actions=meter:1,group:1"
        ;;
    *) exit 0 ;;  # add-meter/add-groups/replace-flows: just succeed and log
esac'

# ovs-save is the real script (not faked) - save_flows() has to actually run
# to generate a real restore script against the fakes above, the same way
# ovs-save-meters-test.sh exercises it. Needs its own ovs-lib stand-in next
# to it, same reason as that test. Two copies: $FAKEBIN/ovs-save is what the
# unit's own hardcoded absolute path gets redirected to below; ovs-lib.in's
# own ovs_save() wrapper (used by save_flows_if_required(), reached pre-fix
# when ovs-systemd-reload's hooks make daemon_is_running see both daemons as
# already up - true for a real routine reload, which is what this test needs
# to reproduce) looks under "$datadir/scripts/" instead, i.e. $OVS_PKGDATADIR
# set below.
cp "$OVS_SAVE_SRC" "$FAKEBIN/ovs-save"
printf '#!/bin/sh\n' > "$WORKDIR/ovs-save-lib"
cp "$WORKDIR/ovs-save-lib" "$FAKEBIN/ovs-lib"
chmod +x "$FAKEBIN/ovs-save"
mkdir -p "$WORKDIR/scripts"
cp "$OVS_SAVE_SRC" "$WORKDIR/scripts/ovs-save"
cp "$WORKDIR/ovs-save-lib" "$WORKDIR/scripts/ovs-lib"
chmod +x "$WORKDIR/scripts/ovs-save"

# ovs-ctl (the one the unit's Exec lines call) - vswitchd itself starting or
# stopping is not this test's concern, only what wraps around it.
write_fake ovs-ctl 'exit 0'
write_fake logger 'exit 0'

# --- the unit's own ExecStop/ExecStart, for real, wired into a fake systemctl ---

exec_start=$(sed -n '/^ExecStart=/,/[^\\]$/p' "$SERVICE_FILE" | sed '1s/^ExecStart=//')
exec_stop=$(sed -n '/^ExecStop=/,/[^\\]$/p' "$SERVICE_FILE" | sed '1s/^ExecStop=//')
if [ -z "$exec_start" ] || [ -z "$exec_stop" ]; then
    echo "FAIL: could not extract ExecStart=/ExecStop= from $SERVICE_FILE" >&2
    exit 1
fi
# Absolute paths the unit calls by design - redirect at the fakes above,
# same technique as ovs-vswitchd-service-restore-failure-test.sh. The
# hardcoded PIDFile path is how ExecStop decides whether vswitchd is
# currently running at all (and so whether there's anything to save) -
# redirected to a test-local file pre-populated with this test's own PID
# (alive, so "kill -0" on it succeeds) rather than writing to the real
# /run/openvswitch, which could collide with an actually-running vswitchd on
# whatever machine runs this test.
PIDFILE="$WORKDIR/run/openvswitch/ovs-vswitchd.pid"
mkdir -p "$(dirname "$PIDFILE")"
echo $$ > "$PIDFILE"
redirect_paths() {
    sed -e "s#/usr/bin/ovs-vsctl#$FAKEBIN/ovs-vsctl#g" \
        -e "s#/usr/share/openvswitch/scripts/ovs-ctl#$FAKEBIN/ovs-ctl#g" \
        -e "s#/usr/share/openvswitch/scripts/ovs-save#$FAKEBIN/ovs-save#g" \
        -e "s#/run/openvswitch/ovs-vswitchd.pid#$PIDFILE#g"
}
exec_start=$(printf '%s' "$exec_start" | redirect_paths)
exec_stop=$(printf '%s' "$exec_stop" | redirect_paths)

export OVS_SAVED_FLOWS="$WORKDIR/run/openvswitch/vswitchd-saved-flows.sh"
mkdir -p "$(dirname "$OVS_SAVED_FLOWS")"

write_fake systemctl "
case \"\$*\" in
    *'stop ovsdb-server'*) exit 0 ;;
    *'start ovsdb-server'*) exit 0 ;;
    *'stop ovs-vswitchd'*)
        OVS_CTL_OPTS='' PATH='$FAKEBIN:/bin:/usr/bin' OVS_SAVED_FLOWS='$OVS_SAVED_FLOWS' \
            sh -c '$(printf '%s' "$exec_stop" | sed "s/'/'\\\\''/g")'
        exit \$?
        ;;
    *'start ovs-vswitchd'*)
        OVS_CTL_OPTS='' PATH='$FAKEBIN:/bin:/usr/bin' OVS_SAVED_FLOWS='$OVS_SAVED_FLOWS' \
            sh -c '$(printf '%s' "$exec_start" | sed "s/'/'\\\\''/g")'
        exit \$?
        ;;
    *) exit 0 ;;
esac"

# --- run the real ovs-systemd-reload, sourcing the real ovs-lib.in ---

DEBIAN_TEST_DIR="$WORKDIR/debian-test"
mkdir -p "$DEBIAN_TEST_DIR"
cp "$OVS_SYSTEMD_RELOAD" "$DEBIAN_TEST_DIR/ovs-systemd-reload"
cp "$OVS_LIB_IN" "$DEBIAN_TEST_DIR/ovs-lib"

# ovs-lib.in's own restart() only takes its outer save/restore path at all if
# daemon_is_running says both daemons are already up when the reload starts -
# true for any real routine reload of a live system, which is exactly the
# case this test needs to reproduce. daemon_is_running checks a pidfile under
# $OVS_RUNDIR *and* that /proc/<pid>/comm matches the daemon name literally -
# satisfied here with real, currently-running background processes actually
# named ovsdb-server/ovs-vswitchd (comm is set by the kernel from the exec'd
# binary's path, not argv[0], so a mere renamed "sleep" won't do).
OVS_RUNDIR="$WORKDIR/rundir"
mkdir -p "$OVS_RUNDIR"
for daemon in ovsdb-server ovs-vswitchd; do
    cp "$(command -v sleep)" "$FAKEBIN/$daemon"
    "$FAKEBIN/$daemon" 300 &
    echo $! > "$OVS_RUNDIR/$daemon.pid"
done
trap 'kill %1 %2 2>/dev/null; rm -rf "$WORKDIR"' EXIT

reload_rc=0
(
    export OVS_LOGDIR="$WORKDIR" OVS_RUNDIR \
           OVS_SYSCONFDIR="$WORKDIR" OVS_PKGDATADIR="$WORKDIR" \
           OVS_BINDIR="$WORKDIR" OVS_DBDIR="$WORKDIR" OVS_VSWITCHD=yes
    PATH="$FAKEBIN:$PATH" bash "$DEBIAN_TEST_DIR/ovs-systemd-reload"
) || reload_rc=$?

echo "--- call log ---"
cat -n "$CALL_LOG"
echo "----------------"

if [ "$reload_rc" -ne 0 ]; then
    echo "FAIL: ovs-systemd-reload exited $reload_rc - a normal reload with" \
         "no injected faults should succeed; this is the double-restore" \
         "failing on its own already-applied meter/group." >&2
    exit 1
fi
echo "PASS: ovs-systemd-reload exited 0."

for cmd in add-meter add-groups replace-flows; do
    count=$(grep -c " $cmd " "$CALL_LOG" || true)
    if [ "$count" -eq 0 ]; then
        echo "FAIL: '$cmd' never ran at all - the fixture isn't exercising" \
             "the restore path this test is about." >&2
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "FAIL: '$cmd' ran $count times - should run exactly once. The" \
             "unit's own restore (inside start_forwarding's systemctl call)" \
             "and ovs-lib.in's outer restart() are both replaying it." >&2
        exit 1
    fi
    echo "PASS: '$cmd' ran exactly once."
done
