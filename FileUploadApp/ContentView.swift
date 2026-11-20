//
//  ContentView.swift
//  FileUploadApp
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var server = UploadServer()
    @State private var isDragging = false
    @State private var selectedFiles: [URL] = []
    @State private var isUploading = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var qrImage: NSImage? = nil
    @State private var showDeleteAllConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧：主功能区
            leftPanel
                .frame(minWidth: 380)

            Divider()

            // 中间：当前上传记录
            currentUploadPanel
                .frame(width: 280)

            Divider()

            // 右侧：所有上传文件
            allFilesPanel
                .frame(width: 280)
        }
        .frame(minWidth: 960, idealWidth: 1000, minHeight: 580)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            server.start()
            refreshQRCode()
        }
        .onDisappear {
            server.stop()
        }
        .onChange(of: server.isRunning) { running in
            if running { refreshQRCode() }
        }
        .onChange(of: server.port) { _ in
            refreshQRCode()
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定") {}
        } message: {
            Text(alertMessage)
        }
        .alert("确认删除", isPresented: $showDeleteAllConfirm) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) {
                server.uploadedFiles.removeAll()
                server.deleteAllFiles()
            }
        } message: {
            Text("确定要删除上传目录中的所有文件吗？此操作不可撤销。")
        }
    }

    // MARK: - 左侧面板

    private var leftPanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 二维码区域
                qrCodeSection
                    .padding(.bottom, 16)

                Divider()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

//                // 标题
//                Text("文件上传")
//                    .font(.system(size: 20, weight: .semibold))
//                    .foregroundColor(.primary)
//                    .padding(.bottom, 16)
//
//                // 拖拽上传区域
//                dropZone
//                    .padding(.horizontal, 20)
//                    .padding(.bottom, 10)
//
//                // 已选文件预览
//                if !selectedFiles.isEmpty {
//                    filePreviewList
//                        .padding(.horizontal, 20)
//                        .padding(.bottom, 10)
//                }
//
//                // 上传按钮
//                uploadButton
//                    .padding(.horizontal, 20)
//                    .padding(.bottom, 12)

                // 底部信息
                bottomInfo
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            .padding(.top, 20)
        }
    }

    // MARK: - 中间面板：当前上传记录

    private var currentUploadPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text("当前上传记录")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if !server.uploadedFiles.isEmpty {
                    Text("\(server.uploadedFiles.count) 个文件")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button {
                        server.uploadedFiles.removeAll()
                    } label: {
                        Text("清空")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if server.uploadedFiles.isEmpty {
                // 空状态
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    Text("暂无上传记录")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(server.uploadedFiles) { file in
                            uploadedFileRow(file)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 右侧面板：所有上传文件

    private var allFilesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text("所有上传文件")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if !server.allFiles.isEmpty {
                    Text("\(server.allFiles.count) 个文件")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button {
                        showDeleteAllConfirm = true
                    } label: {
                        Text("删除全部")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if server.allFiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 32))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    Text("上传目录暂无文件")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(server.allFiles) { file in
                            allFileRow(file)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func allFileRow(_ file: UploadedFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon(for: file.name))
                .foregroundColor(.accentColor)
                .font(.system(size: 18))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(formatSize(file.size))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\u{00b7}")
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    Text(formatDate(file.date))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            let fileURL = server.uploadDir.appendingPathComponent(file.name)
            if !NSWorkspace.shared.open(fileURL) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
        .help("点击打开文件")
    }

    private func uploadedFileRow(_ file: UploadedFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon(for: file.name))
                .foregroundColor(.accentColor)
                .font(.system(size: 18))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(formatSize(file.size))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    Text(formatDate(file.date))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            let fileURL = server.uploadDir.appendingPathComponent(file.name)
            // 先尝试直接打开文件，失败则在 Finder 中定位选中
            if !NSWorkspace.shared.open(fileURL) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
        .help("点击打开文件，无法打开则在 Finder 中定位")
    }

    // MARK: - 二维码区域

    private var qrCodeSection: some View {
        VStack(spacing: 8) {
            Text("手机扫码访问")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)

            if let img = qrImage {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 156, height: 156)
                    .overlay(Text("生成中...").font(.system(size: 12)).foregroundColor(.secondary))
            }

            // 访问地址
            HStack(spacing: 6) {
                Text(server.accessURL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.accessURL, forType: .string)
                    alertMessage = "链接已复制到剪贴板"
                    showAlert = true
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("复制链接")

                Button {
                    NSWorkspace.shared.open(URL(string: String(server.accessURL))!)
                } label: {
                    Image(systemName: "safari").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("在浏览器中打开")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            Text("请确保手机与电脑在同一 WiFi 网络下")
                .font(.system(size: 10))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 拖拽区域

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isDragging ? Color.accentColor : Color(NSColor.separatorColor),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                )
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isDragging ? Color.accentColor.opacity(0.05) : Color(NSColor.controlBackgroundColor))
                )

            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 28))
                    .foregroundColor(isDragging ? .accentColor : Color(NSColor.tertiaryLabelColor))
                Text("点击选择文件或拖拽文件到此处")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 28)
        }
        .frame(height: 110)
        .contentShape(Rectangle())
        .onTapGesture { selectFiles() }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - 已选文件预览

    private var filePreviewList: some View {
        VStack(spacing: 5) {
            ForEach(selectedFiles, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().scaledToFit()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let sz = fileSize(url) {
                            Text(sz).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        selectedFiles.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                }
                .padding(7)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(7)
            }
        }
    }

    // MARK: - 上传按钮

    private var uploadButton: some View {
        Button(action: doUpload) {
            HStack {
                if isUploading {
                    ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                }
                Text(isUploading ? "上传中..." : "上传")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selectedFiles.isEmpty || isUploading ? Color.accentColor.opacity(0.4) : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(8)
            .font(.system(size: 15, weight: .medium))
        }
        .buttonStyle(.plain)
        .disabled(selectedFiles.isEmpty || isUploading)
    }

    // MARK: - 底部信息

    private var bottomInfo: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                // 用 String(server.port) 避免 UInt16 被本地化格式化（千位逗号）
                Text(server.isRunning ? "服务运行中 · 端口 \(String(server.port))" : "服务未启动")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Text("上传目录: ~/Downloads/FileUpload")
                .font(.system(size: 10))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .lineLimit(1)
                .truncationMode(.middle)
            Button("在 Finder 中显示") {
                NSWorkspace.shared.open(server.uploadDir)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundColor(.accentColor)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 操作方法

    private func refreshQRCode() {
        qrImage = generateQRCode(from: server.accessURL, size: 280)
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let newFiles = panel.urls.filter { !selectedFiles.contains($0) }
            selectedFiles.append(contentsOf: newFiles)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    if !self.selectedFiles.contains(url) { self.selectedFiles.append(url) }
                }
            }
        }
    }

    private func doUpload() {
        guard !selectedFiles.isEmpty else {
            alertMessage = "请先选择文件"; showAlert = true; return
        }
        isUploading = true
        let filesToUpload = selectedFiles
        let uploadDir = server.uploadDir

        DispatchQueue.global(qos: .userInitiated).async {
            var savedFiles: [UploadedFile] = []
            for url in filesToUpload {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let data = try Data(contentsOf: url)
                    let safeName = url.lastPathComponent
                    var destURL = uploadDir.appendingPathComponent(safeName)
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        let ext = destURL.pathExtension
                        let base = destURL.deletingPathExtension().lastPathComponent
                        let uuid = String(UUID().uuidString.prefix(8))
                        destURL = ext.isEmpty
                            ? uploadDir.appendingPathComponent("\(base)_\(uuid)")
                            : uploadDir.appendingPathComponent("\(base)_\(uuid).\(ext)")
                    }
                    try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
                    try data.write(to: destURL)
                    savedFiles.append(UploadedFile(name: destURL.lastPathComponent,
                                                   size: Int64(data.count), date: Date()))
                } catch {
                    print("上传文件失败: \(error)")
                }
            }
            DispatchQueue.main.async {
                self.server.uploadedFiles.insert(contentsOf: savedFiles.reversed(), at: 0)
                self.isUploading = false
                let count = savedFiles.count
                self.alertMessage = count > 0 ? "上传成功，共 \(count) 个文件" : "上传失败，请重试"
                self.showAlert = true
                self.selectedFiles = []
            }
        }
    }

    // MARK: - 辅助

    private func fileSize(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return formatSize(size)
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: date)
    }

    /// 根据文件名返回合适的 SF Symbol 名称
    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "m4v":
            return "play.rectangle"
        case "mp3", "m4a", "wav", "aac", "flac":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox"
        case "doc", "docx":
            return "doc.text"
        case "xls", "xlsx":
            return "tablecells"
        case "ppt", "pptx":
            return "rectangle.on.rectangle"
        case "txt", "md":
            return "doc.plaintext"
        default:
            return "doc"
        }
    }
}

#Preview {
    ContentView()
}
