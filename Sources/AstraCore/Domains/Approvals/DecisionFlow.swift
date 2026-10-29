import Foundation

/// Confirms approval decisions. The app's `IntentAuth` conforms (as it does
/// to `WriteAuthenticator`); checks inject a stub so a cancelled confirmation
/// is proven to send zero requests (section 6.1).
public protocol DecisionAuthenticator: Sendable {
    func authenticate(reason: String) async -> DeviceAuthOutcome
}

/// The hash-bound decision sequence of section 6.1, steps 7 to 12.
public struct DecisionFlow: Sendable {
    public let client: LatticeClient
    public let authenticator: any DecisionAuthenticator

    public init(client: LatticeClient, authenticator: any DecisionAuthenticator) {
        self.client = client
        self.authenticator = authenticator
    }

    // M1: implement approve, reject and dismiss with transition verification.
}
