//
//  ASRService+CapturePause.swift
//  fluid
//
//  Pause and resume the microphone during Theater Pause.
//

import Foundation

extension ASRService {
    func setCapturePaused(_ paused: Bool) {
        self.audioCapturePipeline.setCapturePaused(paused)
    }
}
