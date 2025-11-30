import SwiftUI
import ScreenCaptureKit
import AVFoundation
import CoreImage
import Combine
import Network
import Foundation
import AppKit   // NSImage / NSBitmapImageRep

// MARK: - App 入口

@main
struct ScreenStreamerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - 螢幕擷取管理（全 RAM，包含 JPEG Data）

final class CaptureManager: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {

    let objectWillChange = ObservableObjectPublisher()

    // 給 SwiftUI 預覽用
    @Published var latestImage: NSImage?

    // 給 HTTP server 串流用（不落地硬碟）
    @Published var latestJPEG: Data?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "ScreenSampleQueue")

    override init() {
        super.init()
    }

    // 視窗擷取
    func start(window: SCWindow, maxFPS: Int) throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        try startWithFilter(filter,
                            width: Int(window.frame.width),
                            height: Int(window.frame.height),
                            maxFPS: maxFPS)
    }

    // 全螢幕擷取（整個螢幕）
    func start(display: SCDisplay, maxFPS: Int) throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        try startWithFilter(filter,
                            width: Int(display.width),
                            height: Int(display.height),
                            maxFPS: maxFPS)
    }

    private func startWithFilter(_ filter: SCContentFilter,
                                 width: Int,
                                 height: Int,
                                 maxFPS: Int) throws {
        // 停掉舊的 stream
        stop()

        let config = SCStreamConfiguration()
        config.capturesAudio = false

        // maxFPS -> minimumFrameInterval
        let fps = max(1, min(maxFPS, 60))
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))

        config.width  = width
        config.height = height

        let stream = SCStream(filter: filter,
                              configuration: config,
                              delegate: self)
        self.stream = stream

        try stream.addStreamOutput(self,
                                   type: .screen,
                                   sampleHandlerQueue: sampleQueue)
        try stream.startCapture()
        print("✅ SCStream startCapture OK (\(fps) fps, \(width)x\(height))")
    }

    func stop() {
        Task {
            try? await stream?.stopCapture()
        }
        stream = nil
        print("🛑 SCStream stopCapture")
    }

    // 每一 frame 進來這裡
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {

        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let size = NSSize(width: ciImage.extent.width,
                          height: ciImage.extent.height)

        let nsImage = NSImage(cgImage: cgImage, size: size)

        // 轉成 JPEG data（存在記憶體）
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let jpeg = rep.representation(using: .jpeg,
                                      properties: [.compressionFactor: 0.8])

        DispatchQueue.main.async {
            self.latestImage = nsImage        // UI 預覽
            self.latestJPEG  = jpeg           // HTTP 串流
        }
    }
}

// MARK: - 純 Swift HTTP 伺服器（回傳 RAM 裡的 JPEG）

final class HTTPServer: ObservableObject {

    let objectWillChange = ObservableObjectPublisher()

    @Published var isRunning: Bool = false

    // 從這邊拿最新的 JPEG
    weak var captureManager: CaptureManager?

    // 用來控制 HTML 裡的更新頻率（瀏覽器端 FPS）
    var fps: Double = 5.0

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "HTTPServerQueue")

    func start(port: UInt16) {
        guard !isRunning else { return }

        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params,
                                          on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                print("➡️ new connection from \(connection.endpoint)")
                self.setupConnection(connection)
            }

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("✅ HTTP server listening on port \(port)")
                    DispatchQueue.main.async {
                        self?.isRunning = true
                    }
                case .failed(let error):
                    print("❌ HTTP server failed:", error)
                    DispatchQueue.main.async {
                        self?.isRunning = false
                    }
                default:
                    break
                }
            }

            listener.start(queue: queue)

        } catch {
            print("❌ 無法啟動 HTTP server：", error)
        }
    }

    func stop() {
        print("🛑 stop HTTP server")
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    private func setupConnection(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("✅ connection ready:", connection.endpoint)
            case .failed(let error):
                print("❌ connection failed:", error)
            case .cancelled:
                print("ℹ️ connection cancelled")
            default:
                break
            }
        }

        receive(on: connection)
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data = data, !data.isEmpty {
                let request = String(data: data, encoding: .utf8) ?? ""
                print("📩 request:\n\(request)")
                self.handleRequest(request, on: connection)
            } else {
                print("⚠️ got empty data / error =", String(describing: error))
                connection.cancel()
                self.connections.removeAll { $0 === connection }
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                self.connections.removeAll { $0 === connection }
            }
        }
    }

    private func handleRequest(_ request: String, on connection: NWConnection) {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            send404(on: connection)
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send404(on: connection)
            return
        }

        let path = String(parts[1])
        print("➡️ parsed path:", path)

        if path.starts(with: "/shot.jpg") {
            sendImage(on: connection)
        } else {
            sendHTML(on: connection)
        }
    }

    // 黑背景、等比例最大化、不閃爍的 HTML
    private func sendHTML(on connection: NWConnection) {
        let fpsValue = max(0.5, min(fps, 60.0))
        let intervalMs = Int(1000.0 / fpsValue)

        let body = """
        <html>
        <head>
            <meta charset="utf-8">
            <title>Screen Stream</title>
            <style>
                html, body {
                    height: 100%;
                    margin: 0;
                    background: #000000;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                img {
                    max-width: 100vw;
                    max-height: 100vh;
                    object-fit: contain;
                    background: #000000;
                }
            </style>
            <script>
                function updateImage() {
                    var img = document.getElementById('screen');
                    if (!img) return;

                    var url = '/shot.jpg?ts=' + Date.now();

                    var tmp = new Image();
                    tmp.onload = function() {
                        img.src = url; // 載完再換，避免閃爍
                    };
                    tmp.src = url;
                }

                window.onload = function() {
                    updateImage();
                    setInterval(updateImage, \(intervalMs)); // \(fpsValue) FPS
                };
            </script>
        </head>
        <body>
            <img id="screen" src="/shot.jpg">
        </body>
        </html>
        """

        let header = """
        HTTP/1.1 200 OK\r\n\
        Content-Type: text/html; charset=utf-8\r\n\
        Content-Length: \(body.utf8.count)\r\n\
        Connection: close\r\n\
        \r\n
        """

        let data = Data((header + body).utf8)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("❌ sendHTML error:", error)
            }
            connection.cancel()
        })
    }

    // 直接從 RAM 回 JPEG
    private func sendImage(on connection: NWConnection) {
        guard let jpeg = captureManager?.latestJPEG else {
            print("⚠️ 沒有可用的 JPEG frame，回傳 404")
            send404(on: connection)
            return
        }

        let header = """
        HTTP/1.1 200 OK\r\n\
        Content-Type: image/jpeg\r\n\
        Content-Length: \(jpeg.count)\r\n\
        Cache-Control: no-cache, no-store, must-revalidate\r\n\
        Connection: close\r\n\
        \r\n
        """

        var payload = Data(header.utf8)
        payload.append(jpeg)

        connection.send(content: payload, completion: .contentProcessed { error in
            if let error {
                print("❌ sendImage error:", error)
            }
            connection.cancel()
        })
    }

    private func send404(on connection: NWConnection) {
        let body = "404 Not Found"
        let header = """
        HTTP/1.1 404 Not Found\r\n\
        Content-Type: text/plain; charset=utf-8\r\n\
        Content-Length: \(body.utf8.count)\r\n\
        Connection: close\r\n\
        \r\n
        """

        let data = Data((header + body).utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - SwiftUI UI

struct ContentView: View {
    @StateObject private var captureManager = CaptureManager()
    @StateObject private var httpServer = HTTPServer()

    @State private var windows: [SCWindow] = []
    @State private var displays: [SCDisplay] = []
    @State private var selectedWindowIndex: Int = 0
    @State private var selectedDisplayIndex: Int = 0
    @State private var useDisplayCapture: Bool = false

    @State private var status: String = "尚未開始"

    @State private var portText: String = "8000"
    @State private var fps: Double = 5.0   // browser 更新頻率

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HTTP簡易螢幕共享").font(Font.title.bold())
            HStack(spacing: 12) {
                Button("更新列表（視窗 & 螢幕）") {
                    Task { await loadShareableContent() }
                }

                Toggle("全螢幕模式（截取整個螢幕）", isOn: $useDisplayCapture)
            }

            HStack(spacing: 16) {
                HStack {
                    Text("HTTP Port:")
                    TextField("Port", text: $portText)
                        .frame(width: 80)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                Button(httpServer.isRunning ? "停止 HTTP 伺服器" : "啟動 HTTP 伺服器") {
                    if httpServer.isRunning {
                        httpServer.stop()
                    } else {
                        let p = UInt16(portText) ?? 8000
                        httpServer.start(port: p)
                    }
                }
            }

            Text("HTTP 狀態：\(httpServer.isRunning ? "運作中 (http://localhost:\(portText))" : "未啟動")")
                .font(.subheadline)

            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    if useDisplayCapture {
                        Picker("螢幕", selection: $selectedDisplayIndex) {
                            ForEach(displays.indices, id: \.self) { idx in
                                let d = displays[idx]
                                Text("Display \(idx + 1) (\(d.width)x\(d.height))")
                                    .tag(idx)
                            }
                        }
                        .frame(width: 350)
                    } else {
                        Picker("視窗", selection: $selectedWindowIndex) {
                            ForEach(windows.indices, id: \.self) { idx in
                                let win = windows[idx]
                                Text(win.title ?? "無標題視窗 \(idx)")
                                    .tag(idx)
                            }
                        }
                        .frame(width: 350)
                    }
                }

                VStack(alignment: .leading) {
                    Text("瀏覽器 FPS：\(Int(fps))")
                    Slider(value: $fps, in: 1...30, step: 1)
                        .frame(width: 200)
                }
            }

            HStack {
                Button("開始螢幕共享") {
                    startCapture()
                }

                Button("停止螢幕共享") {
                    captureManager.stop()
                    status = "已停止"
                }
            }

            Text("擷取狀態：\(status)")
                .font(.subheadline)

            if let img = captureManager.latestImage {
                Text("預覽：")
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 220)
                    .border(Color.gray)
            } else {
                Text("尚無影像")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 800, minHeight: 600)
        .task {
            httpServer.captureManager = captureManager
            httpServer.fps = fps
            await loadShareableContent()
        }
        .onChange(of: fps) { newFPS in
            httpServer.fps = newFPS
        }
    }

    private func startCapture() {
        let fpsInt = Int(fps)

        do {
            if useDisplayCapture {
                guard displays.indices.contains(selectedDisplayIndex) else {
                    status = "沒有可用的螢幕"
                    return
                }
                let d = displays[selectedDisplayIndex]
                try captureManager.start(display: d, maxFPS: fpsInt)
                status = "全螢幕擷取中（螢幕 \(selectedDisplayIndex + 1)，\(fpsInt) FPS）"
            } else {
                guard windows.indices.contains(selectedWindowIndex) else {
                    status = "沒有可用的視窗"
                    return
                }
                let win = windows[selectedWindowIndex]
                try captureManager.start(window: win, maxFPS: fpsInt)
                status = "視窗擷取中（\(win.title ?? "無標題")，\(fpsInt) FPS）"
            }
        } catch {
            status = "啟動擷取失敗：\(error.localizedDescription)"
        }
    }

    private func loadShareableContent() async {
        do {
            let content = try await SCShareableContent.current
            let visibleWindows = content.windows.filter { $0.isOnScreen }

            DispatchQueue.main.async {
                self.windows = visibleWindows
                self.displays = content.displays

                if visibleWindows.isEmpty && content.displays.isEmpty {
                    self.status = "找不到任何視窗或螢幕（可能 Screen Recording 沒給權限？）"
                } else {
                    self.status = "已載入 \(visibleWindows.count) 個視窗、\(content.displays.count) 個螢幕"
                    self.selectedWindowIndex = min(self.selectedWindowIndex, max(0, visibleWindows.count - 1))
                    self.selectedDisplayIndex = min(self.selectedDisplayIndex, max(0, content.displays.count - 1))
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.status = "取得視窗/螢幕列表失敗：\(error.localizedDescription)"
            }
        }
    }
}
