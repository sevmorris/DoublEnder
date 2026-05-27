import SwiftUI

// MARK: - ContentView (Local build)

struct ContentView: View {
    @ObservedObject private var viewModel = RecorderViewModel.shared
    @State private var isStopping = false
    @StateObject private var popovers = FaceplatePopoverManager()
    @State private var ledFlashOn = false

    private let flashPublisher = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    private var isRecordingState: Bool {
        if case .recording = viewModel.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            FaceplateViewportBackground()
                .padding(FaceplateDesign.viewportInsets)

            content
                .padding(FaceplateDesign.viewportInsets)

            Image("de_faceplate")
                .resizable()
                .frame(width: FaceplateDesign.windowSize.width, height: FaceplateDesign.windowSize.height)
                .allowsHitTesting(false)

            FaceplateScreenGlow()

            Image(isRecordingState && ledFlashOn ? "de_red-led_on" : "de_red-led_off")
                .resizable()
                .scaledToFit()
                .frame(width: FaceplateDesign.ledSize, height: FaceplateDesign.ledSize)
                .position(FaceplateDesign.redLEDPosition)
                .allowsHitTesting(isRecordingState)
                .help(isRecordingState ? "Recording in progress" : "")
        }
        .frame(width: FaceplateDesign.windowSize.width, height: FaceplateDesign.windowSize.height)
        .background(Color.clear)
        .ignoresSafeArea()
        .onReceive(flashPublisher) { _ in
            if isRecordingState { ledFlashOn.toggle() }
            else { ledFlashOn = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .selectingMic, .ready, .recording:
            RecorderMainPanel(viewModel: viewModel, popovers: popovers, isStopping: $isStopping)
        case .error(let message):
            FaceplateErrorView(message: message, onRetry: { viewModel.reset() })
        }
    }
}
