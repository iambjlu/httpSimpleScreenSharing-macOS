
import SwiftUI
import ScreenCaptureKit
import Network
import CoreGraphics
import AppKit
import CoreImage
import Foundation
import Combine
import VideoToolbox

// MARK: - App

@main
struct ScreenStreamerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// MARK: - JS keyCode -> macOS CGKeyCode

private let jsCodeToMacKey: [String: CGKeyCode] = [
    "KeyA":0, "KeyS":1, "KeyD":2, "KeyF":3, "KeyH":4, "KeyG":5,
    "KeyZ":6, "KeyX":7, "KeyC":8, "KeyV":9, "KeyB":11, "KeyQ":12,
    "KeyW":13, "KeyE":14, "KeyR":15, "KeyY":16, "KeyT":17,
    "Digit1":18, "Digit2":19, "Digit3":20, "Digit4":21, "Digit6":22,
    "Digit5":23, "Equal":24, "Digit9":25, "Digit7":26, "Minus":27,
    "Digit8":28, "Digit0":29, "BracketRight":30, "KeyO":31, "KeyU":32,
    "BracketLeft":33, "KeyI":34, "KeyP":35, "Enter":36, "KeyL":37,
    "KeyJ":38, "Quote":39, "KeyK":40, "Semicolon":41, "Backslash":42,
    "Comma":43, "Slash":44, "KeyN":45, "KeyM":46, "Period":47,
    "Tab":48, "Space":49, "Backquote":50, "Backspace":51,
    "Escape":53, "MetaLeft":55, "MetaRight":54,
    "ShiftLeft":56, "CapsLock":57, "AltLeft":58, "ControlLeft":59,
    "ShiftRight":60, "AltRight":61, "ControlRight":62,
    "F1":122, "F2":120, "F3":99, "F4":118, "F5":96, "F6":97,
    "F7":98, "F8":100, "F9":101, "F10":109, "F11":103, "F12":111,
    "F13":105, "F14":107, "F15":113, "F16":106, "F17":64,
    "Home":115, "End":119, "PageUp":116, "PageDown":121,
    "Delete":117, "Insert":114,
    "ArrowLeft":123, "ArrowRight":124, "ArrowDown":125, "ArrowUp":126,
    "NumpadDecimal":65, "NumpadMultiply":67, "NumpadAdd":69,
    "NumpadSubtract":78, "NumpadDivide":75, "NumpadEnter":76,
    "Numpad0":82, "Numpad1":83, "Numpad2":84, "Numpad3":85,
    "Numpad4":86, "Numpad5":87, "Numpad6":88, "Numpad7":89,
    "Numpad8":91, "Numpad9":92,
]

// MARK: - Capture Manager

final class CaptureManager: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var latestImage: NSImage?
    @Published var isCapturing = false

    var onJpegFrame: ((Data) -> Void)?
    var onH264Frame: ((Data) -> Void)?

    // Adjustable by client messages (accessed from capture queue + ws queue — benign race on value types)
    var jpegQuality: Double = 0.75
    var limitTo1080p: Bool  = false
    var encodeH264:   Bool  = false {
        didSet {
            if encodeH264 { h264Encoder.setup(width: captureWidth, height: captureHeight) }
            else           { h264Encoder.teardown() }
        }
    }

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false,
                                               .cacheIntermediates: false])
    let h264Encoder = H264Encoder()
    private var captureWidth  = 1920
    private var captureHeight = 1080
    private var lastUIUpdate = Date.distantPast
    private var storedDisplay: SCDisplay?
    private var storedWindow:  SCWindow?

    func start(display: SCDisplay, fps: Int) throws {
        storedDisplay = display; storedWindow = nil
        captureWidth  = Int(display.width); captureHeight = Int(display.height)
        if encodeH264 { h264Encoder.setup(width: captureWidth, height: captureHeight) }
        stop()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = makeConfig(width: captureWidth, height: captureHeight, fps: fps)
        try launch(filter: filter, config: cfg)
    }

    func start(window: SCWindow, fps: Int) throws {
        storedDisplay = nil; storedWindow = window
        captureWidth  = Int(window.frame.width); captureHeight = Int(window.frame.height)
        if encodeH264 { h264Encoder.setup(width: captureWidth, height: captureHeight) }
        stop()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = makeConfig(width: captureWidth, height: captureHeight, fps: fps)
        try launch(filter: filter, config: cfg)
    }

    func restartWithFps(_ fps: Int) {
        if let d = storedDisplay { try? start(display: d, fps: fps) }
        else if let w = storedWindow { try? start(window: w, fps: fps) }
    }

    private func makeConfig(width: Int, height: Int, fps: Int) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = false
        cfg.minimumFrameInterval = CMTime(value: 1,
                                          timescale: CMTimeScale(max(1, min(fps, 60))))
        cfg.width  = width
        cfg.height = height
        return cfg
    }

    private func launch(filter: SCContentFilter, config: SCStreamConfiguration) throws {
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        stream = s
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try s.startCapture()
        DispatchQueue.main.async { self.isCapturing = true }
    }

    func stop() {
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        h264Encoder.teardown()
        DispatchQueue.main.async { self.isCapturing = false }
    }

    // Called on captureQueue for every frame
    func stream(_ stream: SCStream,
                didOutputSampleBuffer buf: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              let pb = CMSampleBufferGetImageBuffer(buf) else { return }

        // H264 path — encode raw pixel buffer (no 1080p limit; bitrate handles bandwidth)
        if encodeH264 {
            h264Encoder.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(buf))
        }

        // JPEG path — always runs (web viewer + SwiftUI preview)
        var ci = CIImage(cvPixelBuffer: pb)

        if limitTo1080p && ci.extent.height > 1080 {
            let scale = 1080.0 / ci.extent.height
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }

        let rep = NSBitmapImageRep(cgImage: cg)
        if let jpeg = rep.representation(using: .jpeg,
                                         properties: [.compressionFactor: jpegQuality]) {
            onJpegFrame?(jpeg)
        }

        // Throttle the small SwiftUI preview to ~10 fps
        let now = Date()
        if now.timeIntervalSince(lastUIUpdate) > 0.1 {
            lastUIUpdate = now
            let sz  = NSSize(width: ci.extent.width, height: ci.extent.height)
            let img = NSImage(cgImage: cg, size: sz)
            DispatchQueue.main.async { self.latestImage = img }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.isCapturing = false }
    }
}

// MARK: - H.264 Encoder (VideoToolbox)

final class H264Encoder {
    var onEncodedData: ((Data) -> Void)?
    private var session: VTCompressionSession?

    func setup(width: Int, height: Int) {
        teardown()
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: vtOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &s)
        guard st == noErr, let s else { return }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        let bps = 4_000_000 as CFNumber
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let s = session else { return }
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb,
                                         presentationTimeStamp: pts, duration: .invalid,
                                         frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    func teardown() {
        if let s = session { VTCompressionSessionInvalidate(s); session = nil }
    }

    fileprivate func handleOutput(_ sb: CMSampleBuffer) {
        guard let data = annexB(from: sb) else { return }
        onEncodedData?(data)
    }

    private func annexB(from sb: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let cfArr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
        let isKey: Bool
        if let cfArr, let arr = cfArr as? [[CFString: Any]], let first = arr.first {
            isKey = first[kCMSampleAttachmentKey_NotSync] as? Bool != true
        } else { isKey = true }

        let sc: [UInt8] = [0, 0, 0, 1]
        var out = Data()

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var n = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil)
            for i in 0..<n {
                var p: UnsafePointer<UInt8>?; var pLen = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &p,
                    parameterSetSizeOut: &pLen, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let p { out.append(contentsOf: sc); out.append(p, count: pLen) }
            }
        }

        var total = 0
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &total, dataPointerOut: nil)
        var raw = [UInt8](repeating: 0, count: total)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &raw)
        var o = 0
        while o + 4 <= total {
            let len = Int(raw[o]) << 24 | Int(raw[o+1]) << 16 | Int(raw[o+2]) << 8 | Int(raw[o+3])
            o += 4
            guard len > 0, o + len <= total else { break }
            out.append(contentsOf: sc); out.append(contentsOf: raw[o..<o+len])
            o += len
        }
        return out.isEmpty ? nil : out
    }
}

private let vtOutputCallback: VTCompressionOutputCallback = { ref, _, status, _, sb in
    guard status == noErr, let sb, let ref else { return }
    Unmanaged<H264Encoder>.fromOpaque(ref).takeUnretainedValue().handleOutput(sb)
}

// MARK: - Port utility

private func pidsListening(on port: UInt16) -> [pid_t] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    proc.arguments = ["-ti", ":\(port)", "-sTCP:LISTEN"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError  = Pipe()
    try? proc.run(); proc.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").compactMap { pid_t($0) }
}

// MARK: - WebSocket Server  (frames out, input events in)

final class WebSocketServer: ObservableObject {
    @Published var isRunning   = false
    @Published var clientCount = 0
    @Published var portError:  String?
    @Published var blockedPIDs: [pid_t] = []

    var inputEnabled   = true
    var captureBounds  = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    weak var captureManager: CaptureManager?

    private var listener: NWListener?
    private var clients:     [ObjectIdentifier: NWConnection] = [:]
    private var h264Clients: Set<ObjectIdentifier> = []         // connections that negotiated H264
    private let lock  = NSLock()
    private let queue = DispatchQueue(label: "ws", qos: .userInteractive)

    func start(port: UInt16) {
        portError = nil; blockedPIDs = []
        let params  = NWParameters.tcp
        let wsOpts  = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)

        guard let l = try? NWListener(using: params,
                                       on: NWEndpoint.Port(rawValue: port)!) else { return }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler   = { [weak self] s in
            DispatchQueue.main.async {
                switch s {
                case .ready:
                    self?.isRunning = true; self?.portError = nil; self?.blockedPIDs = []
                case .failed:
                    self?.isRunning = false
                    let pids = pidsListening(on: port)
                    self?.portError  = "WS port \(port) 已被佔用"
                    self?.blockedPIDs = pids
                default: break
                }
            }
        }
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel(); listener = nil
        lock.lock(); let all = clients; clients.removeAll(); h264Clients.removeAll(); lock.unlock()
        all.values.forEach { $0.cancel() }
        DispatchQueue.main.async { self.isRunning = false; self.clientCount = 0; self.portError = nil; self.blockedPIDs = [] }
    }

    func broadcastJpeg(_ jpeg: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx  = NWConnection.ContentContext(identifier: "f", metadata: [meta])
        lock.lock(); let conns = clients.filter { !h264Clients.contains($0.key) }.map(\.value); lock.unlock()
        for c in conns {
            c.send(content: jpeg, contentContext: ctx, isComplete: true, completion: .idempotent)
        }
    }

    func broadcastH264(_ annexB: Data) {
        guard !h264Clients.isEmpty else { return }
        // 1-byte prefix 0x48 ('H') + Annex B payload
        var frame = Data([0x48]); frame.append(annexB)
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx  = NWConnection.ContentContext(identifier: "h", metadata: [meta])
        lock.lock(); let conns = clients.filter { h264Clients.contains($0.key) }.map(\.value); lock.unlock()
        for c in conns {
            c.send(content: frame, contentContext: ctx, isComplete: true, completion: .idempotent)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock(); clients[id] = connection; lock.unlock()
        DispatchQueue.main.async { self.clientCount = self.clients.count }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.lock.lock()
                self.clients.removeValue(forKey: id)
                self.h264Clients.remove(id)
                let anyH264 = !self.h264Clients.isEmpty
                self.lock.unlock()
                if !anyH264 { self.captureManager?.encodeH264 = false }
                DispatchQueue.main.async { self.clientCount = self.clients.count }
            default: break
            }
        }
        recv(connection, id: id)
        connection.start(queue: queue)
    }

    private func recv(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, ctx, _, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty,
               let meta = ctx?.protocolMetadata(
                   definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .text,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handleInput(json, from: id, connection: connection)
            }
            self.recv(connection, id: id)
        }
    }

    // MARK: Input injection

    private func handleInput(_ json: [String: Any], from id: ObjectIdentifier, connection: NWConnection) {
        guard let type = json["type"] as? String else { return }

        // Settings messages — handle regardless of inputEnabled
        switch type {
        case "hello":
            let codecs = json["codecs"] as? [String] ?? []
            if codecs.contains("h264") {
                lock.lock(); h264Clients.insert(id); lock.unlock()
                captureManager?.encodeH264 = true
                let resp = #"{"type":"codec","codec":"h264"}"#
                let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                let ctx  = NWConnection.ContentContext(identifier: "r", metadata: [meta])
                connection.send(content: Data(resp.utf8), contentContext: ctx,
                                isComplete: true, completion: .idempotent)
            } else {
                let resp = #"{"type":"codec","codec":"jpeg"}"#
                let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                let ctx  = NWConnection.ContentContext(identifier: "r", metadata: [meta])
                connection.send(content: Data(resp.utf8), contentContext: ctx,
                                isComplete: true, completion: .idempotent)
            }
            return
        case "setQuality":
            if let q = json["quality"] as? Int {
                captureManager?.jpegQuality = Double(q) / 100.0
            }
            return
        case "setFps":
            if let fps = json["fps"] as? Int {
                captureManager?.restartWithFps(fps)
            }
            return
        case "setMaxResolution":
            if let limit = json["limit1080p"] as? Bool {
                captureManager?.limitTo1080p = limit
            }
            return
        default: break
        }

        guard inputEnabled else { return }
        let b = captureBounds

        switch type {

        case "mousemove":
            let pt = cgPoint(json, bounds: b)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: pt, mouseButton: .left)?
                .post(tap: .cghidEventTap)

        case "mousedown", "mouseup":
            let pt     = cgPoint(json, bounds: b)
            let btn    = json["button"] as? Int ?? 0
            let isDown = type == "mousedown"
            let (evtType, mouseBtn): (CGEventType, CGMouseButton) = {
                switch btn {
                case 1:  return isDown ? (.otherMouseDown, .center) : (.otherMouseUp, .center)
                case 2:  return isDown ? (.rightMouseDown, .right)  : (.rightMouseUp, .right)
                default: return isDown ? (.leftMouseDown,  .left)   : (.leftMouseUp,  .left)
                }
            }()
            CGEvent(mouseEventSource: nil, mouseType: evtType,
                    mouseCursorPosition: pt, mouseButton: mouseBtn)?
                .post(tap: .cghidEventTap)

        case "dblclick":
            let pt = cgPoint(json, bounds: b)
            let dn = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                             mouseCursorPosition: pt, mouseButton: .left)
            dn?.setIntegerValueField(CGEventField.mouseEventClickState, value: 2)
            dn?.post(tap: .cghidEventTap)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                             mouseCursorPosition: pt, mouseButton: .left)
            up?.setIntegerValueField(CGEventField.mouseEventClickState, value: 2)
            up?.post(tap: .cghidEventTap)

        case "wheel":
            let dx = json["dx"] as? Double ?? 0
            let dy = json["dy"] as? Double ?? 0
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0)?
                .post(tap: .cghidEventTap)

        case "keydown", "keyup":
            let code   = json["code"] as? String ?? ""
            guard let keyCode = jsCodeToMacKey[code] else { return }
            let isDown = type == "keydown"
            var flags  = CGEventFlags()
            if json["shift"] as? Bool == true { flags.insert(.maskShift) }
            if json["ctrl"]  as? Bool == true { flags.insert(.maskControl) }
            if json["alt"]   as? Bool == true { flags.insert(.maskAlternate) }
            if json["meta"]  as? Bool == true { flags.insert(.maskCommand) }
            let ev = CGEvent(keyboardEventSource: nil,
                             virtualKey: keyCode, keyDown: isDown)
            // CapsLock (kVK_CapsLock = 57) requires maskAlphaShift on keyDown
            // for macOS to actually toggle the caps-lock state via CGEvent.
            if keyCode == 57 {
                ev?.flags = isDown ? [.maskAlphaShift] : []
            } else {
                ev?.flags = flags
            }
            ev?.post(tap: .cghidEventTap)

        default: break
        }
    }

    private func cgPoint(_ json: [String: Any], bounds: CGRect) -> CGPoint {
        let nx = json["x"] as? Double ?? 0
        let ny = json["y"] as? Double ?? 0
        return CGPoint(x: bounds.minX + nx * bounds.width,
                       y: bounds.minY + ny * bounds.height)
    }
}

// MARK: - HTTP Server  (serves the viewer HTML)

final class HTTPServer: ObservableObject {
    @Published var isRunning  = false
    @Published var portError:  String?
    @Published var blockedPIDs: [pid_t] = []

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "http")
    private var wsPort: UInt16 = 8081

    func start(port: UInt16, wsPort: UInt16) {
        self.wsPort = wsPort
        portError = nil; blockedPIDs = []
        guard !isRunning else { return }
        guard let l = try? NWListener(using: .tcp,
                                       on: NWEndpoint.Port(rawValue: port)!) else { return }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.setup(c) }
        l.stateUpdateHandler   = { [weak self] s in
            DispatchQueue.main.async {
                switch s {
                case .ready:
                    self?.isRunning = true; self?.portError = nil; self?.blockedPIDs = []
                case .failed:
                    self?.isRunning = false
                    let pids = pidsListening(on: port)
                    self?.portError   = "HTTP port \(port) 已被佔用"
                    self?.blockedPIDs = pids
                default: break
                }
            }
        }
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections.removeAll()
        DispatchQueue.main.async { self.isRunning = false }
    }

    private func setup(_ c: NWConnection) {
        connections.append(c)
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { c.cancel(); return }
            _ = String(data: data, encoding: .utf8) // consume request
            self.sendHTML(on: c)
        }
        c.start(queue: queue)
    }

    private func sendHTML(on c: NWConnection) {
        let body = makeHTML(wsPort: wsPort)
        let header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(Data(body.utf8))
        c.send(content: data, completion: .contentProcessed { _ in c.cancel() })
    }

    // swiftlint:disable function_body_length
    private func makeHTML(wsPort: UInt16) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>Remote Desktop</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html,body{width:100%;height:100%;background:#000;overflow:hidden;display:flex;align-items:center;justify-content:center}
        canvas{display:block;cursor:default;image-rendering:auto}
        #corner{position:fixed;bottom:10px;right:10px;display:flex;align-items:center;gap:6px;background:rgba(0,0,0,.6);border:1px solid rgba(255,255,255,.15);border-radius:6px;padding:4px 8px;user-select:none;-webkit-user-select:none}
        #fps{color:#fff;font:bold 13px/1 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;min-width:2ch;text-align:right}
        #fs-btn{color:#fff;width:18px;height:18px;cursor:pointer;opacity:.8;background:none;border:none;padding:0;display:flex;align-items:center;justify-content:center}
        #fs-btn:hover{opacity:1}
        #reload-btn{position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);display:none;flex-direction:column;align-items:center;gap:8px;cursor:pointer;background:rgba(0,0,0,.55);border:1px solid rgba(255,255,255,.2);border-radius:12px;padding:18px 24px;color:#fff}
        #reload-btn svg{width:40px;height:40px;opacity:.9}
        #reload-btn span{font:12px/1 sans-serif;opacity:.7}
        #reload-btn:hover svg{opacity:1}
        </style>
        </head>
        <body>
        <canvas id="c" tabindex="0"></canvas>
        <div id="corner">
          <span id="fps">–</span>
          <button id="fs-btn" onclick="toggleFullscreen()" title="全螢幕"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/></svg></button>
        </div>
        <div id="reload-btn" onclick="location.reload()">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 .49-3.51"/>
          </svg>
          <span>重新連線</span>
        </div>
        <script>
        const canvas    = document.getElementById('c');
        const ctx       = canvas.getContext('2d');
        const fpsEl     = document.getElementById('fps');
        const reloadBtn = document.getElementById('reload-btn');
        canvas.focus();

        const ws = new WebSocket('ws://' + location.hostname + ':\(wsPort)');
        ws.binaryType = 'arraybuffer';

        let currentBmp = null, nextBmp = null;
        let frameW = 0, frameH = 0;
        let frames = 0, lastFpsTs = performance.now();

        ws.onopen  = () => { reloadBtn.style.display = 'none'; };
        ws.onclose = () => { reloadBtn.style.display = 'flex'; fpsEl.textContent = '–'; };
        ws.onerror = () => { reloadBtn.style.display = 'flex'; fpsEl.textContent = '–'; };

        ws.onmessage = e => {
            if (!(e.data instanceof ArrayBuffer)) return;
            createImageBitmap(new Blob([e.data],{type:'image/jpeg'})).then(bmp => {
                if (nextBmp) nextBmp.close();
                nextBmp = bmp;
                frames++;
                const now = performance.now();
                if (now - lastFpsTs >= 1000) {
                    fpsEl.textContent = Math.round(frames * 1000 / (now - lastFpsTs));
                    frames = 0; lastFpsTs = now;
                }
            });
        };

        function fitCanvas() {
            if (!frameW || !frameH) return;
            const scale = Math.min(window.innerWidth / frameW, window.innerHeight / frameH);
            canvas.style.width  = Math.round(frameW * scale) + 'px';
            canvas.style.height = Math.round(frameH * scale) + 'px';
        }
        window.addEventListener('resize', fitCanvas);

        function render() {
            if (nextBmp) {
                if (currentBmp) currentBmp.close();
                currentBmp = nextBmp; nextBmp = null;
                if (currentBmp.width !== frameW || currentBmp.height !== frameH) {
                    frameW = currentBmp.width; frameH = currentBmp.height;
                    canvas.width  = frameW;
                    canvas.height = frameH;
                    fitCanvas();
                }
                ctx.drawImage(currentBmp, 0, 0);
            }
            requestAnimationFrame(render);
        }
        requestAnimationFrame(render);

        // --- Input helpers ---
        function normPos(e) {
            const r = canvas.getBoundingClientRect();
            return { x: (e.clientX - r.left) / r.width,
                     y: (e.clientY - r.top)  / r.height };
        }
        function send(obj) {
            if (ws.readyState === 1) ws.send(JSON.stringify(obj));
        }
        function modifiers(e) {
            return { shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey, meta: e.metaKey };
        }

        // Mouse
        canvas.addEventListener('mousemove', e => {
            const p = normPos(e);
            send({ type:'mousemove', ...p });
        });
        canvas.addEventListener('mousedown', e => {
            e.preventDefault(); canvas.focus();
            send({ type:'mousedown', ...normPos(e), button:e.button });
        });
        canvas.addEventListener('mouseup', e => {
            send({ type:'mouseup', ...normPos(e), button:e.button });
        });
        canvas.addEventListener('dblclick', e => {
            e.preventDefault();
            send({ type:'dblclick', ...normPos(e) });
        });
        canvas.addEventListener('contextmenu', e => e.preventDefault());
        canvas.addEventListener('wheel', e => {
            e.preventDefault();
            send({ type:'wheel', dx: e.deltaX, dy: e.deltaY });
        }, { passive: false });

        // Fullscreen
        function toggleFullscreen() {
            if (!document.fullscreenElement) {
                document.documentElement.requestFullscreen().catch(() => {});
            } else {
                document.exitFullscreen();
            }
        }
        const svgEnter = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3"/></svg>';
        const svgExit  = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><path d="M8 3v3a2 2 0 0 1-2 2H3m18 0h-3a2 2 0 0 1-2-2V3m0 18v-3a2 2 0 0 1 2-2h3M3 16h3a2 2 0 0 1 2 2v3"/></svg>';
        document.addEventListener('fullscreenchange', () => {
            const btn = document.getElementById('fs-btn');
            btn.innerHTML = document.fullscreenElement ? svgExit : svgEnter;
        });
        // F11 also toggles fullscreen
        // (handled below in keydown — we intercept before sending to server)

        // Keyboard – capture on document so system keys still reach us
        document.addEventListener('keydown', e => {
            if (e.code === 'F11') { e.preventDefault(); toggleFullscreen(); return; }
            e.preventDefault();
            send({ type:'keydown', code: e.code, key: e.key, ...modifiers(e) });
        });
        document.addEventListener('keyup', e => {
            e.preventDefault();
            send({ type:'keyup', code: e.code, key: e.key, ...modifiers(e) });
        });
        </script>
        </body>
        </html>
        """
    }
    // swiftlint:enable function_body_length
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var capture    = CaptureManager()
    @StateObject private var wsServer   = WebSocketServer()
    @StateObject private var httpServer = HTTPServer()

    @State private var windows:         [SCWindow]  = []
    @State private var displays:        [SCDisplay] = []
    @State private var selectedWindow   = 0
    @State private var selectedDisplay  = 0
    @State private var useDisplay       = true
    @State private var httpPortText          = "8080"
    @State private var status                = "就緒"
    @State private var needsScreenPermission = false
    @State private var inputEnabled          = true

    private var httpPort: UInt16 { UInt16(httpPortText) ?? 8080 }
    private var wsPort:   UInt16 { httpPort + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Text("遠端桌面串流 (60 fps)").font(.title.bold())

            // Screen Recording permission warning
            if needsScreenPermission {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text("需要「螢幕錄製」權限").foregroundColor(.red).bold()
                    Button("開啟系統設定") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }.buttonStyle(.link)
                    Button("重新嘗試") { Task { await loadContent() } }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
                .padding(8)
                .background(Color.red.opacity(0.12))
                .cornerRadius(8)
            }

            // Accessibility warning
            if !AXIsProcessTrusted() {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("需要「輔助使用」權限才能注入滑鼠/鍵盤").foregroundColor(.orange)
                    Button("開啟設定") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }.buttonStyle(.link)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            HStack(spacing: 12) {
                Toggle("全螢幕模式", isOn: $useDisplay)
                Divider().frame(height: 18)
                Toggle("遠端操作", isOn: $inputEnabled)
                    .disabled(!useDisplay)
                    .help(useDisplay ? "允許客戶端控制滑鼠與鍵盤" : "視窗模式不支援遠端操作")
                Spacer()
                Circle()
                    .fill(wsServer.clientCount > 0 ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text("客戶端：\(wsServer.clientCount)")
                    .foregroundColor(wsServer.clientCount > 0 ? .green : .secondary)
            }
            .onChange(of: inputEnabled)  { wsServer.inputEnabled = $0 }
            .onChange(of: useDisplay)    { if !$0 { inputEnabled = false } }

            // Server controls
            HStack(spacing: 12) {
                HStack {
                    Text("HTTP Port:")
                    TextField("8080", text: $httpPortText)
                        .frame(width: 70).textFieldStyle(.roundedBorder)
                }
                Text("WS Port: \(wsPort)").foregroundColor(.secondary)

                Button(httpServer.isRunning ? "停止伺服器" : "啟動伺服器") {
                    if httpServer.isRunning {
                        httpServer.stop(); wsServer.stop()
                    } else {
                        httpServer.start(port: httpPort, wsPort: wsPort)
                        wsServer.start(port: wsPort)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(httpServer.isRunning ? .red : .blue)

                if httpServer.isRunning {
                    Button("在瀏覽器開啟") {
                        NSWorkspace.shared.open(
                            URL(string: "http://localhost:\(httpPort)")!)
                    }
                    .buttonStyle(.link)
                }
            }

            // Port error banner
            let portErr = httpServer.portError ?? wsServer.portError
            let portPIDs = httpServer.blockedPIDs.isEmpty ? wsServer.blockedPIDs : httpServer.blockedPIDs
            if let err = portErr {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(err).foregroundColor(.red)
                    if !portPIDs.isEmpty {
                        Button("強制關閉佔用進程") {
                            portPIDs.forEach { kill($0, SIGTERM) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                httpServer.start(port: httpPort, wsPort: wsPort)
                                wsServer.start(port: wsPort)
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }

            if httpServer.isRunning {
                Text("http://localhost:\(httpPort)")
                    .font(.subheadline.monospaced())
                    .foregroundColor(.blue)
            }

            // Source picker
            HStack(spacing: 16) {
                if useDisplay {
                    Picker("螢幕", selection: $selectedDisplay) {
                        ForEach(displays.indices, id: \.self) { i in
                            Text("Display \(i+1)  (\(displays[i].width)×\(displays[i].height))")
                                .tag(i)
                        }
                    }.frame(width: 320)
                    .onChange(of: selectedDisplay) { _ in updateBounds() }
                } else {
                    Picker("視窗", selection: $selectedWindow) {
                        ForEach(windows.indices, id: \.self) { i in
                            Text(windows[i].title ?? "視窗 \(i)").tag(i)
                        }
                    }.frame(width: 320)
                }

                Button("▶ 開始擷取 (60 fps)") { startCapture() }
                    .buttonStyle(.borderedProminent).tint(.green)

                Button("■ 停止") {
                    capture.stop(); status = "已停止"
                }
                .disabled(!capture.isCapturing)
            }

            Text("狀態：\(status)").font(.subheadline)

            // Live preview (throttled to ~10 fps to save CPU)
            if let img = capture.latestImage {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 200)
                    .border(Color.gray)
                    .overlay(alignment: .topLeading) {
                        Text("預覽 (~10 fps)")
                            .font(.caption).padding(3)
                            .background(.black.opacity(0.5)).foregroundColor(.white)
                    }
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.1))
                    .frame(height: 200)
                    .overlay(Text("尚無影像").foregroundColor(.secondary))
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 720, minHeight: 560)
        .task {
            await loadContent()
            capture.onJpegFrame = { [weak wsServer] jpeg in wsServer?.broadcastJpeg(jpeg) }
            capture.onH264Frame = { [weak wsServer] h264 in wsServer?.broadcastH264(h264) }
            capture.h264Encoder.onEncodedData = { [weak capture] data in capture?.onH264Frame?(data) }
            wsServer.captureManager = capture
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadContent() }
        }
        .onChange(of: useDisplay,      perform: { _ in updateBounds() })
        .onChange(of: selectedDisplay, perform: { _ in updateBounds() })
    }

    // MARK: - Helpers

    private func startCapture() {
        print("▶ startCapture: useDisplay=\(useDisplay) selectedDisplay=\(selectedDisplay) displays.count=\(displays.count) selectedWindow=\(selectedWindow) windows.count=\(windows.count)")
        do {
            if useDisplay {
                guard displays.indices.contains(selectedDisplay) else {
                    let msg = "找不到螢幕（displays.count=\(displays.count), selectedDisplay=\(selectedDisplay)）"
                    print("❌ \(msg)")
                    status = msg; return
                }
                let d = displays[selectedDisplay]
                print("✅ 開始全螢幕擷取 displayID=\(d.displayID) \(d.width)×\(d.height)")
                try capture.start(display: d, fps: 60)
                updateBounds()
                status = "全螢幕擷取中 (\(d.width)×\(d.height) @ 60fps)"
            } else {
                guard windows.indices.contains(selectedWindow) else {
                    let msg = "找不到視窗（windows.count=\(windows.count), selectedWindow=\(selectedWindow)）"
                    print("❌ \(msg)")
                    status = msg; return
                }
                let w = windows[selectedWindow]
                print("✅ 開始視窗擷取 title=\(w.title ?? "nil") frame=\(w.frame)")
                try capture.start(window: w, fps: 60)
                wsServer.captureBounds = w.frame
                status = "視窗擷取中：\(w.title ?? "無標題") @ 60fps"
            }
        } catch {
            print("❌ startCapture 失敗：\(error)")
            status = "啟動失敗：\(error.localizedDescription)"
        }
    }

    /// Convert the selected display's frame to CGEvent global coordinate space
    /// (origin at top-left of primary display, Y axis downward).
    private func updateBounds() {
        guard useDisplay, displays.indices.contains(selectedDisplay) else { return }
        let d = displays[selectedDisplay]
        // CGDisplayBounds is in Quartz coords (Y up, origin bottom-left of primary display).
        // CGEvent coords have Y increasing downward; for the primary display both happen to
        // use the same numbers for x, but Y is flipped relative to screen height.
        // The simplest correct method: read the matching NSScreen.
        let primaryH = NSScreen.screens.first?.frame.height ?? CGFloat(d.height)
        if let screen = NSScreen.screens.first(where: { scr in
            // Match by CGDirectDisplayID stored in deviceDescription
            guard let id = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return id == d.displayID
        }) {
            let f = screen.frame   // Cocoa coords: Y up, origin bottom-left of primary
            // Convert to CGEvent coords: Y down from top of primary display
            wsServer.captureBounds = CGRect(
                x:      f.origin.x,
                y:      primaryH - f.origin.y - f.height,
                width:  f.width,
                height: f.height
            )
        } else {
            wsServer.captureBounds = CGRect(x: 0, y: 0,
                                            width: CGFloat(d.width),
                                            height: CGFloat(d.height))
        }
    }

    private func loadContent() async {
        print("🔍 loadContent: 嘗試取得 SCShareableContent...")
        do {
            let content = try await SCShareableContent.current
            let vis = content.windows.filter { $0.isOnScreen }
            print("✅ loadContent: \(content.displays.count) 個螢幕、\(vis.count) 個視窗（共 \(content.windows.count) 個）")
            for (i, d) in content.displays.enumerated() {
                print("   Display[\(i)] id=\(d.displayID) \(d.width)×\(d.height)")
            }
            await MainActor.run {
                windows  = vis
                displays = content.displays
                status   = "已載入 \(vis.count) 視窗、\(content.displays.count) 螢幕"
                selectedWindow  = min(selectedWindow,  max(0, vis.count - 1))
                selectedDisplay = min(selectedDisplay, max(0, content.displays.count - 1))
                needsScreenPermission = false
            }
            updateBounds()
        } catch {
            print("❌ loadContent 失敗：\(error)")
            print("   localizedDescription: \(error.localizedDescription)")
            await MainActor.run {
                needsScreenPermission = true
                status = "載入失敗（請授權「螢幕錄製」權限）：\(error.localizedDescription)"
            }
        }
    }
}