import Foundation
import Combine

/// High-frequency playback telemetry (updated ~10×/s by `AppState.tick`). Split
/// out of `AppState` on purpose: if these ticking values were `@Published` on
/// AppState, every 0.1s write would fire `AppState.objectWillChange`, invalidating
/// EVERY main-window view that observes AppState via `@EnvironmentObject` and
/// piling up SwiftUI observation-tracking allocations that stay reachable and
/// never release (measured: ~250 MB of live `ObservationTracking` dictionaries).
/// Only `PlayerOverlay` observes this object, so the 10 Hz churn is confined to
/// the HUD that actually renders it.
@MainActor
final class PlaybackTelemetry: ObservableObject {
    @Published var progress: Double = 0        // 0…1 across all chunks
    @Published var chunkProgress: Double = 0   // 0…1 within the current paragraph
    @Published var chunkSeconds: Double = 0    // seconds into the current paragraph

    /// Reset to the pre-playback state (start of a new sequence / stop / finish).
    func reset() { progress = 0; chunkProgress = 0; chunkSeconds = 0 }
}
