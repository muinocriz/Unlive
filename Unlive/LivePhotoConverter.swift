//
//  LivePhotoConverter.swift
//  Unlive
//
//  把一张实况照片复制成静态照片：原样读取静态图的文件数据写入新照片（不重新编码），
//  再把拍摄时间、位置、收藏状态和所在相册带过去。
//  删除原图另外调用 deleteAssets，只在新照片确认写入成功后才删。
//

import Foundation
import Photos

/// 一张照片的处理结果
nonisolated struct ConversionResult: Identifiable, Sendable {
    let id = UUID()
    let originalID: String
    /// 给用户看的照片描述（拍摄时间），方便在相册里找到它
    var label: String
    /// 新生成的静态照片；nil 表示失败
    var newID: String?
    var errorMessage: String?
    /// 照片生成成功了，但有些信息没带过去（比如某个相册不允许添加）
    var warnings: [String] = []

    var succeeded: Bool { newID != nil }
}

/// 转换失败的原因，文字直接展示给用户
nonisolated struct ConversionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated enum LivePhotoConverter {

    /// 依次处理每张照片。progress 回调的参数是整体进度（0~1）和当前状态文字。
    static func convert(
        identifiers: [String],
        progress: @escaping @Sendable (Double, String) -> Void
    ) async -> [ConversionResult] {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assetsByID[asset.localIdentifier] = asset }

        var results: [ConversionResult] = []
        let total = Double(identifiers.count)

        for (index, id) in identifiers.enumerated() {
            let stepText = "正在处理第 \(index + 1) / \(identifiers.count) 张"
            progress(Double(index) / total, stepText)

            guard let asset = assetsByID[id] else {
                results.append(ConversionResult(originalID: id, label: "一张照片", errorMessage: "相册里找不到这张照片（可能已被删除）"))
                continue
            }

            let label = asset.creationDate.map { "拍摄于 \($0.formatted(date: .abbreviated, time: .shortened)) 的照片" } ?? "一张照片"

            do {
                let (newID, warnings) = try await convertOne(asset) { downloadFraction in
                    progress((Double(index) + downloadFraction) / total, "\(stepText)（正在从 iCloud 下载 \(Int(downloadFraction * 100))%）")
                }
                results.append(ConversionResult(originalID: id, label: label, newID: newID, warnings: warnings))
            } catch {
                results.append(ConversionResult(originalID: id, label: label, errorMessage: error.localizedDescription))
            }
        }

        progress(1, "处理完成")
        return results
    }

    /// 处理一张照片，返回新照片的 localIdentifier 和警告
    private static func convertOne(
        _ asset: PHAsset,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (String, [String]) {
        let resources = PHAssetResource.assetResources(for: asset)

        // 编辑过的照片（包括长曝光等效果）有 .fullSizePhoto，就是用户在相册里看到的样子；没编辑过就用原始的 .photo
        guard let original = resources.first(where: { $0.type == .photo }) else {
            throw ConversionError(message: "找不到这张照片的静态图")
        }
        let source = resources.first(where: { $0.type == .fullSizePhoto }) ?? original

        let data = try await readData(of: source, downloadProgress: downloadProgress)

        // 文件名沿用原图（如 IMG_1234），扩展名跟实际数据走（编辑后的版本可能是 JPEG）
        let baseName = (original.originalFilename as NSString).deletingPathExtension
        let ext = (source.originalFilename as NSString).pathExtension
        let filename = ext.isEmpty ? original.originalFilename : "\(baseName).\(ext)"

        // 原图所在的用户相册；共享相册、从电脑同步来的相册等不允许添加，记成警告告诉用户
        var albums: [PHAssetCollection] = []
        var warnings: [String] = []
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        collections.enumerateObjects { collection, _, _ in
            if collection.canPerform(.addContent) {
                albums.append(collection)
            } else {
                warnings.append("未能加入相册「\(collection.localizedTitle ?? "未命名")」：这个相册不允许添加照片")
            }
        }

        let created = Box<String>()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename
                options.uniformTypeIdentifier = source.uniformTypeIdentifier
                // 原样写入文件数据，不经过任何解码和压缩
                request.addResource(with: .photo, data: data, options: options)

                request.creationDate = asset.creationDate
                request.location = asset.location
                request.isFavorite = asset.isFavorite

                guard let placeholder = request.placeholderForCreatedAsset else { return }
                created.value = placeholder.localIdentifier
                for album in albums {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            throw ConversionError(message: "写入相册失败：\(error.localizedDescription)")
        }

        // 再从相册里查一次，确认新照片真的写进去了（之后才允许删除原图）
        guard let newID = created.value,
              PHAsset.fetchAssets(withLocalIdentifiers: [newID], options: nil).count == 1 else {
            throw ConversionError(message: "写入相册后没有找到新照片")
        }
        return (newID, warnings)
    }

    /// 在一次 performChanges 里删除这些照片，系统只弹一次确认框。用户点"不允许"会抛出错误。
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

    /// 读取资源的原始文件数据；只在 iCloud 上的会自动下载
    private static func readData(
        of resource: PHAssetResource,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { downloadProgress($0) }

        let buffer = Box<Data>(Data())
        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                buffer.value?.append(chunk)
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: ConversionError(message: "读取照片失败（可能是网络问题或 iCloud 下载失败）：\(error.localizedDescription)"))
                } else if let data = buffer.value, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ConversionError(message: "读取到的照片数据为空"))
                }
            }
        }
    }
}

/// 在系统回调之间传递数据用的小盒子。系统的这些回调是一个接一个调用的，不会同时访问。
nonisolated private final class Box<T>: @unchecked Sendable {
    var value: T?
    init(_ value: T? = nil) { self.value = value }
}
