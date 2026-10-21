#!/bin/bash
# Regression test for ovs-lib.in's restart()/force_reload_kmod() and
# debian/ovs-systemd-reload correctly propagating a real restore_flows
# failure, instead of silently swallowing it.
#
# Before the fix: restart()/force_reload_kmod() called restore_flows with
# no rc capture, so their own return value ended up being whatever ran
# after it (add_managers) - unrelated to whether flows actually restored.
# ovs-systemd-reload then unconditionally `exit 0`'d on top of that. A
# failed flow/meter/group restore (e.g. OFPERR_OFPMMFC_INVALID_METER) was
# therefore invisible to systemd and to Neutron's check=True subprocess
# call. This sources the real ovs-lib.in with no-op stand-ins for the
# caller-provided hooks (stop_ovsdb etc. - normally supplied by ovs-ctl.in/
# ovs-systemd-reload, not ovs-lib.in itself), forces restore_flows to fail
# via a scripted $script_flows, and asserts the failure actually surfaces.
set -o pipefail
# Deliberately not -u/-e: ovs-lib.in is a vendored script with its own
# unguarded $OVS_* references and functions that return non-zero in cases
# this test doesn't care about - this harness checks the specific exit
# codes it's after explicitly, rather than relying on early-exit semantics.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVS_LIB_IN="$SCRIPT_DIR/utilities/ovs-lib.in"
OVS_SYSTEMD_RELOAD="$SCRIPT_DIR/debian/ovs-systemd-reload"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

FAKEBIN="$WORKDIR/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ovs-vsctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKEBIN/ovs-vsctl"

FAILING_SCRIPT="$WORKDIR/fail.sh"
printf '#!/bin/sh\nexit 7\n' > "$FAILING_SCRIPT"
chmod +x "$FAILING_SCRIPT"

# --- Part 1: ovs-lib.in's restart() itself ---

export OVS_LOGDIR="$WORKDIR" OVS_RUNDIR="$WORKDIR/empty-rundir" \
       OVS_SYSCONFDIR="$WORKDIR" OVS_PKGDATADIR="$WORKDIR" \
       OVS_BINDIR="$WORKDIR" OVS_VSWITCHD=yes
mkdir -p "$OVS_RUNDIR"  # empty: daemon_is_running finds no pidfiles, so
                        # restart() skips straight past the save-current-
                        # flows branch to the unconditional restore below.

# Caller-provided hooks ovs-lib.in expects (normally defined by ovs-ctl.in /
# ovs-systemd-reload, not ovs-lib.in itself) - no-ops so restart() reaches
# restore_flows without needing a real OVS install.
stop_ovsdb() { :; }
start_ovsdb() { :; }
stop_forwarding() { :; }
start_forwarding() { :; }
add_managers() { :; }

. "$OVS_LIB_IN"

script_flows="$FAILING_SCRIPT"

PATH="$FAKEBIN:$PATH" restart
restart_rc=$?

if [ "$restart_rc" -eq 0 ]; then
    echo "FAIL: ovs-lib.in's restart() returned 0 even though restore_flows" \
         "(via \$script_flows) exited 7 - the failure is being swallowed." >&2
    exit 1
fi
echo "PASS: restart() propagated restore_flows' failure (rc=$restart_rc)."

# --- Part 2: the debian/ovs-systemd-reload wrapper on top of it ---
# Runs the real wrapper script (not sourced) with the same fakes, so its own
# exit code - the one systemd and Neutron's check=True actually see - is
# exercised end to end, not just the ovs-lib.in function underneath it.

cat > "$FAKEBIN/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKEBIN/systemctl"

# ovs-systemd-reload does `. "$dir0/ovs-lib" || exit 1` (the *compiled*
# name, post-configure) - copy both it and ovs-lib.in (itself usable as-is
# once the OVS_* env vars below are set, same as Part 1) into one directory
# under that expected name, rather than needing a fully `configure`d tree.
DEBIAN_TEST_DIR="$WORKDIR/debian-test"
mkdir -p "$DEBIAN_TEST_DIR"
cp "$OVS_SYSTEMD_RELOAD" "$DEBIAN_TEST_DIR/ovs-systemd-reload"
cp "$OVS_LIB_IN" "$DEBIAN_TEST_DIR/ovs-lib"

(
    export OVS_LOGDIR="$WORKDIR" OVS_RUNDIR="$WORKDIR/empty-rundir" \
           OVS_SYSCONFDIR="$WORKDIR" OVS_PKGDATADIR="$WORKDIR" \
           OVS_BINDIR="$WORKDIR" OVS_DBDIR="$WORKDIR" OVS_VSWITCHD=yes
    # ovs-systemd-reload defines its own stop_ovsdb/start_ovsdb/etc. as
    # systemctl wrappers - only script_flows needs forcing here.
    export script_flows="$FAILING_SCRIPT"
    PATH="$FAKEBIN:$PATH" bash "$DEBIAN_TEST_DIR/ovs-systemd-reload"
)
reload_rc=$?

if [ "$reload_rc" -eq 0 ]; then
    echo "FAIL: ovs-systemd-reload exited 0 even though restore_flows" \
         "failed - this is what previously made check=True in Neutron's" \
         "wrapper a no-op." >&2
    exit 1
fi
echo "PASS: ovs-systemd-reload propagated the failure (exit $reload_rc)."
