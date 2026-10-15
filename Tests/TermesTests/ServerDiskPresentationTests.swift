import XCTest
import SSHCore
import TermesKit

final class ServerDiskPresentationTests: XCTestCase {
  private func disk(_ source: String, _ mount: String, total: UInt64 = 100, used: UInt64 = 40,
                    available: Int64 = 60) -> ServerDiskUsage {
    .init(filesystem: source, mountPoint: mount, totalBytes: total, usedBytes: used,
      availableBytes: available, usagePercent: .value(40))
  }

  func test_overview_prioritizes_root_and_hides_virtual_mounts_and_duplicate_aliases() {
    let all = [disk("tmpfs", "/run"), disk("/dev/vda1", "/bind"), disk("overlay", "/var/lib/docker/overlay2/container/merged"),
      disk("/dev/vdb1", "/data", total: 200), disk("/dev/vda1", "/"), disk("devtmpfs", "/dev"),
      disk("/dev/loop0", "/snap/core"), disk("shm", "/dev/shm")]
    XCTAssertEqual(ServerDiskPresentation.visible(all, showAll: false).map(\.mountPoint), ["/", "/data"])
    XCTAssertEqual(ServerDiskPresentation.visible(all, showAll: true), all, "details retain complete source data and order")
    XCTAssertEqual(all.count, 8)
  }

  func test_root_overlay_and_actual_storage_under_docker_paths_are_kept() {
    let all = [disk("overlay", "/container/merged"), disk("/dev/vdb1", "/var/lib/docker"), disk("overlay", "/"),
      disk("nas:/volume", "/mnt/共享文件"), disk("tmpfs", "/run")]
    XCTAssertEqual(ServerDiskPresentation.visible(all, showAll: false).map(\.mountPoint), ["/", "/var/lib/docker", "/mnt/共享文件"])
    XCTAssertEqual(ServerDiskPresentation.visible([disk("tmpfs", "/")], showAll: false).map(\.mountPoint), ["/"])
  }

  func test_distinct_capacity_or_quota_is_not_hidden_as_a_duplicate() {
    let all = [disk("/dev/sda1", "/"), disk("/dev/sda1", "/quota", total: 50),
      disk("/dev/sda1", "/reserved", available: 20), disk("/dev/sdb1", "/other")]
    XCTAssertEqual(ServerDiskPresentation.visible(all, showAll: false), all)
    XCTAssertTrue(ServerDiskPresentation.visible([], showAll: false).isEmpty)
  }
}
