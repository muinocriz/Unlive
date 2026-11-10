//
//  VideoCompressor.swift
//  Unlive
//
//  视频压缩模块（独立于实况照片功能，方便以后拆分）：
//  读取原视频 → 用 HEVC 10bit 按更低码率重新压缩（分辨率、帧率、每帧时间戳不变，音频原样复制）
//  → 把文件里的元数据（拍摄时间、GPS、机型等）带过去 → 保存为新视频，并带上相册层面的信息
//  → 验证新视频能正常读取、时长与原片一致。
//  删除原片另外处理，只在新视频验证通过后才删。
//

import Foundation
import Photos
import AVFoundation
import VideoToolbox
import UniformTypeIdentifiers

/// 两档画质，界面上不出现码率数字
nonisolated enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case high = "高画质"
    case saver = "省空间"
    var id: String { rawValue }
}

/// 压缩前读到的原视频参数
nonisolated struct VideoInfo: Sendable {
    let width: Int
    let height: Int
    let duration: Double
    /// 平均帧率，自动帧率视频可能是 27.3 这类值
    let frameRate: Float
    /// 视频部分的平均码率（bit/s，不含音频）
    let videoBitRate: Double
    /// 音频部分的码率合计（bit/s），用来估算压缩后的大小
    let audioBitRate: Double
    let isHDR: Bool
    /// 原视频文件大小；系统没给时为 nil
    let fileBytes: Int64?
    /// 视频只在 iCloud 上、没下载时为 true：码率按"文件大小 ÷ 时长"估算，帧率按 60fps 算（偏保守），
    /// 真正压缩时会下载原片，再按实际参数重新计算
    var isApproximate = false

    /// 按短边只分 4K / 1080p
    var is4K: Bool { min(width, height) > 1080 }
    /// 平均帧率 ≥ 45 归入 60fps 档
    var is60fps: Bool { frameRate >= 45 }

    var label: String {
        if isApproximate { return is4K ? "4K" : "1080p" }
        return "\(is4K ? "4K" : "1080p") · \(is60fps ? 60 : 30)fps" + (isHDR ? " · HDR" : "")
    }

    /// 码率表里的档位值（bit/s）
    func tierBitRate(_ quality: VideoQuality) -> Double {
        let mbps: Double
        switch (is4K, is60fps, quality) {
        case (true, true, .high): mbps = 30
        case (true, true, .saver): mbps = 20
        case (true, false, .high): mbps = 20
        case (true, false, .saver): mbps = 14
        case (false, true, .high): mbps = 12
        case (false, true, .saver): mbps = 8
        case (false, false, .high): mbps = 8
        case (false, false, .saver): mbps = 5
        }
        return mbps * 1_000_000
    }

    /// 目标码率 = min(档位值, 原码率 × 0.7)；原码率已经不高于档位值时返回 nil，表示无需压缩
    func targetBitRate(_ quality: VideoQuality) -> Double? {
        let tier = tierBitRate(quality)
        guard videoBitRate > tier else { return nil }
        return min(tier, videoBitRate * 0.7)
    }

    /// 预计耗时（秒）。实测 4K60 视频压缩用时约等于视频时长；
    /// 分辨率、帧率更低的按每秒要处理的像素数等比例缩短（最少按时长的 1/4 算）
    var estimatedSeconds: Double {
        let pixelsPerSecond = Double(width * height) * Double(frameRate)
        let fourK60 = 3840.0 * 2160.0 * 60.0
        return duration * max(pixelsPerSecond / fourK60, 0.25)
    }

    /// 预计压缩后的大小（字节）= 目标码率 × 时长 ÷ 8，再加音频
    func estimatedBytes(_ quality: VideoQuality) -> Int64? {
        guard let target = targetBitRate(quality) else { return nil }
        return Int64((target + audioBitRate) * duration / 8)
    }
}

/// 一个视频压缩并保存成功后的结果
nonisolated struct VideoCompressionResult: Sendable {
    let newID: String
    let originalBytes: Int64?
    let newBytes: Int64
    let targetBitRate: Double
    let seconds: Double
    /// 新视频生成成功了，但有些信息没带过去（比如某个相簿不允许添加）
    let warnings: [String]
}

/// 压缩失败的原因，文字直接展示给用户
nonisolated struct VideoError: LocalizedError {
    let message: String
    /// true 表示不是出错，而是这个视频不需要或不适合处理（结果页算"跳过"，不提供重试）
    var isSkipped = false
    var errorDescription: String? { message }
}

nonisolated enum VideoCompressor {

    // MARK: - 读取参数

    /// 读取原视频的参数（只在 iCloud 上的会先下载）
    static func inspect(
        _ asset: PHAsset,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoInfo {
        try checkSupported(asset)
        let source = try await loadAVAsset(for: asset, downloadProgress: downloadProgress)
        return try await readInfo(source, asset: asset)
    }

    /// 确认页用：不下载，快速读取参数。
    /// 返回 info 为 nil 表示只在 iCloud 上、连文件大小也拿不到，只能等压缩时再看。
    static func quickInspect(_ asset: PHAsset) async -> (info: VideoInfo?, needsDownload: Bool) {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false

        let local: AVURLAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset as? AVURLAsset)
            }
        }
        if let local, let info = try? await readInfo(local, asset: asset) {
            return (info, false)
        }

        // 只在 iCloud 上：用文件大小估算
        guard let bytes = fileBytes(of: asset), asset.duration > 0 else { return (nil, true) }
        let assumedAudio = 192_000.0
        let info = VideoInfo(
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            duration: asset.duration,
            frameRate: 60,
            videoBitRate: max(Double(bytes) * 8 / asset.duration - assumedAudio, 0),
            audioBitRate: assumedAudio,
            isHDR: false,
            fileBytes: bytes,
            isApproximate: true
        )
        return (info, true)
    }

    /// 不能处理的视频返回原因，能处理返回 nil
    static func unsupportedReason(_ asset: PHAsset) -> String? {
        do {
            try checkSupported(asset)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 是不是编辑过（剪辑、调色等）。这类视频会按编辑后的样子压缩，删除原片后无法再"复原"编辑。
    static func isEdited(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains { $0.type == .fullSizeVideo || $0.type == .adjustmentData }
    }

    // MARK: - 压缩并保存（不删原片）

    /// 压缩一个视频，保存为新视频并验证。progress 回调的参数是进度（0~1）和状态文字。
    static func compressAndSave(
        _ asset: PHAsset,
        quality: VideoQuality,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> VideoCompressionResult {
        let startTime = Date()
        try checkSupported(asset)

        progress(0, "正在读取视频…")
        let source = try await loadAVAsset(for: asset) { fraction in
            progress(0, "正在从 iCloud 下载 \(Int(fraction * 100))%")
        }
        let info = try await readInfo(source, asset: asset)
        guard let target = info.targetBitRate(quality) else {
            throw VideoError(message: "下载原片后发现码率已经很低，无需压缩，已跳过", isSkipped: true)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        // 不管成功失败，临时文件都不留在手机上（成功时它会被移进相册）
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let compressWarnings = try await compress(source, info: info, targetBitRate: target, to: outputURL) { fraction in
            progress(fraction * 0.95, "正在压缩 \(Int(fraction * 100))%")
        }

        progress(0.96, "正在检查压缩后的视频…")
        try await verifyFile(outputURL, expectedDuration: info.duration)
        let newBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0

        progress(0.98, "正在保存到相册…")
        let (newID, warnings) = try await save(outputURL, like: asset, expectedDuration: info.duration)

        progress(1, "完成")
        return VideoCompressionResult(
            newID: newID,
            originalBytes: info.fileBytes,
            newBytes: newBytes,
            targetBitRate: target,
            seconds: Date().timeIntervalSince(startTime),
            warnings: compressWarnings + warnings
        )
    }

    // MARK: - 删除

    /// 在一次 performChanges 里删除这些视频，系统只弹一次确认框。用户点"不允许"会抛出错误。
    static func deleteAssets(identifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// 是不是用户在系统删除弹窗里点了"不允许"
    static func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.userCancelled.rawValue
    }

    // MARK: - 内部步骤

    /// 这些视频无法删除或会丢信息，不处理
    private static func checkSupported(_ asset: PHAsset) throws {
        guard asset.mediaType == .video else {
            throw VideoError(message: "这不是视频", isSkipped: true)
        }
        guard asset.sourceType == .typeUserLibrary else {
            throw VideoError(message: "这个视频来自共享相簿或电脑同步，无法删除原片，已跳过", isSkipped: true)
        }
        if asset.mediaSubtypes.contains(.videoCinematic) {
            throw VideoError(message: "电影效果视频压缩后会丢失后期调焦信息，已跳过", isSkipped: true)
        }
        if asset.mediaSubtypes.contains(.videoHighFrameRate) {
            throw VideoError(message: "慢动作视频压缩后会丢失变速信息，已跳过", isSkipped: true)
        }
        if #available(iOS 18.0, *), asset.mediaSubtypes.contains(.spatialMedia) {
            throw VideoError(message: "空间视频压缩后会丢失立体信息，已跳过", isSkipped: true)
        }
    }

    /// 拿到能直接读取的视频文件。编辑过的视频拿到的是编辑后的样子（用户在相册里看到的）。
    private static func loadAVAsset(
        for asset: PHAsset,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVURLAsset {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction, _, _, _ in downloadProgress(fraction) }

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let urlAsset = avAsset as? AVURLAsset {
                    continuation.resume(returning: urlAsset)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: VideoError(message: "读取视频失败（可能是网络问题或 iCloud 下载失败）：\(error.localizedDescription)"))
                } else if avAsset != nil {
                    continuation.resume(throwing: VideoError(message: "暂不支持这种视频（可能是慢动作或特殊效果视频）"))
                } else {
                    continuation.resume(throwing: VideoError(message: "读取视频失败"))
                }
            }
        }
    }

    private static func readInfo(_ source: AVURLAsset, asset: PHAsset) async throws -> VideoInfo {
        guard let videoTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw VideoError(message: "这个视频里找不到画面")
        }
        let (dataRate, frameRate, naturalSize) = try await videoTrack.load(.estimatedDataRate, .nominalFrameRate, .naturalSize)
        let color = try await colorProperties(of: videoTrack)

        var audioRate: Double = 0
        for track in try await source.loadTracks(withMediaType: .audio) {
            audioRate += Double(try await track.load(.estimatedDataRate))
        }

        return VideoInfo(
            width: Int(naturalSize.width.rounded()),
            height: Int(naturalSize.height.rounded()),
            duration: try await source.load(.duration).seconds,
            frameRate: frameRate,
            videoBitRate: Double(dataRate),
            audioBitRate: audioRate,
            isHDR: color.isHDR,
            fileBytes: fileBytes(of: asset)
        )
    }

    /// 视频文件大小。系统没有公开的"文件大小"接口，这里读取资源自带的 fileSize 属性，只用于展示和估算
    private static func fileBytes(of asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        let videoResource = resources.first(where: { $0.type == .fullSizeVideo }) ?? resources.first(where: { $0.type == .video })
        return videoResource?.value(forKey: "fileSize") as? Int64
    }

    /// 原视频的色彩信息（HDR 视频是 BT.2020 + HLG）。缺失时按普通 SDR（BT.709）处理。
    private static func colorProperties(of track: AVAssetTrack) async throws -> (settings: [String: String], isHDR: Bool) {
        let description = try await track.load(.formatDescriptions).first
        func value(_ key: CFString) -> String? {
            guard let description else { return nil }
            return CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
        }
        let primaries = value(kCMFormatDescriptionExtension_ColorPrimaries) ?? AVVideoColorPrimaries_ITU_R_709_2
        let transfer = value(kCMFormatDescriptionExtension_TransferFunction) ?? AVVideoTransferFunction_ITU_R_709_2
        let matrix = value(kCMFormatDescriptionExtension_YCbCrMatrix) ?? AVVideoYCbCrMatrix_ITU_R_709_2
        let isHDR = transfer == AVVideoTransferFunction_ITU_R_2100_HLG || transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ
        return ([
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ], isHDR)
    }

    /// 真正的压缩：画面重新编码，音频原样复制，每帧时间戳不变
    private static func compress(
        _ source: AVURLAsset,
        info: VideoInfo,
        targetBitRate: Double,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        guard let videoTrack = try await source.loadTracks(withMediaType: .video).first else {
            throw VideoError(message: "这个视频里找不到画面")
        }
        var warnings: [String] = []
        let audioTracks = try await source.loadTracks(withMediaType: .audio)
        let transform = try await videoTrack.load(.preferredTransform)
        let color = try await colorProperties(of: videoTrack)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: source)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw VideoError(message: "无法开始压缩：\(error.localizedDescription)")
        }

        // 文件层的元数据：拍摄时间（带时区）、GPS、机型、镜头等，导出或隔空投送后仍然正确
        writer.metadata = try await source.load(.metadata)

        // 画面：解码成 10bit，再用硬件 HEVC Main10 编码，保留原来的色彩标记（HDR 不发灰）
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: info.width,
            AVVideoHeightKey: info.height,
            AVVideoColorPropertiesKey: color.settings,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(targetBitRate),
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoExpectedSourceFrameRateKey: Int(info.frameRate.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        // 方向信息：竖拍的视频压缩后不能变横
        videoInput.transform = transform
        // 画面轨道自己带的信息：镜头型号、焦距、光圈等（照片 App 的 ⓘ 里显示的镜头信息就在这里）
        videoInput.metadata = try await videoTrack.load(.metadata)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
        // 原轨道 → 新轨道，用来恢复轨道之间的关联
        var inputForTrack: [CMPersistentTrackID: AVAssetWriterInput] = [videoTrack.trackID: videoInput]

        // 音频：原样复制，不重新编码。有多条音轨（如空间音频）时全部带上，并保持"多选一"的关系
        var audioInputs: [AVAssetWriterInput] = []
        var defaultAudioInput: AVAssetWriterInput?
        for track in audioTracks {
            let (formats, isEnabled, trackMetadata) = try await track.load(.formatDescriptions, .isEnabled, .metadata)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = isEnabled
            input.metadata = trackMetadata
            if isEnabled && defaultAudioInput == nil { defaultAudioInput = input }
            audioInputs.append(input)
            inputForTrack[track.trackID] = input
            pairs.append((output, input))
        }

        for (output, input) in pairs {
            guard reader.canAdd(output) else {
                throw VideoError(message: "无法读取这个视频的\(input.mediaType == .video ? "画面" : "声音")")
            }
            reader.add(output)
            guard writer.canAdd(input) else {
                throw VideoError(message: "无法写入压缩后的\(input.mediaType == .video ? "画面" : "声音")")
            }
            writer.add(input)
        }

        // 逐帧附加信息（视频方向、人脸位置、场景亮度、音频混合用的信息等）：原样复制。
        // 某一条复制不了时不让整个压缩失败，但要记下来告诉用户。
        for track in try await source.loadTracks(withMediaType: .metadata) {
            let (formats, isEnabled, trackMetadata) = try await track.load(.formatDescriptions, .isEnabled, .metadata)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formats.first)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = isEnabled
            input.metadata = trackMetadata
            guard reader.canAdd(output), writer.canAdd(input) else {
                warnings.append("视频里的一项附加信息（\(Self.describe(formats.first))）没能保留")
                continue
            }
            reader.add(output)
            writer.add(input)
            inputForTrack[track.trackID] = input
            pairs.append((output, input))
        }

        // 恢复轨道之间的关联（比如附加信息属于哪条画面或声音）
        for track in try await source.load(.tracks) {
            guard let input = inputForTrack[track.trackID] else { continue }
            for type in try await track.load(.availableTrackAssociationTypes) {
                for related in try await track.loadAssociatedTracks(ofType: type) {
                    if let relatedInput = inputForTrack[related.trackID],
                       input.canAddTrackAssociation(withTrackOf: relatedInput, type: type.rawValue) {
                        input.addTrackAssociation(withTrackOf: relatedInput, type: type.rawValue)
                    }
                }
            }
        }

        if audioInputs.count > 1 {
            let group = AVAssetWriterInputGroup(inputs: audioInputs, defaultInput: defaultAudioInput)
            if writer.canAdd(group) { writer.add(group) }
        }

        guard reader.startReading() else {
            throw VideoError(message: "无法读取这个视频：\(reader.error?.localizedDescription ?? "未知错误")")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw VideoError(message: "无法写入压缩后的视频：\(writer.error?.localizedDescription ?? "未知错误")")
        }
        writer.startSession(atSourceTime: .zero)

        let copier = SampleCopier(pairs: pairs, duration: info.duration, progress: progress)
        let completed = await copier.run()

        if !completed || reader.status == .failed || writer.status == .failed {
            let error = writer.error ?? reader.error
            reader.cancelReading()
            writer.cancelWriting()
            throw VideoError(message: "压缩失败（可能是手机存储空间不足）：\(error?.localizedDescription ?? "未知错误")")
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoError(message: "压缩失败（可能是手机存储空间不足）：\(writer.error?.localizedDescription ?? "未知错误")")
        }
        return warnings
    }

    /// 附加信息轨道的名字（如 com.apple.quicktime.video-orientation），用于提示
    private static func describe(_ format: CMFormatDescription?) -> String {
        guard let format, let ids = CMMetadataFormatDescriptionGetIdentifiers(format) as? [String], !ids.isEmpty else {
            return "未知类型"
        }
        return ids.map { $0.components(separatedBy: "/").last ?? $0 }.joined(separator: "、")
    }

    /// 保存前检查压缩后的文件：能正常读取、能解出画面、时长与原片一致
    private static func verifyFile(_ url: URL, expectedDuration: Double) async throws {
        let asset = AVURLAsset(url: url)
        do {
            let (duration, isReadable) = try await asset.load(.duration, .isReadable)
            guard isReadable, try await !asset.loadTracks(withMediaType: .video).isEmpty else {
                throw VideoError(message: "压缩后的视频无法读取")
            }
            guard abs(duration.seconds - expectedDuration) <= 0.2 else {
                throw VideoError(message: String(format: "压缩后的视频时长（%.1f 秒）与原片（%.1f 秒）不一致", duration.seconds, expectedDuration))
            }
            let generator = AVAssetImageGenerator(asset: asset)
            _ = try await generator.image(at: .zero)
        } catch let error as VideoError {
            throw error
        } catch {
            throw VideoError(message: "压缩后的视频无法正常读取：\(error.localizedDescription)")
        }
    }

    /// 保存为新视频，带上拍摄时间、位置、收藏、隐藏和所在相簿；保存后再从相册里核对一次
    private static func save(_ fileURL: URL, like asset: PHAsset, expectedDuration: Double) async throws -> (String, [String]) {
        let resources = PHAssetResource.assetResources(for: asset)
        let filename = resources.first(where: { $0.type == .video })?.originalFilename ?? "\(UUID().uuidString).MOV"

        // 原片所在的用户相簿；共享相簿等不允许添加的，记成警告告诉用户
        var albums: [PHAssetCollection] = []
        var warnings: [String] = []
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { collection, _, _ in
            if collection.canPerform(.addContent) {
                albums.append(collection)
            } else {
                warnings.append("未能加入相簿「\(collection.localizedTitle ?? "未命名")」：这个相簿不允许添加")
            }
        }

        let created = VideoBox<String>()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename
                options.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                // 直接把临时文件移进相册，不在手机上多占一份
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: fileURL, options: options)

                request.creationDate = asset.creationDate
                request.location = asset.location
                request.isFavorite = asset.isFavorite
                // 隐藏的视频，新视频也要隐藏，否则删掉原片后它就"变回可见"了
                request.isHidden = asset.isHidden

                guard let placeholder = request.placeholderForCreatedAsset else { return }
                created.value = placeholder.localIdentifier
                for album in albums {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            throw VideoError(message: "保存到相册失败：\(error.localizedDescription)")
        }

        guard let newID = created.value,
              let newAsset = PHAsset.fetchAssets(withLocalIdentifiers: [newID], options: nil).firstObject else {
            throw VideoError(message: "保存到相册后没有找到新视频")
        }
        guard abs(newAsset.duration - expectedDuration) <= 0.5 else {
            throw VideoError(message: "相册里的新视频时长与原片不一致，原片不会删除")
        }
        return (newID, warnings)
    }
}

/// 把原视频的每一条轨道（画面、声音）一边读一边写。全部写完返回 true；中途写入失败返回 false。
nonisolated private final class SampleCopier: @unchecked Sendable {
    private let pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]
    private let duration: Double
    private let progress: @Sendable (Double) -> Void

    // 下面这些状态会被不同的线程访问，用锁保护
    private let lock = NSLock()
    private var finished: Set<Int> = []
    private var aborted = false
    private var continuation: CheckedContinuation<Bool, Never>?
    /// 上次通知界面的进度；只在画面轨道的线程上读写
    private var lastReported: Double = -1

    init(pairs: [(AVAssetReaderOutput, AVAssetWriterInput)], duration: Double, progress: @escaping @Sendable (Double) -> Void) {
        self.pairs = pairs
        self.duration = duration
        self.progress = progress
    }

    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            for index in pairs.indices {
                let queue = DispatchQueue(label: "Unlive.video.track.\(index)")
                pairs[index].1.requestMediaDataWhenReady(on: queue) { [self] in
                    pump(index)
                }
            }
        }
    }

    private func pump(_ index: Int) {
        let (output, input) = pairs[index]
        while input.isReadyForMoreMediaData {
            guard isActive(index) else { return }
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                complete(index)
                return
            }
            // 第 0 条是画面，用它的时间算进度。每涨 1% 才通知一次界面，
            // 否则每一帧都刷新界面（4K60 每秒几十次），会让 App 很卡
            if index == 0, duration > 0 {
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if seconds.isFinite {
                    let fraction = min(max(seconds / duration, 0), 1)
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
            if !input.append(sample) {
                abort()
                return
            }
        }
    }

    private func isActive(_ index: Int) -> Bool {
        lock.withLock { !aborted && !finished.contains(index) }
    }

    private func complete(_ index: Int) {
        lock.withLock {
            finished.insert(index)
            if finished.count == pairs.count { resume(true) }
        }
    }

    /// 某条轨道写入失败：其他轨道也停下，整体算失败
    private func abort() {
        lock.withLock {
            aborted = true
            resume(false)
        }
    }

    /// 只能回复一次（调用时已经持有锁）
    private func resume(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// 在系统回调之间传递数据用的小盒子。系统的这些回调是一个接一个调用的，不会同时访问。
nonisolated final class VideoBox<T>: @unchecked Sendable {
    var value: T?
    init(_ value: T? = nil) { self.value = value }
}
