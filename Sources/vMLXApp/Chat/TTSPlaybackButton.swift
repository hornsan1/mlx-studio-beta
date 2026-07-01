// SPDX-License-Identifier: Apache-2.0
//
// TTSPlaybackButton — read assistant messages aloud.
//
// Parity with panel/src/renderer/src/components/chat/VoiceChat.tsx
// `TTSPlayer` (used by MessageBubble.tsx). The Electron panel has had
// this since 2026-Q1; the Swift app shipped `EngineTTS.swift` on the
// server side but no client UI was wired to it. Closing the gap so a
// Swift-app user can have assistant replies read aloud the same way
// panel users can.
//
// Flow:
//   1. Tap → POST /v1/audio/speech with the assistant message text.
//   2. Server returns wav bytes from EngineTTS. NOTE: the neural Kokoro
//      backend is not live yet — the server currently ships
//      `PlaceholderSynth`, which returns deterministic tone bursts, and
//      advertises this via the `X-vMLX-TTS-Backend: placeholder-tone`
//      response header. We read that header and reflect the real backend
//      in the button's help text so the UI never claims "speech" when the
//      user is actually hearing a placeholder tone (REVIEW HIGH-3).
//   3. AVAudioPlayer plays the buffer; tap again to stop early.
//
// Defaults match the panel: model = "kokoro", voice = "af_heart",
// speed = 1.0. The panel's TTSPlayer reads these from the user's
// settings store; we read them from the same Swift-side settings
// (`SessionConfig.ttsModel`/`ttsVoice`/`ttsSpeed`) when available.
import AVFoundation
import Foundation
import SwiftUI
import vMLXTheme

@MainActor
final class TTSPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var isFetching = false
    @Published var lastError: String?
    /// The backend the server actually used, from `X-vMLX-TTS-Backend`.
    /// nil until the first successful request. Values: "kokoro" (real
    /// neural speech) or "placeholder-tone…" (deterministic tone, NOT
    /// speech). Drives honest help text (REVIEW HIGH-3).
    @Published var backend: String?

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    func toggle(text: String, port: Int) {
        if isPlaying {
            stop()
        } else {
            play(text: text, port: port)
        }
    }

    func play(text: String, port: Int) {
        stop()
        lastError = nil
        isFetching = true
        let body: [String: Any] = [
            "model": "kokoro",
            "input": text,
            "voice": "af_heart",
            "speed": 1.0,
            "response_format": "wav",
        ]
        guard
            let bodyData = try? JSONSerialization.data(withJSONObject: body),
            let url = URL(string: "http://127.0.0.1:\(port)/v1/audio/speech")
        else {
            lastError = "Bad TTS request"
            isFetching = false
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        task = Task { [weak self] in
            do {
                let (data, resp) = try await URLSession.shared.upload(for: req, from: bodyData)
                await MainActor.run {
                    guard let self else { return }
                    self.isFetching = false
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
                        self.lastError = "TTS HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(snippet)"
                        return
                    }
                    // Record the real backend so the UI can be honest about
                    // whether the user is hearing speech or a placeholder tone.
                    self.backend = http.value(forHTTPHeaderField: "X-vMLX-TTS-Backend")
                    do {
                        let p = try AVAudioPlayer(data: data)
                        p.delegate = self
                        if p.play() {
                            self.player = p
                            self.isPlaying = true
                        } else {
                            self.lastError = "AVAudioPlayer.play returned false"
                        }
                    } catch {
                        self.lastError = "Audio decode failed: \(error.localizedDescription)"
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isFetching = false
                    self.lastError = "TTS fetch error: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let p = player, p.isPlaying { p.stop() }
        player = nil
        isPlaying = false
        isFetching = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.player = nil
        }
    }
}

@MainActor
struct TTSPlaybackButton: View {
    let text: String
    let isGenerating: Bool
    @StateObject private var controller = TTSPlaybackController()
    @AppStorage("vmlx.gatewayPort") private var gatewayPortStorage: Int = 8080

    var body: some View {
        Button {
            controller.toggle(text: text, port: gatewayPortStorage)
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundStyle(isGenerating
                                 ? Theme.Colors.textLow.opacity(0.4)
                                 : (controller.isPlaying ? Theme.Colors.accent : Theme.Colors.textLow))
        }
        .buttonStyle(.plain)
        .disabled(isGenerating || text.isEmpty || controller.isFetching)
        .help(helpText)
    }

    private var iconName: String {
        if controller.isFetching { return "ellipsis" }
        return controller.isPlaying ? "stop.circle" : "speaker.wave.2"
    }

    private var isPlaceholderBackend: Bool {
        (controller.backend ?? "").hasPrefix("placeholder")
    }

    private var helpText: String {
        if let err = controller.lastError { return err }
        // Honest labeling (REVIEW HIGH-3): the neural Kokoro backend is not
        // live yet. Only claim "speech" once the server reports a real
        // backend; otherwise say it's a placeholder tone.
        if controller.isFetching {
            return isPlaceholderBackend ? "Generating placeholder tone…" : "Generating audio…"
        }
        if controller.isPlaying {
            return isPlaceholderBackend ? "Stop (placeholder tone — not speech yet)" : "Stop playback"
        }
        switch controller.backend {
        case .some(let b) where b.hasPrefix("placeholder"):
            return "Play placeholder tone (neural TTS not available yet)"
        case .some("kokoro"):
            return "Read aloud (Kokoro TTS)"
        default:
            // Backend unknown until first request — don't over-promise.
            return "Read aloud"
        }
    }
}
