#!/bin/bash
# Regression test for ovs-save's own exit status actually reflecting a
# failed internal dump command.
#
# Before this fix: "ovs-ofctl dump-flows ... | sed ... > file" (and the
# tlv-map/meters/groups dumps alongside it) piped ovs-ofctl straight into
# awk/sed with no exit-status check. ovs-save itself has no "set -e"/
# pipefail (its shebang is /bin/sh, typically dash, which doesn't support
# pipefail anyway), so under a plain pipeline the exit status is only the
# last stage's (awk/sed), which succeeds even on empty/truncated input.
# ovs-save could therefore exit 0 - "I captured everything fine" - despite
# a dump command actually failing partway through, e.g. a dropped vconn.
# That silently defeats the ExecStop-level fix that only checks ovs-save's
# own exit status before publishing the capture (see
# ovs-vswitchd-service-save-capture-failure-test.sh): if ovs-save itself
# never reports the failure, that gate has nothing to act on.
#
# This runs the real ovs-save with a fake ovs-ofctl that fails on one
# specific dump subcommand while succeeding on everything else (so a
# config this script thinks is fine for the earlier dumps actually dies
# partway through), and asserts ovs-save's own exit status is non-zero -
# once per dump command (tlv-map, meters, groups, flows), since each is an
# independent place this previously went unnoticed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVS_SAVE_SRC="$SCRIPT_DIR/utilities/ovs-save"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cp "$OVS_SAVE_SRC" "$WORKDIR/ovs-save"
printf '#!/bin/sh\n' > "$WORKDIR/ovs-lib"
chmod +x "$WORKDIR/ovs-save" "$WORKDIR/ovs-lib"

FAKEBIN="$WORKDIR/bin"
mkdir -p "$FAKEBIN"

write_fake_ofctl() {
    # $1: the dump subcommand to fail on (dump-tlv-map, dump-meters,
    # dump-groups, or dump-flows); everything else succeeds with minimal
    # but valid-looking output.
    local failing="$1"
    cat > "$FAKEBIN/ovs-ofctl" <<EOF
#!/bin/bash
case "\$*" in
    --version) echo "ovs-ofctl (Open vSwitch) 3.3.6" ;;
    *$failing*) echo "partial output before dying" ; exit 1 ;;
    *dump-tlv-map*) exit 0 ;;
    *dump-meters*) echo "meter=1 kbps bands=type=drop rate=1000 burst_size=100" ;;
    *dump-groups*) exit 0 ;;
    *dump-flows*) echo "cookie=0x0, table=0, priority=100 actions=drop" ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$FAKEBIN/ovs-ofctl"
}

cat > "$FAKEBIN/ovs-vsctl" <<'EOF'
#!/bin/bash
case "$*" in
    "get bridge br0 protocols") echo "[OpenFlow13]" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/ovs-vsctl"

cat > "$FAKEBIN/ovs-appctl" <<'EOF'
#!/bin/bash
case "$*" in
    version) echo "ovs-vswitchd (Open vSwitch) 3.3.6" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/ovs-appctl"

all_pass=true
for dump in dump-tlv-map dump-meters dump-groups dump-flows; do
    write_fake_ofctl "$dump"
    rc=0
    output=$(PATH="$FAKEBIN:$PATH" "$WORKDIR/ovs-save" save-flows br0 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: ovs-save exited 0 despite '$dump' failing for br0 -" \
             "a partial/incomplete capture would be silently accepted as" \
             "complete." >&2
        echo "--- output ---" >&2
        echo "$output" >&2
        all_pass=false
        continue
    fi
    if ! echo "$output" | grep -q "$dump failed"; then
        echo "FAIL: ovs-save failed for '$dump' (rc=$rc) but with no" \
             "diagnostic naming which dump failed:" >&2
        echo "$output" >&2
        all_pass=false
        continue
    fi
    echo "PASS: ovs-save exits non-zero when '$dump' fails (rc=$rc)."
done

$all_pass
