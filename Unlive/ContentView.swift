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
    @State private var showingSelectionAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // 嵌入式系统照片选择器：只显示实况照片，多选不限数量。
            // 必须传 photoLibrary: .shared()，否则拿不到照片的 itemIdentifier，后面就找不到原图。
            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: nil,
                selectionBehavior: .continuous,
                matching: .livePhotos,
                photoLibrary: .shared()
            ) {
                Text("选择实况照片")
            }
            .photosPickerStyle(.inline)
            // 隐藏选择器自带的"取消/添加"按钮，用下面我们自己的"完成"按钮
            .photosPickerDisabledCapabilities(.selectionActions)
            .ignoresSafeArea(edges: .top)

            Button {
                showingSelectionAlert = true
            } label: {
                Text(selectedItems.isEmpty ? "完成" : "完成（\(selectedItems.count)）")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedItems.isEmpty)
            .padding()
        }
        .alert("已选 \(selectedItems.count) 张实况照片", isPresented: $showingSelectionAlert) {
            Button("好", role: .cancel) {}
        }
    }
}

#Preview {
    ContentView()
}
