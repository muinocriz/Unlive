//
//  ContentView.swift
//  Unlive
//
//  Created by chao gong on 8/11/26.
//

import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var showingSelectionAlert = false

    var body: some View {
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
                    showingSelectionAlert = true
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
        .alert("已选 \(selectedItems.count) 张实况照片", isPresented: $showingSelectionAlert) {
            Button("好", role: .cancel) {}
        }
    }
}

#Preview {
    ContentView()
}
