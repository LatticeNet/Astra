import Foundation

/// The M3 writes, each at the tier the parity matrix assigns (section 3.2).
enum MonitoringIntents {
    // MARK: Checks

    /// Pause or resume (T2). Sends the version that was read; a stale one is
    /// refused and the list reloads to show the current state.
    nonisolated static func setEnabled(_ monitor: Monitor, enabled: Bool) -> WriteIntent {
        let object = ObjectRef(kind: "check", id: monitor.id, name: monitor.displayName)
        let name = monitor.displayName
        return WriteIntent(
            tier: .t2,
            verb: enabled ? "Resume check" : "Pause check",
            object: object,
            scopes: ["monitor:admin"],
            consequence: enabled ? "Results and incidents resume." : "No results or incidents until resumed.",
            affected: [object],
            verify: { client in
                let current = try await client.listMonitors().first { $0.id == monitor.id }
                return current.map { "\(name) is \($0.enabled ? "running" : "paused")." } ?? "\(name) is gone."
            },
            idempotent: true,
            changes: [.checks, .paths],
            perform: { client, _ in
                do {
                    let updated = try await client.monitoringSetEnabled(id: monitor.id, version: monitor.version, enabled: enabled)
                    return .done("\(updated.enabled ? "Resumed" : "Paused") \(name)")
                } catch LatticeAPIError.conflict(let code, let message, _) {
                    if code == "version_conflict" {
                        return .refused(.versionConflict, "\(name) changed since you opened it. Showing its current state.")
                    }
                    return .refused(.managed(by: monitor.checkDefinitionID.isEmpty ? monitor.managedBy : monitor.checkDefinitionID), message)
                }
            }
        )
    }

    /// Delete (T4): irreversible, loses the check's history.
    nonisolated static func deleteCheck(_ monitor: Monitor) -> WriteIntent {
        let object = ObjectRef(kind: "check", id: monitor.id, name: monitor.displayName)
        let name = monitor.displayName
        return WriteIntent(
            tier: .t4,
            verb: "Delete check",
            object: object,
            scopes: ["monitor:admin"],
            consequence: "Deletes \(name) and every result it recorded. Its incidents stop. This cannot be undone.",
            affected: [object],
            changes: [.checks, .paths, .incidents],
            perform: { client, _ in
                do {
                    try await client.deleteMonitor(id: monitor.id)
                } catch LatticeAPIError.conflict(_, let message, _) {
                    return .refused(.managed(by: monitor.checkDefinitionID), message)
                }
                return .done("Deleted check \(name)")
            }
        )
    }

    // MARK: Definitions

    /// Delete a definition (T4). The dry run reads the definition by id and
    /// lists every monitor that goes with it; the write sends that version and
    /// exactly those monitor ids, and stops if either changed in between.
    nonisolated static func deleteDefinition(id: String, name: String) -> WriteIntent {
        let object = ObjectRef(kind: "definition", id: id, name: name)
        return WriteIntent(
            tier: .t4,
            verb: "Delete definition",
            object: object,
            scopes: ["monitor:admin"],
            consequence: "Deletes the definition \(name) and every check it generated, each with its result history. This cannot be undone.",
            affected: [object],
            confirmPhrase: name,
            dryRun: { client in
                let definition = try await client.monitoringDefinition(id: id)
                return report(definition)
            },
            changes: [.definitions, .checks, .paths],
            perform: { client, _ in
                let definition = try await client.monitoringDefinition(id: id)
                guard let request = MonitoringDefinitionDeleteRequest(definition: definition) else {
                    return .refused(.validation("The server did not list this definition's checks."), "The server did not list this definition's checks.")
                }
                do {
                    let result = try await client.monitoringDeleteDefinition(request)
                    let count = result.deleted.count
                    return .done("Deleted \(name) and \(count == 1 ? "1 check" : "\(count) checks")")
                } catch LatticeAPIError.conflict(let code, _, _) {
                    let message = code == "version_conflict" ? "\(name) changed since you reviewed it. Review again." : "The checks of \(name) changed since you reviewed them. Review again."
                    return .refused(code == "version_conflict" ? .versionConflict : .validation(message), message)
                }
            }
        )
    }

    /// The definition's monitors as dry-run lines, grouped by what goes.
    nonisolated static func report(_ definition: MonitoringCheckDefinition) -> DryRunReport {
        guard let monitors = definition.monitors else {
            return DryRunReport(lines: [DetailLine(label: "Checks", value: "not listed by the server")], blocking: true, fingerprint: "none")
        }
        let lines = monitors.map { monitor in
            DetailLine(
                label: "\(monitor.method) to \(monitor.target)",
                value: monitor.runs == 1 ? "1 result" : "\(monitor.runs.formatted()) results",
                group: monitor.inSet ? "Checks and their history" : "Paused targets and their history"
            )
        }
        let fingerprint = "\(definition.version):" + monitors.map(\.monitorID).sorted().joined(separator: ",")
        return DryRunReport(lines: lines, blocking: monitors.isEmpty, fingerprint: fingerprint)
    }

    // MARK: Maintenance

    /// Start maintenance now (T2), from MaintenanceStartSheet.
    nonisolated static func startMaintenance(_ input: MaintenanceWindowInput, subject: String, until: String) -> WriteIntent {
        let object = ObjectRef(kind: "maintenance", id: input.nodeIDs?.first ?? input.name, name: subject)
        return WriteIntent(
            tier: .t2,
            verb: "Start maintenance on",
            object: object,
            scopes: ["monitor:admin"],
            consequence: "Incidents for \(subject) are held and no alerts are sent until \(until).",
            affected: [object],
            changes: [.maintenance, .incidents],
            perform: { client, _ in
                let window = try await client.upsertMaintenanceWindow(input)
                return .done("Maintenance on \(subject) until \(until): \(window.name)")
            }
        )
    }

    /// End now (T2): resends the stored window with only `ends_at` changed.
    nonisolated static func endMaintenance(_ window: MaintenanceWindow) -> WriteIntent {
        let object = ObjectRef(kind: "maintenance", id: window.id, name: window.name)
        return WriteIntent(
            tier: .t2,
            verb: "End maintenance window",
            object: object,
            scopes: ["monitor:admin"],
            consequence: "Incidents it holds are no longer held, and alerts for them resume now.",
            affected: [object],
            idempotent: true,
            changes: [.maintenance, .incidents],
            perform: { client, _ in
                _ = try await client.upsertMaintenanceWindow(MaintenanceWindowInput(ending: window, at: Date()))
                return .done("Ended \(window.name)")
            }
        )
    }

    /// Delete (T2), naming the window.
    nonisolated static func deleteMaintenance(_ window: MaintenanceWindow) -> WriteIntent {
        let object = ObjectRef(kind: "maintenance", id: window.id, name: window.name)
        return WriteIntent(
            tier: .t2,
            verb: "Delete maintenance window",
            object: object,
            scopes: ["monitor:admin"],
            consequence: "Removes the window. Incidents it held alert again if they are still open.",
            affected: [object],
            changes: [.maintenance, .incidents],
            perform: { client, _ in
                try await client.deleteMaintenanceWindow(id: window.id)
                return .done("Deleted \(window.name)")
            }
        )
    }
}
