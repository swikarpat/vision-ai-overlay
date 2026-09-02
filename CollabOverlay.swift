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

// 2. Hardware-Level Ghost HUD (Excluded from Screen Shares & WebRTC)
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
        // Default State: Neon Violet border (Audio Listening Idle)
        contentView?.layer?.borderColor = NSColor(red: 0.65, green: 0.33, blue: 0.97, alpha: 0.85).cgColor
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

    // 4. Live Audio Tap Toggle & ScreenCaptureKit Pipeline
    func toggleAudioListening() {
        isAudioListening.toggle()
        if isAudioListening {
            // Hot state: Vivid Emerald border
            panel.contentView?.layer?.borderColor = NSColor(red: 0.06, green: 0.72, blue: 0.51, alpha: 0.95).cgColor
            panel.contentView?.layer?.borderWidth = 2.0
            print("🎙️ Audio Tap: ACTIVE (Listening to Interviewer Output)")
            startAudioStreamIfNeeded()
        } else {
            // Idle state: Revert to Neon Violet border
            panel.contentView?.layer?.borderColor = NSColor(red: 0.65, green: 0.33, blue: 0.97, alpha: 0.85).cgColor
            panel.contentView?.layer?.borderWidth = 1.5
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
                print("⚡ ScreenCaptureKit Audio Stream Initialized")
            } catch {
                print("❌ Audio Stream Failed: \(error.localizedDescription)")
            }
        }
    }

    // 5. Audio Buffer Ingestion & Voice Activity Detection (VAD)
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
            flags: 0, // Flag resolved: 0 is standard for reading the retained block buffer
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
            
            // 1.3s pause detection: Interviewer finished speaking
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

    // 6. Whisper Neural Engine Transcription & Gemini Dispatch
    func processSpokenQuestion(samples: [Float]) {
        defer { self.isTranscribing = false }

        // Safe PCM conversion: uses withUnsafeBytes to eliminate dangling pointer warning
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

            guard cleaned.count >= 10 else { return }
            print("🎯 Interviewer Question Detected: \"\(cleaned)\"")

            let prompt = """
            The interviewer just verbally asked this question in our live technical/system design session:
            "\(cleaned)"

            Provide a concise, senior-level response formatted STRICTLY for me to glance at and speak out loud naturally:

            ### 1. DIRECT 1-SENTENCE ANSWER (Say this immediately)
            A direct, confident answer to establish authority and buy 5 seconds.

            ### 2. CORE TALKING POINTS (3 bullets maximum)
            - Architecture / Data Structure / Algorithm choice and the fundamental trade-off.
            - Component interaction / scaling strategy (e.g., partitioning, caching, indexing).
            - Bottleneck mitigation (e.g., backpressure, write buffers, read replicas).

            ### 3. CONCRETE METRICS / SCALE
            Provide 2 realistic numbers, scale bounds, or Big-O complexities to mention out loud.

            ### 4. COLLABORATIVE FOLLOW-UP
            1 proactive technical question to throw back to the interviewer to keep it interactive.
            """

            DispatchQueue.main.async {
                self.sendToGemini(prompt)
            }
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

    // 7. Background Full-Screen Ingestion Engine
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

                let payload = """
                The following text is a raw full-screen OCR transcription of a live collaborative interview environment (e.g., CoderPad, CodeSignal Live, Google Docs, or HackerRank CodePair).
                It may contain:
                - Code editor tabs, video chat layout, participant lists, or terminal output.
                - Problem text pasted as inline code comments, side docs, or instructions.
                - Existing starter code, imports, and function signatures.

                INSTRUCTIONS:
                1. Filter out all collaborative tool UI noise (names, chat, buttons, line numbers).
                2. Identify the core coding problem and extract any existing code boilerplate/function signature.
                3. Format your response into these exact sections:

                ### 1. QUESTIONS TO ASK OUT LOUD (Say this to the interviewer first)
                Provide 2 concise, senior-level clarifying questions (input constraints, null/empty edge cases, scale).

                ### 2. VERBAL APPROACH / TALKING POINTS
                Give 3 bullet points explaining the core algorithmic strategy and chosen data structures to speak through before typing code.

                ### 3. COMPLETE CODE SOLUTION
                Production-ready, clean code implementation. MUST match any pre-existing function signature, class name, or parameter types found in the editor.

                ### 4. TIME & SPACE COMPLEXITY
                State Big-O time and auxiliary space in 1 sentence to explain when finished.

                ### 5. EDGE CASES TO WALK THROUGH TOGETHER
                List 2 quick test scenarios (e.g., duplicates, single-element input) to trace aloud with the interviewer.

                RAW SCREEN TRANSCRIPTION:
                \(finalScreenDump)
                """
                DispatchQueue.main.async { self.sendToGemini(payload) }
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

    // 8. Global Hotkeys with Dedicated Audio Trigger
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
            (3, kVK_ANSI_S),           // Option + S : Stop Generation
            (4, kVK_ANSI_Q),           // Option + Q : Clean Quit
            (5, kVK_ANSI_Equal),       // Option + = : Scale Up
            (6, kVK_ANSI_Minus),       // Option + - : Scale Down
            (7, kVK_ANSI_LeftBracket), // Option + [ : Opacity Down
            (8, kVK_ANSI_RightBracket),// Option + ] : Opacity Up
            (9, kVK_DownArrow),        // Option + Down : Scroll Down
            (10, kVK_UpArrow),         // Option + Up : Scroll Up
            (11, kVK_ANSI_O),          // Option + O : Full-Screen Scan (Part 1)
            (12, kVK_ANSI_1),          // Option + 1 : Snap Left Flush
            (13, kVK_ANSI_2),          // Option + 2 : Snap Top Right Corner
            (14, kVK_ANSI_3),          // Option + 3 : Taller & Narrower
            (15, kVK_ANSI_4),          // Option + 4 : Wider & Shorter
            (16, kVK_ANSI_P),          // Option + P : Append Part 2 Scan
            (17, kVK_ANSI_A)           // Option + A : Toggle Live Audio Listener
        ]

        for (id, code) in binds {
            let hID = EventHotKeyID(signature: OSType(0x434F), id: id)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, hID, GetApplicationEventTarget(), 0, &ref)
        }

        // Accidental Key Interceptor (Excludes 'A' as it triggers our audio toggle)
        let swallowKeys: [Int] = [
            kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
            kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
            kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_R, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_W,
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
        case 12: snap(.leftEdgeFlush)
        case 13: snap(.topRight)
        case 14: adjustShape(dw: -50, dh: +60)
        case 15: adjustShape(dw: +60, dh: -50)
        case 16: runOCR(isAppend: true)
        case 17: toggleAudioListening()
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

    func adjustShape(dw: CGFloat, dh: CGFloat) {
        guard let s = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame
        let nw = max(300, min(s.width, f.width + dw))
        let nh = max(260, min(s.height, f.height + dh))
        let dy = nh - f.height
        f.origin.y = max(s.minY, f.origin.y - dy)
        f.size = CGSize(width: nw, height: nh)
        if f.maxX > s.maxX { f.origin.x = s.maxX - f.width }
        if f.minX < s.minX { f.origin.x = s.minX }
        panel.setFrame(f, display: true, animate: false)
    }

    enum Position { case leftEdgeFlush, topRight }
    func snap(_ pos: Position) {
        guard let s = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame
        switch pos {
        case .leftEdgeFlush:
            f.origin = NSPoint(x: s.minX, y: s.maxY - f.height)
        case .topRight:
            f.origin = NSPoint(x: s.maxX - f.width, y: s.maxY - f.height)
        }
        panel.setFrame(f, display: true, animate: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()