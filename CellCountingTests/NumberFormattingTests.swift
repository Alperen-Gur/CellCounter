import Foundation
import Testing
@testable import CellCounting

struct NumberFormattingTests {
    @Test @MainActor func measurementLabelsPreserveOrdinaryPrecision() {
        #expect(20.0.trimmedString == "20")
        #expect(20.5.trimmedString == "20.5")
        #expect((-2.0).trimmedString == "-2")
        #expect(0.0.trimmedString == "0")
    }

    @Test @MainActor func malformedAndExtremeMeasurementsDoNotTrap() {
        #expect(Double.nan.trimmedString == "—")
        #expect(Double.infinity.trimmedString == "—")
        #expect((-Double.infinity).trimmedString == "—")
        for value in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
                      Double(Int.max), Double(Int.min) * 2] {
            let text = value.trimmedString
            #expect(!text.isEmpty)
            #expect(text.count < 32)
        }
    }
}
