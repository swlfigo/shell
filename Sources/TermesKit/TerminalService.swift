import Foundation
import SSHCore

/// Pumps bytes between a `ShellChannel` and a terminal view.
@MainActor
public final class TerminalService {
  private let channel: ShellChannel
  private var pump: Task<Void, Never>?
  private var writer: Task<Void, Never>?

  private enum Command: Sendable {
    case data(Data)
    case resize(cols: Int, rows: Int)
  }
  /// Outbound operations are funneled through one stream consumed by a single writer task,
  /// so the order the channel sees equals the order of `sendInput`/`resize` calls.
  private let commands: AsyncStream<Command>
  private let commandsCont: AsyncStream<Command>.Continuation

  public var onData: ((Data) -> Void)?
  public var onClosed: (() -> Void)?

  public init(channel: ShellChannel) {
    self.channel = channel
    (commands, commandsCont) = AsyncStream.makeStream(of: Command.self)
  }

  public func start() {
    guard pump == nil else { return }
    let stream = channel.output
    let channel = self.channel
    let commands = self.commands
    writer = Task {
      for await cmd in commands {
        if Task.isCancelled { return }
        switch cmd {
        case .data(let d): await channel.send(d)
        case .resize(let c, let r): await channel.resize(cols: c, rows: r)
        }
      }
    }
    pump = Task { [weak self] in
      for await chunk in stream {
        if Task.isCancelled { return }
        self?.onData?(chunk)
      }
      // Stream ended naturally (not cancelled by stop()).
      if !Task.isCancelled { self?.onClosed?() }
    }
  }

  public func sendInput(_ data: Data) {
    commandsCont.yield(.data(data))
  }

  public func resize(cols: Int, rows: Int) {
    commandsCont.yield(.resize(cols: cols, rows: rows))
  }

  public func stop() {
    commandsCont.finish()
    writer?.cancel()
    writer = nil
    pump?.cancel()
    pump = nil
    let channel = self.channel
    Task { await channel.close() }
  }
}
