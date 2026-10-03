import SlipstreamMenubarCore
import SwiftUI

/// The models to choose from, their download sizes, and the New Model… check.
@MainActor
final class ModelPicker: ObservableObject {
    enum NewModelState: Equatable {
        case idle
        case checking
        case suitable(ModelSpec, size: Int64)
        case unsuitable(String)
    }

    @Published private(set) var models: [ModelSpec]
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published var newModelOpen: Bool
    @Published var newRepository = ""
    @Published private(set) var newModelState: NewModelState = .idle

    init(models: [ModelSpec], newModelOpen: Bool) {
        self.models = models
        self.newModelOpen = newModelOpen
    }

    func loadSizes() {
        for model in models where sizes[model.repository] == nil {
            Task {
                if let size = try? await ModelDownloader.totalSize(of: model) { sizes[model.repository] = size }
            }
        }
    }

    /// Whether a pasted repository is something Slipstream can serve: a package in a
    /// format the launcher reads, or Qwen3.8-Flash-Next GGUF shards the converter takes.
    func checkNewModel() {
        guard let repository = HubModelID.parse(newRepository) else {
            newModelState = .unsuitable("Enter a Hugging Face model id like owner/name.")
            return
        }
        newModelState = .checking
        Task { newModelState = await Self.check(repository) }
    }

    /// Also setup's "Model from Hugging Face".
    static func check(_ repository: String) async -> NewModelState {
        guard let treeURL = URL(string: "https://huggingface.co/api/models/\(repository)/tree/main?recursive=true"),
              let (tree, response) = try? await URLSession.shared.data(from: treeURL) else {
            return .unsuitable("Hugging Face could not be reached.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return .unsuitable("\(repository) was not found on Hugging Face (it may be private or gated).")
        }
        let (layout, size) = ModelCheck.layout(ofTree: tree)
        switch layout {
        case .unsupported(let reason):
            return .unsuitable("\(repository) is not suitable: \(reason).")
        case .package:
            guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/main/manifest.json"),
                  let (manifest, _) = try? await URLSession.shared.data(from: url) else {
                return .unsuitable("Its manifest.json could not be read.")
            }
            if let problem = ModelCheck.problem(withManifest: manifest) {
                return .unsuitable("\(repository) is not suitable: \(problem).")
            }
        case .gguf(let shard, _):
            guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/main/\(shard)") else {
                return .unsuitable("Its GGUF files could not be read.")
            }
            var request = URLRequest(url: url)
            request.setValue("bytes=0-\(GGUFHeader.probeBytes - 1)", forHTTPHeaderField: "Range")
            let head = try? await URLSession.shared.data(for: request).0
            if let problem = ModelCheck.problem(withArchitecture: head.flatMap(GGUFHeader.architecture(in:))) {
                return .unsuitable("\(repository) is not suitable: \(problem).")
            }
        }
        guard var spec = ModelCheck.spec(repository: repository, layout: layout) else {
            return .unsuitable("\(repository) is not suitable.")
        }
        var total = size
        if !spec.extraFiles.isEmpty, let withExtras = try? await ModelDownloader.totalSize(of: spec) {
            total = withExtras
        }
        spec.title = repository.split(separator: "/").last.map(String.init) ?? repository
        return .suitable(spec, size: total)
    }
}

/// The first step of "Download Model…".
struct ModelPickerView: View {
    @ObservedObject var picker: ModelPicker
    let choose: (ModelSpec) -> Void
    let add: (ModelSpec) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a model to download").font(.headline)
            Text("This Mac has \(MachineCheck.memoryGiB) GB of memory. Slipstream runs Qwen3.8-Flash-Next "
                 + "models, which need a 64 GB Mac.")
                .font(.callout).foregroundStyle(MachineCheck.hasEnoughMemory ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(picker.models, id: \.repository) { model in
                    ModelRow(model: model, size: picker.sizes[model.repository], choose: { choose(model) })
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

            DisclosureGroup("New Model…", isExpanded: $picker.newModelOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Hugging Face model id", text: $picker.newRepository,
                                  prompt: Text("owner/name"))
                            .onSubmit { picker.checkNewModel() }
                        Button("Check") { picker.checkNewModel() }
                            .disabled(picker.newRepository.isEmpty || picker.newModelState == .checking)
                    }
                    switch picker.newModelState {
                    case .idle:
                        Text("Qwen3.8-Flash-Next only: GGUF files, or a ready-to-run Slipstream package.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .unsuitable(let reason):
                        Label(reason, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    case .suitable(let model, let size):
                        HStack {
                            Label("Suitable: \(model.kind == .package ? "ready-to-run package" : "GGUF, prepared on first start"), "
                                  + "\(bytes(size)), needs a \(model.memoryNote).", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                            Spacer()
                            Button("Download") {
                                add(model)
                                choose(model)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct ModelRow: View {
    let model: ModelSpec
    let size: Int64?
    let choose: () -> Void

    var body: some View {
        let present = ModelPresence.isAvailable(model.repository)
        let fits = MachineCheck.memoryGiB >= model.minimumMemoryGiB
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                Text("\(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…") · "
                     + "\(model.memoryNote) · \(model.kind == .package ? "ready to run" : "GGUF")")
                    .font(.caption).foregroundStyle(fits ? Color.secondary : Color.orange)
            }
            Spacer()
            if present {
                Label("Downloaded", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Download", action: choose)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
