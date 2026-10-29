#!/bin/sh
# Namespace check for module code (design sections 8.1 and 9.2, item 6).
#
# Every top-level, non-private struct, class, enum, protocol, actor,
# typealias and global function under AstraApp/App/Features/<Module>/ and
# Sources/AstraCore/Domains/<Domain>/, and every function in an
# `extension LatticeClient` there, must be one of:
#   - a type named exactly like its file's basename (NodesScreen in NodesScreen.swift),
#   - a name prefixed with its folder name (FleetDisableRequest, func fleetDisableNode),
#   - private or fileprivate.
# Ported v2 names (skeleton reading 1) are allowlisted below and nowhere else.
#
# Usage: scripts/check-names.sh [Folder ...]   e.g. scripts/check-names.sh Fleet Inbox
# With no arguments every module and domain folder is checked. Exits 1 on a violation.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)

# Names that existed in the domain files when M0 split the core
# mechanically. They are frozen (section 8.4), so they are allowlisted here
# rather than renamed: the v2 types of docs/design/m0-skeleton-notes.md
# reading 1, the request bodies and protocol that moved with them, and the
# LatticeClient functions they carried. New names never join this list.
allowlist='
LatticeToken CreatedTokenResponse MachineProfile MachineProfileRequest RenewalCycle
RenewalReminderFire InventorySummary Monitor MonitorType MonitorResult MonitorStats
NotifyChannel NotifyRule LogSource LogLine LogQueryResponse LogSourceStats NetEndpoint
NetRule NetPolicy NetGraph NetGraphNode NetGraphEdge NetGraphExternal TunnelProfile
TunnelIngress NodeCapabilityEffective NodeCapabilitiesResponse NodeTokenResponse
NodeGeoResolveResult MetricSample MetricsHistory AuditChainStatus
CreateTokenRequest RevokeTokenRequest ApproveRequest ApprovalIDRequest DismissApprovalRequest
DecisionAuthenticator NodeDisableRequest NodeIDRequest EnrollNodeRequest NodeGeoInput
NodeGeoSetRequest NodeGeoResolveRequest MachineDeleteRequest MachineRenewRequest
MonitorCreateRequest TaskIDRequest
approveApproval approveReviewed rejectApproval dismissApproval logStats enrollNode setNodeGeo
createMonitor deleteMonitor netPolicyGraph deleteNotifyChannel deleteNotifyRule cancelTask
listTokens createToken revokeToken verifyAuditChain listLogSources queryLogs setNodeDisabled
rotateNodeToken resolveNodeGeo fetchNodeCapabilities listMachines createMachine updateMachine
deleteMachine renewMachine runRenewalReminders listMonitors monitorResults listNetPolicies
listTunnels listNotifyChannels listNotifyRules testNotifyChannel
'

folders() {
    if [ "$#" -gt 0 ]; then
        for name in "$@"; do
            for base in "$root/AstraApp/App/Features" "$root/Sources/AstraCore/Domains"; do
                [ -d "$base/$name" ] && echo "$base/$name"
            done
        done
        return 0
    fi
    for base in "$root/AstraApp/App/Features" "$root/Sources/AstraCore/Domains"; do
        [ -d "$base" ] || continue
        find "$base" -mindepth 1 -maxdepth 1 -type d | sort
    done
}

status=0
for dir in $(folders "$@"); do
    folder=$(basename "$dir")
    prefix_type="$folder"
    # The function prefix: the folder name with its leading capitals lowered
    # (Fleet -> fleet, SSHGuard -> sshGuard, VPN -> vpn, AgentUpdates -> agentUpdates).
    prefix_func=$(printf '%s' "$folder" | perl -pe 's/^([A-Z]+)(?=[A-Z][a-z])|^([A-Z]+)$|^([A-Z])/lc($1 \/\/ $2 \/\/ $3)/e')
    find "$dir" -name '*.swift' | sort | while read -r file; do
        base=$(basename "$file" .swift)
        perl -ne '
            BEGIN {
                ($base, $ptype, $pfunc, $allow, $grand) = @ARGV[0..4];
                @ARGV = ($ARGV[5]);
                %allowed = map { $_ => 1 } split /\s+/, $allow;
                %grand = map { $_ => 1 } split /\s+/, $grand;
            }
            if (/^((?:@\w+\s+)*)((?:(?:public|internal|open|package|final|nonisolated|indirect)\s+)*)(struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)/) {
                my ($mods, $kind, $name) = ($2, $3, $4);
                next if $mods =~ /\b(private|fileprivate)\b/;
                next if $name eq $base || index($name, $ptype) == 0 || $allowed{$name};
                print "$ARGV:$.: $kind $name is neither $base nor prefixed $ptype\n";
                next;
            }
            if (/^(?:(?:public|internal|package)\s+)?extension\s+LatticeClient\b/) { $inclient = 1; next; }
            if ($inclient && /^\}/) { $inclient = 0; next; }
            if (/^((?:@\w+\s+)*)((?:(?:public|internal|package|nonisolated)\s+)*)func\s+([A-Za-z_][A-Za-z0-9_]*)/) {
                my ($mods, $name) = ($2, $3);
                next if $mods =~ /\b(private|fileprivate)\b/;
                next if index($name, $pfunc) == 0;
                print "$ARGV:$.: global func $name is not prefixed $pfunc\n";
                next;
            }
            if ($inclient && /^\s{4}((?:(?:public|internal|package|nonisolated|static|private|fileprivate)\s+)*)func\s+([A-Za-z_][A-Za-z0-9_]*)/) {
                my ($mods, $name) = ($1, $2);
                next if $mods =~ /\b(private|fileprivate)\b/;
                next if index($name, $pfunc) == 0 || $grand{$name};
                print "$ARGV:$.: LatticeClient func $name is not prefixed $pfunc\n";
            }
        ' "$base" "$prefix_type" "$prefix_func" "$allowlist" "$allowlist" "$file"
    done
done > "${TMPDIR:-/tmp}/check-names.$$"

if [ -s "${TMPDIR:-/tmp}/check-names.$$" ]; then
    sed "s|$root/||" "${TMPDIR:-/tmp}/check-names.$$"
    status=1
else
    echo "check-names: every module name is prefixed or matches its file"
fi
rm -f "${TMPDIR:-/tmp}/check-names.$$"
exit "$status"
