//
//  ContentView.swift
//  Unlive
//
//  Created by chao gong on 8/11/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "livephoto.slash")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("定格")
                .font(.largeTitle.bold())
            Text("把实况照片变成静态照片，节省空间")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
