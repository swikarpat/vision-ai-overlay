import Cocoa
import WebKit
import Carbon
import Vision
import ScreenCaptureKit
import AVFoundation

// Single-instance process lock to prevent duplicate daemon processes
let lockPath = "/tmp/com.swikar.collaboverlay.lock"
let lock = open(lockPath, O_CREAT | O_WRONLY, 0o600)
if lock == -1 || flock(lock, LOCK_EX | LOCK_NB) != 0 { exit(0) }

// Custom floating panel excluded from screen shares with dual-state mouse pass-through
class CollabPanel: NSPanel {
    var isInteractive = false

    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        sharingType = .none // Excluded from Zoom, Teams, Meet, and WebRTC screen capture
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true // Default click-through ghost mode
        isMovableByWindowBackground = true

        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 12
        contentView?.layer?.masksToBounds = true
        contentView?.layer?.borderWidth = 1.5
    }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { isInteractive }
}

// Main application controller managing UI, ScreenCaptureKit audio/video, Whisper STT, and hotkeys
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, SCStreamOutput {
    var panel: CollabPanel!
    var webView: WKWebView!
    var opacity: CGFloat = 1.0
    var questionBuffer = ""

    // 4-Mode interview assistant configuration
    enum Mode {
        case coding, systemDesign, projectDeepDive, behavioral

        var color: CGColor {
            switch self {
            case .coding:          return NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.9).cgColor // Electric Cyan
            case .systemDesign:    return NSColor(red: 0.65, green: 0.33, blue: 0.97, alpha: 0.9).cgColor // Neon Violet
            case .projectDeepDive: return NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.9).cgColor // Amber Gold
            case .behavioral:      return NSColor(red: 0.96, green: 0.25, blue: 0.37, alpha: 0.9).cgColor // Rose Red
            }
        }
    }

    var currentMode: Mode = .coding
    var isAudioListening = false, isSpeaking = false, isTranscribing = false
    var speechDuration: Double = 0, silenceDuration: Double = 0
    var audioStream: SCStream?
    var audioSamples: [Float] = []
    let audioQueue = DispatchQueue(label: "audio.q", qos: .userInitiated)

    // Lifecycle setup: Initializes HUD panel, headless WebKit view, and anti-detection scripts
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = CollabPanel(rect: NSRect(x: s.maxX - 560, y: s.maxY - 740, width: 540, height: 720))
        panel.alphaValue = opacity
        updateBorder()

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
        if let url = URL(string: "https://gemini.google.com/app") { webView.load(URLRequest(url: url)) }
        panel.orderFront(nil)
    }

    // WebKit navigation callback: Injects CSS to strip sidebars, user profile icons, and headers
    func webView(_ wv: WKWebView, didFinish n: WKNavigation!) {
        let css = "bard-sidenav,mat-sidenav,.boqGeminiUiSideNav,.side-navigation-v2,header,.top-bar,button[aria-label*='Main menu'],button[aria-label*='Google Account'],.profile-button,.user-menu{display:none!important;width:0!important;height:0!important;}main,.main-container,.conversation-container,chat-window{margin:0!important;padding:0 10px!important;width:100%!important;max-width:100%!important;}"
        wv.evaluateJavaScript("const s=document.createElement('style');s.innerHTML=`\(css)`;document.head.appendChild(s);", completionHandler: nil)
    }

    // Synchronizes the HUD border color to reflect the active mode, audio state, or interactive mode
    func updateBorder() {
        if panel.isInteractive {
            panel.contentView?.layer?.borderColor = NSColor.white.cgColor
            panel.contentView?.layer?.borderWidth = 2.5
        } else if isAudioListening {
            panel.contentView?.layer?.borderColor = NSColor(red: 0.06, green: 0.72, blue: 0.51, alpha: 0.95).cgColor // Vivid Emerald
            panel.contentView?.layer?.borderWidth = 2.0
        } else {
            panel.contentView?.layer?.borderColor = currentMode.color
            panel.contentView?.layer?.borderWidth = 1.5
        }
    }

    // Option + I: Toggles mouse event interaction, dragging, and key focus for manual sign-in / model selection
    func toggleInteractive() {
        panel.isInteractive.toggle()
        panel.ignoresMouseEvents = !panel.isInteractive
        if panel.isInteractive {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.resignKey()
        }
        updateBorder()
    }

    // Option + R: Clears local buffers and resets Gemini chat via DOM click without triggering a sign-in redirect
    func resetRound() {
        questionBuffer = ""; audioSamples.removeAll(); isSpeaking = false; speechDuration = 0; silenceDuration = 0
        try? FileManager.default.removeItem(atPath: "/tmp/collab_interviewer.wav")
        let js = "const b=document.querySelector('button[aria-label*=\"New chat\"],[data-test-id=\"new-chat-button\"],a[href=\"/app\"]');if(b)b.click();else{const e=document.querySelector('[contenteditable=\"true\"]');if(e){e.focus();document.execCommand('selectAll');document.execCommand('delete');}}"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // Option + A: Activates display-level system audio capture via ScreenCaptureKit (zero virtual audio drivers)
    func toggleAudio() {
        isAudioListening.toggle()
        updateBorder()
        guard isAudioListening, audioStream == nil else { return }

        Task {
            do {
                let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let d = c.displays.first else { return }
                let myPID = ProcessInfo.processInfo.processIdentifier
                let f = SCContentFilter(display: d, excludingWindows: c.windows.filter { $0.owningApplication?.processID == myPID })

                let cfg = SCStreamConfiguration()
                cfg.capturesAudio = true
                cfg.sampleRate = 16000
                cfg.channelCount = 1
                cfg.excludesCurrentProcessAudio = true // Prevents capturing sounds generated by overlay itself
                cfg.width = 100
                cfg.height = 100
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let s = SCStream(filter: f, configuration: cfg, delegate: nil)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                try await s.startCapture()
                self.audioStream = s
            } catch { print("Audio err: \(error)") }
        }
    }

    // ScreenCaptureKit delegate: Ingests raw PCM samples and runs RMS Voice Activity Detection (VAD)
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isAudioListening, !isTranscribing,
              let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }

        var bb: CMBlockBuffer?
        var abl = AudioBufferList()
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &bb
        ) == noErr else { return }

        var chunk: [Float] = []
        for b in UnsafeMutableAudioBufferListPointer(&abl) {
            guard let d = b.mData else { continue }
            if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                chunk.append(contentsOf: UnsafeBufferPointer(start: d.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4))
            } else if asbd.mBitsPerChannel == 16 {
                let p = d.assumingMemoryBound(to: Int16.self)
                for i in 0..<(Int(b.mDataByteSize) / 2) { chunk.append(Float(p[i]) / 32768.0) }
            }
        }
        guard !chunk.isEmpty else { return }

        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let dur = Double(chunk.count) / 16000.0

        if rms >= 0.015 {
            if !isSpeaking { isSpeaking = true; speechDuration = 0 }
            silenceDuration = 0
            speechDuration += dur
            audioSamples.append(contentsOf: chunk)
            if audioSamples.count > 480000 { audioSamples.removeFirst(80000) } // Cap buffer at 30 seconds
        } else if isSpeaking {
            silenceDuration += dur
            audioSamples.append(contentsOf: chunk)
            // Trigger question transcription when speaker pauses for >= 1.3 seconds
            if silenceDuration >= 1.3 {
                let s = audioSamples
                let spk = speechDuration
                isSpeaking = false; speechDuration = 0; silenceDuration = 0; audioSamples.removeAll()

                if spk >= 1.5 {
                    isTranscribing = true
                    DispatchQueue.global(qos: .userInitiated).async { self.processWhisper(samples: s) }
                }
            }
        }
    }

    // Offloads captured PCM audio to the local Whisper CoreML/Metal CLI on the Apple Neural Engine
    func processWhisper(samples: [Float]) {
        defer { isTranscribing = false }
        var pcm = Data()
        pcm.reserveCapacity(samples.count * 2)
        for s in samples {
            let iv = Int16(max(-1.0, min(1.0, s)) * 32767.0).littleEndian
            withUnsafeBytes(of: iv) { pcm.append(contentsOf: $0) }
        }

        let wav = makeWav(size: pcm.count) + pcm
        try? wav.write(to: URL(fileURLWithPath: "/tmp/collab_interviewer.wav"))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/whisper-engine/whisper-cli")
        p.arguments = ["-m", "/usr/local/bin/whisper-engine/ggml-base.en.bin", "-f", "/tmp/collab_interviewer.wav", "--no-timestamps", "-nt", "-t", "4"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()

        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()

        guard let txt = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return }
        let c = txt.replacingOccurrences(of: "[BLANK_AUDIO]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        if c.count >= 8 {
            let prompt = buildPrompt(input: c)
            DispatchQueue.main.async { self.sendToGemini(prompt) }
        }
    }

    // Constructs a valid 44-byte RIFF/WAVE header for standard 16kHz mono 16-bit PCM audio
    func makeWav(size: Int) -> Data {
        var h = Data("RIFF".utf8); var s = UInt32(36 + size).littleEndian; h.append(Data(bytes: &s, count: 4))
        h.append(Data("WAVEfmt ".utf8)); var ss: UInt32 = 16, f: UInt16 = 1, ch: UInt16 = 1, sr: UInt32 = 16000
        var br: UInt32 = 32000, ba: UInt16 = 2, bp: UInt16 = 16, ds = UInt32(size).littleEndian
        h.append(Data(bytes: &ss, count: 4)); h.append(Data(bytes: &f, count: 2)); h.append(Data(bytes: &ch, count: 2))
        h.append(Data(bytes: &sr, count: 4)); h.append(Data(bytes: &br, count: 4)); h.append(Data(bytes: &ba, count: 2))
        h.append(Data(bytes: &bp, count: 2)); h.append(Data("data".utf8)); h.append(Data(bytes: &ds, count: 4))
        return h
    }

    // Formats dynamic prompts tailored to the active mode and injects ContextVault ground truth when relevant
    func buildPrompt(input: String) -> String {
        let v = (try? String(contentsOfFile: NSString(string: "~/.config/overlay/ContextVault.md").expandingTildeInPath, encoding: .utf8)) ?? ""
        switch currentMode {
        case .coding:
            return "Coding Problem:\n\(input)\n\nProvide:\n### 1. CLARIFYING QUESTIONS (2 bullets)\n### 2. VERBAL APPROACH (3 bullets)\n### 3. COMPLETE CODE IMPLEMENTATION (Clean, match signatures)\n### 4. TIME & SPACE COMPLEXITY"
        case .systemDesign:
            return "System Design:\n\(input)\n\nProvide:\n### 1. 10-SEC VERBAL OPENER (Scope & constraints)\n### 2. MONOSPACE ASCII ARCHITECTURE (Clean box chars: +, -, |, >)\n### 3. DATA MODEL & SCALING\n### 4. CONCRETE NUMBERS\n### 5. FAILURE MODES & MITIGATIONS"
        case .projectDeepDive:
            return "Interviewer Question: \"\(input)\"\nGROUND TRUTH VAULT:\n\(v)\n\nAnswer strictly from ground truth:\n### 1. DIRECT ANSWER (Project A, B, or C scale)\n### 2. TECHNICAL MECHANISMS & TRADE-OFFS\n### 3. CHECK-IN QUESTION"
        case .behavioral:
            return "Behavioral Question: \"\(input)\"\nGROUND TRUTH VAULT:\n\(v)\n\nProvide a first-person STAR story:\n### 1. SITUATION & TASK (20s)\n### 2. ACTIONS TAKEN (3 concrete steps)\n### 3. QUANTIFIED RESULTS"
        }
    }

    // Option + O / Option + P: Captures full screen via ScreenCaptureKit and runs on-device OCR via Vision
    func runOCR(append: Bool = false) {
        Task {
            do {
                let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let d = c.displays.first else { return }
                let myPID = ProcessInfo.processInfo.processIdentifier
                let f = SCContentFilter(display: d, excludingWindows: c.windows.filter { $0.owningApplication?.processID == myPID })

                let cfg = SCStreamConfiguration()
                cfg.width = Int(d.width); cfg.height = Int(d.height); cfg.showsCursor = false

                let img = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])

                let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }

                let dump = append && !questionBuffer.isEmpty ? "\(questionBuffer)\n\(text)" : text
                questionBuffer = append ? "" : text

                let prompt = buildPrompt(input: dump)
                DispatchQueue.main.async { self.sendToGemini(prompt) }
            } catch { print("OCR err: \(error)") }
        }
    }

    // Injects formulated prompts into Gemini's contenteditable DOM input field and triggers submission
    func sendToGemini(_ text: String) {
        if panel.alphaValue == 0 { panel.alphaValue = opacity }
        guard let d = try? JSONSerialization.data(withJSONObject: [text]), let j = String(data: d, encoding: .utf8) else { return }
        let js = "(()=>{const e=document.querySelector('[contenteditable=\"true\"]');if(!e)return;e.focus();document.execCommand('selectAll');document.execCommand('insertText',false,\(j)[0]);e.dispatchEvent(new Event('input',{bubbles:true}));setTimeout(()=>{let s=false;document.querySelectorAll('button,[role=\"button\"]').forEach(b=>{const a=(b.getAttribute('aria-label')||'').toLowerCase();if((a.includes('send')||a.includes('submit'))&&!b.disabled){b.click();s=true;}});if(!s)e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true}));},300);})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // Registers system-wide Carbon hotkeys and intercepts unassigned keys to prevent text pollution in shared editors
    func setupHotkeys() {
        var s = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, ev, u) -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let del = Unmanaged<AppDelegate>.fromOpaque(u!).takeUnretainedValue()
            DispatchQueue.main.async { del.handleKey(hk.id) }
            return noErr
        }, 1, &s, Unmanaged.passUnretained(self).toOpaque(), nil)

        let opt = UInt32(optionKey)
        let binds: [(UInt32, Int)] = [
            (1, kVK_ANSI_Z), (2, kVK_ANSI_V), (3, kVK_ANSI_S), (4, kVK_ANSI_Q),
            (5, kVK_ANSI_Equal), (6, kVK_ANSI_Minus), (7, kVK_ANSI_LeftBracket), (8, kVK_ANSI_RightBracket),
            (9, kVK_DownArrow), (10, kVK_UpArrow), (11, kVK_ANSI_O), (12, kVK_ANSI_P),
            (13, kVK_ANSI_A), (14, kVK_ANSI_1), (15, kVK_ANSI_2), (16, kVK_ANSI_3),
            (17, kVK_ANSI_4), (18, kVK_ANSI_R), (19, kVK_ANSI_T), (20, kVK_ANSI_E),
            (21, kVK_ANSI_I) // Option + I : Interactive Mode Toggle
        ]
        for (id, code) in binds {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x434F), id: id), GetApplicationEventTarget(), 0, &ref)
        }

        // Swallows Option + Key combinations to avoid inserting special characters (e.g., ∑, å, ∂) into coding pads
        let swallow = [kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_U, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0, kVK_ANSI_Semicolon, kVK_ANSI_Slash, kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Grave, kVK_ANSI_Backslash]
        for code in swallow {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, EventHotKeyID(signature: OSType(0x434F), id: 9999), GetApplicationEventTarget(), 0, &ref)
        }
    }

    // Global hotkey routing table
    func handleKey(_ id: UInt32) {
        switch id {
        case 1: panel.alphaValue = panel.alphaValue > 0 ? 0 : opacity
        case 2: if let t = NSPasteboard.general.string(forType: .string) { sendToGemini(t) }
        case 3: webView.evaluateJavaScript("document.querySelectorAll('button').forEach(b => (b.innerText.includes('Stop') || b.getAttribute('aria-label')?.includes('Stop')) && b.click())", completionHandler: nil)
        case 4: exit(0)
        case 5: scaleWindow(1.08)
        case 6: scaleWindow(0.92)
        case 7, 8: opacity = max(0.2, min(1.0, opacity + (id == 8 ? 0.15 : -0.15))); panel.alphaValue = opacity
        case 9, 10: webView.evaluateJavaScript("window.scrollBy({top: \(id == 9 ? 400 : -400), behavior: 'smooth'})", completionHandler: nil)
        case 11: runOCR(append: false)
        case 12: runOCR(append: true)
        case 13: toggleAudio()
        case 14: currentMode = .coding; updateBorder()
        case 15: currentMode = .systemDesign; updateBorder()
        case 16: currentMode = .projectDeepDive; updateBorder()
        case 17: currentMode = .behavioral; updateBorder()
        case 18: resetRound()
        case 19: sendToGemini("Summarize your previous response into 2 ultra-concise, high-impact bullet points for an immediate 15-second verbal answer.")
        case 20: sendToGemini("Elaborate on that specific solution: drill down into low-level internals, concurrency, and failure modes.")
        case 21: toggleInteractive()
        default: break
        }
    }

    // Proportional window scaling helper
    func scaleWindow(_ d: CGFloat) {
        guard let s = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame
        let nw = max(320, min(s.width, f.width * d))
        let nh = max(300, min(s.height, f.height * d))
        f.origin.y = max(s.minY, f.maxY - nh)
        f.size = CGSize(width: nw, height: nh)
        panel.setFrame(f, display: true, animate: false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
