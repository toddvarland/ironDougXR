import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ARViewModel()
    @State private var showMarkerList = false

    var body: some View {
        ZStack(alignment: .top) {
            ARViewContainer(viewModel: viewModel)
                .ignoresSafeArea()
                .onTapGesture { location in
                    viewModel.handleTap(at: location)
                }

            statusBanner

            if viewModel.isRelocalizing {
                relocalizationOverlay
            }

            VStack {
                Spacer()
                bottomControls
            }
        }
        .sheet(isPresented: $showMarkerList) {
            MarkerListView(viewModel: viewModel)
        }
        .alert(
            "Environment Calibration Needed",
            isPresented: $viewModel.showRecalibrationPrompt
        ) {
            Button("Clear & Start Fresh", role: .destructive) {
                viewModel.clearAllAnchors()
            }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(
                "Saved markers could not be restored, or the world map is out of date. " +
                "Clear all markers, re-scan the environment, re-place markers, then Save."
            )
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var statusBanner: some View {
        Text(viewModel.trackingStatusMessage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 12)
            .accessibilityIdentifier("statusBanner")
    }

    @ViewBuilder
    private var relocalizationOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text(viewModel.trackingStatusMessage)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 80)
    }

    @ViewBuilder
    private var bottomControls: some View {
        HStack(spacing: 16) {
            Button("Save") {
                viewModel.saveWorldMap()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.isReadyToSave)
            .accessibilityIdentifier("saveButton")

            Button {
                showMarkerList = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("markerListButton")
        }
        .padding(.bottom, 40)
    }
}

// MARK: - Marker List

struct MarkerListView: View {
    @ObservedObject var viewModel: ARViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var anchorToRename: AnchorRecord?
    @State private var renameText: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.savedAnchors.isEmpty {
                    ContentUnavailableView(
                        "No Markers",
                        systemImage: "mappin.slash",
                        description: Text("Tap a surface in the AR view to place a marker.")
                    )
                } else {
                    List {
                        ForEach(viewModel.savedAnchors) { record in
                            Button {
                                anchorToRename = record
                                renameText = record.label
                            } label: {
                                HStack {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.label)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        Text(record.timestamp, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                viewModel.deleteAnchor(id: viewModel.savedAnchors[i].id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Markers (\(viewModel.anchorCount))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Rename Marker", isPresented: Binding(
            get: { anchorToRename != nil },
            set: { if !$0 { anchorToRename = nil } }
        )) {
            TextField("Label", text: $renameText)
            Button("Save") {
                if let id = anchorToRename?.id, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.renameAnchor(id: id, label: renameText.trimmingCharacters(in: .whitespaces))
                }
                anchorToRename = nil
            }
            Button("Cancel", role: .cancel) {
                anchorToRename = nil
            }
        } message: {
            Text("Enter a new name for \"\(anchorToRename?.label ?? "")\"")
        }
    }
}
