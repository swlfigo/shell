import Foundation

/// Product identity; legacy values are used only to retain pre-rename local data.
public enum ApplicationIdentity {
  public static let name = "Termes"
  public static let credentialService = "com.termes.credentials"
  public static let legacyName = "Shell"
  public static let legacyCredentialService = "com.shell.credentials"
}

/// Copies the previous application's entire data directory before exposing the new one.
/// Existing Termes data always wins, and the legacy directory remains available for rollback.
public enum ApplicationDataDirectory {
  public static func current(in supportDirectory: URL) -> URL {
    supportDirectory.appendingPathComponent(ApplicationIdentity.name, isDirectory: true)
  }

  public static func legacy(in supportDirectory: URL) -> URL {
    supportDirectory.appendingPathComponent(ApplicationIdentity.legacyName, isDirectory: true)
  }

  public static func prepare(in supportDirectory: URL, fileManager: FileManager = .default) throws -> URL {
    let destination = current(in: supportDirectory)
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
      }
      return destination
    }

    let source = legacy(in: supportDirectory)
    guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
      try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
      return destination
    }
    guard isDirectory.boolValue else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
    }

    let staging = supportDirectory.appendingPathComponent(".termes-migration-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }
    try fileManager.copyItem(at: source, to: staging)
    do {
      try fileManager.moveItem(at: staging, to: destination)
    } catch {
      // Another launch may have completed the same migration while this copy was in progress.
      if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
        return destination
      }
      throw error
    }
    return destination
  }
}
