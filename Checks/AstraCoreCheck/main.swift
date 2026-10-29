import Foundation

// Every check, in the order of section 8.5. Frozen after M0: each domain fills
// in its own check function, and this list never changes.
do {
    try await checkShared()
    try await checkContrast()
    try await checkDemo()
    try await checkApprovals()
    try await checkFleet()
    try await checkMonitoring()
    try await checkTasks()
    try await checkAudit()
    try await checkInventory()
    try await checkNetworking()
    try await checkSSHGuard()
    try await checkAgentUpdates()
    try await checkPlatform()
    try await checkNotify()
    try await checkEvidence()
    try await checkAccess()
    try await checkTerminal()
    try await checkVPN()
    print("AstraCoreCheck passed")
} catch {
    fputs("AstraCoreCheck failed: \(error)\n", stderr)
    exit(1)
}
