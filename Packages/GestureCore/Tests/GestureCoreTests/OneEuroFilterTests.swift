import Foundation
import Testing
@testable import GestureCore

struct OneEuroFilterTests {
    @Test func firstSamplePassesThrough() {
        var filter = OneEuroFilter()
        #expect(filter.filter(0.42, at: 0) == 0.42)
    }

    @Test func constantSignalStaysConstant() {
        var filter = OneEuroFilter()
        var output = 0.0
        for frame in 0..<30 {
            output = filter.filter(0.5, at: Double(frame) / 30)
        }
        #expect(abs(output - 0.5) < 1e-12)
    }

    @Test func jitterAtRestIsDamped() {
        var filter = OneEuroFilter(params: .cursor)
        var worst = 0.0
        for frame in 0..<90 {
            let noisy = 0.5 + (frame.isMultiple(of: 2) ? 0.01 : -0.01)
            let output = filter.filter(noisy, at: Double(frame) / 30)
            if frame > 30 { worst = max(worst, abs(output - 0.5)) }
        }
        #expect(worst < 0.005)
    }
}
