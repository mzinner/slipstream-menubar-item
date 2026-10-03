import Foundation

/// The first-run setup's steps, and where it stands, from what is on disk.
public enum SetupStep: Int, CaseIterable, Comparable, Sendable {
    case welcome, slipstream, model, server

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .slipstream: return "Slipstream"
        case .model: return "Model"
        case .server: return "Server"
        }
    }

    public static func < (lhs: SetupStep, rhs: SetupStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum SetupProgress {
    /// Setup opens at launch until it was completed, and only while something is missing:
    /// a Mac that already has Slipstream and its model never sees it.
    public static func isNeeded(config: ServerConfig, hasInstallation: Bool, modelPresent: Bool) -> Bool {
        !config.setupCompleted && !(hasInstallation && modelPresent)
    }

    /// Where a reopened setup continues: the first step whose result is not on disk.
    /// A chosen model whose download did not finish is chosen again (the download resumes).
    public static func firstIncompleteStep(hasInstallation: Bool, modelPresent: Bool) -> SetupStep {
        if !hasInstallation { return .welcome }
        if !modelPresent { return .model }
        return .server
    }
}
