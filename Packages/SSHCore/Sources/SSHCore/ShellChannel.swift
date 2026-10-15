import Foundation

public protocol ShellChannel: AnyObject, Sendable {
  var output: AsyncStream<Data> { get }
  func send(_ data: Data) async
  func resize(cols: Int, rows: Int) async
  func close() async
}
