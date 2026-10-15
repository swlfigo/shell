import Foundation
import SSHCore

/// Display-only filtering; the full SSH sample remains available for details.
public enum ServerDiskPresentation {
  public static func visible(_ disks: [ServerDiskUsage], showAll: Bool) -> [ServerDiskUsage] {
    if showAll { return disks }
    let ordered = disks.filter { $0.mountPoint == "/" } + disks.filter { $0.mountPoint != "/" }
    var seen: Set<Key> = []
    return ordered.filter { disk in
      if disk.mountPoint != "/", isVirtual(disk) { return false }
      let key = Key(source: disk.filesystem, total: disk.totalBytes, used: disk.usedBytes, available: disk.availableBytes)
      return seen.insert(key).inserted
    }
  }
  private struct Key: Hashable { let source: String; let total, used: UInt64; let available: Int64 }
  private static func isVirtual(_ disk: ServerDiskUsage) -> Bool {
    let source = disk.filesystem.lowercased()
    return ["tmpfs", "devtmpfs", "overlay", "overlayfs", "shm", "udev", "proc", "sysfs", "cgroup", "cgroup2", "none"].contains(source)
      || source.hasPrefix("/dev/loop")
  }
}
