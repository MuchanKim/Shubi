import CoreGraphics

/// The app's one spacing scale and the fixed sizes built from it.
enum Layout {
    /// 4-point grid.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Outer margin of every detail screen and sheet, so their leading edges line up.
    static let pageMargin = Spacing.xl
    static let cardPadding = Spacing.l
    static let cornerRadius: CGFloat = 12

    static let windowDefaultWidth: CGFloat = 1200
    static let windowDefaultHeight: CGFloat = 600
    /// Every column at its widest still leaves the table room for all its columns.
    static let windowMinWidth = sidebarMaxWidth + tableMinWidth + inspectorMaxWidth
    static let windowMinHeight: CGFloat = 520

    static let sidebarMinWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 220
    static let sidebarRowHeight: CGFloat = 32
    static let sidebarTileSize: CGFloat = 22
    static let inspectorMinWidth: CGFloat = 260
    static let inspectorIdealWidth: CGFloat = 320
    static let inspectorMaxWidth: CGFloat = 340
    /// Measured: below this the location column is cut off (column minimums are 480, plus insets and the scroller).
    static let tableMinWidth: CGFloat = 580
    static let nameColumnMinWidth: CGFloat = 160
    static let locationColumnMinWidth: CGFloat = 120
    static let sizeColumnWidth: CGFloat = 88
    static let dateColumnWidth: CGFloat = 112

    static let ringPanelWidth: CGFloat = 320
    static let ringSize: CGFloat = 232
    /// Rows never get shorter than this; spare window height is shared equally between them.
    static let rowMinHeight: CGFloat = 56
    static let iconTileSize: CGFloat = 32
    static let rowTitleWidth: CGFloat = 160
    /// Row dividers start under the title, past the icon tile.
    static let rowDividerInset = cardPadding + iconTileSize + Spacing.m

    static let settingsWidth: CGFloat = 440
    static let themeSwatchWidth: CGFloat = 72
    static let themeSwatchHeight: CGFloat = 48

    static let sheetWidth: CGFloat = 512
    static let sheetListHeight: CGFloat = 240
}
