import Foundation

/// Every Platform write and reveal, with the tier the parity matrix gives it
/// (section 3.2): plugin activate or disable T3, delete binding T4, revoke
/// storage token T4, share refresh T2, share rotate T3, share delete T4,
/// reveal share URL S. Nothing here sends a request until ActionRunner gates it.
enum PlatformIntents {
    // MARK: Plugins

    /// Activate or disable a plugin. Activation starts its runtime and the
    /// server refuses it while a required dependency is inactive.
    static func lifecycle(pluginID: String, name: String, to status: String) -> WriteIntent {
        let activate = status == "active"
        let ref = ObjectRef(kind: "plugin", id: pluginID, name: name)
        return WriteIntent(
            tier: .t3,
            verb: activate ? "Activate" : "Disable",
            object: ref,
            scopes: [PlatformStore.adminScope],
            consequence: activate
                ? "\(name) starts its runtime, answers plugin calls and shows its pages to everyone allowed to see them."
                : "\(name) stops its runtime at once. Its pages disappear, calls to it fail, and anything it publishes stops updating. Its data stays.",
            affected: [ref],
            verify: { client in
                let current = try await client.platformLifecycle().first { $0.id == pluginID }
                return "\(name) is now \(current?.status ?? "unknown")."
            },
            idempotent: true,
            changes: [.plugins],
            perform: { client, _ in
                do {
                    let result = try await client.platformSetPluginStatus(id: pluginID, status: status)
                    if activate, result.runtime?.state == "failed" {
                        return .refused(.validation(result.runtime?.message ?? "runtime failed"), "\(name) is active but its runtime failed: \(result.runtime?.message ?? "no message")")
                    }
                    return .done(activate ? "Activated \(name)" : "Disabled \(name)")
                } catch LatticeAPIError.conflict(_, let message, _) {
                    return .refused(.validation(message), "Not activated: \(message)")
                }
            }
        )
    }

    // MARK: Storage

    /// Deletes a host binding: the route stops answering at once.
    static func deleteBinding(kind: PlatformStorageKind, id: String, route: String, bucket: String) -> WriteIntent {
        WriteIntent(
            tier: .t4,
            verb: "Delete binding",
            object: ObjectRef(kind: "binding", id: id, name: route),
            scopes: [kind.adminScope],
            consequence: "\(route) stops serving the \(kind.title) bucket \(bucket) at once. The bucket and its contents stay. This cannot be undone.",
            affected: [ObjectRef(kind: "bucket", id: bucket, name: bucket)],
            verify: { client in
                try await client.platformBindings(kind: kind).contains { $0.id == id } ? "\(route) is still bound." : "\(route) is no longer bound."
            },
            changes: [.publishing, .store],
            perform: { client, _ in
                try await client.platformDeleteBinding(kind: kind, id: id)
                return .done("Deleted the binding \(route)")
            }
        )
    }

    /// Revokes a storage token; the server purges its cache so it stops at once.
    static func revokeToken(kind: PlatformStorageKind, id: String, name: String, buckets: String) -> WriteIntent {
        let ref = ObjectRef(kind: "storage token", id: id, name: name)
        return WriteIntent(
            tier: .t4,
            verb: "Revoke storage token",
            object: ref,
            scopes: [kind.adminScope],
            consequence: "Anything using \(name) loses access to \(buckets) at once. A revoked token cannot be restored; create a new one on the web.",
            affected: [ref],
            verify: { client in
                let current = try await client.platformStorageTokens(kind: kind).first { $0.id == id }
                return current?.isRevoked == true ? "\(name) is revoked." : "\(name) is still active."
            },
            changes: [.publishing, .store],
            perform: { client, _ in
                _ = try await client.platformRevokeStorageToken(kind: kind, tokenID: id)
                return .done("Revoked \(name)")
            }
        )
    }

    // MARK: Shares

    static func shareRef(id: String, slug: String) -> ObjectRef {
        ObjectRef(kind: "share", id: id, name: slug)
    }

    /// Fetches the provider now (plugin sources only).
    static func refreshShare(id: String, slug: String, sink: PlatformRefreshSink) -> WriteIntent {
        WriteIntent(
            tier: .t2,
            verb: "Refresh",
            object: shareRef(id: id, slug: slug),
            scopes: [PublishingStore.shareScope],
            consequence: "Fetches \(slug)'s subscription from its provider now and drops the cached body, so clients get new content on their next fetch.",
            idempotent: true,
            changes: [.publishing],
            perform: { client, _ in
                let result = try await client.platformRefreshShare(id: id)
                await sink.set(result)
                if result.stale {
                    return .partial(succeeded: [], failed: [ObjectFailure(object: shareRef(id: id, slug: slug), reason: result.error)],
                                    message: "The provider fetch failed; \(slug) keeps serving its last snapshot. \(result.error)")
                }
                return .done("Refreshed \(slug): \(ByteFormatter.bytes(UInt64(max(result.bytes, 0)))) fetched")
            }
        )
    }

    /// A new token: the old URL stops working for every client holding it.
    /// `rotatedBefore` is the share's rotation stamp as last read, so the
    /// verify compares server stamps, never the phone clock.
    static func rotateShare(id: String, slug: String, rotatedBefore: Date?) -> WriteIntent {
        let ref = shareRef(id: id, slug: slug)
        return WriteIntent(
            tier: .t3,
            verb: "Rotate the URL of",
            object: ref,
            scopes: [PublishingStore.shareScope],
            consequence: "The current URL of \(slug) stops working at once for every client that holds it. Reveal the new URL afterwards and send it again.",
            affected: [ref],
            verify: { client in
                let share = try await client.platformShares().first { $0.id == id }
                guard let rotated = share?.rotatedAt else { return "\(slug) shows no rotation." }
                if let rotatedBefore, rotated <= rotatedBefore { return "\(slug) was not rotated." }
                return "\(slug) was rotated."
            },
            changes: [.publishing],
            perform: { client, _ in
                _ = try await client.platformRotateShare(id: id)
                return .done("Rotated \(slug): the old URL no longer works")
            }
        )
    }

    /// Deletes the share; its URL stops answering at once.
    static func deleteShare(id: String, slug: String) -> WriteIntent {
        let ref = shareRef(id: id, slug: slug)
        return WriteIntent(
            tier: .t4,
            verb: "Delete share",
            object: ref,
            scopes: [PublishingStore.shareScope],
            consequence: "The URL of \(slug) stops answering at once and its cached body is dropped. Clients holding it get nothing. This cannot be undone.",
            affected: [ref],
            verify: { client in
                try await client.platformShares().contains { $0.id == id } ? "\(slug) still exists." : "\(slug) is deleted."
            },
            changes: [.publishing, .upcoming],
            perform: { client, _ in
                try await client.platformDeleteShare(id: id)
                return .done("Deleted the share \(slug)")
            }
        )
    }

    /// Reveals the share URL once after step-up on the session; meant to be sent, so it offers Share.
    static func revealShare(id: String, slug: String, origin: URL?) -> RevealIntent {
        RevealIntent(purpose: .shareURL, object: shareRef(id: id, slug: slug), scopes: [PublishingStore.shareScope], shareable: true) { client, grant in
            let reveal = try await client.platformRevealShare(id: id, grant: grant)
            return RevealedSecret(title: "Share URL for \(slug)", value: reveal.fullURL(origin: origin), kind: .shareableLink)
        }
    }
}

/// Carries a refresh answer out of the write, so the share screen can show
/// when the provider was last fetched from this iPhone.
actor PlatformRefreshSink {
    private(set) var result: PlatformShareRefresh?

    func set(_ value: PlatformShareRefresh) {
        result = value
    }
}
