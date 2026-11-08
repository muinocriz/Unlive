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

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "livephoto.slash")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("定格")
                    .font(.largeTitle.bold())
                Text(selectedItems.isEmpty ? "把实况照片变成静态照片，节省空间" : "已选 \(selectedItems.count) 张实况照片")
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
            // 从底部弹出系统照片选择器：只显示实况照片，多选不限数量。
            // 不用嵌入模式，因为嵌入时系统不支持滑动多选。
            // 必须传 photoLibrary: .shared()，否则拿不到照片的 itemIdentifier，后面就找不到原图。
            .photosPicker(
                isPresented: $showingPicker,
                selection: $selectedItems,
                maxSelectionCount: nil,
                matching: .livePhotos,
                photoLibrary: .shared()
            )
            .navigationDestination(isPresented: $showingConfirm) {
                ConfirmView(identifiers: selectedItems.compactMap(\.itemIdentifier)) {
                    // 处理完点"返回首页"：清空选择，回到首页
                    showingConfirm = false
                    selectedItems = []
                }
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
}

// MARK: - 确认页

struct ConfirmView: View {
    let identifiers: [String]
    let onFinish: () -> Void

    @State private var foundCount: Int?
    @State private var videoBytes: Int64 = 0
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

            Button {
                showingProcessing = true
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
            foundCount = result.found
        }
        .navigationDestination(isPresented: $showingProcessing) {
            ProcessingView(identifiers: identifiers, onFinish: onFinish)
        }
    }

    private func formatMB(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// 只统计实况照片里视频部分的大小（删掉原图后真正能省下的就是这些）。
    /// 编辑过的实况照片会额外保存编辑后的视频和编辑前的原始视频，也一起算上。
    nonisolated static func measureVideoSize(identifiers: [String]) -> (found: Int, bytes: Int64) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        let videoTypes: Set<PHAssetResourceType> = [.pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo]
        var total: Int64 = 0
        assets.enumerateObjects { asset, _, _ in
            for resource in PHAssetResource.assetResources(for: asset) where videoTypes.contains(resource.type) {
                // 系统没有公开的"文件大小"接口，这里读取资源自带的 fileSize 属性，只用于估算
                if let size = resource.value(forKey: "fileSize") as? Int64 {
                    total += size
                }
            }
        }
        return (assets.count, total)
    }
}

// MARK: - 处理页

struct ProcessingView: View {
    let identifiers: [String]
    let onFinish: () -> Void

    @State private var progress: Double = 0
    @State private var statusText = "准备中…"
    @State private var results: [ConversionResult]?

    var body: some View {
        Group {
            if let results {
                resultList(results)
            } else {
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
            }
        }
        .navigationTitle(results == nil ? "正在处理" : "处理结果")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task {
            guard results == nil else { return }
            // 处理时不让屏幕自动锁定，否则 App 进入后台会中断处理
            UIApplication.shared.isIdleTimerDisabled = true
            let finished = await LivePhotoConverter.convert(identifiers: identifiers) { value, text in
                Task { @MainActor in
                    progress = value
                    statusText = text
                }
            }
            UIApplication.shared.isIdleTimerDisabled = false
            results = finished
        }
    }

    /// 临时的结果汇总（完整的结果页在第 5 步做）
    private func resultList(_ results: [ConversionResult]) -> some View {
        let succeeded = results.filter(\.succeeded)
        let failed = results.filter { !$0.succeeded }
        let warned = succeeded.filter { !$0.warnings.isEmpty }

        return List {
            Section {
                Text("成功生成 \(succeeded.count) 张静态照片")
                if !failed.isEmpty {
                    Text("失败 \(failed.count) 张")
                        .foregroundStyle(.red)
                }
                Text("原实况照片都还在，这一步不会删除")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !failed.isEmpty {
                Section("失败原因") {
                    ForEach(failed) { Text($0.errorMessage ?? "未知错误") }
                }
            }
            if !warned.isEmpty {
                Section("需要注意") {
                    ForEach(warned) { result in
                        ForEach(result.warnings, id: \.self) { Text($0) }
                    }
                }
            }
            Section {
                Button("返回首页", action: onFinish)
            }
        }
    }
}

#Preview {
    ContentView()
}
