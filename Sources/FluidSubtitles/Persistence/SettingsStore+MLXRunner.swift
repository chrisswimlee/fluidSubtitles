//
//  SettingsStore+MLXRunner.swift
//  Fluid
//
//  Optional local MLX caption polish. New runner keys belong here.
//

import Combine
import Foundation

extension SettingsStore {
    private enum MLXRunnerDefaults {
        static let polishEnabled = "LLMTranslationPolishEnabled"
        static let enabled = "MLXRunnerEnabled"
        static let modelID = "MLXRunnerModelID"
        static let port = "MLXRunnerPort"
    }

    var llmTranslationPolishEnabled: Bool {
        get { self.defaults.bool(forKey: MLXRunnerDefaults.polishEnabled) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: MLXRunnerDefaults.polishEnabled)
        }
    }

    /// Local MLX runner for finished Korean / English / Thai captions.
    var mlxRunnerEnabled: Bool {
        get { self.defaults.bool(forKey: MLXRunnerDefaults.enabled) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: MLXRunnerDefaults.enabled)
        }
    }

    var mlxRunnerModelID: String {
        get { MLXRunnerCatalog.resolvedModelID(self.defaults.string(forKey: MLXRunnerDefaults.modelID) ?? "") }
        set {
            objectWillChange.send()
            self.defaults.set(MLXRunnerCatalog.resolvedModelID(newValue), forKey: MLXRunnerDefaults.modelID)
        }
    }

    static let mlxRunnerPortRange: ClosedRange<Int> = 1024...65535

    var mlxRunnerPort: Int {
        get {
            let value = self.defaults.object(forKey: MLXRunnerDefaults.port) as? Int ?? MLXRunnerCatalog.defaultPort
            return min(Self.mlxRunnerPortRange.upperBound, max(Self.mlxRunnerPortRange.lowerBound, value))
        }
        set {
            objectWillChange.send()
            self.defaults.set(
                min(Self.mlxRunnerPortRange.upperBound, max(Self.mlxRunnerPortRange.lowerBound, newValue)),
                forKey: MLXRunnerDefaults.port
            )
        }
    }
}
