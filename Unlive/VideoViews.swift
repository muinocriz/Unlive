//
//  VideoViews.swift
//  Unlive
//
//  视频压缩功能的页面。
//  阶段 1（测试版）：选一个视频 → 看参数 → 压缩并保存为新视频，**不删除原片**，
//  用来在真机上检查元数据、画质、HDR 和速度。
//

import SwiftUI
import PhotosUI
import Photos

struct VideoTestView: View {
    @State private var selection: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var permissionMessage: String?

    @State private var asset: PHAsset?
    @State private var info: VideoInfo?
    @State private var quality: VideoQuality = .high

    @State private var isBusy = false
    @State private var progress: Double = 0
    @State private var statusText = ""
    @State private var result: VideoCompressionResult?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("测试版：压缩后会保存为一个新视频，原视频保留不删，方便你对比。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(asset == nil ? "选择一个视频" : "重新选择") {
                    showingPicker = true
                }
                .disabled(isBusy)
            }

            if let info {
                Section("原视频") {
                    row("规格", info.label)
                    row("分辨率", "\(info.width) × \(info.height)")
                    row("帧率", String(format: "%.2f fps", info.frameRate))
                    row("时长", formatDuration(info.duration))
                    row("视频码率", String(format: "%.1f Mbps", info.videoBitRate / 1_000_000))
                    if let bytes = info.fileBytes {
                        row("文件大小", formatBytes(bytes))
                    }
                }

                Section("压缩") {
                    Picker("画质", selection: $quality) {
                        ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isBusy)

                    if let target = info.targetBitRate(quality), let estimate = info.estimatedBytes(quality) {
                        row("目标码率", String(format: "%.1f Mbps", target / 1_000_000))
                        row("预计大小", "约 \(formatBytes(estimate))")
                        row("预计耗时", "约 \(formatDuration(info.duration / 2))")
                        Button("开始压缩") {
                            Task { await compress() }
                        }
                        .disabled(isBusy)
                    } else {
                        Text("无需压缩：这个视频的码率已经不高于这一档")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isBusy {
                Section {
                    ProgressView(value: progress)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("压缩过程中请不要离开 App")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if let result {
                Section("结果") {
                    Label("新视频已保存到相册", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let original = result.originalBytes {
                        row("大小", "\(formatBytes(original)) → \(formatBytes(result.newBytes))")
                    } else {
                        row("新视频大小", formatBytes(result.newBytes))
                    }
                    row("实际码率", String(format: "%.1f Mbps", result.targetBitRate / 1_000_000))
                    row("耗时", formatDuration(result.seconds))
                    Text("原视频没有删除。请去照片 App 对比两个视频的日期、位置、画质。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !result.warnings.isEmpty {
                    Section("需要注意") {
                        ForEach(result.warnings, id: \.self) { Text($0) }
                    }
                }
            }
        }
        .navigationTitle("压缩视频（测试版）")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isBusy)
        // 只显示视频，排除电影效果、慢动作、空间视频（压缩会丢失它们的特殊信息）
        .photosPicker(
            isPresented: $showingPicker,
            selection: $selection,
            maxSelectionCount: 1,
            matching: Self.videoFilter,
            photoLibrary: .shared()
        )
        .onChange(of: selection) {
            guard let id = selection.first?.itemIdentifier else { return }
            Task { await load(id) }
        }
        .alert(
            "需要相册的完全访问权限",
            isPresented: Binding(
                get: { permissionMessage != nil },
                set: { if !$0 { permissionMessage = nil } }
            )
        ) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(permissionMessage ?? "")
        }
    }

    static var videoFilter: PHPickerFilter {
        var excluded: [PHPickerFilter] = [.cinematicVideos, .slomoVideos]
        if #available(iOS 18.0, *) {
            excluded.append(.spatialMedia)
        }
        return .all(of: [.videos, .not(.any(of: excluded))])
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    /// 选好视频后：确认权限，再读取参数
    private func load(_ id: String) async {
        asset = nil
        info = nil
        result = nil
        errorMessage = nil

        guard await hasFullAccess() else { return }
        guard let picked = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            errorMessage = "相册里找不到这个视频（可能已被删除）"
            return
        }

        isBusy = true
        progress = 0
        statusText = "正在读取视频…"
        do {
            info = try await VideoCompressor.inspect(picked) { fraction in
                Task { @MainActor in
                    progress = fraction
                    statusText = "正在从 iCloud 下载 \(Int(fraction * 100))%"
                }
            }
            asset = picked
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func compress() async {
        guard let asset else { return }
        result = nil
        errorMessage = nil
        isBusy = true
        progress = 0
        statusText = "准备中…"
        // 压缩时不让屏幕自动锁定，否则 App 进入后台会中断压缩
        UIApplication.shared.isIdleTimerDisabled = true

        do {
            result = try await VideoCompressor.compressAndSave(asset, quality: quality) { value, text in
                Task { @MainActor in
                    progress = value
                    statusText = text
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        UIApplication.shared.isIdleTimerDisabled = false
        isBusy = false
    }

    /// 需要完全访问权限才能找到原视频、保存新视频
    private func hasFullAccess() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        switch status {
        case .authorized:
            return true
        case .limited:
            permissionMessage = "你只允许了访问部分照片。压缩视频需要访问全部照片，才能找到原视频并保存压缩后的新视频。请在设置里把照片权限改为“完全访问”（或“所有照片”）。"
        default:
            permissionMessage = "压缩视频需要访问你的相册。请在设置里把照片权限改为“完全访问”（或“所有照片”）。"
        }
        return false
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000 ? String(format: "%.2f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) 分 \(total % 60) 秒" : "\(total) 秒"
    }
}
