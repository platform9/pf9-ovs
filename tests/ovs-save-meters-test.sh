#!/bin/bash
# Regression test for utilities/ovs-save's meter save/restore.
#
# Without this, ovs-save only saved TLV maps, groups and flows. A flow
# referencing a meter survived a reload's *dump*, but the meter itself did
# not get restored, so replaying that flow against a switch with no meters
# yet failed the whole atomic flow/group bundle with OFPERR_OFPMMFC_
# INVALID_METER (ofproto.c's ofproto_check_ofpacts()).
#
# This stubs ovs-appctl/ovs-ofctl/ovs-vsctl, runs the real save_flows()
# against a fake bridge with one meter and one meter-referencing flow, and
# asserts the generated restore script: (1) contains an add-meter command
# for it, and (2) orders that add-meter *before* the add-groups/
# replace-flows --bundle commands - meters aren't bundlable (lib/ofp-
# bundle.c), so they must already exist by the time the bundle replays.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVS_SAVE_SRC="$SCRIPT_DIR/../utilities/ovs-save"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ovs-save sources "$dir0/ovs-lib" at the top; save_flows() itself doesn't
# call anything from it, so an empty stand-in next to a copy of ovs-save is
# enough - avoids needing a fully `configure`d tree just to run this script.
cp "$OVS_SAVE_SRC" "$WORKDIR/ovs-save"
printf '#!/bin/sh\n' > "$WORKDIR/ovs-lib"
chmod +x "$WORKDIR/ovs-save" "$WORKDIR/ovs-lib"

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

write_fake ovs-vsctl '
case "$*" in
    "get bridge br0 protocols") echo "[OpenFlow13]" ;;
    *) exit 0 ;;
esac'

write_fake ovs-appctl '
case "$*" in
    "version") echo "ovs-vswitchd (Open vSwitch) 3.3.6" ;;
    *) exit 0 ;;
esac'

write_fake ovs-ofctl '
case "$*" in
    --version) echo "ovs-ofctl (Open vSwitch) 3.3.6" ;;
    *dump-tlv-map*) exit 0 ;;  # empty TLV map is fine
    *dump-meters*)
        # Real dump-meters output, confirmed against an actual OVS instance:
        # the header ("meter=<id> <flags> bands=") and each band
        # ("type=... rate=...") print on *separate* lines - never one line
        # with the band appended, which is what this fixture used to claim
        # and is not what dump-meters ever actually prints. A fixture that
        # only exercised the single-line shape could not have caught the
        # real bug it claims to guard: grepping for "^meter=" alone threw
        # every band line away, generating a bandless add-meter that OVS
        # rejects outright.
        printf "OFPST_METER_CONFIG reply (OF1.3) (xid=0x2):\n"
        printf "meter=1 kbps bands=\n"
        printf "type=drop rate=1000 burst_size=100\n"
        ;;
    *dump-groups*) exit 0 ;;  # no groups in this fixture
    *dump-flows*)
        echo "cookie=0x0, table=0, priority=100 actions=meter:1,drop"
        ;;
    *) exit 0 ;;
esac'

restore_script=$(PATH="$FAKEBIN:$PATH" "$WORKDIR/ovs-save" save-flows br0)

echo "--- generated restore script ---"
echo "$restore_script"
echo "---------------------------------"

meter_line=$(echo "$restore_script" | grep -n "add-meter br0 '" | head -1 | cut -d: -f1)
bundle_line=$(echo "$restore_script" | grep -n "add-groups br0" | head -1 | cut -d: -f1)

if [ -z "$meter_line" ]; then
    echo "FAIL: no add-meter command found in the generated restore script" >&2
    exit 1
fi
if [ -z "$bundle_line" ]; then
    echo "FAIL: no add-groups command found in the generated restore script" >&2
    exit 1
fi
if [ "$meter_line" -ge "$bundle_line" ]; then
    echo "FAIL: add-meter (line $meter_line) did not precede add-groups" \
         "(line $bundle_line) - a flow referencing this meter would fail" \
         "the bundle replay." >&2
    exit 1
fi
if ! echo "$restore_script" | grep -q "meter=1 kbps bands=type=drop rate=1000 burst_size=100"; then
    echo "FAIL: the dumped meter config did not make it into the add-meter command" >&2
    exit 1
fi

echo "PASS: add-meter (line $meter_line) runs before add-groups" \
     "(line $bundle_line), carrying the dumped meter config."
