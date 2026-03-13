import SwiftUI
import ARKit
import RealityKit

struct ARViewContainer: UIViewRepresentable {
    let viewModel: ARViewModel

    func makeUIView(context: Context) -> ARView {
        #if targetEnvironment(simulator)
        // ARKit is unavailable in the simulator; return a plain view so the app
        // can launch (needed for unit test hosts and Xcode previews).
        return ARView(frame: .zero)
        #else
        let arView = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        viewModel.arView = arView
        arView.session.delegate = viewModel
        viewModel.startSession()
        return arView
        #endif
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
