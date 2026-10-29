import SwiftUI

/// M4's contribution to Browse search (section 8.5): task runs, the newest
/// 200 fetched once per search session (60 s) and filtered on device with
/// the query grammar (`status:failed node:edge-tyo-1`, a run id, a node name).
enum ActivitySearch: SearchProvider {
    /// One list per credential; a failed read is asked again next time
    /// instead of reading as empty.
    @MainActor private static var cache: (generation: Int, at: Date, tasks: [LatticeTask])?

    static func results(for query: LatticeQuery, context: SearchContext) async -> [SearchResult] {
        guard !query.source.trimmingCharacters(in: .whitespaces).isEmpty, let client = context.session.client else { return [] }
        if let missing = context.session.missing(TasksStore.readRequirement), !missing.isEmpty { return [] }
        let now = Date()
        let generation = context.session.generation
        var tasks: [LatticeTask]
        if let held = cache, held.generation == generation, now.timeIntervalSince(held.at) <= 60 {
            tasks = held.tasks
        } else {
            guard let page = try? await client.listTasks(query: TaskQuery(limit: TasksModel.lookupLimit)) else { return [] }
            tasks = page.tasks
            cache = (generation, now, tasks)
        }
        let rows = tasks.map { TasksSearchRow(task: $0, nodeNames: $0.targets.map { context.nodes.name(for: $0) }) }
        guard case .success(let compiled) = LatticeQueryEngine.compile(query.source, provider: TasksQueryFields.self) else { return [] }
        let matched = LatticeQueryEngine.apply(compiled, to: rows, now: now)
        return TasksModel.sorted(matched.map(\.task)).map { task in
            let state = task.runState(now: now)
            let targets = task.targets.first.map { first in
                let name = context.nodes.name(for: first)
                return task.targets.count == 1 ? name : "\(name) and \(task.targets.count - 1) more"
            }
            let age = task.createdAt.map { RelativeDateFormatter.string(from: $0, now: now) }
            return SearchResult(kind: "Tasks", id: task.id, title: task.id, detail: [targets, age].compactMap { $0 }.joined(separator: ", "),
                                style: .task(state), target: .push(.activity(.task(id: task.id))))
        }
    }
}
