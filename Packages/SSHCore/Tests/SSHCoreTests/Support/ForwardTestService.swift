import Foundation
import Darwin

/// A real loopback TCP service for forwarding tests. Every accepted connection has
/// its own blocking worker; stop shuts workers down without closing reused descriptors.
final class ForwardTestService: @unchecked Sendable {
  let port: Int
  private let listener: Int32
  private let queue = DispatchQueue(label: "termes.test.tcp-listener")
  private let lock = NSLock()
  private var stopped = false
  private var clients: Set<Int32> = []
  private var errors: [String] = []
  var failures: [String] { lock.withLock { errors } }
  var clientCount: Int { lock.withLock { clients.count } }

  init(port: Int = 0, handler: @escaping @Sendable (Int32) throws -> Void) throws {
    listener = try ForwardTestSocket.listener(port: port)
    self.port = try ForwardTestSocket.boundPort(listener).port
    _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL, 0) | O_NONBLOCK)
    queue.async { [self] in
      while !lock.withLock({ stopped }) {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 20) > 0 else { continue }
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { continue }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK)
        var one: Int32 = 1, timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let accepted = lock.withLock {
          if stopped { return false }
          clients.insert(fd); return true
        }
        guard accepted else { Darwin.close(fd); continue }
        DispatchQueue(label: "termes.test.tcp-client").async { [self] in
          do { try handler(fd) }
          catch { lock.withLock { if !stopped { errors.append(String(describing: error)) } } }
          lock.withLock { clients.remove(fd); Darwin.close(fd) }
        }
      }
    }
  }

  func stop() {
    let first = lock.withLock {
      guard !stopped else { return false }
      stopped = true
      for fd in clients { Darwin.shutdown(fd, SHUT_RDWR) }
      return true
    }
    guard first else { return }
    Darwin.shutdown(listener, SHUT_RDWR)
    queue.sync {}
    Darwin.close(listener)
  }
}
