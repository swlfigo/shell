import AppKit
import XCTest
import TermesKit
@testable import Termes

@MainActor
private final class SplitResizeRecorder: PaneContainerDelegate {
  var resizes: [UUID] = []
  func paneContainer(_ c: PaneContainerView, didResizeSplit id: UUID, fractions: [Double]) { resizes.append(id) }
  func paneContainer(_ c: PaneContainerView, canAccept payload: TabDragPayload) -> Bool { false }
  func paneContainer(_ c: PaneContainerView, drop payload: TabDragPayload, onto pane: UUID, edge: PaneEdge) {}
}

@MainActor
final class PaneContainerViewTests: XCTestCase {
  private func services() throws -> AppServices {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return AppServices(directory: directory, secrets: InMemorySecretStore())
  }
  private func pane(_ services: AppServices) -> SessionPaneController {
    let pane = SessionPaneController(session: services.makeSession(), profiles: services.profiles)
    _ = pane.view; pane.isInWorkspace = true
    return pane
  }
  private func host(_ container: PaneContainerView) -> NSWindow {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 700))
    host.addSubview(container); window.contentView = host
    return window
  }
  private func assertUsable(_ pane: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertGreaterThanOrEqual(pane.frame.width, LayoutMetrics.paneMin.width, file: file, line: line)
    XCTAssertGreaterThanOrEqual(pane.frame.height, LayoutMetrics.paneMin.height, file: file, line: line)
    let column = try XCTUnwrap(pane.subviews.first as? NSStackView, file: file, line: line)
    let header = try XCTUnwrap(column.arrangedSubviews.first as? NSStackView, file: file, line: line)
    for button in header.arrangedSubviews.compactMap({ $0 as? NSButton }).filter({ !$0.isHidden }) {
      // Auto Layout sizes alignment rectangles. SF Symbol buttons have optical insets
      // that make their frame heights differ even though every height constraint is 24.
      let alignment = button.alignmentRect(forFrame: button.frame)
      XCTAssertEqual(alignment.width, 22, accuracy: 0.5, file: file, line: line)
      XCTAssertEqual(alignment.height, 24, accuracy: 0.5, file: file, line: line)
      XCTAssertTrue(pane.bounds.contains(button.convert(button.bounds, to: pane)), file: file, line: line)
    }
  }

  func test_zero_bounds_mount_and_transient_resize_keep_a_usable_pane() throws {
    let pane = pane(try services()), container = PaneContainerView(frame: .zero), window = host(container)
    defer { pane.close(); window.close() }
    container.render(root: .pane(pane.id), maximized: nil, views: [pane.id: pane.view])
    for size in [NSSize.zero, .init(width: 930, height: 700), .init(width: 0, height: 700),
                 .init(width: 930, height: 0), .init(width: 240, height: 140), .init(width: 930, height: 700)] {
      container.setFrameSize(size); container.needsLayout = true; container.layoutSubtreeIfNeeded()
      try assertUsable(pane.view)
      XCTAssertTrue(container.visiblePanes[pane.id] === pane.view)
      if size.width >= 240 && size.height >= 140 { XCTAssertEqual(pane.view.frame, container.bounds) }
    }
  }

  func test_nested_split_mount_zoom_and_resize_preserve_minimums_proportions_and_views() throws {
    let services = try services(), a = pane(services), b = pane(services), c = pane(services)
    let container = PaneContainerView(frame: .zero), recorder = SplitResizeRecorder(), window = host(container)
    defer { a.close(); b.close(); c.close(); window.close() }
    container.delegate = recorder
    let root = PaneNode.split(id: UUID(), axis: .horizontal,
      children: [.pane(a.id), .split(id: UUID(), axis: .vertical, children: [.pane(b.id), .pane(c.id)], fractions: [0.4, 0.6])],
      fractions: [0.35, 0.65])
    let views = [a.id: a.view, b.id: b.view, c.id: c.view]
    container.render(root: root, maximized: nil, views: views)
    for size in [NSSize.zero, .init(width: 930, height: 700), .zero, .init(width: 1000, height: 600)] {
      container.setFrameSize(size); container.needsLayout = true; container.layoutSubtreeIfNeeded()
      for pane in [a, b, c] {
        try assertUsable(pane.view)
        XCTAssertTrue(container.visiblePanes[pane.id] === pane.view)
      }
      if size.width > 0 {
        XCTAssertEqual(a.view.frame.width, ((size.width - 1) * 0.35).rounded(.down), accuracy: 0.5)
        XCTAssertEqual(b.view.frame.height, ((size.height - 1) * 0.4).rounded(.down), accuracy: 0.5)
      }
    }
    container.setFrameSize(.zero)
    container.render(root: root, maximized: a.id, views: views); container.layoutSubtreeIfNeeded()
    XCTAssertEqual(container.visiblePanes.count, 1); try assertUsable(a.view)
    container.render(root: root, maximized: nil, views: views); container.layoutSubtreeIfNeeded()
    for pane in [a, b, c] { try assertUsable(pane.view) }
    XCTAssertTrue(recorder.resizes.isEmpty, "mounting and window resizes must not write back as user divider drags")
  }

  func test_workspace_assigns_initial_container_bounds_before_a_pane_is_mounted() {
    _ = NSApplication.shared
    let container = PaneContainerView(frame: .zero)
    let workspace = WorkspaceView(sidebar: NSView(), tabBar: TabBarView(windowToken: UUID().uuidString), container: container)
    XCTAssertGreaterThan(container.frame.width, 0); XCTAssertGreaterThan(container.frame.height, 0)
    XCTAssertEqual(container.frame.width, workspace.bounds.width - WorkspaceView.sidebarWidth, accuracy: 0.5)
    XCTAssertEqual(container.frame.height, workspace.bounds.height - LayoutMetrics.tabBarHeight, accuracy: 0.5)
  }
}
