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
        let minimumWidths = canvas.subviews.map { $0.frame.width }
        let minimumContentWidth = canvas.frame.width
        strip.setFrameSize(NSSize(width: 600, height: 28))
        strip.layout()
        let fixedChrome = strip.frame.width - scroll.frame.width
        let fitWidth = minimumContentWidth + fixedChrome
        for delta: CGFloat in [-0.5, 0, 0.5, 0.75, 1, 1.5] {
            strip.setFrameSize(NSSize(width: fitWidth + delta, height: 28))
            strip.layout()
            let items = canvas.subviews
            for (item, minimum) in zip(items, minimumWidths) {
                #expect(item.frame.width >= minimum)
            }
            if delta < 0 {
                #expect(canvas.frame.width > scroll.contentSize.width)
            } else {
                #expect(canvas.frame.width == scroll.contentSize.width)
                let first = try #require(items.first)
                let last = try #require(items.last)
                #expect(abs(first.frame.minX - (canvas.frame.maxX - last.frame.maxX)) < 0.5)
                #expect(items.map { $0.frame.width }.max()! - items.map { $0.frame.width }.min()! <= 0.5)
            }
        }
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
