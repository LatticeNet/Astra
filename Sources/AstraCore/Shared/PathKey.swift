import Foundation

/// A path's address, as the console's `pathsModel.ts` names it: a pair of
/// nodes whichever checks measure it, or a check to an address. An empty
/// source is the control plane.
public enum PathAddress: Sendable, Hashable {
    case pair(source: String, targetNode: String)
    case check(source: String, monitorID: String)

    /// The key's spelling of the control plane.
    public static let controlPlane = "_"

    public var source: String {
        switch self {
        case .pair(let source, _), .check(let source, _): source
        }
    }
}

/// `encodePathKey`: `<source>~<targetNode>` for a pair and
/// `<source>~@<monitorID>` for a check, with `_` for the control plane.
public func encodePathKey(_ address: PathAddress) -> String {
    let source = address.source.isEmpty ? PathAddress.controlPlane : address.source
    switch address {
    case .pair(_, let targetNode): return "\(source)~\(targetNode)"
    case .check(_, let monitorID): return "\(source)~@\(monitorID)"
    }
}

/// `decodePathKey`: nil for anything `encodePathKey` cannot have produced.
public func decodePathKey(_ raw: String) -> PathAddress? {
    guard let tilde = raw.firstIndex(of: "~"), tilde != raw.startIndex else { return nil }
    let rest = raw[raw.index(after: tilde)...]
    guard !rest.isEmpty else { return nil }
    let sourceRaw = String(raw[..<tilde])
    let source = sourceRaw == PathAddress.controlPlane ? "" : sourceRaw
    if rest.hasPrefix("@") {
        let monitorID = String(rest.dropFirst())
        return monitorID.isEmpty ? nil : .check(source: source, monitorID: monitorID)
    }
    return .pair(source: source, targetNode: String(rest))
}
