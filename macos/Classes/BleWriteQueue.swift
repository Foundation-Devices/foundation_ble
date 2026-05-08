import CoreBluetooth
import Foundation

final class BleWriteQueue: @unchecked Sendable {
  private enum PendingWriteMode {
    case withResponse
    case withoutResponse
  }

  static let connectionBufferWaitTimeMs = 15

  private let peripheral: CBPeripheral
  private let characteristic: CBCharacteristic
  private let preferredWriteType: CBCharacteristicWriteType
  private let queue = DispatchQueue(
    label: "com.foundation.ble.macos.writequeue",
    qos: .userInteractive
  )

  private var writeQueue: [WriteRequest] = []
  private var currentRequest: WriteRequest?
  private var isActive = true
  private var isProcessing = false

  private var pendingContinuation: CheckedContinuation<Bool, Never>?
  private var pendingWriteMode: PendingWriteMode?
  private var pendingWriteData: Data?
  private var pendingWriteGeneration: UInt64?
  private var readyTimeoutWorkItem: DispatchWorkItem?
  private var queueGeneration: UInt64 = 0

  init(
    peripheral: CBPeripheral,
    characteristic: CBCharacteristic
  ) {
    self.peripheral = peripheral
    self.characteristic = characteristic
    preferredWriteType = characteristic.properties.contains(.writeWithoutResponse)
      ? .withoutResponse : .withResponse
    startProcessingQueue()
  }

  private func startProcessingQueue() {
    queue.async { [weak self] in
      self?.processQueue()
    }
  }

  private func processQueue() {
    queue.async { [weak self] in
      guard let self else { return }

      while self.isActive {
        guard !self.writeQueue.isEmpty else {
          self.isProcessing = false
          return
        }

        self.isProcessing = true
        let request = self.writeQueue.removeFirst()
        self.currentRequest = request
        let generation = self.queueGeneration

        Task {
          let success = await self.performWrite(data: request.data, generation: generation)
          self.queue.async { [weak self] in
            guard let self else {
              request.completion(false)
              return
            }

            guard self.queueGeneration == generation else {
              return
            }

            if !success {
              self.isActive = false
              request.completion(false)
              self.clearQueue()
              self.isProcessing = false
              return
            }

            request.completion(true)
            self.currentRequest = nil

            if !self.writeQueue.isEmpty {
              self.processQueue()
            } else {
              self.isProcessing = false
            }
          }
        }

        return
      }
    }
  }

  func restart() {
    queue.async { [weak self] in
      guard let self, !self.isActive else { return }
      self.queueGeneration &+= 1
      self.failPendingWrite()
      self.isActive = true
      self.currentRequest = nil
      self.clearQueue()
      self.startProcessingQueue()
    }
  }

  func enqueue(data: Data) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: false)
          return
        }

        guard self.isActive else {
          continuation.resume(returning: false)
          return
        }

        var hasResumed = false
        let request = WriteRequest(data: data) { success in
          if !hasResumed {
            hasResumed = true
            continuation.resume(returning: success)
          }
        }

        self.writeQueue.append(request)

        if !self.isProcessing {
          self.isProcessing = true
          self.processQueue()
        }
      }
    }
  }

  func cancel() {
    queue.async { [weak self] in
      guard let self else { return }
      self.queueGeneration &+= 1
      self.failPendingWrite()
      self.currentRequest?.completion(false)
      self.currentRequest = nil
      self.clearQueue()
      self.isActive = false
      self.isProcessing = false
    }
  }

  func notifyReady() {
    queue.async { [weak self] in
      guard let self else { return }
      guard self.isActive,
            self.pendingWriteMode == .withoutResponse,
            let generation = self.pendingWriteGeneration,
            self.queueGeneration == generation
      else {
        return
      }

      guard let pendingWrite = self.takePendingWrite(),
            let data = pendingWrite.data
      else {
        return
      }

      guard self.peripheral.state != .disconnected else {
        pendingWrite.continuation.resume(returning: false)
        return
      }

      self.peripheral.writeValue(data, for: self.characteristic, type: .withoutResponse)
      pendingWrite.continuation.resume(returning: true)
    }
  }

  func notifyWriteCompleted(error: Error?) {
    queue.async { [weak self] in
      guard let self else { return }
      guard self.pendingWriteMode == .withResponse,
            let pendingWrite = self.takePendingWrite()
      else {
        return
      }

      pendingWrite.continuation.resume(returning: error == nil)
    }
  }

  private func performWrite(data: Data, generation: UInt64) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: false)
          return
        }

        guard self.isActive, self.queueGeneration == generation else {
          continuation.resume(returning: false)
          return
        }

        guard self.peripheral.state != .disconnected else {
          continuation.resume(returning: false)
          return
        }

        if self.preferredWriteType == .withResponse {
          self.failPendingWrite()
          self.pendingContinuation = continuation
          self.pendingWriteMode = .withResponse
          self.pendingWriteGeneration = generation
          self.pendingWriteData = nil
          self.peripheral.writeValue(
            data,
            for: self.characteristic,
            type: .withResponse
          )
          return
        }

        if !self.peripheral.canSendWriteWithoutResponse {
          self.failPendingWrite()
          self.pendingContinuation = continuation
          self.pendingWriteMode = .withoutResponse
          self.pendingWriteData = data
          self.pendingWriteGeneration = generation
          self.scheduleReadyTimeout(generation: generation)
          return
        }

        self.peripheral.writeValue(data, for: self.characteristic, type: .withoutResponse)
        continuation.resume(returning: true)
      }
    }
  }

  private func scheduleReadyTimeout(generation: UInt64) {
    readyTimeoutWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self,
            self.isActive,
            self.pendingWriteMode == .withoutResponse,
            let pendingGeneration = self.pendingWriteGeneration,
            self.queueGeneration == generation,
            pendingGeneration == generation,
            let pendingWrite = self.takePendingWrite(),
            let data = pendingWrite.data
      else {
        return
      }

      guard self.peripheral.state != .disconnected else {
        pendingWrite.continuation.resume(returning: false)
        return
      }

      self.peripheral.writeValue(data, for: self.characteristic, type: .withoutResponse)
      pendingWrite.continuation.resume(returning: true)
    }

    readyTimeoutWorkItem = workItem
    queue.asyncAfter(
      deadline: .now() + .milliseconds(Self.connectionBufferWaitTimeMs),
      execute: workItem
    )
  }

  private func takePendingWrite() -> (
    continuation: CheckedContinuation<Bool, Never>,
    mode: PendingWriteMode?,
    data: Data?,
    generation: UInt64?
  )? {
    guard let continuation = pendingContinuation else {
      return nil
    }

    let pendingWrite = (
      continuation: continuation,
      mode: pendingWriteMode,
      data: pendingWriteData,
      generation: pendingWriteGeneration
    )

    readyTimeoutWorkItem?.cancel()
    readyTimeoutWorkItem = nil
    pendingContinuation = nil
    pendingWriteMode = nil
    pendingWriteData = nil
    pendingWriteGeneration = nil

    return pendingWrite
  }

  private func failPendingWrite() {
    guard let pendingWrite = takePendingWrite() else {
      return
    }

    pendingWrite.continuation.resume(returning: false)
  }

  private func clearQueue() {
    while !writeQueue.isEmpty {
      let request = writeQueue.removeFirst()
      request.completion(false)
    }
  }
}

private struct WriteRequest {
  let data: Data
  let completion: (Bool) -> Void
}
