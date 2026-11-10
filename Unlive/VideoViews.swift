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
                        row("预计耗时", "约 \(formatDuration(info.estimatedSeconds))")
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

// MARK: - 正式流程：确认页

/// 确认页里的一个视频
struct VideoItem: Identifiable {
    let id: String
    var asset: PHAsset?
    var info: VideoInfo?
    var needsDownload = false
    var isEdited = false
    /// 不能处理的原因（找不到、电影效果、共享相簿等）；nil 表示可以处理
    var unsupportedReason: String?
    var isLoaded = false

    /// 在当前画质档下是否值得压缩。只在 iCloud 上、参数未知的，先当作值得压缩
    func isCompressible(_ quality: VideoQuality) -> Bool {
        guard isLoaded, unsupportedReason == nil else { return false }
        guard let info else { return true }
        return info.targetBitRate(quality) != nil
    }
}

struct VideoConfirmView: View {
    let identifiers: [String]
    let onFinish: () -> Void

    @State private var items: [VideoItem] = []
    @State private var quality: VideoQuality = .high
    /// 用户手动取消勾选的视频（其余值得压缩的默认勾选）
    @State private var unchecked: Set<String> = []
    @State private var showingEditedWarning = false
    @State private var idsToProcess: [String] = []
    @State private var showingProcessing = false
    @State private var spaceMessage: String?

    private var isLoading: Bool { items.contains { !$0.isLoaded } }
    private var selected: [VideoItem] {
        items.filter { $0.isCompressible(quality) && !unchecked.contains($0.id) }
    }
    private var savedBytes: Int64 {
        selected.reduce(0) { total, item in
            guard let info = item.info, let original = info.fileBytes, let estimate = info.estimatedBytes(quality) else { return total }
            return total + max(original - estimate, 0)
        }
    }
    private var estimatedSeconds: Double {
        selected.reduce(0) { $0 + ($1.info?.estimatedSeconds ?? 0) }
    }

    var body: some View {
        List {
            Section {
                Picker("画质", selection: $quality) {
                    ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(quality == .high ? "画质几乎看不出变化，空间节省得少一些。" : "空间节省得更多，放大看细节会略有损失。")
            }

            Section {
                ForEach(items) { item in
                    VideoRow(
                        item: item,
                        quality: quality,
                        isChecked: item.isCompressible(quality) && !unchecked.contains(item.id)
                    ) {
                        if unchecked.contains(item.id) {
                            unchecked.remove(item.id)
                        } else {
                            unchecked.insert(item.id)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("已选 \(identifiers.count) 个视频")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard items.isEmpty else { return }
            await loadItems()
        }
        // 有编辑过的视频时先提醒：处理后无法复原编辑。选"跳过"的就当没选过。
        .confirmationDialog("有 \(editedSelected.count) 个视频编辑过", isPresented: $showingEditedWarning, titleVisibility: .visible) {
            Button("全部处理") {
                start(selected.map(\.id))
            }
            if editedSelected.count < selected.count {
                Button("跳过编辑过的视频") {
                    start(selected.filter { !$0.isEdited }.map(\.id))
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些视频会按编辑后的样子压缩，删除原视频后将无法再“复原”编辑。")
        }
        .navigationDestination(isPresented: $showingProcessing) {
            VideoProcessingView(identifiers: idsToProcess, quality: quality, onFinish: onFinish)
        }
        .alert(
            "手机存储空间不足",
            isPresented: Binding(
                get: { spaceMessage != nil },
                set: { if !$0 { spaceMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(spaceMessage ?? "")
        }
    }

    private var editedSelected: [VideoItem] { selected.filter(\.isEdited) }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView("正在读取视频信息…")
            } else {
                Text("共 \(selected.count) 个，约可节省 \(VideoFormat.bytes(savedBytes))，预计耗时约 \(VideoFormat.duration(estimatedSeconds))")
                    .font(.subheadline)
                if estimatedSeconds > 600 {
                    Label("预计超过 10 分钟，建议接上电源", systemImage: "bolt.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if selected.contains(where: \.needsDownload) {
                    Text("“需下载”的视频要先从 iCloud 下载原片，实际节省空间和耗时以压缩时为准。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Text("压缩完成后，系统会请你确认删除原视频。删除的视频会先放进“最近删除”，30 天内可恢复。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                if editedSelected.isEmpty {
                    start(selected.map(\.id))
                } else {
                    showingEditedWarning = true
                }
            } label: {
                Text("开始压缩（\(selected.count)）")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || selected.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func start(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        if let message = spaceShortage(for: ids) {
            spaceMessage = message
            return
        }
        idsToProcess = ids
        showingProcessing = true
    }

    /// 开始前检查剩余空间。原视频要等全部压完才删除，所以压缩期间要放得下：
    /// 所有新视频 + 要从 iCloud 下载的原视频 + 1GB 余量。放得下返回 nil，放不下返回给用户看的说明。
    private func spaceShortage(for ids: [String]) -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            // 读不到剩余空间时不拦着；真写满了，压缩会失败并提示，原视频不会被删
            return nil
        }
        let chosen = Set(ids)
        let needs: [Int64] = items.filter { chosen.contains($0.id) }.map { item in
            let output = item.info?.estimatedBytes(quality) ?? item.info?.fileBytes ?? 0
            let download = item.needsDownload ? (item.info?.fileBytes ?? 0) : 0
            return output + download
        }
        let margin: Int64 = 1_000_000_000
        let required = needs.reduce(0, +) + margin
        guard required > available else { return nil }

        // 从占空间最大的开始去掉，算出大约要少选几个
        var remaining = required
        var removeCount = 0
        for need in needs.sorted(by: >) where remaining > available {
            remaining -= need
            removeCount += 1
        }
        return "这批视频压缩时大约需要 \(VideoFormat.bytes(required)) 的空闲空间（原视频要等全部压完才删除），手机目前只剩 \(VideoFormat.bytes(available))。建议少选约 \(removeCount) 个视频，或先清理手机空间（包括清空“最近删除”）后再试。"
    }

    /// 逐个读取参数（不下载），读完一个显示一个
    private func loadItems() async {
        items = identifiers.map { VideoItem(id: $0) }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assetsByID[asset.localIdentifier] = asset }

        for index in items.indices {
            var item = items[index]
            if let asset = assetsByID[item.id] {
                item.asset = asset
                item.isEdited = VideoCompressor.isEdited(asset)
                item.unsupportedReason = VideoCompressor.unsupportedReason(asset)
                if item.unsupportedReason == nil {
                    let (info, needsDownload) = await VideoCompressor.quickInspect(asset)
                    item.info = info
                    item.needsDownload = needsDownload
                }
            } else {
                item.unsupportedReason = "相册里找不到这个视频（可能已被删除）"
            }
            item.isLoaded = true
            items[index] = item
        }
    }
}

/// 确认页的一行：缩略图、时长、标签、大小变化、勾选框
struct VideoRow: View {
    let item: VideoItem
    let quality: VideoQuality
    let isChecked: Bool
    let onToggle: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            if let thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if let asset = item.asset {
                        Text(VideoFormat.clock(asset.duration))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(3)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(item.unsupportedReason == nil ? Color.secondary : Color.red)
                }
                Spacer()

                if item.isLoaded && item.isCompressible(quality) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                } else if !item.isLoaded {
                    ProgressView()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.isCompressible(quality))
        .task(id: item.asset?.localIdentifier) {
            guard let asset = item.asset, thumbnail == nil else { return }
            thumbnail = await Self.loadThumbnail(asset)
        }
    }

    /// 第一行：规格 · 建议
    private var title: String {
        guard item.isLoaded else { return "正在读取…" }
        guard item.unsupportedReason == nil else { return "无法处理" }
        var parts: [String] = []
        if let info = item.info { parts.append(info.label) }
        if item.needsDownload { parts.append("需下载") }
        if item.isEdited { parts.append("编辑过") }
        parts.append(item.isCompressible(quality) ? "建议压缩" : "无需压缩")
        return parts.joined(separator: " · ")
    }

    /// 第二行：大小变化，或不能处理的原因
    private var detail: String {
        if let reason = item.unsupportedReason { return reason }
        guard let info = item.info, let original = info.fileBytes else {
            return item.isLoaded ? "大小未知，压缩时再计算" : ""
        }
        if let estimate = info.estimatedBytes(quality) {
            return "\(VideoFormat.bytes(original)) → 约 \(VideoFormat.bytes(estimate))"
        }
        return "\(VideoFormat.bytes(original))，码率已经很低"
    }

    private static func loadThumbnail(_ asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 192, height: 192),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - 正式流程：压缩页 / 结果页

/// 一个视频的处理结果
struct VideoJobResult: Identifiable {
    let id: String
    let label: String
    var result: VideoCompressionResult?
    var errorMessage: String?
    /// 不需要或不适合处理（如码率已经很低），不算失败，也不提供重试
    var isSkipped = false
    var succeeded: Bool { result != nil }
    var failed: Bool { result == nil && !isSkipped }
}

/// 逐个压缩并保存为新视频，全部完成后一次删除验证通过的原视频
struct VideoProcessingView: View {
    let identifiers: [String]
    let quality: VideoQuality
    let onFinish: () -> Void

    /// 原视频没删成时（用户点了"不允许"或出错），等用户决定怎么处理刚生成的新视频
    struct PendingDecision {
        let reason: String
        let originalIDs: [String]
        let newIDs: [String]
    }

    @State private var started = false
    @State private var isWorking = true
    @State private var progress: Double = 0
    @State private var statusText = "准备中…"
    @State private var results: [VideoJobResult] = []
    /// 已删除原视频的（按原视频 ID 记）
    @State private var deletedOriginals: Set<String> = []
    /// 用户选择删除了新视频的（按原视频 ID 记）
    @State private var deletedCopies: Set<String> = []
    @State private var pendingDecision: PendingDecision?
    @State private var copyDeletionError: String?
    @State private var cancelFlag = CancelFlag()
    @State private var isCancelling = false
    @State private var showingCancelConfirm = false
    @State private var background = VideoBackgroundRunner()
    /// 后台继续压缩开启失败时的说明
    @State private var backgroundError: String?
    /// 压完了，等用户回到 App 确认删除
    @State private var waitingForForeground = false

    var body: some View {
        Group {
            if isWorking {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView(value: progress)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let backgroundError {
                        Text(backgroundError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    } else if VideoBackgroundRunner.isSupported {
                        Text("可以切到其他 App，压缩会在后台继续。压完后需要回到这里确认删除原视频。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("压缩过程中请不要离开 App")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !waitingForForeground {
                        Button("取消", role: .destructive) {
                            showingCancelConfirm = true
                        }
                        .disabled(isCancelling)
                    }
                }
                .padding()
            } else {
                resultList
            }
        }
        .navigationTitle(isWorking ? "正在压缩" : "压缩结果")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task {
            guard !started else { return }
            started = true
            await run(identifiers)
        }
        .confirmationDialog("确定要取消吗？", isPresented: $showingCancelConfirm, titleVisibility: .visible) {
            Button("取消压缩", role: .destructive) {
                cancel()
            }
            Button("继续压缩", role: .cancel) {}
        } message: {
            Text("正在压缩的这个会放弃，后面的不再处理，它们的原视频都保留不动。已经压好的仍会请你确认删除原视频。")
        }
    }

    private func cancel() {
        isCancelling = true
        cancelFlag.cancel()
        statusText = "正在取消…"
    }

    /// 压缩一批视频，然后一次性删除其中新视频已验证通过的原视频。第一次处理和"重试"都走这里。
    private func run(_ ids: [String]) async {
        isWorking = true
        isCancelling = false
        waitingForForeground = false
        progress = 0
        statusText = "准备中…"
        // 压缩时不让屏幕自动锁定
        UIApplication.shared.isIdleTimerDisabled = true

        // 每一批（包括重试）用新的取消开关
        let cancel = CancelFlag()
        cancelFlag = cancel
        // 申请后台继续压缩（iOS 26 起）；用户在系统界面里取消时，等同于点了"取消"
        background.onExpire = { [cancel] in
            cancel.cancel()
        }
        backgroundError = nil
        if VideoBackgroundRunner.isSupported {
            do {
                try background.start()
            } catch {
                backgroundError = "没能开启后台继续压缩（\(error.localizedDescription)），压缩过程中请不要离开 App。"
            }
        }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assetsByID[asset.localIdentifier] = asset }
        let total = Double(ids.count)

        var batch: [VideoJobResult] = []
        for (index, id) in ids.enumerated() {
            let step = "第 \(index + 1) / \(ids.count) 个"
            progress = Double(index) / total
            if cancel.isCancelled {
                // 取消后剩下的不再处理
                batch.append(VideoJobResult(id: id, label: label(for: assetsByID[id]), errorMessage: VideoError.cancelled.message, isSkipped: true))
                continue
            }
            statusText = step
            background.update(progress: progress, subtitle: step)

            guard let asset = assetsByID[id] else {
                batch.append(VideoJobResult(id: id, label: "一个视频", errorMessage: "相册里找不到这个视频（可能已被删除）"))
                continue
            }
            let jobLabel = label(for: asset)
            do {
                let result = try await VideoCompressor.compressAndSave(asset, quality: quality, cancel: cancel) { value, text in
                    Task { @MainActor in
                        guard !cancel.isCancelled else { return }
                        progress = (Double(index) + value) / total
                        statusText = "\(step)：\(text)"
                        background.update(progress: progress, subtitle: "\(step)：\(text)")
                    }
                }
                // 记下来：万一 App 在删除原视频前被关掉，下次打开时提醒
                VideoPendingStore.add(originalID: id, newID: result.newID)
                batch.append(VideoJobResult(id: id, label: jobLabel, result: result))
            } catch {
                let skipped = (error as? VideoError)?.isSkipped ?? false
                batch.append(VideoJobResult(id: id, label: jobLabel, errorMessage: error.localizedDescription, isSkipped: skipped))
            }
        }

        // 重试的结果替换掉原来那条记录
        for job in batch {
            if let index = results.firstIndex(where: { $0.id == job.id }) {
                results[index] = job
            } else {
                results.append(job)
            }
        }

        // 压缩部分结束，告诉系统后台任务完成了
        background.finish(success: true)

        // 只删除这一批里新视频已验证通过的原视频，放在一次操作里，系统只弹一次确认框
        let succeeded = batch.filter(\.succeeded)
        if !succeeded.isEmpty {
            progress = 1
            // 系统删除确认框只能在 App 前台弹出：在后台压完的，等用户回来
            if UIApplication.shared.applicationState != .active {
                waitingForForeground = true
                statusText = "压缩完成，请回到 App 确认删除原视频"
                while UIApplication.shared.applicationState != .active {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                waitingForForeground = false
            }
            statusText = "正在删除原视频…"
            let originalIDs = succeeded.map(\.id)
            do {
                try await VideoCompressor.deleteAssets(identifiers: originalIDs)
                deletedOriginals.formUnion(originalIDs)
                VideoPendingStore.remove(originalIDs: originalIDs)
            } catch {
                let reason = VideoCompressor.isUserCancelled(error)
                    ? "你在系统弹窗里没有允许删除。"
                    : "删除原视频时出错：\(error.localizedDescription)"
                pendingDecision = PendingDecision(reason: reason, originalIDs: originalIDs, newIDs: succeeded.compactMap { $0.result?.newID })
            }
        }

        UIApplication.shared.isIdleTimerDisabled = false
        isWorking = false
    }

    private func label(for asset: PHAsset?) -> String {
        asset?.creationDate.map { "拍摄于 \($0.formatted(date: .abbreviated, time: .shortened)) 的视频" } ?? "一个视频"
    }

    /// 原视频没删时，用户选择删除刚生成的新视频（同样会弹系统确认框）
    private func deleteCopies(_ decision: PendingDecision) async {
        do {
            try await VideoCompressor.deleteAssets(identifiers: decision.newIDs)
            VideoPendingStore.remove(originalIDs: decision.originalIDs)
            deletedCopies.formUnion(decision.originalIDs)
            copyDeletionError = nil
            pendingDecision = nil
        } catch {
            copyDeletionError = VideoCompressor.isUserCancelled(error)
                ? "你没有允许删除，新视频仍然保留着。"
                : "删除新视频失败：\(error.localizedDescription)"
        }
    }

    private var resultList: some View {
        let succeeded = results.filter(\.succeeded)
        let failed = results.filter(\.failed)
        let skipped = results.filter(\.isSkipped)
        let warnings = succeeded.flatMap { $0.result?.warnings ?? [] }
        let deleted = succeeded.filter { deletedOriginals.contains($0.id) }
        let undoneCount = succeeded.filter { deletedCopies.contains($0.id) }.count
        let pendingCount = pendingDecision?.originalIDs.count ?? 0
        let keptCount = succeeded.count - deleted.count - undoneCount - pendingCount
        // 只算原视频真的删掉了的
        let saved = deleted.reduce(Int64(0)) { total, job in
            guard let r = job.result, let original = r.originalBytes else { return total }
            return total + max(original - r.newBytes, 0)
        }

        return List {
            Section {
                Label("成功 \(succeeded.count) 个", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !failed.isEmpty {
                    Label("失败 \(failed.count) 个", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                if !skipped.isEmpty {
                    Label("跳过 \(skipped.count) 个", systemImage: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                if !deleted.isEmpty {
                    Text("其中 \(deleted.count) 个原视频已删除")
                }
                if keptCount > 0 {
                    Text("其中 \(keptCount) 个保留了压缩后的新视频，原视频也还在")
                }
                if undoneCount > 0 {
                    Text("其中 \(undoneCount) 个已删除刚生成的新视频，原视频还在")
                }
            }

            if let pendingDecision {
                Section("原视频没有删除") {
                    Text(pendingDecision.reason)
                    Text("\(pendingDecision.originalIDs.count) 个压缩后的新视频已经生成，原视频仍在。请选择怎么处理刚生成的新视频：")
                    Button("保留新视频") {
                        VideoPendingStore.remove(originalIDs: pendingDecision.originalIDs)
                        self.pendingDecision = nil
                        copyDeletionError = nil
                    }
                    Button("删除刚生成的新视频", role: .destructive) {
                        Task { await deleteCopies(pendingDecision) }
                    }
                    if let copyDeletionError {
                        Text(copyDeletionError)
                            .foregroundStyle(.red)
                    }
                }
            }

            if !deleted.isEmpty {
                Section {
                    Text("已节省 \(VideoFormat.bytes(saved))，清空“最近删除”后生效")
                        .font(.headline)
                    Label("原视频已移到“最近删除”，30 天内可恢复。去照片 App 的“相簿”页，在最下面找到“最近删除”并清空后，空间才会真正释放。", systemImage: "info.circle")
                        .font(.subheadline)
                }
            }

            if !succeeded.isEmpty {
                Section("已压缩") {
                    ForEach(succeeded) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.label)
                            if let r = job.result {
                                Text("\(r.originalBytes.map(VideoFormat.bytes) ?? "未知") → \(VideoFormat.bytes(r.newBytes))，用时 \(VideoFormat.duration(r.seconds))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !failed.isEmpty {
                Section {
                    ForEach(failed) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.label)
                            Text(job.errorMessage ?? "未知错误")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    Button("重试失败的 \(failed.count) 个") {
                        Task { await run(failed.map(\.id)) }
                    }
                    .disabled(pendingDecision != nil)
                } header: {
                    Text("失败原因")
                } footer: {
                    if pendingDecision != nil {
                        Text("请先处理上面的新视频，再重试")
                    }
                }
            }

            if !skipped.isEmpty {
                Section("跳过的视频（原视频保留不动）") {
                    ForEach(skipped) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.label)
                            Text(job.errorMessage ?? "")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !warnings.isEmpty {
                Section("需要注意") {
                    ForEach(warnings, id: \.self) { Text($0) }
                }
            }

            Section {
                Button("继续选择", action: onFinish)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - 共用

/// 视频选择器：只显示视频，排除电影效果、慢动作、空间视频（压缩会丢失它们的特殊信息）
let videoPickerFilter: PHPickerFilter = {
    var excluded: [PHPickerFilter] = [.cinematicVideos, .slomoVideos]
    if #available(iOS 18.0, *) {
        excluded.append(.spatialMedia)
    }
    return .all(of: [.videos, .not(.any(of: excluded))])
}()

/// 大小、时长的显示格式
nonisolated enum VideoFormat {
    static func bytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000 ? String(format: "%.2f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) 分 \(total % 60) 秒" : "\(total) 秒"
    }

    /// 缩略图上的时长，如 0:17、12:05
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
