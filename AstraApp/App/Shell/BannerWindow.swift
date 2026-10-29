import SwiftUI
import UIKit

/// A window just above the app (F-16) that holds the OutcomeBanner, so the
/// banner stays visible over any presented sheet. Touches outside the banner
/// pass through to the app below: the window claims only the frame the banner
/// reports, because SwiftUI content does not hit-test as separate views.
final class BannerWindow: UIWindow {
    private let bannerCenter: BannerCenter

    init(scene: UIWindowScene, center: BannerCenter, services: AppServices) {
        self.bannerCenter = center
        super.init(windowScene: scene)
        windowLevel = .normal + 1
        backgroundColor = .clear
        let host = UIHostingController(rootView: OutcomeBannerView(center: center).environment(services.network))
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        rootViewController = host
        isHidden = false
    }

    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bannerCenter.current != nil, let frame = bannerCenter.bannerFrame else { return false }
        return frame.contains(point)
    }
}
