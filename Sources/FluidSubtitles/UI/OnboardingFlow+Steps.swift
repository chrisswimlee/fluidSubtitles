//
//  OnboardingFlow+Steps.swift
//  fluid
//
//  Onboarding landing, language, voice, permissions, and Try Theater.
//

import AVFoundation
import SwiftUI

extension OnboardingFlowView {
    var landingStep: some View {
        GeometryReader { proxy in
            let landing = self.theme.metrics.onboardingSurface.landing

            ZStack {
                VStack(alignment: .center, spacing: self.theme.metrics.onboardingSurface.landing.sectionSpacing) {
                    FluidOnboardingLandingHero(
                        eyebrow: FluidProduct.displayName,
                        title: "Captions after each sentence.",
                        accentTitle: "Korean, English, and Thai.",
                        firstDetail: FluidProduct.manifesto,
                        secondDetail: "Open Theater, press Listen. Share the window when the audience needs another language."
                    ) {
                        FluidOnboardingLandingPrimaryButton(title: "Next") {
                            self.goNext()
                        }
                        .frame(
                            width: FluidOnboardingLandingPrimaryButton.size.width,
                            height: FluidOnboardingLandingPrimaryButton.size.height
                        )
                    }
                }
                .frame(width: landing.contentWidth, alignment: .center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .offset(y: -78)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
                .zIndex(-1)
            }
            .background {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)
            }
        }
    }

    func updateLandingGlow(location: CGPoint, in size: CGSize) {
        guard !self.reduceMotion else { return }
        guard location.x.isFinite, location.y.isFinite, size.width > 0, size.height > 0 else { return }

        let dx = location.x - self.lastLandingGlowLocation.x
        let dy = location.y - self.lastLandingGlowLocation.y
        guard (dx * dx) + (dy * dy) > (self.landingGlowMovementThreshold * self.landingGlowMovementThreshold) else { return }

        self.lastLandingGlowLocation = location
        let normalizedX = min(max(location.x / size.width, 0), 1)
        let normalizedY = min(max(location.y / size.height, 0), 1)

        withAnimation(.easeOut(duration: 0.22)) {
            self.landingGlowCenter = UnitPoint(x: normalizedX, y: normalizedY)
        }
    }

    func resetLandingGlow() {
        guard !self.reduceMotion else { return }
        self.lastLandingGlowLocation = CGPoint(x: -1000, y: -1000)

        withAnimation(.easeOut(duration: 0.35)) {
            self.landingGlowCenter = UnitPoint(x: 0.5, y: 0.18)
        }
    }

    func playLandingWelcomeSoundIfNeeded() {
        guard self.step == .landing, !self.hasPlayedLandingWelcomeSound else { return }
        Task { @MainActor in
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
            await AudioStartupGate.shared.waitUntilOpen()
            guard self.isOnboardingFlowVisible,
                  self.step == .landing,
                  self.hasPlayedLandingWelcomeSound == false
            else { return }
            self.hasPlayedLandingWelcomeSound = true
            OnboardingSoundPlayer.shared.playWelcomeSound()
        }
    }

    var languageStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("What language will\nyou speak most?")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.bottom, 18)

                            Text("fluidSubtitles works among Korean, English, and Thai. Pick the language you speak. You can swap direction anytime.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 26)

                            LazyVGrid(
                                columns: [
                                    GridItem(.fixed(166), spacing: 16),
                                    GridItem(.fixed(166), spacing: 16),
                                    GridItem(.fixed(166), spacing: 16),
                                ],
                                spacing: 16
                            ) {
                                ForEach(self.popularOnboardingLanguages) { language in
                                    self.languageChoiceCard(for: language)
                                }
                            }
                            .frame(width: 530)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Translate into")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.7))
                                Picker("Target language", selection: self.$settings.translationTargetLanguageID) {
                                    ForEach(self.onboardingTargetLanguages) { language in
                                        Text(language.displayName).tag(language.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 280)
                            }
                            .padding(.top, 22)

                            Text("Any pair among Korean, English, and Thai works. You can swap later.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .padding(.top, 18)

                            if SpokenLanguageResolver.sourceLanguage().id
                                != SpokenLanguageResolver.targetLanguage().id
                            {
                                if !self.languagePackAvailability.isEmpty {
                                    Text(self.languagePackAvailability)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.56))
                                        .padding(.top, 10)
                                }
                                Button("Download language pack") {
                                    Task {
                                        await self.refreshLanguagePackAvailability(requestDownload: true)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .padding(.top, self.languagePackAvailability.isEmpty ? 10 : 6)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
            .task {
                await self.refreshLanguagePackAvailability()
            }
            .onChange(of: self.settings.translationSourceLanguageID) { _, _ in
                Task { await self.refreshLanguagePackAvailability() }
            }
            .onChange(of: self.settings.translationTargetLanguageID) { _, _ in
                Task { await self.refreshLanguagePackAvailability() }
            }
        }
    }

    func languageChoiceCard(for language: VoiceEngineLanguage) -> some View {
        let isSelected = self.selectedLanguageID == language.id
        let isHovered = self.hoveredLanguageID == language.id
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let cardFillOpacity = isSelected
            ? (isHovered ? 0.15 : 0.075)
            : (isHovered ? 0.10 : 0.04)
        let borderColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 1 : 0.92)
            : (isHovered ? FluidOnboardingLandingColors.blue.opacity(0.58) : Color.white.opacity(0.10))
        let borderWidth: CGFloat = isSelected
            ? (isHovered ? 1.8 : 1.4)
            : (isHovered ? 1.2 : 1)
        let shadowColor = isSelected
            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.36 : 0.18)
            : FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.18 : 0)
        let shadowRadius: CGFloat = isSelected
            ? (isHovered ? 24 : 18)
            : (isHovered ? 20 : 14)

        return Button {
            self.selectOnboardingLanguage(language)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? FluidOnboardingLandingColors.blue : Color.white.opacity(0.72))
                    .frame(width: 22)

                Text(language.popularDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(FluidOnboardingLandingColors.blue)
                }
            }
            .padding(.horizontal, 15)
            .frame(width: 166, height: 58)
            .background(
                shape
                    .fill(Color.white.opacity(cardFillOpacity))
                    .overlay(
                        shape.stroke(
                            borderColor,
                            lineWidth: borderWidth
                        )
                    )
            )
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered in
            if isHovered {
                self.setHoveredLanguage(language.id)
            } else if self.hoveredLanguageID == language.id {
                self.setHoveredLanguage(nil)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    self.selectOnboardingLanguage(language)
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.displayName)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    func cinematicFooter(
        continueTitle: String,
        canContinue: Bool,
        continueAction: @escaping () -> Void,
        skipTitle: String? = nil,
        canSkip: Bool = false,
        skipAction: (() -> Void)? = nil
    ) -> some View {
        let canNavigateBack = !self.isModelPreparationInProgress && !self.asr.isRunning && !self.isRecordingAnyShortcut

        return HStack {
            self.cinematicFooterButton(
                title: "Back",
                kind: .back,
                isEnabled: canNavigateBack
            ) {
                self.goBack()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let skipTitle, let skipAction {
                self.cinematicFooterButton(
                    title: skipTitle,
                    kind: .skip,
                    isEnabled: canSkip
                ) {
                    skipAction()
                }
            }

            self.cinematicFooterButton(
                title: continueTitle,
                kind: .next,
                isEnabled: canContinue
            ) {
                continueAction()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 24)
    }

    func cinematicFooterButton(
        title: String,
        kind: OnboardingFooterButton,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isPrimary = kind == .next
        let isHovered = self.hoveredFooterButton == kind && isEnabled

        return self.onboardingPillButton(
            configuration: OnboardingPillButtonConfiguration(
                title: title,
                systemImage: nil,
                tone: isPrimary ? .primary : .secondary,
                width: 132,
                height: 48,
                fontSize: 16,
                iconSize: 14,
                isHovered: isHovered,
                isEnabled: isEnabled
            ),
            action: action
        ) { isHovered in
            self.setHoveredFooterButton(isHovered ? kind : nil)
        }
        .accessibilityLabel(title)
    }

    func setHoveredFooterButton(_ button: OnboardingFooterButton?) {
        guard self.hoveredFooterButton != button else { return }
        if self.reduceMotion {
            self.hoveredFooterButton = button
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredFooterButton = button
            }
        }
    }

    func setHoveredLanguage(_ languageID: String?) {
        guard self.hoveredLanguageID != languageID else { return }
        if self.reduceMotion {
            self.hoveredLanguageID = languageID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredLanguageID = languageID
            }
        }
    }

    func selectOnboardingLanguage(_ language: VoiceEngineLanguage) {
        guard self.selectedLanguageID != language.id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = language.id
            self.settings.onboardingSelectedLanguageID = language.id
            if let translationLanguage = TranslationLanguageCatalog.language(id: language.id) {
                self.settings.translationSourceLanguageID = translationLanguage.id
            }
            self.selectedModelRouteID = VoiceEngineLanguageCatalog.routes(for: language).first?.id
            self.isShowingOtherModelRoutes = false
            self.resetTryoutValidationForSetupChange()
        }
    }

    func syncOnboardingSelectionFromSettings() {
        let allRoutes = VoiceEngineLanguageCatalog.allLanguages()
            .flatMap { VoiceEngineLanguageCatalog.routes(for: $0) }

        let storedLanguageID = self.settings.onboardingSelectedLanguageID
        let storedLanguageRoutes = VoiceEngineLanguageCatalog.routes(forLanguageID: storedLanguageID)
        let route = storedLanguageRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        } ?? storedLanguageRoutes.first ?? allRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        }

        guard let route else {
            if self.selectedModelRouteID == nil {
                self.selectedModelRouteID = self.selectedLanguageRoutes.first?.id
            }
            return
        }

        guard self.selectedLanguageID != route.language.id || self.selectedModelRouteID != route.id else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = route.language.id
            self.selectedModelRouteID = route.id
            self.isShowingOtherModelRoutes = false
        }
    }

    var voiceModelStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: self.isShowingOtherModelRoutes) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("Choose your\nvoice engine")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 16)

                            Text(self.recommendedModelReasonText)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 14)

                            Text(self.selectedOnboardingLanguage.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FluidOnboardingLandingColors.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(FluidOnboardingLandingColors.blue.opacity(0.12))
                                        .overlay(Capsule().stroke(FluidOnboardingLandingColors.blue.opacity(0.24), lineWidth: 1))
                                )
                                .padding(.bottom, 18)

                            VStack(spacing: 10) {
                                let defaultRoutes = self.defaultDisplayedModelRoutes
                                if defaultRoutes.count == 1, let route = defaultRoutes.first {
                                    self.onboardingRouteCard(for: route)
                                } else if !defaultRoutes.isEmpty {
                                    HStack(spacing: 16) {
                                        ForEach(defaultRoutes) { route in
                                            self.onboardingRouteCard(for: route)
                                        }
                                    }
                                }

                                if !self.otherModelRoutes.isEmpty {
                                    self.otherModelRoutesToggleButton
                                }

                                if self.isShowingOtherModelRoutes {
                                    LazyVGrid(
                                        columns: [
                                            GridItem(.fixed(292), spacing: 16, alignment: .top),
                                            GridItem(.fixed(292), spacing: 16, alignment: .top),
                                        ],
                                        spacing: 16
                                    ) {
                                        ForEach(self.otherModelRoutes) { route in
                                            self.onboardingRouteCard(for: route, enablesHover: false)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .frame(width: 608)

                            if self.isModelPreparationInProgress {
                                Label("Initial preparation can take a while to get your Mac ready for near-instant transcription.", systemImage: "clock.arrow.circlepath")
                                    .font(self.theme.typography.captionStrong)
                                    .foregroundStyle(Color.white.opacity(0.58))
                                    .labelStyle(.titleAndIcon)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.86)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.06))
                                            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                                    )
                                    .padding(.top, 14)
                            }

                            Text("You can switch models later in Voice Engine settings.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .padding(.top, self.isModelPreparationInProgress ? 8 : 18)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    var permissionsStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("Let \(FluidProduct.displayName)\nhear you")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.bottom, 16)

                            Text("Microphone is required. Accessibility is only if you want a translation typed into another app.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 28)

                            VStack(spacing: 14) {
                                self.permissionRow(
                                    stepNumber: 1,
                                    title: self.isMicrophoneReady ? "Microphone access allowed" : "Allow microphone",
                                    subtitle: self.isMicrophoneReady
                                        ? "Choose the microphone you want \(FluidProduct.displayName) to use."
                                        : "macOS will ask once. Click Allow so \(FluidProduct.displayName) can hear you.",
                                    systemImage: "mic.fill",
                                    isReady: self.isMicrophoneReady,
                                    actionTitle: self.microphoneActionButtonTitle
                                ) {
                                    self.handleMicrophoneAction()
                                }

                                if self.isMicrophoneReady {
                                    OnboardingMicrophoneSetupPanel(
                                        devices: self.orderedOnboardingInputDevices,
                                        selectedUID: self.selectedOnboardingInputUID,
                                        level: self.onboardingMicrophoneLevel,
                                        errorMessage: self.asr.microphonePreviewError,
                                        onSelect: { self.selectOnboardingMicrophone(uid: $0) }
                                    )
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Optional — type into another app")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.white.opacity(0.42))

                                    self.permissionRow(
                                        stepNumber: 2,
                                        title: self.accessibilityPermissionTitle,
                                        subtitle: self.accessibilityPermissionSubtitle,
                                        systemImage: "keyboard.fill",
                                        isReady: self.isAccessibilityReady,
                                        statusTitle: self.accessibilityPermissionStatusTitle,
                                        actionTitle: self.accessibilityPermissionActionTitle
                                    ) {
                                        self.openAccessibilitySettings()
                                    }

                                    if !self.isAccessibilityReady {
                                        Text("Skip this unless you want a translation typed into another app. Theater captions do not need it.")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.white.opacity(0.42))
                                            .padding(.top, 2)
                                    }
                                }
                            }
                            .frame(width: 560)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    var playgroundStep: some View {
        GeometryReader { proxy in
            ZStack {
                FluidOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    FluidOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("Try a Theater caption.")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.74)
                                .padding(.horizontal, 32)
                                .padding(.bottom, 14)

                            Text("Open Theater and press Listen. Continue after a line appears.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 22)

                            if !self.translationController.overlayText.isEmpty {
                                Text(self.translationController.overlayText)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 420, alignment: .leading)
                                    .padding(14)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                    .padding(.bottom, 18)
                            }

                            Button {
                                PresenterCaptionController.shared.setVisible(true)
                                LiveTranslationController.shared.startCaptionListening()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "rectangle.on.rectangle")
                                    Text("Open Theater")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 200, height: 40)
                                .background(
                                    FluidOnboardingLandingColors.blue.opacity(0.92),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .onChange(of: self.translationController.subscriber.committedLines) { _, lines in
                                guard !lines.isEmpty else { return }
                                self.settings.theaterListenUsed = true
                                self.settings.onboardingPlaygroundValidated = true
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue,
                        continueAction: {
                            self.handlePrimaryAction()
                        },
                        skipTitle: "Skip",
                        canSkip: !self.asr.isRunning && !self.isRecordingAnyShortcut,
                        skipAction: {
                            self.settings.onboardingPlaygroundSkipped = true
                            self.finishSetupFromPlayground()
                        }
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                FluidOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    var microphoneActionButtonTitle: String {
        switch self.asr.micStatus {
        case .notDetermined:
            return "Allow"
        case .denied, .restricted:
            return "Open Settings"
        default:
            return "Allow"
        }
    }

    var accessibilityPermissionTitle: String {
        if self.isAccessibilityReady {
            return "Typing access is ready"
        }
        return self.accessibilitySetupInProgress ? "Finish typing access" : "Optional: type into another app"
    }

    var accessibilityPermissionSubtitle: String {
        if self.isAccessibilityReady {
            return "\(self.appDisplayName) can place text into the app you're using."
        }
        if self.accessibilitySetupInProgress {
            return "Use the floating guide to drag \(self.appDisplayName) into the Accessibility apps list."
        }
        return "Only if you want a translation typed into another app. Theater captions work without it."
    }

    var appDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    var accessibilityPermissionStatusTitle: String {
        if self.isAccessibilityReady {
            return "Ready"
        }
        return self.accessibilitySetupInProgress ? "In Settings" : "Optional"
    }

    var accessibilityPermissionActionTitle: String {
        self.accessibilitySetupInProgress ? "Show Guide" : "Open Settings"
    }

    var otherModelRoutesToggleButton: some View {
        Button {
            self.toggleOtherModelRoutes()
        } label: {
            HStack(spacing: 6) {
                Text(self.isShowingOtherModelRoutes ? "Hide other models" : "Show other models")

                Image(systemName: self.isShowingOtherModelRoutes ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.62))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.025))
                    .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(self.isShowingOtherModelRoutes ? "Hide other models" : "Show other models")
    }

    func toggleOtherModelRoutes() {
        self.isShowingOtherModelRoutes.toggle()
    }

    func isOnboardingModelSelected(_ model: SettingsStore.SpeechModel) -> Bool {
        self.settings.selectedSpeechModel == model
    }

    func isOnboardingModelReady(_ model: SettingsStore.SpeechModel) -> Bool {
        self.isOnboardingModelSelected(model) && self.asr.isAsrReady
    }

    func isOnboardingRouteReady(_ route: VoiceEngineLanguageRoute) -> Bool {
        self.isRouteSelectedInSettings(route) && self.asr.isAsrReady
    }

    func isOnboardingModelDownloaded(_ model: SettingsStore.SpeechModel) -> Bool {
        self.isOnboardingModelBundledOrInstalled(model) || (self.isOnboardingModelSelected(model) && (self.asr.isAsrReady || self.asr.modelsExistOnDisk))
    }

    func isOnboardingModelBundledOrInstalled(_ model: SettingsStore.SpeechModel) -> Bool {
        model.isInstalled
    }

    func isPreparingOnboardingModel(_ model: SettingsStore.SpeechModel) -> Bool {
        self.isOnboardingModelSelected(model) && (self.asr.isDownloadingModel || (self.asr.isLoadingModel && !self.asr.isAsrReady))
    }

    func onboardingModelActionButtonTitle(isPreparing: Bool, isDownloaded: Bool, isReady: Bool) -> String {
        if isPreparing {
            return self.asr.isLoadingModel ? "Loading..." : "Downloading..."
        }
        if isReady {
            return "Active now"
        }
        if isDownloaded {
            return "Activate"
        }
        return "Download & Activate"
    }

    func prepareOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        guard !self.asr.isRunning, !self.isModelPreparationInProgress, self.uninstallingModelRouteID == nil else { return }

        self.modelPreparationTask?.cancel()
        self.preparingModelRouteID = route.id
        self.selectOnboardingRoute(route)

        self.modelPreparationTask = Task { @MainActor in
            defer {
                self.preparingModelRouteID = nil
                self.modelPreparationTask = nil
            }

            do {
                try await self.asr.ensureAsrReady()
            } catch is CancellationError {
                DebugLogger.shared.info("Cancelled onboarding voice model setup for \(route.model.displayName)", source: "OnboardingFlowView")
            } catch {
                DebugLogger.shared.error("Failed to prepare onboarding voice model \(route.model.displayName): \(error)", source: "OnboardingFlowView")
                // Surface the failure in the UI instead of only logging it, so the user
                // isn't stuck at a disabled button. The shared ContentView alert (bound to
                // asr.showError) presents this during onboarding. See #355.
                self.asr.errorTitle = "Voice Model Setup Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
            guard !Task.isCancelled else { return }
            await self.asr.checkIfModelsExistAsync()
        }
    }

    func cancelOnboardingModelPreparation() {
        self.modelPreparationTask?.cancel()
        self.asr.cancelModelPreparation()
    }

    func uninstallOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        guard !self.asr.isRunning, !self.isModelPreparationInProgress, self.uninstallingModelRouteID == nil else { return }

        self.uninstallingModelRouteID = route.id

        Task { @MainActor in
            defer {
                self.uninstallingModelRouteID = nil
            }

            do {
                try await self.asr.clearModelCache(for: route.model)
                await self.asr.checkIfModelsExistAsync()
            } catch {
                DebugLogger.shared.error("Failed to delete onboarding voice model \(route.model.displayName): \(error)", source: "OnboardingFlowView")
                self.asr.errorTitle = "Model Delete Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    func onboardingRouteCard(
        for route: VoiceEngineLanguageRoute,
        enablesHover: Bool = true
    ) -> some View {
        let model = route.model
        let isSelected = self.isOnboardingRouteSelected(route)
        let isHovered = enablesHover && self.hoveredModelRouteID == route.id
        let isRouteActiveInSettings = self.isRouteSelectedInSettings(route)
        let isDownloaded = self.isOnboardingModelBundledOrInstalled(model) || (isRouteActiveInSettings && (self.asr.isAsrReady || self.asr.modelsExistOnDisk))
        let isPreparing = self.preparingModelRouteID == route.id || (isRouteActiveInSettings && (self.asr.isDownloadingModel || (self.asr.isLoadingModel && !self.asr.isAsrReady)))
        let isReady = self.isOnboardingRouteReady(route)
        let isUninstalling = self.uninstallingModelRouteID == route.id
        let areModelActionsBlocked = self.asr.isRunning || self.uninstallingModelRouteID != nil || self.preparingModelRouteID != nil || isPreparing || self.isModelPreparationInProgress
        let isBuiltInAppleModel = model == .appleSpeech || model == .appleSpeechAnalyzer
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let cardFill = isHovered
            ? Color(red: 0.042, green: 0.052, blue: 0.074)
            : Color(red: 0.030, green: 0.038, blue: 0.056)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(self.onboardingModelTitle(for: model))
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Image(systemName: "info.circle")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .help(self.onboardingModelTooltip(for: route))
                    .accessibilityLabel(self.onboardingModelTooltip(for: route))
            }
            .frame(height: 38, alignment: .top)

            self.onboardingModelMetadataRow(badgeText: route.badgeText)

            self.onboardingModelFeaturePanel(for: model)

            Spacer(minLength: 0)

            Divider()
                .overlay(Color.white.opacity(0.10))

            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .frame(width: 22)

                Text("Download size")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(Color.white.opacity(0.62))

                Spacer()

                Text(model.downloadSize)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
            }

            if isPreparing || isUninstalling {
                HStack(spacing: 8) {
                    self.onboardingModelPreparationStatus(isUninstalling: isUninstalling)

                    if isPreparing {
                        self.onboardingModelActionButton(
                            id: "\(route.id)-cancel",
                            title: self.asr.isCancellingModelPreparation ? "Cancelling…" : "Cancel",
                            systemImage: "xmark",
                            tone: .secondary,
                            width: 104,
                            isDisabled: self.asr.isCancellingModelPreparation
                        ) {
                            self.cancelOnboardingModelPreparation()
                        }
                    }
                }
                .frame(height: 42, alignment: .center)
            } else if isDownloaded, isBuiltInAppleModel {
                self.onboardingModelActionButton(
                    id: "\(route.id)-activate",
                    title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: true, isReady: isReady),
                    systemImage: isReady ? "checkmark" : "bolt.fill",
                    tone: .primary,
                    width: nil,
                    isDisabled: areModelActionsBlocked || isReady
                ) {
                    self.prepareOnboardingRoute(route)
                }
            } else if isDownloaded {
                HStack(spacing: 8) {
                    self.onboardingModelActionButton(
                        id: "\(route.id)-activate",
                        title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: true, isReady: isReady),
                        systemImage: isReady ? "checkmark" : "bolt.fill",
                        tone: .primary,
                        width: 124,
                        isDisabled: areModelActionsBlocked || isReady
                    ) {
                        self.prepareOnboardingRoute(route)
                    }

                    self.onboardingModelActionButton(
                        id: "\(route.id)-uninstall",
                        title: "Delete",
                        systemImage: "trash",
                        tone: .destructive,
                        width: 124,
                        isDisabled: areModelActionsBlocked
                    ) {
                        self.uninstallOnboardingRoute(route)
                    }
                }
            } else {
                self.onboardingModelActionButton(
                    id: "\(route.id)-download-activate",
                    title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: false, isReady: false),
                    systemImage: "arrow.down.circle.fill",
                    tone: .primary,
                    width: nil,
                    isDisabled: areModelActionsBlocked
                ) {
                    self.prepareOnboardingRoute(route)
                }
            }
        }
        .padding(16)
        .frame(width: 292, height: 292, alignment: .topLeading)
        .background(
            shape
                .fill(cardFill)
                .overlay(
                    shape.stroke(
                        isSelected
                            ? FluidOnboardingLandingColors.blue.opacity(isHovered ? 0.92 : 0.78)
                            : (isHovered ? Color.white.opacity(0.20) : Color.white.opacity(0.10)),
                        lineWidth: isSelected ? 1.4 : 1
                    )
                )
        )
        .shadow(color: Color.black.opacity(0.34), radius: isHovered ? 20 : 14, x: 0, y: isHovered ? 12 : 8)
        .contentShape(shape)
        .onTapGesture {
            guard !areModelActionsBlocked else { return }
            self.selectOnboardingRoute(route)
        }
        .onHover { isHovered in
            guard enablesHover else { return }
            self.setHoveredModelRoute(isHovered ? route.id : nil)
        }
    }

    func onboardingModelFeaturePanel(for model: SettingsStore.SpeechModel) -> some View {
        VStack(spacing: 10) {
            self.onboardingModelMetricRow(
                fillPercent: model.speedPercent,
                color: .yellow,
                secondaryColor: .orange,
                icon: "bolt.fill",
                label: "Speed"
            )

            self.onboardingModelMetricRow(
                fillPercent: model.accuracyPercent,
                color: Color.fluidGreen,
                secondaryColor: .cyan,
                icon: "target",
                label: "Accuracy"
            )
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Speed \(Int(model.speedPercent * 100)) percent. Accuracy \(Int(model.accuracyPercent * 100)) percent.")
    }

    func onboardingModelPreparationStatus(isUninstalling: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if self.asr.isCancellingModelPreparation {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()

                    Text("Cancelling...")
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            } else if self.asr.isDownloadingModel,
                      self.asr.modelPreparationPhase == .downloading,
                      let progress = self.asr.downloadProgress
            {
                ProgressView(value: progress)
                    .tint(FluidOnboardingLandingColors.blue)

                HStack(spacing: 6) {
                    Text(self.asr.modelPreparationStatusText)
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()

                    Text(
                        isUninstalling
                            ? "Deleting..."
                            : self.asr.modelPreparationStatusText
                    )
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func onboardingModelMetadataRow(badgeText: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let badgeText {
                Label(badgeText, systemImage: "checkmark.seal.fill")
                    .font(self.theme.typography.badge)
                    .foregroundStyle(Color.green.opacity(0.92))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(height: badgeText == nil ? 0 : 18, alignment: .leading)
    }

    func onboardingModelMetricRow(
        fillPercent: Double,
        color: Color,
        secondaryColor: Color,
        icon: String,
        label: String
    ) -> some View {
        let clampedFill = min(max(fillPercent, 0), 1)

        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(color)

                Text(label)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(width: 86, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.075))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color, secondaryColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, proxy.size.width * CGFloat(clampedFill)))
                        .overlay(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.24),
                                            Color.clear,
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                }
            }
            .frame(height: 9)

            Text("\(Int(fillPercent * 100))%")
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(fillPercent > 0 ? color : Color.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .contentTransition(.numericText())
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 18)
    }

    func onboardingModelActionButton(
        id: String,
        title: String,
        systemImage: String,
        tone: OnboardingPillButtonTone = .primary,
        width: CGFloat?,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = self.hoveredModelActionButtonID == id && !isDisabled

        return self.onboardingPillButton(
            configuration: OnboardingPillButtonConfiguration(
                title: title,
                systemImage: systemImage,
                tone: tone,
                width: width,
                height: 36,
                fontSize: 12,
                iconSize: 14,
                isHovered: isHovered,
                isEnabled: !isDisabled
            ),
            action: action
        ) { isHovered in
            self.setHoveredModelActionButton(isHovered ? id : nil)
        }
    }

    func onboardingPillButton(
        configuration: OnboardingPillButtonConfiguration,
        action: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void
    ) -> some View {
        let shape = Capsule()
        let accentColor: Color = configuration.tone == .destructive ? .red : FluidOnboardingLandingColors.blue
        let isFilledTone = configuration.tone == .primary || configuration.tone == .destructive
        let fillColor: Color = {
            switch configuration.tone {
            case .primary, .destructive:
                return accentColor.opacity(configuration.isEnabled ? 1 : 0.34)
            case .secondary:
                return Color.white.opacity(configuration.isEnabled ? (configuration.isHovered ? 0.11 : 0.07) : 0.045)
            }
        }()
        let borderColor: Color = {
            switch configuration.tone {
            case .primary, .destructive:
                return Color.white.opacity(configuration.isHovered && configuration.isEnabled ? 0.30 : 0)
            case .secondary:
                return configuration.isHovered && configuration.isEnabled ? FluidOnboardingLandingColors.blue.opacity(0.30) : Color.white.opacity(0.07)
            }
        }()
        let foregroundOpacity: Double = configuration.isEnabled ? (isFilledTone ? 1.0 : (configuration.isHovered ? 0.94 : 0.78)) : 0.42
        let shadowOpacity: Double = {
            guard configuration.isEnabled else { return 0 }
            switch configuration.tone {
            case .primary, .destructive:
                return configuration.isHovered ? 0.56 : 0.26
            case .secondary:
                return configuration.isHovered ? 0.08 : 0
            }
        }()
        let ringOpacity: Double = configuration.isHovered && configuration.isEnabled ? 0.50 : 0

        return Button {
            action()
        } label: {
            HStack(spacing: configuration.systemImage == nil ? 0 : 8) {
                if let systemImage = configuration.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: configuration.iconSize, weight: .bold))
                }

                Text(configuration.title)
                    .font(.system(size: configuration.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.white.opacity(foregroundOpacity))
            .frame(width: configuration.width, height: configuration.height)
            .frame(maxWidth: configuration.width == nil ? .infinity : nil)
            .background(
                shape
                    .fill(fillColor)
                    .overlay(shape.fill(Color.white.opacity(isFilledTone && configuration.isHovered && configuration.isEnabled ? 0.10 : 0)))
                    .overlay(shape.stroke(borderColor, lineWidth: configuration.isHovered && configuration.isEnabled ? 1.2 : 1))
                    .overlay(
                        shape
                            .stroke(accentColor.opacity(ringOpacity), lineWidth: configuration.isHovered && configuration.isEnabled ? 1.4 : 1)
                            .padding(-2)
                    )
                    .shadow(color: accentColor.opacity(shadowOpacity), radius: configuration.isHovered && configuration.isEnabled ? 16 : 9, x: 0, y: configuration.isHovered && configuration.isEnabled ? 6 : 3)
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(shape)
        .disabled(!configuration.isEnabled)
        .onHover { isHovered in
            onHover(isHovered && configuration.isEnabled)
        }
    }

    func onboardingModelTooltip(for route: VoiceEngineLanguageRoute) -> String {
        let model = route.model
        return "\(self.onboardingModelSubtitle(for: model)) - \(model.downloadSize)\n\(model.cardDescription)"
    }

    func onboardingModelTitle(for model: SettingsStore.SpeechModel) -> String {
        model.humanReadableName
    }

    func onboardingModelSubtitle(for model: SettingsStore.SpeechModel) -> String {
        switch model {
        case .parakeetTDT:
            return "Parakeet v3"
        case .parakeetTDTv2:
            return "Parakeet v2"
        case .parakeetRealtime:
            return "Parakeet Flash"
        case .cohereTranscribeSixBit:
            return "Cohere"
        case .nemotronStreaming:
            return "Nemotron Streaming"
        case .nemotronOffline:
            return "Nemotron Offline"
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return "Whisper"
        default:
            return model.displayName
        }
    }

    func permissionRow(
        stepNumber: Int,
        title: String,
        subtitle: String,
        systemImage: String,
        isReady: Bool,
        statusTitle: String? = nil,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let resolvedStatusTitle = statusTitle ?? (isReady ? "Ready" : "Needed")

        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isReady ? Color.green.opacity(0.16) : FluidOnboardingLandingColors.blue.opacity(0.12))
                    .frame(width: 46, height: 46)

                if isReady {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.green.opacity(0.92))
                } else {
                    VStack(spacing: 1) {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .bold))

                        Text("\(stepNumber)")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(FluidOnboardingLandingColors.blue)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(resolvedStatusTitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isReady ? Color.green.opacity(0.92) : FluidOnboardingLandingColors.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((isReady ? Color.green : FluidOnboardingLandingColors.blue).opacity(0.12))
                        )
                }

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(2)
            }

            Spacer()

            if !isReady {
                let actionIcon = ["Open Settings", "Show Guide"].contains(actionTitle) ? "arrow.up.right" : "hand.tap.fill"
                let buttonID = "permission-\(stepNumber)"

                self.onboardingPillButton(
                    configuration: OnboardingPillButtonConfiguration(
                        title: actionTitle,
                        systemImage: actionIcon,
                        tone: .primary,
                        width: 132,
                        height: 36,
                        fontSize: 12,
                        iconSize: 10,
                        isHovered: self.hoveredPermissionButtonID == buttonID,
                        isEnabled: true
                    ),
                    action: action
                ) { isHovered in
                    self.setHoveredPermissionButton(isHovered ? buttonID : nil)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 88)
        .background(
            shape
                .fill(Color.white.opacity(isReady ? 0.045 : 0.070))
                .overlay(
                    shape.stroke(
                        isReady ? Color.green.opacity(0.18) : FluidOnboardingLandingColors.blue.opacity(0.26),
                        lineWidth: 1
                    )
                )
        )
    }

    func isRouteModelAndLanguageSettingsSelected(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return true
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    func selectOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        let oldModel = self.settings.selectedSpeechModel
        let oldAppleSpeechLocaleIdentifier = self.settings.selectedAppleSpeechLocaleIdentifier
        let oldCohereLanguage = self.settings.selectedCohereLanguage
        let oldNemotronLanguage = self.settings.selectedNemotronLanguage

        self.selectedModelRouteID = route.id
        VoiceEngineLanguageCatalog.apply(route, to: self.settings)

        let languageChanged: Bool
        switch route.binding {
        case .automatic, .whisper:
            languageChanged = false
        case .appleSpeech:
            languageChanged = oldAppleSpeechLocaleIdentifier != self.settings.selectedAppleSpeechLocaleIdentifier
        case .cohere:
            languageChanged = oldCohereLanguage != self.settings.selectedCohereLanguage
        case .nemotron:
            languageChanged = oldNemotronLanguage != self.settings.selectedNemotronLanguage
        }

        if oldModel != self.settings.selectedSpeechModel || languageChanged {
            self.resetTryoutValidationForSetupChange()
            self.asr.resetTranscriptionProvider()
        }
    }

    func setHoveredModelRoute(_ routeID: String?) {
        guard self.hoveredModelRouteID != routeID else { return }
        if self.reduceMotion {
            self.hoveredModelRouteID = routeID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredModelRouteID = routeID
            }
        }
    }

}
