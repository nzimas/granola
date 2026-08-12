import Foundation
import Combine

/// A meter value on its own observable object.
///
/// Metering arrives 15 times a second per track. If it lived on `TrackModel`
/// every reading would republish the whole track and re-render the entire
/// channel strip — including the waveform canvas. Isolating it here means a
/// meter update redraws one small bar and nothing else.
final class MeterLevel: ObservableObject {
    @Published var level: Double = 0
}

/// Master meter, isolated from `GranolaModel` for the same reason: republishing
/// the app model re-evaluates every strip in the window.
final class StereoMeter: ObservableObject {
    @Published var left: Double = 0
    @Published var right: Double = 0
}
