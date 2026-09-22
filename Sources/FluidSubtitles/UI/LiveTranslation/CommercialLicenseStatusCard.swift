import SwiftUI

/// Honor-system work notice, or Licensed to {org} after a signed key.
struct CommercialLicenseStatusCard: View {
    var showsKeyField = false
    var compact = false
    var style: ThemedCardStyle = .standard

    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @State private var draft = ""
    @State private var message: String?

    var body: some View {
        if self.compact {
            self.compactBody
        } else {
            self.fullBody
        }
    }

    private var compactBody: some View {
        HStack(spacing: 8) {
            Text(self.settings.isCommerciallyLicensed ? self.title : "Personal use is free.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
            if !self.settings.isCommerciallyLicensed {
                Link("Request a commercial license", destination: FluidProduct.commercialLicenseMailURL)
                    .textLinkPointer()
                    .font(self.theme.typography.bodySmall)
                    .accessibilityIdentifier("commercial.license.request")
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("commercial.license")
    }

    private var fullBody: some View {
        ThemedCard(style: self.style, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(self.title)
                            .font(self.theme.typography.bodyStrong)
                        Text(self.detail)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }

                if !self.settings.isCommerciallyLicensed {
                    HStack(spacing: 8) {
                        Link("Request a commercial license", destination: FluidProduct.commercialLicenseMailURL)
                            .textLinkPointer()
                            .accessibilityIdentifier("commercial.license.request")
                        Link("License page", destination: FluidProduct.commercialLicenseURL)
                            .textLinkPointer()
                            .accessibilityIdentifier("commercial.license.page")
                    }
                    .font(self.theme.typography.bodySmall)
                }

                if self.showsKeyField {
                    self.keyField
                }
            }
        }
        .accessibilityIdentifier("commercial.license")
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if let record = self.settings.commercialLicenseRecord {
            return record.licensedToLine
        }
        return FluidProduct.workNoticeTitle
    }

    private var detail: String {
        if let record = self.settings.commercialLicenseRecord {
            return record.expiryLine()
        }
        if let failure = self.settings.commercialLicenseFailure {
            return failure.localizedDescription
        }
        return FluidProduct.workNotice
    }

    @ViewBuilder
    private var keyField: some View {
        if self.settings.isCommerciallyLicensed {
            Button("Remove license") {
                self.settings.removeCommercialLicense()
                self.draft = ""
                self.message = nil
            }
            .buttonStyle(.theaterText)
            .accessibilityIdentifier("commercial.license.remove")
        } else {
            TextField("Paste a commercial license key", text: self.$draft)
                .textFieldStyle(.roundedBorder)
                .font(self.theme.typography.bodySmall)
                .accessibilityIdentifier("commercial.license.field")
            HStack(spacing: 8) {
                Button("Activate") {
                    self.activate()
                }
                .buttonStyle(.theaterTextProminent)
                .disabled(self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("commercial.license.activate")
                if let message {
                    Text(message)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func activate() {
        switch self.settings.activateCommercialLicense(self.draft) {
        case .success:
            self.draft = ""
            self.message = nil
        case let .failure(failure):
            self.message = failure.localizedDescription
        }
    }
}
