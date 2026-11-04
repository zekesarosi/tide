import SwiftUI

extension EnvironmentValues {
    /// The moment forecast screens evaluate at. A station screen sets it from
    /// a minute-by-minute `TimelineView`, so every part of the screen (and
    /// what it pushes or presents) shows the same "now" and keeps moving
    /// without refetching. Nil outside such a screen: use `Date()`.
    @Entry var forecastNow: Date? = nil
}
