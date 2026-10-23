#!/bin/bash
# Regression test for ovs-lib.in's restart() correctly propagating a real
# restore_flows failure, instead of silently swallowing it, in the two
# different contexts it actually runs in.
#
# Before the fix: restart()/force_reload_kmod() called restore_flows with
# no rc capture, so their own return value ended up being whatever ran
# after it (add_managers) - unrelated to whether flows actually restored. A
# failed flow/meter/group restore (e.g. OFPERR_OFPMMFC_INVALID_METER) was
# therefore invisible to whatever called restart().
#
# Also covers a second bug on the same code path: even once the exit status
# above correctly propagated, flow_restore_complete() (the "we are done,
# clear other_config:flow-restore-wait" signal to ofproto) was called
# unconditionally, before ever looking at restore_rc. A caller checking the
# exit code - which is all the first bug's fix covers - still saw a failed
# reload, but ofproto itself had already been told to proceed normally over
# whatever partial table the failed restore left behind.
#
# Part 1 sources the real ovs-lib.in directly with no-op stand-ins for the
# caller-provided hooks (stop_ovsdb etc. - normally supplied by ovs-ctl.in,
# not ovs-lib.in itself), forces restore_flows to fail via a scripted
# $script_flows, and asserts both the exit code and flow-restore-wait.
#
# Part 2 runs the real debian/ovs-systemd-reload wrapper - the actual reload
# path Neutron's config script invokes via systemctl reload-or-restart - but
# that script's hooks are systemctl calls, not ovs-ctl's stop_daemon/
# start_daemon, and (see ovs-reload-double-restore-test.sh) ovs-systemd-
# reload now stubs out restore_flows/flow_restore_complete/etc entirely, so
# $script_flows injection has no effect there by design. What Part 2 tests
# instead is the thing that still has to work in that context: a failure
# from the start_forwarding hook (systemctl start ovs-vswitchd - standing in
# for the real unit's ExecStart failing) still propagates out through
# restart()'s own "start_forwarding || return 1" and ovs-systemd-reload's
# exit code.
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
VSCTL_LOG="$WORKDIR/vsctl.log"
: > "$VSCTL_LOG"
cat > "$FAKEBIN/ovs-vsctl" <<EOF
#!/bin/sh
echo "\$*" >> "$VSCTL_LOG"
exit 0
EOF
chmod +x "$FAKEBIN/ovs-vsctl"

# flow_restore_complete()'s exact call, so a test can assert it was or
# wasn't made without caring about every other ovs-vsctl invocation along
# the way (set_system_ids, add_managers, etc).
flow_restore_wait_cleared() {
    grep -q -- '--if-exists remove open_vswitch . other_config flow-restore-wait=true' "$1"
}

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

if flow_restore_wait_cleared "$VSCTL_LOG"; then
    echo "FAIL: flow_restore_complete ran despite restore_flows failing -" \
         "ofproto was told to proceed normally over a broken table." >&2
    exit 1
fi
echo "PASS: restart() left flow-restore-wait set after the failed restore."

# Confirm the fix didn't just stop calling flow_restore_complete altogether -
# it has to still run, and clear the guard, on an actual successful restore.
: > "$VSCTL_LOG"
PASSING_SCRIPT="$WORKDIR/pass.sh"
printf '#!/bin/sh\nexit 0\n' > "$PASSING_SCRIPT"
chmod +x "$PASSING_SCRIPT"
script_flows="$PASSING_SCRIPT"

PATH="$FAKEBIN:$PATH" restart
restart_ok_rc=$?

if [ "$restart_ok_rc" -ne 0 ]; then
    echo "FAIL: restart() returned $restart_ok_rc for a restore_flows that" \
         "succeeded" >&2
    exit 1
fi
if ! flow_restore_wait_cleared "$VSCTL_LOG"; then
    echo "FAIL: flow_restore_complete did not run after a successful" \
         "restore - the fix over-corrected and now never clears the guard." >&2
    exit 1
fi
echo "PASS: restart() clears flow-restore-wait after a successful restore."

# --- Part 2: the debian/ovs-systemd-reload wrapper on top of it ---
# Runs the real wrapper script (not sourced) so its own exit code - the one
# systemd and Neutron's check=True actually see - is exercised end to end.
#
# ovs-systemd-reload's stop_ovsdb/start_ovsdb/stop_forwarding/start_forwarding
# are systemctl calls, not ovs-lib.in's own stop_daemon/start_daemon - and as
# of a later fix, ovs-systemd-reload also stubs out save_flows_if_required/
# flow_restore_wait/restore_flows/flow_restore_complete entirely (see
# ovs-reload-double-restore-test.sh for why: with those hooks pointed at
# systemctl, openvswitch-switch.ovs-vswitchd.service's own ExecStop/ExecStart
# already run a complete save/restore cycle, and layering ovs-lib.in's cycle
# on top double-restored every meter/group). That means the $script_flows
# injection Part 1 uses above has no effect here by design - ovs-systemd-
# reload's own restore_flows is a hardcoded `return 0` regardless of
# $script_flows's content. What still has to work, and what this part
# actually tests, is that a failure from systemctl itself (standing in for
# the real unit's ExecStart failing - covered directly, against the real
# unit text, by ovs-vswitchd-service-restore-failure-test.sh) still
# propagates through restart()'s "start_forwarding || return 1" and out
# through ovs-systemd-reload's own exit code.

# ovs-systemd-reload does `. "$dir0/ovs-lib" || exit 1` (the *compiled*
# name, post-configure) - copy both it and ovs-lib.in (itself usable as-is
# once the OVS_* env vars below are set, same as Part 1) into one directory
# under that expected name, rather than needing a fully `configure`d tree.
DEBIAN_TEST_DIR="$WORKDIR/debian-test"
mkdir -p "$DEBIAN_TEST_DIR"
cp "$OVS_SYSTEMD_RELOAD" "$DEBIAN_TEST_DIR/ovs-systemd-reload"
cp "$OVS_LIB_IN" "$DEBIAN_TEST_DIR/ovs-lib"

run_reload() {
    local systemctl_rc="$1" rc=0
    cat > "$FAKEBIN/systemctl" <<EOF
#!/bin/sh
case "\$*" in
    *"start ovs-vswitchd"*) exit $systemctl_rc ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$FAKEBIN/systemctl"
    (
        export OVS_LOGDIR="$WORKDIR" OVS_RUNDIR="$WORKDIR/empty-rundir" \
               OVS_SYSCONFDIR="$WORKDIR" OVS_PKGDATADIR="$WORKDIR" \
               OVS_BINDIR="$WORKDIR" OVS_DBDIR="$WORKDIR" OVS_VSWITCHD=yes
        PATH="$FAKEBIN:$PATH" bash "$DEBIAN_TEST_DIR/ovs-systemd-reload"
    ) || rc=$?
    return $rc
}

reload_fail_rc=0
run_reload 9 || reload_fail_rc=$?
if [ "$reload_fail_rc" -eq 0 ]; then
    echo "FAIL: ovs-systemd-reload exited 0 even though its start_forwarding" \
         "hook (systemctl start ovs-vswitchd) failed - standing in for the" \
         "real unit's ExecStart failing, which would mean a broken restore" \
         "is invisible to systemd and to Neutron's check=True subprocess" \
         "call." >&2
    exit 1
fi
echo "PASS: ovs-systemd-reload propagated start_forwarding's failure (exit $reload_fail_rc)."

reload_ok_rc=0
run_reload 0 || reload_ok_rc=$?
if [ "$reload_ok_rc" -ne 0 ]; then
    echo "FAIL: ovs-systemd-reload exited $reload_ok_rc when start_forwarding" \
         "succeeded" >&2
    exit 1
fi
echo "PASS: ovs-systemd-reload exits 0 when start_forwarding succeeds."
