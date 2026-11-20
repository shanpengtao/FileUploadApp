//
//  UploadServer.swift
//  FileUploadApp
//
//  HTTP 文件上传服务器，使用 Network.framework 实现
//

import Foundation
import Network
import Combine

// MARK: - 数据模型

struct UploadedFile: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64
    let date: Date
}

// MARK: - 端口工具

private let kDefaultPort: UInt16 = 6888
private let kPortRangeMin: UInt16 = 4000
private let kPortRangeMax: UInt16 = 7999
/// UserDefaults key：上次使用的端口
private let kLastPortKey = "com.58.FileUploadApp.lastPort"
/// UserDefaults key：上次启动的 PID（用于判断占用者是否是本 App 的上一个实例）
private let kLastPIDKey  = "com.58.FileUploadApp.lastPID"
/// 进程标识字符串，写入 HTTP 响应头 Server 字段，也用于 lsof 对比
private let kServerTag   = "FileUploadApp/1.0"

/// 通过 lsof 查询占用指定端口的 PID 列表
/// 在 App Sandbox 下 lsof 可能被拒绝，此时静默返回空数组
private func pidsOccupying(port: UInt16) -> [Int32] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    proc.arguments = ["-ti", "tcp:\(port)"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let result = String(data: data, encoding: .utf8) ?? ""
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
        .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        .filter { $0 > 0 }
}

/// 尝试 kill 指定 PID（SIGTERM，给一点时间后再 SIGKILL）
/// 在 App Sandbox 下可能无权限 kill，静默忽略错误
private func killProcess(_ pid: Int32) {
    let result = kill(pid, SIGTERM)
    guard result == 0 else { return } // 无权限则直接返回
    // 等最多 0.5 秒让其退出
    let deadline = Date().addingTimeInterval(0.5)
    while Date() < deadline {
        if kill(pid, 0) != 0 { return } // 进程已不存在
        Thread.sleep(forTimeInterval: 0.05)
    }
    kill(pid, SIGKILL)
}

/// 检查端口是否可绑定（即没有其他进程占用）
private func isPortAvailable(_ port: UInt16) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { close(sock) }
    var val: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &val, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port   = port.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

/// 决定本次使用哪个端口：
/// 1. 优先 6888
/// 2. 6888 被占 → 检查占用者是否是本 App 上次的实例 (PID 匹配)
///    - 是 → kill 旧实例，继续用 6888
///    - 否 → 在 4000-7999 随机找一个空闲端口
private func resolvePort() -> UInt16 {
    if isPortAvailable(kDefaultPort) {
        return kDefaultPort
    }

    // 6888 被占，查占用 PID
    let occupyingPIDs = pidsOccupying(port: kDefaultPort)
    let lastPID = Int32(UserDefaults.standard.integer(forKey: kLastPIDKey))

    if lastPID > 0 && occupyingPIDs.contains(lastPID) {
        // 是本 App 上一个实例，kill 掉后重用 6888
        killProcess(lastPID)
        // 等端口释放（最多 1 秒）
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if isPortAvailable(kDefaultPort) { return kDefaultPort }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // 仍未释放，走随机逻辑
    }

    // 被其他进程占用，随机找可用端口
    let candidates = Array(kPortRangeMin...kPortRangeMax).map { UInt16($0) }.shuffled()
    for p in candidates.prefix(60) {
        if isPortAvailable(p) { return p }
    }
    return kDefaultPort // 极端 fallback
}

// MARK: - UploadServer

class UploadServer: ObservableObject {
    @Published var isRunning = false
    @Published var uploadedFiles: [UploadedFile] = []
    @Published private(set) var port: UInt16 = 6888
    @Published var allFiles: [UploadedFile] = []

    /// 上传目录：~/Downloads/FileUploadApp
    /// 在沙盒内用 FileManager 标准 API 获取 Downloads 路径，配合 entitlements 中的
    /// com.apple.security.files.downloads.read-write 权限，只弹一次授权弹窗
    let uploadDir: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString("~").expandingTildeInPath).appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("FileUploadApp")
    }()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.58.fileupload.server", qos: .userInitiated)
    private let serverName = "com.58.FileUploadApp.HTTPServer"

    // MARK: - 启动/停止

    func start() {
        // 创建上传目录
        try? FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)

        // 记录本进程 PID，供下次启动时判断占用者身份
        UserDefaults.standard.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: kLastPIDKey)

        // 加载上传目录中的所有历史文件
        loadAllFiles()

        // 决定端口（在后台线程执行，避免 kill 操作阻塞主线程）
        queue.async { [weak self] in
            guard let self else { return }
            let selectedPort = resolvePort()
            DispatchQueue.main.async { self.port = selectedPort }
            UserDefaults.standard.set(Int(selectedPort), forKey: kLastPortKey)
            self.startListener(on: selectedPort)
        }
    }

    private func startListener(on selectedPort: UInt16) {
        do {
            let params = NWParameters.tcp
            // 注意：不设置 allowLocalEndpointReuse，在 macOS 13.x 上该属性可能导致监听失败
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: selectedPort)!)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        print("服务器已启动，端口: \(selectedPort)")
                    case .failed(let error):
                        self?.isRunning = false
                        print("服务器启动失败: \(error)")
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: queue)
        } catch {
            print("创建 Listener 失败: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    // MARK: - 所有上传文件管理

    /// 从磁盘目录加载所有文件信息
    func loadAllFiles() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: uploadDir,
                                                           includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                                                           options: .skipsHiddenFiles) else {
            allFiles = []
            return
        }
        var files: [UploadedFile] = []
        for url in contents {
            guard !url.hasDirectoryPath else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            files.append(UploadedFile(name: url.lastPathComponent, size: Int64(size), date: date))
        }
        // 按时间倒序（最新的在前）
        files.sort { $0.date > $1.date }
        allFiles = files
    }

    /// 删除上传目录下的所有文件
    func deleteAllFiles() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: uploadDir,
                                                           includingPropertiesForKeys: nil,
                                                           options: .skipsHiddenFiles) else { return }
        for url in contents {
            guard !url.hasDirectoryPath else { continue }
            try? fm.removeItem(at: url)
        }
        allFiles = []
    }

    // MARK: - 连接处理（nonisolated，运行在 queue 上）

    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection: connection, buffer: Data())
    }

    nonisolated private func receiveRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self = self else { return }

            var accumulated = buffer
            if let data = data { accumulated.append(data) }

            let crlf2 = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let headerEndRange = accumulated.range(of: crlf2) else {
                if isComplete { connection.cancel() }
                else { self.receiveRequest(connection: connection, buffer: accumulated) }
                return
            }

            let headerData = accumulated.subdata(in: 0..<headerEndRange.lowerBound)
            guard let headerStr = String(data: headerData, encoding: .utf8) else {
                self.sendError(connection: connection, status: 400, message: "Bad Request")
                return
            }

            let lines = headerStr.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                self.sendError(connection: connection, status: 400, message: "Bad Request")
                return
            }
            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                self.sendError(connection: connection, status: 400, message: "Bad Request")
                return
            }

            let method = parts[0]
            let path = parts[1]

            if method == "GET" && path == "/" {
                self.sendHTML(connection: connection)
                return
            }
            guard method == "POST" && path == "/" else {
                self.sendError(connection: connection, status: 404, message: "Not Found")
                return
            }

            var contentLength = 0
            var boundary = ""
            for line in lines {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    contentLength = Int(line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
                } else if lower.hasPrefix("content-type:") && lower.contains("boundary=") {
                    boundary = self.extractBoundary(from: line)
                }
            }

            let bodyStart = headerEndRange.upperBound
            let bodyData = accumulated.subdata(in: bodyStart..<accumulated.count)
            let received = bodyData.count

            if received >= contentLength {
                self.parseAndSave(bodyData: bodyData, boundary: boundary, connection: connection)
            } else {
                self.receiveBody(connection: connection, accumulated: bodyData,
                                 remaining: contentLength - received, boundary: boundary)
            }
        }
    }

    nonisolated private func receiveBody(connection: NWConnection, accumulated: Data, remaining: Int, boundary: String) {
        let toReceive = min(remaining, 1_048_576)
        connection.receive(minimumIncompleteLength: 1, maximumLength: toReceive) { [weak self] data, _, isComplete, _ in
            guard let self = self else { return }
            var newAccumulated = accumulated
            if let data = data { newAccumulated.append(data) }
            let newRemaining = remaining - (data?.count ?? 0)
            if newRemaining <= 0 || isComplete {
                self.parseAndSave(bodyData: newAccumulated, boundary: boundary, connection: connection)
            } else {
                self.receiveBody(connection: connection, accumulated: newAccumulated, remaining: newRemaining, boundary: boundary)
            }
        }
    }

    nonisolated private func extractBoundary(from contentType: String) -> String {
        for comp in contentType.components(separatedBy: ";") {
            let t = comp.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("boundary=") {
                return String(t.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return ""
    }

    nonisolated private func parseAndSave(bodyData: Data, boundary: String, connection: NWConnection) {
        guard !boundary.isEmpty else {
            sendJSON(connection: connection, json: "{\"ok\":false,\"msg\":\"no boundary\"}", status: 400)
            return
        }

        let boundaryData = ("--" + boundary).data(using: .utf8)!
        var parts: [Data] = []
        var searchStart = 0

        while searchStart < bodyData.count {
            guard let rangeStart = bodyData.range(of: boundaryData, in: searchStart..<bodyData.count) else { break }
            let afterBoundary = rangeStart.upperBound
            if afterBoundary + 2 <= bodyData.count {
                let twoBytes = bodyData.subdata(in: afterBoundary..<afterBoundary+2)
                if twoBytes == Data([0x2D, 0x2D]) { break }
            }
            let partStart = afterBoundary + 2
            guard let rangeEnd = bodyData.range(of: boundaryData, in: partStart..<bodyData.count) else { break }
            var partEnd = rangeEnd.lowerBound
            if partEnd >= 2 && bodyData[partEnd-2] == 0x0D && bodyData[partEnd-1] == 0x0A {
                partEnd -= 2
            }
            if partStart < partEnd {
                parts.append(bodyData.subdata(in: partStart..<partEnd))
            }
            searchStart = rangeEnd.lowerBound
        }

        var savedFiles: [UploadedFile] = []
        for part in parts {
            if let saved = savePart(part) { savedFiles.append(saved) }
        }

        DispatchQueue.main.async {
            for file in savedFiles { self.uploadedFiles.insert(file, at: 0) }
            self.loadAllFiles()
        }
        sendJSON(connection: connection, json: "{\"ok\":true,\"count\":\(savedFiles.count)}", status: 200)
    }

    nonisolated private func savePart(_ part: Data) -> UploadedFile? {
        let crlf2 = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerEndRange = part.range(of: crlf2) else { return nil }
        let headerData = part.subdata(in: 0..<headerEndRange.lowerBound)
        let fileData = part.subdata(in: headerEndRange.upperBound..<part.count)

        guard let headerStr = String(data: headerData, encoding: .utf8),
              headerStr.contains("filename=") else { return nil }

        var filename = ""
        for line in headerStr.components(separatedBy: "\r\n") {
            if line.lowercased().contains("content-disposition") && line.contains("filename=") {
                if let match = line.range(of: #"filename="([^"]+)""#, options: .regularExpression) {
                    filename = String(line[match])
                        .replacingOccurrences(of: "filename=\"", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                } else if let idx = line.range(of: "filename=") {
                    filename = String(line[idx.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespaces))
                }
            }
        }
        guard !filename.isEmpty else { return nil }
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        var destURL = uploadDir.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: destURL.path) {
            let ext = destURL.pathExtension
            let base = destURL.deletingPathExtension().lastPathComponent
            let uuid = String(UUID().uuidString.prefix(8))
            destURL = ext.isEmpty
                ? uploadDir.appendingPathComponent("\(base)_\(uuid)")
                : uploadDir.appendingPathComponent("\(base)_\(uuid).\(ext)")
        }
        do {
            try fileData.write(to: destURL)
            return UploadedFile(name: destURL.lastPathComponent, size: Int64(fileData.count), date: Date())
        } catch {
            print("保存文件失败: \(error)")
            return nil
        }
    }

    // MARK: - 发送响应

    nonisolated private func sendHTML(connection: NWConnection) {
        let html = buildHTML()
        let body = html.data(using: .utf8) ?? Data()
        sendRaw(connection: connection,
                header: "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nServer: \(kServerTag)\r\nConnection: close\r\n\r\n",
                body: body)
    }

    nonisolated private func sendJSON(connection: NWConnection, json: String, status: Int) {
        let body = json.data(using: .utf8) ?? Data()
        let statusText = status == 200 ? "OK" : "Error"
        sendRaw(connection: connection,
                header: "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nServer: \(kServerTag)\r\nConnection: close\r\n\r\n",
                body: body)
    }

    nonisolated private func sendError(connection: NWConnection, status: Int, message: String) {
        sendJSON(connection: connection, json: "{\"ok\":false,\"msg\":\"\(message)\"}", status: status)
    }

    nonisolated private func sendRaw(connection: NWConnection, header: String, body: Data) {
        var response = header.data(using: .utf8)!
        response.append(body)
        connection.send(content: response, completion: .contentProcessed({ _ in connection.cancel() }))
    }

    // MARK: - 网络工具

    nonisolated func getLocalIP() -> String {
        let addresses = Host.current().addresses
        for addr in addresses {
            if addr.contains(".") && !addr.hasPrefix("127.") && !addr.hasPrefix("169.254.") {
                return addr
            }
        }
        return "127.0.0.1"
    }

    nonisolated var accessURL: String {
        "http://\(getLocalIP()):\(port)"
    }

    // MARK: - 构建 HTML

    nonisolated private func buildHTML() -> String {
        let url = accessURL
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>文件上传</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f0f2f5; min-height: 100vh; display: flex; justify-content: center; align-items: center; padding: 20px; }
        .container { background: #fff; border-radius: 12px; padding: 40px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); width: 100%; max-width: 520px; }
        .qrcode-section { display: flex; flex-direction: column; align-items: center; text-align: center; margin-bottom: 24px; padding-bottom: 24px; border-bottom: 1px dashed #e0e0e0; }
        .qrcode-section h2 { font-size: 16px; color: #333; margin-bottom: 12px; }
        .qrcode-wrapper { display: block; padding: 8px; background: #fff; border: 1px solid #eee; border-radius: 6px; }
        .url-text { margin-top: 10px; font-size: 13px; color: #666; background: #f5f5f5; padding: 6px 12px; border-radius: 4px; display: block; width: 100%; word-break: break-all; box-sizing: border-box; }
        .hint { margin-top: 8px; font-size: 12px; color: #999; }
        h1 { font-size: 22px; color: #1a1a1a; margin-bottom: 24px; text-align: center; }
        .drop-zone { border: 2px dashed #d9d9d9; border-radius: 8px; padding: 32px 20px; text-align: center; cursor: pointer; transition: border-color 0.3s; margin-bottom: 16px; }
        .drop-zone:hover, .drop-zone.dragover { border-color: #4a90d9; background: #f8faff; }
        .drop-zone p { color: #888; font-size: 14px; margin-top: 8px; }
        .drop-zone .icon { font-size: 36px; color: #bbb; }
        input[type="file"] { display: none; }
        .btn { display: block; width: 100%; padding: 12px; border: none; border-radius: 6px; background: #4a90d9; color: #fff; font-size: 16px; cursor: pointer; transition: background 0.3s; }
        .btn:hover { background: #357abd; }
        .btn:disabled { background: #a0c4e8; cursor: not-allowed; }
        .preview-list { margin-top: 16px; }
        .preview-item { display: flex; align-items: center; gap: 10px; padding: 8px 10px; border: 1px solid #eee; border-radius: 6px; margin-bottom: 8px; background: #fafafa; }
        .preview-item img { width: 44px; height: 44px; object-fit: cover; border-radius: 4px; flex-shrink: 0; }
        .preview-item .file-icon { width: 44px; height: 44px; background: #f0f2f5; border-radius: 4px; display: flex; align-items: center; justify-content: center; font-size: 22px; flex-shrink: 0; }
        .preview-item .info { flex: 1; overflow: hidden; }
        .preview-item .info .name { font-size: 13px; color: #333; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .preview-item .info .size { font-size: 12px; color: #aaa; margin-top: 2px; }
        .preview-item .del { background: none; border: none; color: #ccc; font-size: 18px; cursor: pointer; padding: 0 4px; line-height: 1; flex-shrink: 0; }
        .preview-item .del:hover { color: #f55; }
        .port-info { text-align: center; color: #aaa; font-size: 12px; margin-top: 20px; }
        </style>
        </head>
        <body>
        <div class="container">
            <div class="qrcode-section">
                <h2>手机扫码访问</h2>
                <div class="qrcode-wrapper" id="qrcodeContainer"></div>
                <div class="url-text" id="accessUrl"></div>
                <div class="hint">请确保手机与电脑在同一 WiFi 网络下</div>
            </div>
            <h1>文件上传</h1>
            <div class="drop-zone" id="dropZone">
                <div class="icon">&#128193;</div>
                <p>点击选择文件或拖拽文件到此处</p>
                <input type="file" name="file" id="fileInput" multiple>
            </div>
            <button class="btn" id="uploadBtn" onclick="doUpload()">上传</button>
            <div class="preview-list" id="previewList"></div>
            <div class="port-info">上传目录: ~/Downloads/FileUpload/</div>
        </div>
        <script>
        \(qrcodeJS)
        var accessUrl = "\(url)";
        document.getElementById('accessUrl').textContent = accessUrl;
        new QRCode(document.getElementById('qrcodeContainer'), {text: accessUrl, width: 148, height: 148, colorDark: '#333333', colorLight: '#ffffff', correctLevel: QRCode.CorrectLevel.H});
        var dropZone = document.getElementById('dropZone');
        var fileInput = document.getElementById('fileInput');
        var previewList = document.getElementById('previewList');
        var selectedFiles = [];
        dropZone.addEventListener('click', function() { fileInput.click(); });
        dropZone.addEventListener('dragover', function(e) { e.preventDefault(); dropZone.classList.add('dragover'); });
        dropZone.addEventListener('dragleave', function() { dropZone.classList.remove('dragover'); });
        dropZone.addEventListener('drop', function(e) { e.preventDefault(); dropZone.classList.remove('dragover'); setFiles(e.dataTransfer.files); });
        fileInput.addEventListener('change', function() { setFiles(this.files); });
        function setFiles(files) {
            selectedFiles = Array.from(files);
            renderPreview();
        }
        function removeFile(index) {
            selectedFiles.splice(index, 1);
            renderPreview();
        }
        function renderPreview() {
            previewList.innerHTML = '';
            selectedFiles.forEach(function(f, i) {
                var item = document.createElement('div'); item.className = 'preview-item';
                var thumb;
                if (f.type.startsWith('image/')) { thumb = document.createElement('img'); thumb.src = URL.createObjectURL(f); }
                else { thumb = document.createElement('div'); thumb.className = 'file-icon'; thumb.innerHTML = '&#128196;'; }
                var info = document.createElement('div'); info.className = 'info';
                info.innerHTML = '<div class="name">' + f.name + '</div><div class="size">' + (f.size >= 1048576 ? (f.size/1048576).toFixed(1)+' MB' : (f.size/1024).toFixed(1)+' KB') + '</div>';
                var del = document.createElement('button'); del.className = 'del'; del.innerHTML = '&times;'; del.onclick = (function(idx){ return function(){ removeFile(idx); }; })(i);
                item.appendChild(thumb); item.appendChild(info); item.appendChild(del); previewList.appendChild(item);
            });
        }
        function doUpload() {
            if (selectedFiles.length === 0) { alert('请先选择文件'); return; }
            var btn = document.getElementById('uploadBtn');
            btn.disabled = true; btn.textContent = '上传中...';
            var fd = new FormData();
            selectedFiles.forEach(function(f) { fd.append('file', f); });
            var xhr = new XMLHttpRequest();
            xhr.open('POST', '/');
            xhr.onload = function() {
                btn.disabled = false; btn.textContent = '上传';
                if (xhr.status === 200) { alert('上传成功，共 ' + selectedFiles.length + ' 个文件'); selectedFiles = []; renderPreview(); fileInput.value = ''; }
                else { alert('上传失败，请重试'); }
            };
            xhr.onerror = function() { btn.disabled = false; btn.textContent = '上传'; alert('网络错误，请重试'); };
            xhr.send(fd);
        }
        </script>
        </body>
        </html>
        """
    }
}
