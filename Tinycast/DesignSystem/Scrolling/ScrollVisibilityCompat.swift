import SwiftUI

extension View {
    @ViewBuilder
    func sonomaOnScrollVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onScrollVisibilityChange { action($0) }
        } else {
            self
        }
    }
}
