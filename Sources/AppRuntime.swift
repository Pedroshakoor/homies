import AppKit
import AVFoundation
import Carbon
import Combine

@MainActor final class AppRuntime: ObservableObject {
    static let shared = AppRuntime()
    let context = ContextController()
    let voice = VoiceController()
    @Published var keyCode: UInt32 = 49
    @Published var modifiers: UInt32 = 786432
    @Published var error: String?
    var label: String { modifiers == 393216 ? "⌃⇧ Space" : modifiers == 1179648 ? "⌘⇧ Space" : "⌃⌥ Space" }
    var selectedAgent: (() -> AgentModel?)?
    var showPanel: (() -> Void)?
    private var hotkey: GlobalHotKey?
    private var captureHotkey: GlobalHotKey?
    private var voiceAgent: AgentModel?
    private var autoSend = false
    private var starting = false
    private var released = false
    private var finishing = false
    func configure() {
        let defaults = UserDefaults.standard
        let saved = defaults.integer(forKey: "voiceModifiers")
        if saved != 0 { modifiers = UInt32(saved) }
        setHotkey(keyCode: keyCode, modifiers: modifiers)
        do {
            let capture = try GlobalHotKey(keyCode: 49, modifiers: UInt32(controlKey | optionKey | shiftKey))
            capture.onPress = { [weak self] in
                guard let self, let agent = self.selectedAgent?(), !agent.isRunning else { return }
                let selected = self.context.currentSelection()
                Task {
                    do {
                        guard let target = try await self.context.listCaptureTargets().first(where: { $0.kind == "display" }) else { throw AppError.message("No screen available.") }
                        let screenshot = try await self.context.capture(targetID: target.id, agentID: agent.id)
                        agent.attachments.append(Attachment(url: screenshot))
                        if let selected, !selected.isEmpty { agent.draftOrigin = ""; agent.draft += (agent.draft.isEmpty ? "" : "\n") + selected }
                        self.showPanel?(); agent.send()
                    } catch { agent.error = error.localizedDescription; self.showPanel?() }
                }
            }
            captureHotkey = capture
        } catch { self.error = error.localizedDescription }
    }
    func setHotkey(keyCode: UInt32, modifiers: UInt32) {
        guard keyCode == 49, [786432, 393216, 1179648].contains(modifiers) else { return }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        do {
            if let hotkey { try hotkey.register(keyCode: keyCode, modifiers: carbon) }
            else {
                let binding = try GlobalHotKey(keyCode: keyCode, modifiers: carbon)
                binding.onPress = { [weak self] in
                    guard let self, let agent = self.selectedAgent?() else { return }
                    self.showPanel?(); self.startVoice(agent: agent, autoSend: true)
                }
                binding.onRelease = { [weak self] in self?.stopVoice() }
                hotkey = binding
            }
            self.keyCode = keyCode; self.modifiers = modifiers; error = nil
            UserDefaults.standard.set(Int(modifiers), forKey: "voiceModifiers")
        } catch { self.error = error.localizedDescription }
    }
    func startVoice(agent: AgentModel, autoSend: Bool = false) {
        guard !starting, !finishing, voice.state != .recording, voice.state != .transcribing, !agent.isRunning else { return }
        starting = true; released = false; self.autoSend = autoSend; voiceAgent = agent
        Task {
            await voice.startRecording()
            starting = false
            if released { stopVoice() }
        }
    }
    func stopVoice() {
        if starting { released = true; return }
        guard !finishing, voice.state == .recording else { return }
        finishing = true
        Task {
            defer { finishing = false }
            await voice.stopRecording()
            guard let agent = voiceAgent else { return }
            do {
                if let url = voice.audioURL {
                    let copy = try context.importFiles([url], agentID: agent.id).first!
                    let file = try AVAudioFile(forReading: copy)
                    agent.pendingVoice = VoiceNote(duration: Double(file.length) / file.processingFormat.sampleRate, audioURL: copy, transcript: voice.transcript)
                }
                if let transcript = voice.transcript, !transcript.isEmpty {
                    agent.draftOrigin = ""; agent.draft = agent.draft.isEmpty ? transcript : agent.draft + "\n" + transcript
                    if autoSend { agent.send() }
                } else if let message = voice.error { agent.error = message }
            } catch { agent.error = error.localizedDescription }
        }
    }
    func captureSelection(agent: AgentModel) {
        if let selected = context.currentSelection(), !selected.isEmpty {
            agent.draftOrigin = ""; agent.draft += (agent.draft.isEmpty ? "" : "\n") + selected
        } else { agent.error = "Select text in another app or copy it first, then capture selection." }
    }
}
