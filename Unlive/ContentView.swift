//
//  ContentView.swift
//  Unlive
//
//  Created by chao gong on 8/11/26.
//

import SwiftUI
import PhotosUI
import Photos

struct ContentView: View {
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var showingConfirm = false
    @State private var permissionMessage: String?
    @State private var videoItems: [PhotosPickerItem] = []
    @State private var showingVideoPicker = false
    @State private var showingVideoConfirm = false
    /// 上次没删完原视频的个数（App 中途被关掉时会出现）
    @State private var pendingVideoCount = 0
    @State private var showingPendingVideos = false
    @State private var pendingVideoMessage: String?
    /// 每次打开 App 只检查一次
    private static var checkedPendingVideos = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "livephoto.slash")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("定格")
                    .font(.largeTitle.bold())
                Text(selectedItems.isEmpty ? "为相册腾出空间" : "已选 \(selectedItems.count) 张实况照片")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()

                if selectedItems.isEmpty {
                    Button {
                        showingPicker = true
                    } label: {
                        Text("选择实况照片")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    // 第二个入口：压缩视频。选完直接进确认页
                    Button {
                        showingVideoPicker = true
                    } label: {
                        Text("选择视频")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    // 只显示视频（排除电影效果、慢动作、空间视频），最多 30 个
                    .photosPicker(
                        isPresented: $showingVideoPicker,
                        selection: $videoItems,
                        maxSelectionCount: 30,
                        matching: videoPickerFilter,
                        photoLibrary: .shared()
                    )
                } else {
                    Button {
                        Task { await checkPermissionThenContinue() }
                    } label: {
                        Text("完成（\(selectedItems.count)）")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("重新选择") {
                        showingPicker = true
                    }
                }
            }
            .padding()
            // 从底部弹出系统照片选择器：只显示实况照片，最多选 100 张（一次复制太多可能把存储空间写满）。
            // 不用嵌入模式，因为嵌入时系统不支持滑动多选。
            // 必须传 photoLibrary: .shared()，否则拿不到照片的 itemIdentifier，后面就找不到原图。
            .photosPicker(
                isPresented: $showingPicker,
                selection: $selectedItems,
                maxSelectionCount: 100,
                matching: .livePhotos,
                photoLibrary: .shared()
            )
            .navigationDestination(isPresented: $showingConfirm) {
                ConfirmView(identifiers: selectedItems.compactMap(\.itemIdentifier)) {
                    // 结果页点"继续选择"：清空选择，回到首页
                    showingConfirm = false
                    selectedItems = []
                }
            }
            .onChange(of: videoItems) {
                guard !videoItems.isEmpty else { return }
                Task { await checkVideoPermission() }
            }
            .navigationDestination(isPresented: $showingVideoConfirm) {
                VideoConfirmView(identifiers: videoItems.compactMap(\.itemIdentifier)) {
                    // 结果页点"继续选择"：回到首页
                    showingVideoConfirm = false
                }
            }
            // 从确认页返回首页时清空选择，下次重新选
            .onChange(of: showingVideoConfirm) {
                if !showingVideoConfirm { videoItems = [] }
            }
            .task {
                guard !Self.checkedPendingVideos else { return }
                Self.checkedPendingVideos = true
                pendingVideoCount = VideoPendingStore.all().count
                showingPendingVideos = pendingVideoCount > 0
            }
            .alert("上次有 \(pendingVideoCount) 个视频已压缩，原视频还没删除", isPresented: $showingPendingVideos) {
                Button("删除原视频") {
                    Task { await deletePendingVideos() }
                }
                Button("保留两份", role: .cancel) {
                    VideoPendingStore.remove(originalIDs: VideoPendingStore.all().map(\.originalID))
                }
            } message: {
                Text("可能是压缩时 App 被关闭了。压缩后的新视频已经保存在相册里。删除原视频时系统会请你确认，删除的视频会先放进“最近删除”，30 天内可恢复。")
            }
            .alert(
                "提示",
                isPresented: Binding(
                    get: { pendingVideoMessage != nil },
                    set: { if !$0 { pendingVideoMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(pendingVideoMessage ?? "")
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
    }

    /// 第一次点"完成"时才申请权限；拿到完全访问权限才进入确认页
    private func checkPermissionThenContinue() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }

        switch status {
        case .authorized:
            showingConfirm = true
        case .limited:
            permissionMessage = "你只允许了访问部分照片。定格需要访问全部照片，才能找到选中的原图、生成静态照片并删除原图。请在设置里把照片权限改为“完全访问”（或“所有照片”）。"
        default:
            permissionMessage = "定格需要访问你的相册，才能生成静态照片并删除原图。请在设置里把照片权限改为“完全访问”（或“所有照片”）。"
        }
    }

    /// 删除上次没删完的原视频（只删新视频还在的那些）
    private func deletePendingVideos() async {
        do {
            let (deleted, missing) = try await VideoPendingStore.deletePendingOriginals()
            var text = "已删除 \(deleted) 个原视频，清空“最近删除”后空间才会真正释放。"
            if missing > 0 {
                text += "另有 \(missing) 个压缩后的新视频已经找不到，对应的原视频没有删除。"
            }
            pendingVideoMessage = text
        } catch {
            pendingVideoMessage = VideoCompressor.isUserCancelled(error)
                ? "你没有允许删除，原视频还在。下次打开 App 时会再提醒你。"
                : "删除原视频失败：\(error.localizedDescription)。下次打开 App 时会再提醒你。"
        }
    }

    /// 选完视频后检查权限；拿到完全访问权限才进入视频确认页
    private func checkVideoPermission() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }

        switch status {
        case .authorized:
            showingVideoConfirm = true
        case .limited:
            videoItems = []
            permissionMessage = "你只允许了访问部分照片。压缩视频需要访问全部照片，才能找到原视频、保存压缩后的新视频并删除原视频。请在设置里把照片权限改为“完全访问”（或“所有照片”）。"
        default:
            videoItems = []
            permissionMessage = "压缩视频需要访问你的相册。请在设置里把照片权限改为“完全访问”（或“所有照片”）。"
        }
    }
}

// MARK: - 确认页

struct ConfirmView: View {
    let identifiers: [String]
    let onFinish: () -> Void

    @State private var foundCount: Int?
    @State private var videoBytes: Int64 = 0
    @State private var editedIDs: [String] = []
    @State private var showingEditedWarning = false
    @State private var idsToProcess: [String] = []
    @State private var showingProcessing = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if let foundCount {
                Text("已选 \(identifiers.count) 张")
                    .font(.title2.bold())
                Text("约可释放 \(formatMB(videoBytes))")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if foundCount < identifiers.count {
                    Text("有 \(identifiers.count - foundCount) 张在相册里找不到，将不会处理")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } else {
                ProgressView("正在计算可释放空间…")
            }
            Spacer()

            Text("处理完成后，系统会请你确认删除原实况照片。删除的照片会先放进“最近删除”，30 天内可恢复。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if editedIDs.isEmpty {
                    start(identifiers)
                } else {
                    showingEditedWarning = true
                }
            } label: {
                Text("开始处理")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(foundCount == nil || foundCount == 0)
        }
        .padding()
        .navigationTitle("确认")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let ids = identifiers
            let result = await Task.detached { Self.measureVideoSize(identifiers: ids) }.value
            videoBytes = result.bytes
            editedIDs = result.edited
            foundCount = result.found
        }
        // 有编辑过的照片时先提醒：处理后无法复原编辑。选"跳过"的就当没选过，不处理也不删除。
        .confirmationDialog("有 \(editedIDs.count) 张照片编辑过", isPresented: $showingEditedWarning, titleVisibility: .visible) {
            Button("全部处理") {
                start(identifiers)
            }
            if editedIDs.count < identifiers.count {
                Button("跳过编辑过的照片") {
                    let edited = Set(editedIDs)
                    start(identifiers.filter { !edited.contains($0) })
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些照片会按编辑后的样子生成静态照片，删除原图后将无法再“复原”编辑。")
        }
        .navigationDestination(isPresented: $showingProcessing) {
            ProcessingView(identifiers: idsToProcess, onFinish: onFinish)
        }
    }

    private func start(_ ids: [String]) {
        idsToProcess = ids
        showingProcessing = true
    }

    private func formatMB(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// 只统计实况照片里视频部分的大小（删掉原图后真正能省下的就是这些）。
    /// 编辑过的实况照片会额外保存编辑后的视频和编辑前的原始视频，也一起算上。
    /// 同时找出编辑过的照片，开始处理前要提醒用户。
    nonisolated static func measureVideoSize(identifiers: [String]) -> (found: Int, bytes: Int64, edited: [String]) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        let videoTypes: Set<PHAssetResourceType> = [.pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo]
        var total: Int64 = 0
        var edited: [String] = []
        assets.enumerateObjects { asset, _, _ in
            if LivePhotoConverter.isEdited(asset) {
                edited.append(asset.localIdentifier)
            }
            for resource in PHAssetResource.assetResources(for: asset) where videoTypes.contains(resource.type) {
                // 系统没有公开的"文件大小"接口，这里读取资源自带的 fileSize 属性，只用于估算
                if let size = resource.value(forKey: "fileSize") as? Int64 {
                    total += size
                }
            }
        }
        return (assets.count, total, edited)
    }
}

// MARK: - 处理页 / 结果页

struct ProcessingView: View {
    let identifiers: [String]
    let onFinish: () -> Void

    /// 原图没删成时（用户点了"不允许"或出错），等用户决定怎么处理刚生成的副本
    struct PendingDecision {
        let reason: String
        let originalIDs: [String]
        let copyIDs: [String]
    }

    @State private var started = false
    @State private var isWorking = true
    @State private var progress: Double = 0
    @State private var statusText = "准备中…"
    @State private var results: [ConversionResult] = []
    /// 已删除原图的照片（按原图 ID 记）
    @State private var deletedOriginals: Set<String> = []
    /// 用户选择删除了副本的照片（按原图 ID 记）
    @State private var deletedCopies: Set<String> = []
    @State private var pendingDecision: PendingDecision?
    @State private var copyDeletionError: String?

    var body: some View {
        Group {
            if isWorking {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView(value: progress)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("处理过程中请不要离开 App")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            } else {
                resultList
            }
        }
        .navigationTitle(isWorking ? "正在处理" : "处理结果")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task {
            guard !started else { return }
            started = true
            await run(identifiers)
        }
    }

    /// 转换一批照片，然后一次性删除其中转换成功的原图。第一次处理和"重试"都走这里。
    private func run(_ ids: [String]) async {
        isWorking = true
        progress = 0
        statusText = "准备中…"
        // 处理时不让屏幕自动锁定，否则 App 进入后台会中断处理
        UIApplication.shared.isIdleTimerDisabled = true

        let batch = await LivePhotoConverter.convert(identifiers: ids) { value, text in
            Task { @MainActor in
                progress = value
                statusText = text
            }
        }
        // 重试的结果替换掉原来那条失败记录
        for result in batch {
            if let index = results.firstIndex(where: { $0.originalID == result.originalID }) {
                results[index] = result
            } else {
                results.append(result)
            }
        }

        // 只删除这一批里转换成功（新照片已确认写入相册）的原图
        let succeeded = batch.filter(\.succeeded)
        if !succeeded.isEmpty {
            statusText = "正在删除原实况照片…"
            let originalIDs = succeeded.map(\.originalID)
            do {
                try await LivePhotoConverter.deleteAssets(identifiers: originalIDs)
                deletedOriginals.formUnion(originalIDs)
            } catch {
                let reason = LivePhotoConverter.isUserCancelled(error)
                    ? "你在系统弹窗里没有允许删除。"
                    : "删除原图时出错：\(error.localizedDescription)"
                pendingDecision = PendingDecision(reason: reason, originalIDs: originalIDs, copyIDs: succeeded.compactMap(\.newID))
            }
        }

        UIApplication.shared.isIdleTimerDisabled = false
        isWorking = false
    }

    /// 原图没删时，用户选择删除刚生成的副本（同样会弹系统确认框）
    /// 原图没删时，用户选择再删一次原图（系统会再弹一次确认框）
    private func deleteOriginalsAgain(_ decision: PendingDecision) async {
        do {
            try await LivePhotoConverter.deleteAssets(identifiers: decision.originalIDs)
            deletedOriginals.formUnion(decision.originalIDs)
            copyDeletionError = nil
            pendingDecision = nil
        } catch {
            copyDeletionError = LivePhotoConverter.isUserCancelled(error)
                ? "你没有允许删除，原实况照片仍在。"
                : "删除原图失败：\(error.localizedDescription)"
        }
    }

    private func deleteCopies(_ decision: PendingDecision) async {
        do {
            try await LivePhotoConverter.deleteAssets(identifiers: decision.copyIDs)
            deletedCopies.formUnion(decision.originalIDs)
            copyDeletionError = nil
            pendingDecision = nil
        } catch {
            copyDeletionError = LivePhotoConverter.isUserCancelled(error)
                ? "你没有允许删除，副本仍然保留着。"
                : "删除副本失败：\(error.localizedDescription)"
        }
    }

    private var resultList: some View {
        let succeeded = results.filter(\.succeeded)
        let failed = results.filter { !$0.succeeded }
        let warnings = succeeded.flatMap(\.warnings)
        let deletedCount = succeeded.filter { deletedOriginals.contains($0.originalID) }.count
        let undoneCount = succeeded.filter { deletedCopies.contains($0.originalID) }.count
        let pendingCount = pendingDecision?.originalIDs.count ?? 0
        let keptCount = succeeded.count - deletedCount - undoneCount - pendingCount

        return List {
            Section {
                Label("成功 \(succeeded.count) 张", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !failed.isEmpty {
                    Label("失败 \(failed.count) 张", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                if deletedCount > 0 {
                    Text("其中 \(deletedCount) 张原实况照片已删除")
                }
                if keptCount > 0 {
                    Text("其中 \(keptCount) 张保留了静态副本，原实况照片也还在")
                }
                if undoneCount > 0 {
                    Text("其中 \(undoneCount) 张已删除刚生成的副本，原实况照片还在")
                }
            }

            if let pendingDecision {
                Section("原图没有删除") {
                    Text(pendingDecision.reason)
                    Text("\(pendingDecision.originalIDs.count) 张静态副本已经生成，原实况照片仍在。请选择怎么处理：")
                    // 刚才误点了"不允许"时，可以再删一次原图（系统会再弹一次确认框）
                    Button("删除原实况照片") {
                        Task { await deleteOriginalsAgain(pendingDecision) }
                    }
                    Button("保留副本（两份都留着）") {
                        self.pendingDecision = nil
                        copyDeletionError = nil
                    }
                    Button("删除刚生成的副本", role: .destructive) {
                        Task { await deleteCopies(pendingDecision) }
                    }
                    if let copyDeletionError {
                        Text(copyDeletionError)
                            .foregroundStyle(.red)
                    }
                }
            }

            if deletedCount > 0 {
                Section {
                    Label("原图已移到“最近删除”。去照片 App 的“相簿”页，在最下面找到“最近删除”并清空后，空间才会真正释放。", systemImage: "info.circle")
                        .font(.subheadline)
                }
            }

            if !failed.isEmpty {
                Section {
                    ForEach(failed) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.label)
                            Text(result.errorMessage ?? "未知错误")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    Button("重试失败的 \(failed.count) 张") {
                        Task { await run(failed.map(\.originalID)) }
                    }
                    .disabled(pendingDecision != nil)
                } header: {
                    Text("失败原因")
                } footer: {
                    if pendingDecision != nil {
                        Text("请先处理上面的副本，再重试")
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

#Preview {
    ContentView()
}
