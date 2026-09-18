import SwiftUI

private struct SonomaCGFloatKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct SonomaCGRectKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

extension View {
    @ViewBuilder
    func sonomaOnWidth(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onGeometryChange(for: CGFloat.self) { $0.size.width } action: { action($0) }
        } else {
            background {
                GeometryReader { geo in
                    Color.clear.preference(key: SonomaCGFloatKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(SonomaCGFloatKey.self, perform: action)
        }
    }

    @ViewBuilder
    func sonomaOnHeight(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onGeometryChange(for: CGFloat.self) { $0.size.height } action: { action($0) }
        } else {
            background {
                GeometryReader { geo in
                    Color.clear.preference(key: SonomaCGFloatKey.self, value: geo.size.height)
                }
            }
            .onPreferenceChange(SonomaCGFloatKey.self, perform: action)
        }
    }

    @ViewBuilder
    func sonomaOnGlobalFrame(_ action: @escaping (CGRect) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { action($0) }
        } else {
            background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SonomaCGRectKey.self, value: geo.frame(in: .global))
                }
            }
            .onPreferenceChange(SonomaCGRectKey.self, perform: action)
        }
    }
}
