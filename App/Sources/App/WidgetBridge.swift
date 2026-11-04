import Foundation
import TideKit
import WidgetKit

/// Keeps the home- and lock-screen widgets in step with the app.
enum WidgetBridge {
    /// Publish a compact copy of a fresh forecast to the shared store (if
    /// it's the newest) and ask WidgetKit to redraw from it; no network
    /// needed on the widget side.
    static func publish(_ result: ForecastResult) {
        guard ForecastPublisher.publish(ForecastSnapshot(result: result)) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
    }

    /// Units, datum, favorites or keys changed: widgets re-render.
    static func settingsChanged() {
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
    }
}
