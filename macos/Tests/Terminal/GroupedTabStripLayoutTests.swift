import Cocoa
import Testing
@testable import Ghostty

@MainActor
struct GroupedTabStripLayoutTests {
    @Test func unequalMinimaDoNotForceUnnecessaryScrolling() throws {
        let strip = GroupedTabStrip(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        let tabs: [TabOrganization.TabPresentation] = [
            .init(id: UUID(), title: "", color: .none, isSelected: false),
            .init(id: UUID(), title: "A long colored terminal title", color: .blue, isSelected: false)
        ]
        strip.render(.init(windowID: UUID(), groups: [], unassigned: tabs,
                           selectedTabID: nil, activeGroupID: nil))
        strip.layout()
        let scroll = try #require(strip.subviews.compactMap { $0 as? NSScrollView }.first)
        let canvas = try #require(scroll.documentView)
        let items = canvas.subviews
        #expect(items.count == 2)
        #expect(items[0].frame.width < items[1].frame.width)
        #expect(canvas.frame.width == scroll.contentSize.width)
        #expect(abs(items[0].frame.minX - (canvas.frame.maxX - items[1].frame.maxX)) <= 0.5)

        strip.setFrameSize(NSSize(width: 400, height: 28))
        strip.layout()
        #expect(abs(items[0].frame.width - items[1].frame.width) <= 0.5)
        #expect(canvas.frame.width == scroll.contentSize.width)
    }

    @Test func fractionalFitBoundaryPreservesPixelsAndMinimumWidths() throws {
        let strip = GroupedTabStrip(frame: NSRect(x: 0, y: 0, width: 120, height: 28))
        let tabs = (0..<3).map {
            TabOrganization.TabPresentation(id: UUID(), title: "Terminal \($0)",
                                            color: .none, isSelected: false)
        }
        strip.render(.init(windowID: UUID(), groups: [], unassigned: tabs,
                           selectedTabID: nil, activeGroupID: nil))
        strip.layout()
        let scroll = try #require(strip.subviews.compactMap { $0 as? NSScrollView }.first)
        let canvas = try #require(scroll.documentView)
        try #require(canvas.frame.width > scroll.contentSize.width)
        let minimumWidths = canvas.subviews.map { $0.frame.width }
        let minimumContentWidth = canvas.frame.width
        strip.setFrameSize(NSSize(width: 600, height: 28))
        strip.layout()
        let fullViewportFrame = scroll.frame
        let fixedChrome = strip.frame.width - scroll.frame.width
        let fitWidth = minimumContentWidth + fixedChrome
        var availableWidths: [CGFloat] = []
        var exercisedResidualPixels = false
        for delta: CGFloat in [-1, -0.5, 0, 0.5, 0.75, 1, 1.5] {
            strip.setFrameSize(NSSize(width: fitWidth + delta, height: 28))
            // Sample AppKit's full viewport before layout reserves any overflow controls.
            var viewportFrame = fullViewportFrame
            viewportFrame.size.width = strip.bounds.width - fixedChrome
            scroll.frame = viewportFrame
            let availableWidth = scroll.contentSize.width
            availableWidths.append(availableWidth)
            strip.layout()
            let items = canvas.subviews
            for (item, minimum) in zip(items, minimumWidths) {
                #expect(item.frame.width >= minimum)
            }
            if availableWidth < minimumContentWidth {
                #expect(canvas.frame.width > scroll.contentSize.width)
            } else {
                #expect(scroll.contentSize.width == availableWidth)
                #expect(canvas.frame.width == scroll.contentSize.width)
                let first = try #require(items.first)
                let last = try #require(items.last)
                #expect(abs(first.frame.minX - (canvas.frame.maxX - last.frame.maxX)) < 0.5)
                let widths = items.map { $0.frame.width }
                let widthDifference = widths.max()! - widths.min()!
                #expect(widthDifference <= 0.5)
                let sparePixels = Int(floor(availableWidth * 2)) - Int(minimumContentWidth * 2)
                if sparePixels % tabs.count != 0 {
                    exercisedResidualPixels = true
                    #expect(widthDifference == 0.5)
                }
            }
        }
        #expect(availableWidths.contains { $0 < minimumContentWidth })
        #expect(availableWidths.contains(minimumContentWidth))
        #expect(availableWidths.contains { $0 > minimumContentWidth })
        #expect(exercisedResidualPixels)
    }

    @Test func compactHeadersRemainUsableWithoutVisibleMembers() throws {
        let strip = GroupedTabStrip(frame: NSRect(x: 0, y: 0, width: 500, height: 28))
        let group = TabOrganization.GroupPresentation(
            id: UUID(), name: "G", color: .blue,
            tabs: [.init(id: UUID(), title: "Hidden", color: .none, isSelected: false)], isActive: false)
        strip.render(.init(windowID: UUID(), groups: [group], unassigned: [],
                           selectedTabID: nil, activeGroupID: nil))
        strip.layout()
        let scroll = try #require(strip.subviews.compactMap { $0 as? NSScrollView }.first)
        let canvas = try #require(scroll.documentView)
        let header = try #require(canvas.subviews.first)
        #expect(header.frame.width == 79)
        #expect(header.frame.maxX < canvas.frame.maxX)
        strip.setFrameSize(NSSize(width: 700, height: 28))
        strip.layout()
        #expect(header.frame.width == 79)
        #expect(canvas.frame.width == scroll.contentSize.width)
    }
}
