#!/bin/bash
# Regression test for debian/ovs-systemd-reload's force-reload-kmod branch.
#
# ovs-reload-double-restore-test.sh covers the plain "restart" branch - the
# one `systemctl reload-or-restart` takes, and the one Neutron's config
# script actually triggers. This covers the other branch, which nothing else
# tests: force_reload_kmod() in ovs-lib.in, reached by running
# `ovs-systemd-reload force-reload-kmod` by hand to swap the openvswitch
# kernel module without a full reinstall.
#
# It matters here because that function is wrapped by the same stubs: the
# zero-loss fix neutralises save_flows_if_required/flow_restore_wait/
# restore_flows/flow_restore_complete in this script so the per-unit
# ExecStop/ExecStart own flow preservation and nothing double-restores. But
# force_reload_kmod() ALSO uses init_restore_scripts() for $script_interfaces
# - real interface/iptables state, a completely separate concern from flows
# and one nothing at the unit level handles. So init_restore_scripts is
# deliberately NOT stubbed, and this test pins that distinction down:
#
#   * flows get restored exactly once (by the unit's ExecStart), not twice
#   * interface configuration IS still saved and restored around the kmod swap
#   * the datapath teardown and module removal happen while vswitchd is down,
#     i.e. after its ExecStop and before its ExecStart
#
# Same wiring as the double-restore test: real reload wrapper, real
# ovs-lib.in, real ovs-save, and the literal ExecStop/ExecStart extracted
# from the real unit file, with fakes underneath.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVS_LIB_IN="$SCRIPT_DIR/utilities/ovs-lib.in"
OVS_SAVE_SRC="$SCRIPT_DIR/utilities/ovs-save"
OVS_SYSTEMD_RELOAD="$SCRIPT_DIR/debian/ovs-systemd-reload"
SERVICE_FILE="$SCRIPT_DIR/debian/openvswitch-switch.ovs-vswitchd.service"

WORKDIR=$(mktemp -d)
FAKEBIN="$WORKDIR/bin"
mkdir -p "$FAKEBIN"
CALL_LOG="$WORKDIR/calls.log"
: > "$CALL_LOG"

write_fake() {
    local name="$1" body="$2"
    cat > "$FAKEBIN/$name" <<EOF
#!/bin/bash
echo "\$(basename \$0) \$*" >> "$CALL_LOG"
$body
EOF
    chmod +x "$FAKEBIN/$name"
}

write_fake ovs-appctl '
case "$*" in
    version) echo "ovs-vswitchd (Open vSwitch) 3.3.6" ;;
    *) exit 0 ;;
esac'

write_fake ovs-vsctl '
case "$*" in
    "get bridge br0 protocols") echo "[OpenFlow13]" ;;
    *"--real list-br") echo "br0" ;;
    *"--columns=name find Interface type=internal"*)
        # internal_interfaces() filters this list by /sys/class/net/<dev>
        # existing, so it has to name a device that really is there or the
        # list comes back empty and save_interfaces exits before doing any
        # work. "lo" is present on every host and safe to "save".
        echo "lo" ;;
    *) exit 0 ;;
esac'

write_fake ovs-ofctl '
case "$*" in
    --version) echo "ovs-ofctl (Open vSwitch) 3.3.6" ;;
    *dump-tlv-map*) exit 0 ;;
    *dump-meters*)
        printf "OFPST_METER_CONFIG reply (OF1.3) (xid=0x2):\n"
        printf "meter=1 kbps bands=\n"
        printf "type=drop rate=1000 burst_size=100\n"
        ;;
    *dump-groups*) echo "group_id=1,type=all,bucket=actions=output:1" ;;
    *dump-flows*) echo "cookie=0x0, table=0, priority=100 actions=meter:1,group:1" ;;
    *) exit 0 ;;
esac'

# The kmod-specific tools force_reload_kmod() reaches for. ovs-dpctl must
# report a datapath so the teardown loop actually runs.
write_fake ovs-dpctl '
case "$*" in
    dump-dps) echo "system@ovs-system" ;;
    *) exit 0 ;;
esac'
write_fake ovs-kmod-ctl 'exit 0'
write_fake rmmod 'exit 0'
write_fake ovs-check-dead-ifs 'exit 0'
write_fake ovs-ctl 'exit 0'
write_fake logger 'exit 0'
# save_interfaces shells out to these; it only needs them to not fail.
write_fake ip '
case "$*" in
    "link show dev lo")
        echo "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000"
        echo "    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00"
        ;;
    *) exit 0 ;;
esac'
write_fake iptables-save 'exit 0'
write_fake iptables-restore 'exit 0'

# Real ovs-save, in both places it gets looked up from: the unit's hardcoded
# absolute path (redirected below) and ovs-lib.in's own "$datadir/scripts".
cp "$OVS_SAVE_SRC" "$FAKEBIN/ovs-save"
printf '#!/bin/sh\n' > "$FAKEBIN/ovs-lib"
chmod +x "$FAKEBIN/ovs-save"
mkdir -p "$WORKDIR/scripts"
cp "$OVS_SAVE_SRC" "$WORKDIR/scripts/ovs-save"
printf '#!/bin/sh\n' > "$WORKDIR/scripts/ovs-lib"
chmod +x "$WORKDIR/scripts/ovs-save"
# ovs_kmod_ctl() calls "$dir0/ovs-kmod-ctl", i.e. next to the sourced lib.
cp "$FAKEBIN/ovs-kmod-ctl" "$WORKDIR/scripts/ovs-kmod-ctl"

exec_start=$(sed -n '/^ExecStart=/,/[^\\]$/p' "$SERVICE_FILE" | sed '1s/^ExecStart=//')
exec_stop=$(sed -n '/^ExecStop=/,/[^\\]$/p' "$SERVICE_FILE" | sed '1s/^ExecStop=//')
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

write_fake systemctl "
case \"\$*\" in
    *'stop ovsdb-server'*|*'start ovsdb-server'*) exit 0 ;;
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

DEBIAN_TEST_DIR="$WORKDIR/debian-test"
mkdir -p "$DEBIAN_TEST_DIR"
cp "$OVS_SYSTEMD_RELOAD" "$DEBIAN_TEST_DIR/ovs-systemd-reload"
cp "$OVS_LIB_IN" "$DEBIAN_TEST_DIR/ovs-lib"
cp "$FAKEBIN/ovs-kmod-ctl" "$DEBIAN_TEST_DIR/ovs-kmod-ctl"

# Both daemons must look live or force_reload_kmod() skips its save path -
# real processes actually named ovsdb-server/ovs-vswitchd, since
# daemon_is_running checks /proc/<pid>/comm, not just the pidfile.
OVS_RUNDIR="$WORKDIR/rundir"
mkdir -p "$OVS_RUNDIR"
for daemon in ovsdb-server ovs-vswitchd; do
    cp "$(command -v sleep)" "$FAKEBIN/$daemon"
    "$FAKEBIN/$daemon" 300 &
    echo $! > "$OVS_RUNDIR/$daemon.pid"
done
trap 'kill %1 %2 2>/dev/null; rm -rf "$WORKDIR"' EXIT

rc=0
(
    export OVS_LOGDIR="$WORKDIR" OVS_RUNDIR \
           OVS_SYSCONFDIR="$WORKDIR" OVS_PKGDATADIR="$WORKDIR" \
           OVS_BINDIR="$WORKDIR" OVS_DBDIR="$WORKDIR" OVS_VSWITCHD=yes
    PATH="$FAKEBIN:$PATH" bash "$DEBIAN_TEST_DIR/ovs-systemd-reload" force-reload-kmod
) || rc=$?

echo "--- call log ---"
cat -n "$CALL_LOG"
echo "----------------"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ "$rc" -eq 0 ] || fail "ovs-systemd-reload force-reload-kmod exited $rc"
echo "PASS: force-reload-kmod exited 0."

for cmd in add-meter add-groups replace-flows; do
    n=$(grep -c " $cmd " "$CALL_LOG" || true)
    [ "$n" -gt 0 ] || fail "'$cmd' never ran - the fixture isn't exercising the restore"
    [ "$n" -eq 1 ] || fail "'$cmd' ran $n times - the unit's ExecStart restore and
    ovs-lib.in's own restore are both replaying it (the double-restore bug,
    on the force-reload-kmod path this time)"
    echo "PASS: '$cmd' ran exactly once."
done

# The kmod swap itself, and that it happened with vswitchd down: the datapath
# removal must land after the stop and before the start.
grep -q "ovs-dpctl del-dp" "$CALL_LOG" || fail "the datapath was never torn down"
grep -q "ovs-kmod-ctl remove" "$CALL_LOG" || fail "the kernel module was never removed"
stop_line=$(grep -n "ovs-ctl .*--no-ovsdb-server.* stop" "$CALL_LOG" | head -1 | cut -d: -f1)
deldp_line=$(grep -n "ovs-dpctl del-dp" "$CALL_LOG" | head -1 | cut -d: -f1)
start_line=$(grep -n "ovs-ctl .*--no-ovsdb-server.* start" "$CALL_LOG" | head -1 | cut -d: -f1)
if [ -z "$stop_line" ] || [ -z "$start_line" ]; then
    fail "could not locate vswitchd stop/start in the call log"
fi
if [ "$deldp_line" -lt "$stop_line" ] || [ "$deldp_line" -gt "$start_line" ]; then
    fail "datapath teardown (line $deldp_line) did not happen between vswitchd
    stop (line $stop_line) and start (line $start_line) - the module would be
    swapped under a running forwarding plane"
fi
echo "PASS: datapath teardown + module removal happened with vswitchd stopped."

# init_restore_scripts must NOT be stubbed out: force_reload_kmod needs
# $script_interfaces for interface/iptables state, which nothing at the unit
# level restores.
grep -q "iptables-save" "$CALL_LOG" || fail "interface/iptables state was never
    saved - init_restore_scripts or save_interfaces got neutralised along with
    the flow functions, losing a concern the units do not cover"
echo "PASS: interface/iptables configuration was saved around the kmod swap."
