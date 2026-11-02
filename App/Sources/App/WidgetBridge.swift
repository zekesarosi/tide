import Foundation
import TideKit
import WidgetKit

/// Keeps the home- and lock-screen widgets in step with the app.
enum WidgetBridge {
    /// Save a compact copy of a fresh forecast for the widgets and ask
    /// WidgetKit to redraw them (no network needed on the widget side).
    static func publish(_ forecast: WaterLevelForecast) {
        try? AppGroup.snapshots.save(ForecastSnapshot(forecast: forecast))
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
    }

    /// Units, datum, favorites or keys changed: widgets re-render.
    static func settingsChanged() {
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
    }
}
