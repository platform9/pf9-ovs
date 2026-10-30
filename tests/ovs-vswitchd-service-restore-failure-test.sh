#!/bin/bash
# Regression test for openvswitch-switch.ovs-vswitchd.service's ExecStart:
# a failed flow restore must not be treated as a successful start.
#
# Before this fix: ExecStart ran "$OVS_SAVED_FLOWS" (now "sh
# "$OVS_SAVED_FLOWS""), unconditionally deleted it, and unconditionally
# cleared flow-restore-wait right after - regardless of whether the restore
# actually succeeded. A failed restore (the saved script now starts with
# "set -e", so a real failure inside it is no longer masked by "rm -rf
# $workdir" succeeding as the script's last command either) was therefore
# indistinguishable from the outside: vswitchd ended up looking fully
# started, flow-restore-wait cleared, with whatever partial table the
# script got through before dying - and the one artifact that could explain
# why was already deleted.
#
# A second bug followed from the first fix's own remedy: it *moved* the
# failed script to .failed for diagnosis, which meant the *next* ExecStart -
# whether from Restart=on-failure or a manual retry - found nothing at
# $OVS_SAVED_FLOWS, skipped the restore block entirely as if there were
# simply nothing to restore, and fell straight through to clearing
# flow-restore-wait and exiting 0. Reproduced directly: a second invocation
# right after the first failure exited successfully without restoring
# anything. Fixed by *copying* the failure for diagnosis instead of moving
# it, so the next attempt genuinely retries the same restore.
#
# This extracts the literal ExecStart= command out of the real .service
# file (so a future edit to the unit is exercised as written, not
# retyped here) and runs it with fakes, forcing the saved-flows script to
# fail partway through.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_FILE="$SCRIPT_DIR/debian/openvswitch-switch.ovs-vswitchd.service"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Pull the ExecStart= value out of the unit file: everything from the
# "ExecStart=" line through the last line of its backslash continuation.
# systemd joins continued lines the same way before executing, so this
# exercises the directive as actually written, not retyped here.
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

# ovs-ctl's "start" succeeds (vswitchd itself starts fine - only the flow
# *replay* after that is made to fail below).
write_fake ovs-ctl 'exit 0'
VSCTL_LOG="$WORKDIR/vsctl.log"
: > "$VSCTL_LOG"
write_fake ovs-vsctl 'echo "$*" >> "'"$VSCTL_LOG"'"; exit 0'
LOGGER_LOG="$WORKDIR/logger.log"
: > "$LOGGER_LOG"
write_fake logger 'echo "$*" >> "'"$LOGGER_LOG"'"; exit 0'

flow_restore_wait_cleared() {
    grep -q -- '--if-exists remove open_vswitch \. other_config flow-restore-wait=true' "$1"
}

RUNDIR="$WORKDIR/run/openvswitch"
mkdir -p "$RUNDIR"
SAVED_FLOWS="$RUNDIR/vswitchd-saved-flows.sh"
# A saved-flows script that fails partway through, as a real one would if
# e.g. replace-flows was rejected - set -e (from the ovs-save fix) means
# this exits non-zero instead of limping on to a trailing success.
cat > "$SAVED_FLOWS" <<'EOF'
set -e
echo "this command succeeds"
false
echo "this must never run"
EOF
chmod 644 "$SAVED_FLOWS"   # deliberately not executable: it's read via
                            # "sh", never exec'd directly (see the fix for
                            # /run being noexec) - exec bit is irrelevant.

# The unit calls these by absolute path (deliberately - a PATH-dependent
# ExecStart would be a bug in its own right), so a PATH-only fake doesn't
# intercept them; redirect those two specific absolute paths at the fakes
# above instead of trying to fake out /usr itself.
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
    echo "FAIL: ExecStart exited 0 despite the flow-restore script failing -" \
         "a failed restore is being reported as a successful start." >&2
    exit 1
fi
echo "PASS: ExecStart propagated the restore failure (exit $exec_start_rc)."

if flow_restore_wait_cleared "$VSCTL_LOG"; then
    echo "FAIL: flow-restore-wait was cleared despite the restore failing -" \
         "ofproto is left believing it's fully converged on a broken table." >&2
    exit 1
fi
echo "PASS: flow-restore-wait was left set after the failed restore."

if [ ! -e "$SAVED_FLOWS" ]; then
    echo "FAIL: the saved-flows script was removed from its live path after" \
         "a failed restore - the next start has nothing left to retry and" \
         "will silently skip straight to 'success'." >&2
    exit 1
fi
if [ ! -e "$SAVED_FLOWS.failed" ]; then
    echo "FAIL: expected a copy of the failed script preserved at" \
         "$SAVED_FLOWS.failed" >&2
    exit 1
fi
if ! cmp -s "$SAVED_FLOWS" "$SAVED_FLOWS.failed"; then
    echo "FAIL: $SAVED_FLOWS.failed does not match the live script it was" \
         "supposedly copied from" >&2
    exit 1
fi
echo "PASS: the saved-flows script stays live for retry, with a copy at" \
     ".failed for inspection."

if ! grep -q 'failed' "$LOGGER_LOG"; then
    echo "FAIL: no diagnostic logged for the restore failure" >&2
    exit 1
fi
echo "PASS: the restore failure was logged."

# --- Part 2: the actual reproduction - retry the exact same (still-broken) ---
# --- restore immediately, the way Restart=on-failure or a manual retry    ---
# --- would, and confirm it does NOT silently "succeed".                   ---
: > "$VSCTL_LOG"
: > "$LOGGER_LOG"

retry_rc=0
env \
    OVS_CTL_OPTS="" \
    OVS_SAVED_FLOWS="$SAVED_FLOWS" \
    PATH="$FAKEBIN:/bin:/usr/bin" \
    sh -c "$exec_start" || retry_rc=$?

if [ "$retry_rc" -eq 0 ]; then
    echo "FAIL: retrying ExecStart with the same still-broken saved-flows" \
         "script exited 0 - this is the exact bug: a retry that skips the" \
         "restore entirely and reports success." >&2
    exit 1
fi
echo "PASS: retrying with the same broken script still fails (exit $retry_rc)," \
     "not a silent success."
if flow_restore_wait_cleared "$VSCTL_LOG"; then
    echo "FAIL: flow-restore-wait was cleared on the retry despite the" \
         "restore still failing." >&2
    exit 1
fi
echo "PASS: flow-restore-wait is still left set on the retry."

# --- Part 3: whatever caused the failure is now resolved (a later package ---
# --- fix, a transient condition clearing) - the *next* retry must be able ---
# --- to genuinely succeed, not be permanently wedged by the .failed copy. ---
: > "$VSCTL_LOG"
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
    echo "FAIL: ExecStart exited $happy_rc for a restore script that succeeded" >&2
    exit 1
fi
echo "PASS: ExecStart exits 0 once a retried restore actually succeeds."

if [ -e "$SAVED_FLOWS" ] || [ -e "$SAVED_FLOWS.failed" ]; then
    echo "FAIL: the saved-flows script should be deleted after a successful restore" >&2
    exit 1
fi
echo "PASS: the saved-flows script is cleaned up after a successful restore."

if ! flow_restore_wait_cleared "$VSCTL_LOG"; then
    echo "FAIL: flow-restore-wait was not cleared after a successful restore" >&2
    exit 1
fi
echo "PASS: flow-restore-wait is cleared after a successful restore."
