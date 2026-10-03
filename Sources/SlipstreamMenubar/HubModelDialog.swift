import SlipstreamMenubarCore
import SwiftUI

/// The state of "Load from Hugging Face…": the pasted id and its check, by Slipstream when
/// it has `pull --check` (ModelPicker.check). Setup and Settings each own one.
@MainActor
final class HubModelChecker: ObservableObject {
    @Published var input = ""
    @Published private(set) var state: ModelPicker.NewModelState = .idle
    private let installation: () -> SlipstreamInstallation?
    private let searchPath: () -> [String]
    private var checkNumber = 0
    private var checkedInput = ""

    init(installation: @escaping () -> SlipstreamInstallation?, searchPath: @escaping () -> [String]) {
        self.installation = installation
        self.searchPath = searchPath
    }

    /// A fresh dialog, optionally with an id filled in.
    func reset(input: String = "") {
        self.input = input
        checkedInput = input
        state = .idle
    }

    func check() {
        guard let repository = HubModelID.parse(input) else {
            state = .unsuitable("That is not a Hugging Face model id. Enter it as owner/name, "
                + "or paste the model page's address.")
            return
        }
        input = repository
        checkedInput = repository
        state = .checking
        checkNumber += 1
        let number = checkNumber
        let installation = installation()
        let searchPath = searchPath()
        Task {
            let result = await ModelPicker.check(repository, installation: installation, searchPath: searchPath)
            // A newer check, or an edit since, wins.
            if number == checkNumber { state = result }
        }
    }

    /// An edit makes an earlier result stale.
    func inputChanged() {
        guard input != checkedInput else { return }
        checkedInput = input
        if case .checking = state { return }
        state = .idle
    }

    var suitableModel: ModelSpec? {
        if case .suitable(let spec, _) = state { return spec }
        return nil
    }
}

/// "Load from Hugging Face…": which id to paste, and the check of it.
struct HubModelDialog: View {
    @ObservedObject var checker: HubModelChecker
    /// Called with the checked model.
    let use: (ModelSpec) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model from Hugging Face").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste the model's Hugging Face id, **owner/name**: the part of its page address after huggingface.co/. For example:")
                Text(verbatim: "nitinpanj/qwen38-flash-next-v3")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                Text(verbatim: "Its page address works too, e.g. https://huggingface.co/nitinpanj/qwen38-flash-next-v3.")
                Text("Slipstream runs Qwen3.8-Flash-Next models: one model's GGUF files, or a "
                     + "ready-to-run Slipstream package. Slipstream checks the repository before anything "
                     + "is downloaded.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            TextField("Hugging Face model id", text: $checker.input, prompt: Text(verbatim: "owner/name"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { primary.action() }
                .onChange(of: checker.input) { checker.inputChanged() }
            status
                .frame(minHeight: 34, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(primary.title, action: primary.action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!primary.enabled)
                    .id(primary.title)  // the focus ring follows the label's size (Check → Use This Model)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var primary: (title: String, enabled: Bool, action: () -> Void) {
        switch checker.state {
        case .suitable(let spec, _): return ("Use This Model", true, { use(spec) })
        case .checking: return ("Check", false, {})
        default:
            return ("Check", !checker.input.trimmingCharacters(in: .whitespaces).isEmpty, checker.check)
        }
    }

    @ViewBuilder private var status: some View {
        switch checker.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking on Hugging Face…").foregroundStyle(.secondary)
            }
        case .unsuitable(let reason):
            InlineError(message: reason)
        case .suitable(let model, let size):
            Label {
                Text((model.kind == .package ? "A ready-to-run package" : "GGUF files, prepared on the first start")
                     + ", \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), needs a \(model.memoryNote).")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        }
    }
}
