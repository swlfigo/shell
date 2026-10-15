import AppKit
import XCTest
import TermesKit
@testable import Termes

@MainActor
final class TabBarViewTests: XCTestCase {
  private final class Delegate: TabBarViewDelegate {
    var selected: UUID?
    var closed: UUID?
    func tabBar(_ bar: TabBarView, select id: UUID) { selected = id }
    func tabBar(_ bar: TabBarView, close id: UUID) { closed = id }
    func tabBarAddTab(_ bar: TabBarView) {}
    func tabBar(_ bar: TabBarView, move id: UUID, to index: Int) {}
  }

  private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  private func makeBar() -> (TabBarView, NSWindow) {
    _ = NSApplication.shared
    let bar = TabBarView(windowToken: "window")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 38),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = bar
    return (bar, window)
  }

  func test_many_tabs_scroll_and_keep_the_selected_tab_and_add_button_visible() throws {
    let (bar, window) = makeBar()
    defer { window.close() }
    let items = (0..<30).map { TabBarItem(id: UUID(), title: "主机 \($0) " + String(repeating: "long", count: 20), status: .connected) }
    bar.update(items: items, selected: items.last?.id)
    bar.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSScrollView }.first)
    let document = try XCTUnwrap(scroll.documentView)
    let tabs = descendants(of: bar).compactMap { $0 as? TabItemView }
    XCTAssertEqual(tabs.count, 30)
    XCTAssertTrue(tabs.allSatisfy { $0.frame.width >= 112 })
    XCTAssertGreaterThan(document.frame.width, scroll.contentView.bounds.width)
    XCTAssertTrue(scroll.contentView.bounds.contains(try XCTUnwrap(tabs.last).frame))
    let add = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }.first { $0.title == "+" })
    XCTAssertTrue(bar.bounds.contains(add.frame))
    XCTAssertEqual(window.frame.width, 480, accuracy: 0.5)

    bar.update(items: items, selected: items[10].id)
    bar.layoutSubtreeIfNeeded()
    XCTAssertTrue(scroll.contentView.bounds.contains(tabs[10].frame))
    window.setContentSize(NSSize(width: 820, height: 38))
    bar.layoutSubtreeIfNeeded()
    window.setContentSize(NSSize(width: 480, height: 38))
    bar.layoutSubtreeIfNeeded()
    XCTAssertTrue(scroll.contentView.bounds.contains(tabs[10].frame))
  }

  func test_status_refresh_keeps_tab_views_and_manual_scroll_position() throws {
    let (bar, window) = makeBar()
    defer { window.close() }
    var items = (0..<10).map { TabBarItem(id: UUID(), title: "host \($0)", status: .idle) }
    bar.update(items: items, selected: items[0].id)
    bar.layoutSubtreeIfNeeded()
    let tabs = descendants(of: bar).compactMap { $0 as? TabItemView }
    let next = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }.first { $0.title == "›" })
    next.performClick(nil)
    let scroll = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSScrollView }.first)
    let position = scroll.contentView.bounds.minX
    XCTAssertGreaterThan(position, 0)
    items[0].status = .connected
    bar.update(items: items, selected: items[0].id)
    bar.layoutSubtreeIfNeeded()
    XCTAssertEqual(scroll.contentView.bounds.minX, position, accuracy: 0.5)
    let refreshed = descendants(of: bar).compactMap { $0 as? TabItemView }
    XCTAssertTrue(zip(tabs, refreshed).allSatisfy { $0 === $1 })
    XCTAssertEqual(refreshed[0].toolTip, "host 0")
  }

  func test_few_tabs_fit_without_scroll_buttons() throws {
    let (bar, window) = makeBar()
    defer { window.close() }
    let items = (0..<2).map { TabBarItem(id: UUID(), title: "host \($0)", status: .idle) }
    bar.update(items: items, selected: items[0].id)
    bar.layoutSubtreeIfNeeded()
    let arrows = bar.subviews.compactMap { $0 as? NSButton }.filter { $0.title == "‹" || $0.title == "›" }
    XCTAssertTrue(arrows.allSatisfy(\.isHidden))
    let scroll = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSScrollView }.first)
    XCTAssertEqual(scroll.documentView?.frame.width ?? 0, scroll.contentView.bounds.width, accuracy: 0.5)
  }

  func test_new_tabs_have_valid_geometry_before_the_bar_first_lays_out() throws {
    let (bar, window) = makeBar()
    defer { window.close() }
    let items = (0..<3).map { TabBarItem(id: UUID(), title: "server \($0)", status: .connected) }
    bar.update(items: items, selected: items[0].id)
    let tabs = descendants(of: bar).compactMap { $0 as? TabItemView }
    for tab in tabs {
      // AppKit can lay out a newly attached child before the frame-driven parent.
      XCTAssertGreaterThanOrEqual(tab.frame.width, 112)
      XCTAssertEqual(tab.frame.height, 28)
      tab.layoutSubtreeIfNeeded()
    }
    bar.layoutSubtreeIfNeeded()
    for tab in tabs {
      let close = try XCTUnwrap(descendants(of: tab).compactMap { $0 as? NSButton }.first)
      if !close.isHiddenOrHasHiddenAncestor {
        let rect = close.convert(close.bounds, to: tab)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertLessThanOrEqual(rect.maxX, tab.bounds.maxX)
      }
    }
  }

  func test_titlebar_clicks_select_tabs_and_close_buttons_after_scrolling() throws {
    _ = NSApplication.shared
    let bar = TabBarView(windowToken: "window")
    let delegate = Delegate()
    bar.delegate = delegate
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 540))
    bar.frame = NSRect(x: 0, y: 502, width: 820, height: 38)
    root.addSubview(bar)
    window.contentView = root
    defer { window.close() }
    for count in [2, 30] {
      let items = (0..<count).map { TabBarItem(id: UUID(), title: "server \($0)", status: .connected) }
      bar.update(items: items, selected: items.last?.id)
      root.layoutSubtreeIfNeeded()
      let tabs = descendants(of: bar).compactMap { $0 as? TabItemView }
      let scroll = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSScrollView }.first)
      let theme = try XCTUnwrap(root.superview)
      XCTAssertEqual(scroll.contentInsets.top, 0)
      for tab in tabs where scroll.contentView.bounds.contains(tab.frame) {
        XCTAssertTrue(tab.isEnabled, "tab controls must be enabled")
        let close = try XCTUnwrap(descendants(of: tab).compactMap { $0 as? NSButton }.first)
        XCTAssertFalse(close.isHidden, "every tab has its own visible close button")
        let closeRect = close.convert(close.bounds, to: tab)
        XCTAssertEqual(tab.bounds.maxX - closeRect.maxX, 6, accuracy: 0.5,
          "close stays at the tab's trailing edge for short and truncated titles")
        // Both the status dot and title must remain clickable inside the title-bar band.
        for x in [14, tab.bounds.midX] {
          let center = NSPoint(x: x, y: tab.bounds.midY)
          let rootPoint = tab.convert(center, to: root)
          let themePoint = tab.convert(center, to: theme)
          let hit = try XCTUnwrap(root.hitTest(rootPoint))
          XCTAssertTrue(hit === tab)
          XCTAssertTrue(theme.hitTest(themePoint) === tab)
          let point = tab.convert(center, to: nil)
          let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
          let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
          delegate.selected = nil
          hit.mouseDown(with: down)
          hit.mouseUp(with: up)
          XCTAssertEqual(delegate.selected, tab.item.id)
        }
      }
      let selected = try XCTUnwrap(tabs.last)
      XCTAssertEqual(selected.accessibilityLabel(), selected.item.title)
      XCTAssertEqual(selected.accessibilityRole(), .radioButton)
      delegate.selected = nil
      XCTAssertTrue(selected.accessibilityPerformPress())
      XCTAssertEqual(delegate.selected, selected.item.id)
      let close = try XCTUnwrap(selected.subviews.flatMap { descendants(of: $0) }.compactMap { $0 as? NSButton }.first)
      let closePoint = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: root)
      XCTAssertTrue(root.hitTest(closePoint) === close, "close retains its own click target")
      close.performClick(nil)
      XCTAssertEqual(delegate.closed, selected.item.id)
      if let directory = ProcessInfo.processInfo.environment["TERMES_TAB_BAR_RENDER_DIRECTORY"] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
        bar.cacheDisplay(in: bar.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("tabs-\(count).png"))
      }
    }
  }
}
