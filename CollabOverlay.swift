import Cocoa
import WebKit
import Carbon
import Vision
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// 1. Independent Instance Guard
let lockPath = "/tmp/com.swikar.collaboverlay.lock"
let lock = open(lockPath, O_CREAT | O_WRONLY, 0o600)
if lock == -1 || flock(lock, LOCK_EX | LOCK_NB) != 0 { exit(0) }

// 2. Hardware-Level Ghost HUD
class CollabPanel: NSPanel {
    init(rect: NSRect) {
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        sharingType = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 12
        contentView?.layer?.masksToBounds = true
        contentView?.layer?.borderWidth = 1.5
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// 3. Application Controller
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, SCStreamOutput {
    var panel: CollabPanel!
    var webView: WKWebView!
    var opacity: CGFloat = 1.0
    var questionBuffer: String = ""

    enum AssistantMode {
        case coding          // Option + 1: Electric Cyan
        case systemDesign    // Option + 2: Neon Violet
        case projectDeepDive // Option + 3: Amber Gold
        case behavioral      // Option + 4: Rose Red

        var borderColor: CGColor {
            switch self {
            case .coding:          return NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.9).cgColor
            case .systemDesign:    return NSColor(red: 0.65, green: 0.33, blue: 0.97, alpha: 0.9).cgColor
            case .projectDeepDive: return NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.9).cgColor
            case .behavioral:      return NSColor(red: 0.96, green: 0.25, blue: 0.37, alpha: 0.9).cgColor
            }
        }
    }

    var currentMode: AssistantMode = .coding

    // Live Audio Tap & VAD Properties
    var isAudioListening = false
    var audioStream: SCStream?
    let audioQueue = DispatchQueue(label: "com.swikar.collab.audio", qos: .userInitiated)
    var audioSamples: [Float] = []
    var isSpeaking = false
    var speechDuration: Double = 0
    var silenceDuration: Double = 0
    var isTranscribing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = CollabPanel(rect: NSRect(x: s.maxX - 560, y: s.maxY - 740, width: 540, height: 720))
        panel.alphaValue = opacity
        updateBorderColor()

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.userContentController.addUserScript(
            WKUserScript(
                source: "Object.defineProperty(navigator, 'webdriver', { get: () => undefined });",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        
        webView = WKWebView(frame: panel.contentView!.bounds, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        
        panel.contentView?.addSubview(webView)

        setupHotkeys()
        if let url = URL(string: "https://gemini.google.com/app") {
            webView.load(URLRequest(url: url))
        }
        panel.orderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let cleanupCSS = """
        const style = document.createElement('style');
        style.innerHTML = `
            bard-sidenav, mat-sidenav, .boqGeminiUiSideNav, .side-navigation-v2,
            header, .top-bar, button[aria-label*="Main menu"], 
            button[aria-label*="Google Account"], .profile-button, .user-menu { 
                display: none !important; 
                width: 0 !important; 
                height: 0 !important; 
                visibility: hidden !important; 
            }
            main, .main-container, .conversation-container, chat-window {
                margin: 0 !important; 
                padding: 0 12px !important; 
                width: 100% !important; 
                max-width: 100% !important; 
            }
        `;
        document.head.appendChild(style);
        """
        webView.evaluateJavaScript(cleanupCSS, completionHandler: nil)
    }

    // 4. Session Hygiene & Dynamic Mode Signaling
    func setMode(_ mode: AssistantMode) {
        currentMode = mode
        updateBorderColor()
        print("🔄 Mode Switched: \(mode)")
    }

    func updateBorderColor() {
        if isAudioListening {
            panel.contentView?.layer?.borderColor = NSColor(red: 0.06, green: 0.72, blue: 0.51, alpha: 0.95).cgColor
            panel.contentView?.layer?.borderWidth = 2.0
        } else {
            panel.contentView?.layer?.borderColor = currentMode.borderColor
            panel.contentView?.layer?.borderWidth = 1.5
        }
    }

    func resetRound() {
        print("🧹 Resetting Round Session & Clearing Buffers...")
        questionBuffer = ""
        audioSamples.removeAll()
        isSpeaking = false
        speechDuration = 0
        silenceDuration = 0
        try? FileManager.default.removeItem(atPath: "/tmp/collab_interviewer.wav")
        
        let js = """
        (() => {
            const btn = document.querySelector('button[aria-label*="New chat"], [data-test-id="new-chat-button"], a[href*="/app"]');
            if (btn) {
                btn.click();
            } else {
                window.location.href = "https://gemini.google.com/app";
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func loadContextVault() -> String {
        let path = NSString(string: "~/.config/overlay/ContextVault.md").expandingTildeInPath
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    // 5. Audio Tap & Voice Activity Detection
    func toggleAudioListening() {
        isAudioListening.toggle()
        updateBorderColor()
        if isAudioListening {
            print("🎙️ Audio Tap: ACTIVE")
            startAudioStreamIfNeeded()
        } else {
            print("🔇 Audio Tap: PAUSED")
        }
    }

    func startAudioStreamIfNeeded() {
        guard audioStream == nil else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let disp = content.displays.first else { return }
                
                let myPID = ProcessInfo.processInfo.processIdentifier
                let excludedWindows = content.windows.filter { $0.owningApplication?.processID == myPID }

                let filter = SCContentFilter(display: disp, excludingWindows: excludedWindows)
                let cfg = SCStreamConfiguration()
                cfg.capturesAudio = true
                cfg.sampleRate = 16000
                cfg.channelCount = 1
                cfg.excludesCurrentProcessAudio = true
                cfg.width = 100
                cfg.height = 100
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                try await stream.startCapture()
                self.audioStream = stream
            } catch {
                print("❌ Audio Stream Failed: \(error.localizedDescription)")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isAudioListening, !isTranscribing else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        var chunk: [Float] = []
        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        for buf in buffers {
            guard let data = buf.mData else { continue }
            let bytes = Int(buf.mDataByteSize)
            if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                let floatCount = bytes / MemoryLayout<Float>.size
                let ptr = data.assumingMemoryBound(to: Float.self)
                chunk.append(contentsOf: UnsafeBufferPointer(start: ptr, count: floatCount))
            } else if asbd.mBitsPerChannel == 16 {
                let intCount = bytes / MemoryLayout<Int16>.size
                let ptr = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<intCount {
                    chunk.append(Float(ptr[i]) / 32768.0)
                }
            }
        }

        guard !chunk.isEmpty else { return }

        var sumSquares: Float = 0
        for s in chunk { sumSquares += s * s }
        let rms = sqrt(sumSquares / Float(chunk.count))
        let isSilent = rms < 0.015
        let chunkDuration = Double(chunk.count) / 16000.0

        if !isSilent {
            if !isSpeaking {
                isSpeaking = true
                speechDuration = 0
            }
            silenceDuration = 0
            speechDuration += chunkDuration
            audioSamples.append(contentsOf: chunk)
            if audioSamples.count > 16000 * 30 {
                audioSamples.removeFirst(16000 * 5)
            }
        } else if isSpeaking {
            silenceDuration += chunkDuration
            audioSamples.append(contentsOf: chunk)
            
            if silenceDuration >= 1.3 {
                let capturedSpeech = audioSamples
                let totalSpoken = speechDuration
                
                isSpeaking = false
                speechDuration = 0
                silenceDuration = 0
                audioSamples.removeAll()

                if totalSpoken >= 1.5 {
                    self.isTranscribing = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.processSpokenQuestion(samples: capturedSpeech)
                    }
                }
            }
        }
    }

    func processSpokenQuestion(samples: [Float]) {
        defer { self.isTranscribing = false }

        var pcmData = Data()
        pcmData.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intVal = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: intVal) { pcmData.append(contentsOf: $0) }
        }

        let wavPath = "/tmp/collab_interviewer.wav"
        let fullWav = makeWavHeader(dataSize: pcmData.count, sampleRate: 16000) + pcmData
        do {
            try fullWav.write(to: URL(fileURLWithPath: wavPath))
        } catch {
            print("❌ WAV Write Error: \(error.localizedDescription)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/whisper-engine/whisper-cli")
        proc.arguments = [
            "-m", "/usr/local/bin/whisper-engine/ggml-base.en.bin",
            "-f", wavPath,
            "--no-timestamps",
            "-nt",
            "-t", "4"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()

            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let rawText = String(data: outData, encoding: .utf8) else { return }

            let cleaned = rawText.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                                 .replacingOccurrences(of: "(applause)", with: "")
                                 .replacingOccurrences(of: "(music)", with: "")
                                 .trimmingCharacters(in: .whitespacesAndNewlines)

            guard cleaned.count >= 8 else { return }
            print("🎯 Transcribed Question: \"\(cleaned)\" [Mode: \(currentMode)]")

            let prompt = buildPromptForCurrentMode(input: cleaned, isSpoken: true)
            DispatchQueue.main.async { self.sendToGemini(prompt) }
        } catch {
            print("❌ Whisper Execution Error: \(error.localizedDescription)")
        }
    }

    func makeWavHeader(dataSize: Int, sampleRate: Int = 16000) -> Data {
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        var chunkSize = UInt32(36 + dataSize).littleEndian
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        var subchunk1Size = UInt32(16).littleEndian
        header.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat = UInt16(1).littleEndian
        header.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = UInt16(1).littleEndian
        header.append(Data(bytes: &numChannels, count: 2))
        var sRate = UInt32(sampleRate).littleEndian
        header.append(Data(bytes: &sRate, count: 4))
        var byteRate = UInt32(sampleRate * 1 * 2).littleEndian
        header.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(2).littleEndian
        header.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample = UInt16(16).littleEndian
        header.append(Data(bytes: &bitsPerSample, count: 2))
        header.append(contentsOf: "data".utf8)
        var subchunk2Size = UInt32(dataSize).littleEndian
        header.append(Data(bytes: &subchunk2Size, count: 4))
        return header
    }

    // 6. Dynamic Multi-Mode Prompt Engine (With Calibrated ASCII System Design)
    func buildPromptForCurrentMode(input: String, isSpoken: Bool) -> String {
        let vault = loadContextVault()

        switch currentMode {
        case .coding:
            return """
            You are assisting an engineer in a live coding interview.
            INPUT:
            \(input)

            Format your response into these exact sections:
            ### 1. CLARIFYING QUESTIONS TO ASK OUT LOUD
            2 senior-level questions on constraints, edge cases, or scale.

            ### 2. VERBAL APPROACH / TALKING POINTS
            3 bullet points explaining data structures, algorithm, and trade-offs before typing.

            ### 3. COMPLETE CODE IMPLEMENTATION
            Clean, production-grade code. MUST match any pre-existing function signatures or types present in the input.

            ### 4. TIME & SPACE COMPLEXITY
            1 sentence summarizing Big-O time and auxiliary space.
            """

        case .systemDesign:
            return """
            You are assisting a Staff Distributed Systems & AI Architect in a live System Design interview.
            INPUT:
            \(input)

            Format your response into these exact sections:
            ### 1. 10-SECOND VERBAL OPENER
            A direct summary clarifying scope, scale constraints (read vs. write throughput, p99 SLA), and primary architectural bottlenecks.

            ### 2. MONOSPACE ASCII ARCHITECTURE DIAGRAM
            Provide a clean ASCII architecture diagram strictly using standard characters (+, -, |, >, [ ]).
            Do NOT use special Unicode box drawing symbols.
            Ensure lines fit cleanly within 60 columns so it pastes cleanly into CoderPad, Docs, or plain text:
            Example format:
            [Client / App] --> [CDN / Edge]
                                  |
                           [API Gateway]
                                  |
                    +-------------+-------------+
                    |                           |
             [Ingest Service]           [Query Service]
                    |                           |
             [Kafka Topic]              [Redis Cache]
                    |                           |
             [Worker Pool]              [Primary DB]

            ### 3. DATA MODEL & SCALING STRATEGY
            - Data Schema & Sharding Key: Core table keys, horizontal partitioning strategy.
            - Caching & Storage: Write policy (write-through / write-back), evictions (TTL/LRU).
            - Messaging & Concurrency: Consumer group scaling, backpressure, idempotency guarantees.

            ### 4. CONCRETE NUMBERS & SIZING
            2 specific calculations (e.g., IOPS, daily storage footprint, read/write ratio).

            ### 5. FAILURE MODES & MITIGATIONS
            2 specific mitigations (e.g., handling split-brain, replication lag, cascading timeouts).
            """

        case .projectDeepDive:
            return """
            The interviewer asked a technical deep-dive question about past engineering work:
            "\(input)"

            GROUND TRUTH RESUME & FLAGSHIP PROJECTS:
            \(vault)

            INSTRUCTIONS:
            Answer strictly using the candidate's actual projects, technologies, and metrics from the ground truth above. Never invent companies or architectures outside this scope.

            Format into these exact sections:
            ### 1. DIRECT ANSWER (Say this first — 2 to 3 sentences)
            Anchor immediately on the exact flagship project (Project A, B, or C) that matches the question. State the scale ($40M+ wire fraud, 10M+ sessions, or 50k+ TPS) and the architectural approach.

            ### 2. TECHNICAL MECHANISMS & TRADE-OFFS (Bullet points)
            - How it works internally (mention specific tools: MCP, Neo4j, FSMs, Redis, H3, Kafka, or PSI).
            - The specific failure, bottleneck, or production incident that was solved.
            - The engineering trade-off accepted.

            ### 3. CHECK-IN QUESTION (1 sentence)
            A natural closing prompt to steer the conversation deeper.
            """

        case .behavioral:
            return """
            The interviewer asked a behavioral or leadership question:
            "\(input)"

            GROUND TRUTH EXPERIENCE & STAR STORIES:
            \(vault)

            INSTRUCTIONS:
            Formulate a structured first-person STAR story based on the candidate's real career incidents from the ground truth above.

            Format into these exact sections:
            ### 1. SITUATION & TASK (20 seconds)
            The business context, scale constraints, and what made the problem difficult.

            ### 2. SPECIFIC ACTIONS TAKEN (45 seconds)
            3 clear engineering actions taken as a technical leader (architectural design, veto, or cross-functional alignment).

            ### 3. QUANTIFIED RESULTS (15 seconds)
            The concrete metrics and long-term organizational impact achieved.
            """
        }
    }

    // 7. OCR Pipeline
    func mergeTextChunks(top: String, bottom: String) -> String {
        let topLines = top.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let bottomLines = bottom.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        
        var overlapCount = 0
        let maxCheck = min(topLines.count, bottomLines.count, 8)
        
        for count in stride(from: maxCheck, through: 1, by: -1) {
            let topSlice = topLines.suffix(count)
            let bottomSlice = bottomLines.prefix(count)
            if Array(topSlice) == Array(bottomSlice) {
                overlapCount = count
                break
            }
        }
        
        let nonOverlappingBottom = bottomLines.dropFirst(overlapCount)
        return (topLines + nonOverlappingBottom).joined(separator: "\n")
    }

    func runOCR(isAppend: Bool = false) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let disp = content.displays.first else { return }

                let myPID = ProcessInfo.processInfo.processIdentifier
                let excludedWindows = content.windows.filter { $0.owningApplication?.processID == myPID }

                let cfg = SCStreamConfiguration()
                cfg.width = Int(disp.width)
                cfg.height = Int(disp.height)
                cfg.showsCursor = false

                let filter = SCContentFilter(display: disp, excludingWindows: excludedWindows)
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = false
                req.recognitionLanguages = ["en-US"]

                try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])

                let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else { return }

                var finalScreenDump = text

                if isAppend && !self.questionBuffer.isEmpty {
                    finalScreenDump = self.mergeTextChunks(top: self.questionBuffer, bottom: text)
                    self.questionBuffer = ""
                } else {
                    self.questionBuffer = text
                }

                let prompt = buildPromptForCurrentMode(input: finalScreenDump, isSpoken: false)
                DispatchQueue.main.async { self.sendToGemini(prompt) }
            } catch {
                print("❌ OCR Error: \(error.localizedDescription)")
            }
        }
    }

    func sendToGemini(_ text: String) {
        if panel.alphaValue == 0 { panel.alphaValue = opacity }
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return }

        let js = """
        (() => {
            const ed = document.querySelector('[contenteditable="true"]');
            if (!ed) return;
            ed.focus();
            document.execCommand('selectAll');
            document.execCommand('insertText', false, \(json)[0]);
            ed.dispatchEvent(new Event('input', { bubbles: true }));
            setTimeout(() => {
                let sent = false;
                document.querySelectorAll('button, [role="button"]').forEach(b => {
                    const aria = (b.getAttribute('aria-label') || '').toLowerCase();
                    if ((aria.includes('send') || aria.includes('submit')) && !b.disabled) {
                        b.click();
                        sent = true;
                    }
                });
                if (!sent) ed.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true }));
            }, 300);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // 8. Global Hotkeys & Steering Engine
    func setupHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, theEvent, userData) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(theEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let del = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { del.handleKey(hkID.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        let opt = UInt32(optionKey)

        let binds: [(UInt32, Int)] = [
            (1, kVK_ANSI_Z),           // Option + Z : Hide / Reveal
            (2, kVK_ANSI_V),           // Option + V : Direct Clipboard Prompt
            (3, kVK_ANSI_S),           // Option + S : Stop Output
            (4, kVK_ANSI_Q),           // Option + Q : Clean Quit
            (5, kVK_ANSI_Equal),       // Option + = : Scale Up
            (6, kVK_ANSI_Minus),       // Option + - : Scale Down
            (7, kVK_ANSI_LeftBracket), // Option + [ : Opacity Down
            (8, kVK_ANSI_RightBracket),// Option + ] : Opacity Up
            (9, kVK_DownArrow),        // Option + Down : Scroll Down
            (10, kVK_UpArrow),         // Option + Up : Scroll Up
            (11, kVK_ANSI_O),          // Option + O : Full-Screen Scan (Part 1)
            (12, kVK_ANSI_P),          // Option + P : Append Part 2 Scan
            (13, kVK_ANSI_A),          // Option + A : Toggle Live Audio Listener
            (14, kVK_ANSI_1),          // Option + 1 : Mode: Coding / DSA (Electric Cyan)
            (15, kVK_ANSI_2),          // Option + 2 : Mode: System & AI Design (Neon Violet)
            (16, kVK_ANSI_3),          // Option + 3 : Mode: Project Deep Dive (Amber Gold)
            (17, kVK_ANSI_4),          // Option + 4 : Mode: Behavioral / STAR (Rose Red)
            (18, kVK_ANSI_R),          // Option + R : Reset Round / New Chat Session
            (19, kVK_ANSI_T),          // Option + T : Quick Steer: Make it Shorter / TL;DR
            (20, kVK_ANSI_E)           // Option + E : Quick Steer: Elaborate / Deep Dive
        ]

        for (id, code) in binds {
            let hID = EventHotKeyID(signature: OSType(0x434F), id: id)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, hID, GetApplicationEventTarget(), 0, &ref)
        }

        // Accidental Key Interceptor (Suppresses unused letter symbols)
        let swallowKeys: [Int] = [
            kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_F,
            kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
            kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_U, kVK_ANSI_W,
            kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
            kVK_ANSI_9, kVK_ANSI_0, kVK_ANSI_Semicolon, kVK_ANSI_Slash, kVK_ANSI_Quote,
            kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Grave, kVK_ANSI_Backslash
        ]

        for code in swallowKeys {
            let hID = EventHotKeyID(signature: OSType(0x434F), id: 9999)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, hID, GetApplicationEventTarget(), 0, &ref)
        }
    }

    func handleKey(_ id: UInt32) {
        switch id {
        case 1:  panel.alphaValue = (panel.alphaValue > 0) ? 0 : opacity
        case 2:  if let t = NSPasteboard.general.string(forType: .string) { sendToGemini(t) }
        case 3:  webView.evaluateJavaScript("document.querySelectorAll('button').forEach(b => (b.innerText.includes('Stop') || b.getAttribute('aria-label')?.includes('Stop')) && b.click())", completionHandler: nil)
        case 4:  exit(0)
        case 5:  scaleWindow(delta: 1.08)
        case 6:  scaleWindow(delta: 0.92)
        case 7, 8: opacity = max(0.2, min(1.0, opacity + (id == 8 ? 0.15 : -0.15))); panel.alphaValue = opacity
        case 9, 10: webView.evaluateJavaScript("window.scrollBy({top: \(id == 9 ? 400 : -400), behavior: 'smooth'})", completionHandler: nil)
        case 11: runOCR(isAppend: false)
        case 12: runOCR(isAppend: true)
        case 13: toggleAudioListening()
        case 14: setMode(.coding)          // Option + 1
        case 15: setMode(.systemDesign)    // Option + 2
        case 16: setMode(.projectDeepDive) // Option + 3
        case 17: setMode(.behavioral)      // Option + 4
        case 18: resetRound()              // Option + R
        case 19: sendToGemini("Summarize your previous response into 2 ultra-concise, high-impact bullet points designed for an immediate 15-second verbal answer right now.") // Option + T
        case 20: sendToGemini("Elaborate on that specific solution: drill down into low-level internals, data structures, concurrency handling, and failure modes.") // Option + E
        case 9999: break
        default: break
        }
    }

    func scaleWindow(delta: CGFloat) {
        guard let s = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame
        let nw = max(320, min(s.width, f.width * delta))
        let nh = max(300, min(s.height, f.height * delta))
        f.origin.y = max(s.minY, f.maxY - nh)
        f.size = CGSize(width: nw, height: nh)
        panel.setFrame(f, display: true, animate: false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()