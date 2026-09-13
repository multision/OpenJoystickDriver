import CoreHID
import Foundation

extension UserSpaceOutputDispatcher {
  @available(macOS 15, *)
  final class CoreHIDDelegate: HIDVirtualDeviceDelegate {
    let handler: UserSpaceHostReportHandler

    init(handler: UserSpaceHostReportHandler) { self.handler = handler }

    func hidVirtualDevice(
      _ device: HIDVirtualDevice,
      receivedSetReportRequestOfType type: HIDReportType,
      id: HIDReportID?,
      data: Data
    ) async throws {
      do { try enqueueSetReport(type: type, id: id, data: data) } catch {
        throw UserSpaceHostReportHandler.coreHIDError(error)
      }
      await Task.yield()
    }

    func enqueueSetReport(type: HIDReportType, id: HIDReportID?, data: Data) throws {
      let reportID = UInt32(id?.rawValue ?? 0)
      let task = try handler.setReport(
        type: Self.reportType(type),
        reportID: reportID,
        bytes: Array(data)
      )
      Task { [handler] in
        do { try await task.value } catch {
          handler.reportAsynchronousFailure(error, reportID: reportID)
        }
      }
    }

    func hidVirtualDevice(
      _ device: HIDVirtualDevice,
      receivedGetReportRequestOfType type: HIDReportType,
      id: HIDReportID?,
      maxSize: Int
    ) throws -> Data {
      do {
        return try Data(
          handler.getReport(
            type: Self.reportType(type),
            reportID: UInt32(id?.rawValue ?? 0),
            maxSize: maxSize
          )
        )
      } catch { throw UserSpaceHostReportHandler.coreHIDError(error) }
    }

    private static func reportType(_ type: HIDReportType) throws -> VirtualHostReportType {
      switch type {
      case .input: .input
      case .output: .output
      case .feature: .feature
      @unknown default: throw VirtualHostReportError.unsupported
      }
    }
  }
}
