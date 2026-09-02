import Cocoa
import WebKit
import Carbon
import Vision
import ScreenCaptureKit

// 1. Single-Instance Guard
let lockPath = "/tmp/com.swikar.stealthoverlay.lock"
let lock = open(lockPath, O_CREAT | O_WRONLY, 0o600)
if lock == -1 || flock(lock, LOCK_EX | LOCK_NB) != 0 { exit(0) }

// 2. Pure Ghost Panel (Hardware-Excluded from Screen Sharing & Recorders)
class StealthPanel: NSPanel {
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
// Electric Cyan border (HackerRank / Assessments)
contentView?.layer?.borderColor = NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.85).cgColor    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// 3. Application Controller
class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var panel: StealthPanel!
    var webView: WKWebView!
    var opacity: CGFloat = 1.0
    var questionBuffer: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let s = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = StealthPanel(rect: NSRect(x: s.minX, y: s.maxY - 720, width: 540, height: 720))
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

    // 4. Background Full-Screen Ingestion Engine
    func runOCR(isAppend: Bool = false) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let disp = content.displays.first else {
                    print("❌ ScreenCaptureKit: No active display found.")
                    return
                }

                // Strip the overlay window so it captures only the underlying browser
                let myPID = ProcessInfo.processInfo.processIdentifier
                let excludedWindows = content.windows.filter { $0.owningApplication?.processID == myPID }

                let cfg = SCStreamConfiguration()
                // No sourceRect defined: captures 100% native screen resolution
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

                guard !text.isEmpty else {
                    print("⚠️ OCR completed, but detected no text on display.")
                    return
                }

                var finalScreenDump = text

                if isAppend && !self.questionBuffer.isEmpty {
                    finalScreenDump = self.mergeTextChunks(top: self.questionBuffer, bottom: text)
                    self.questionBuffer = ""
                    print("⚡ Merged Multi-Part Screen Dump (\(finalScreenDump.count) chars). Sending to Gemini...")
                } else {
                    self.questionBuffer = text
                    print("⚡ Captured Full Screen (\(text.count) chars).")
                }

                let payload = """
                The following text is a raw full-screen OCR transcription of a coding assessment environment (e.g., HackerRank).
                It contains:
                - Left side: Problem title, description, constraints, and example I/O.
                - Right side: Code editor with pre-populated starter code, function signature, boilerplate, and class structure.
                - Interface noise: Browser tabs, editor line numbers, action buttons ("Run Code", "Submit").

                INSTRUCTIONS:
                1. Filter out all browser and platform UI noise.
                2. Identify the target problem and examine the starter code / function signature in the editor.
                3. Format your response into these exact sections:

                ### 1. PLATFORM AI COVER PROMPTS (For Section 2 & 3)
                Provide 2 senior-level diagnostic questions for HackerRank's native AI assistant (one on edge-case behavior, one on internal architecture).

                ### 2. ROOT CAUSE SUMMARY
                A 2-sentence diagnosis of the algorithmic strategy or bug.

                ### 3. COMPLETE CODE SOLUTION
                Provide the full implementation code. CRITICAL: The solution MUST match the exact function signature, parameter types, and class structure present in the editor starter code.

                ### 4. TELEMETRY PLAN
                Provide 1 test-failure step and the exact method/line to edit first.

                RAW SCREEN TRANSCRIPTION:
                \(finalScreenDump)
                """
                DispatchQueue.main.async { self.sendToGemini(payload) }
            } catch {
                print("❌ ScreenCaptureKit / Vision Error: \(error.localizedDescription)")
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

    // 5. Global Hotkeys with Accidental Key Suppression
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
            (1, kVK_ANSI_Z),           // Option + Z : Visibility Toggle
            (2, kVK_ANSI_V),           // Option + V : Clipboard Paste
            (3, kVK_ANSI_S),           // Option + S : Stop Output
            (4, kVK_ANSI_Q),           // Option + Q : Clean Quit
            (5, kVK_ANSI_Equal),       // Option + = : Scale Up
            (6, kVK_ANSI_Minus),       // Option + - : Scale Down
            (7, kVK_ANSI_LeftBracket), // Option + [ : Opacity Down
            (8, kVK_ANSI_RightBracket),// Option + ] : Opacity Up
            (9, kVK_DownArrow),        // Option + Down : Scroll Down
            (10, kVK_UpArrow),         // Option + Up : Scroll Up
            (11, kVK_ANSI_O),          // Option + O : Full-Screen Scan (Part 1)
            (12, kVK_ANSI_1),          // Option + 1 : Snap Left Flush
            (13, kVK_ANSI_2),          // Option + 2 : Snap Top-Right
            (14, kVK_ANSI_3),          // Option + 3 : Taller & Narrower
            (15, kVK_ANSI_4),          // Option + 4 : Wider & Shorter
            (16, kVK_ANSI_P)           // Option + P : Append Part 2 Scan
        ]

        for (id, code) in binds {
            let hID = EventHotKeyID(signature: OSType(0x5354), id: id)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), opt, hID, GetApplicationEventTarget(), 0, &ref)
        }

        // Accidental Key Interceptor
        let swallowKeys: [Int] = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
            kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
            kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_R, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_W,
            kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
            kVK_ANSI_9, kVK_ANSI_0, kVK_ANSI_Semicolon, kVK_ANSI_Slash, kVK_ANSI_Quote,
            kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Grave, kVK_ANSI_Backslash
        ]

        for code in swallowKeys {
            let hID = EventHotKeyID(signature: OSType(0x5354), id: 9999)
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
        case 11: runOCR(isAppend: false) // Option + O : Full-screen scan
        case 12: snap(.leftEdgeFlush)
        case 13: snap(.topRight)
        case 14: adjustShape(dw: -50, dh: +60)
        case 15: adjustShape(dw: +60, dh: -50)
        case 16: runOCR(isAppend: true)  // Option + P : Full-screen scroll append
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