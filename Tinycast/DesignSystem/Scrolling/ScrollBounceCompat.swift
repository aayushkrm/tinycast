import SwiftUI

struct SonomaBounce: ViewModifier {
    let always: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.scrollBounceBehavior(always ? .always : .basedOnSize)
        } else {
            content
        }
    }
}

extension View {
    func sonomaScrollBounce(always: Bool) -> some View {
        modifier(SonomaBounce(always: always))
    }

    func sonomaScrollBounceBasedOnSize() -> some View {
        modifier(SonomaBounce(always: false))
    }
}
