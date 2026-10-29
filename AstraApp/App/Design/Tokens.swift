import SwiftUI

// Semantic color tokens (section 4.1). Each one is a color set in
// Assets.xcassets with Any, Dark, High Contrast and Dark High Contrast
// values; views use these statics and never raw colors.
//
// Hex values, mirrored from the asset catalog for ContrastChecks:
//
//   token              light    dark     light HC dark HC
//   accent.text        #2F5BEA  #7C9BFF  #1A3DB8  #A3BAFF
//   accent.fill        #2F5BEA  #2F5BEA  #1A3DB8  #2F5BEA
//   destructive.fill   #D70015  #D70015  #A00010  #D70015
//   status.ok.fill     #248A3D  #30D158  #1B6B30  #30DB5B
//   status.ok.text     #1F7A35  #30D158  #145A26  #5BE37D
//   status.warn.fill   #C93400  #FF9F0A  #A12A00  #FFB340
//   status.warn.text   #B25000  #FF9F0A  #803800  #FFB340
//   status.fail.fill   #E0281E  #FF453A  #B8000F  #FF6961
//   status.fail.text   #D70015  #FF7A72  #A00010  #FFA39E
//   chart.band         secondaryLabel at 12%, 18%, 20%, 26%
//
// SF Symbols: every symbol name in the specification exists in SF Symbols 7
// for iOS 26, so no substitutions are recorded here.

extension Color {
    /// Tinted text, links, selection, the primary chart series. Never a status.
    static let accentText = Color("AccentText")
    /// Background of prominent buttons only.
    static let accentFill = Color("AccentFill")
    /// Background of the T4 destructive button: white reaches 4.5:1, which
    /// system red does not.
    static let destructiveFill = Color("DestructiveFill")

    static let statusOKFill = Color("StatusOKFill")
    static let statusOKText = Color("StatusOKText")
    static let statusWarnFill = Color("StatusWarnFill")
    static let statusWarnText = Color("StatusWarnText")
    static let statusFailFill = Color("StatusFailFill")
    static let statusFailText = Color("StatusFailText")
    /// Acknowledged, snoozed, held, pending, unknown and every off state.
    static let statusQuiet = Color(uiColor: .secondaryLabel)

    /// Maintenance windows on charts.
    static let chartBand = Color("ChartBand")
    /// The previous-window series.
    static let chartCompare = Color(uiColor: .secondaryLabel)
}
