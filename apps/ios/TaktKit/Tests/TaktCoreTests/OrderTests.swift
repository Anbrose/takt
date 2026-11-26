import Testing
@testable import TaktCore

/// Three rows of 60 with a 10 gap: tops 0, 70, 140.
private let rows = [60.0, 60, 60]

@Suite struct OrderTests {
    @Test func dropTargetGapKeepsSlot() {
        #expect(Order.dropTarget(heights: rows, gap: 10, from: 0, offset: 40) == .reorder(to: 0))
    }

    @Test func dropTargetIntoNextRow() {
        #expect(Order.dropTarget(heights: rows, gap: 10, from: 0, offset: 70) == .into(index: 1))
    }

    @Test func dropTargetPastBand() {
        #expect(Order.dropTarget(heights: rows, gap: 10, from: 0, offset: 90) == .reorder(to: 1))
    }

    @Test func dropTargetUpward() {
        #expect(Order.dropTarget(heights: rows, gap: 10, from: 2, offset: -70) == .into(index: 1))
    }

    @Test func dropTargetEdgesUnchanged() {
        #expect(Order.dropTarget(heights: rows, gap: 10, from: 0, offset: -50) == .reorder(to: 0))
        #expect(Order.dropTarget(heights: rows, gap: 10, from: 2, offset: 50) == .reorder(to: 2))
        #expect(Order.dropTarget(heights: [60], gap: 10, from: 0, offset: 30) == .reorder(to: 0))
    }
}
