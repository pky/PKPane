import CBZip2
import Compression
import Foundation
import zlib

struct StreamingDecompressionConfiguration: Sendable {
  let inputChunkSize: Int
  let outputChunkSize: Int
  let ratioCheckMinimumOutputBytes: UInt64
  let didAllocateBuffers: (@Sendable (Int) -> Void)?
  let didProduceOutput: (@Sendable (UInt64) -> Void)?

  static let `default` = Self(
    inputChunkSize: 64 * 1_024,
    outputChunkSize: 64 * 1_024,
    ratioCheckMinimumOutputBytes: 1 * 1_024 * 1_024,
    didAllocateBuffers: nil,
    didProduceOutput: nil)
}

struct StreamingDecompressionResult: Equatable, Sendable {
  let compressedBytes: UInt64
  let uncompressedBytes: UInt64
}

enum StreamingArchiveDecoder {
  typealias InputProgress = @Sendable (_ consumedBytes: UInt64, _ totalBytes: UInt64) -> Void

  static func decompress(
    at archiveURL: URL,
    to outputURL: URL,
    format: ArchiveFormat,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress,
    configuration: StreamingDecompressionConfiguration = .default,
    inputProgress: InputProgress? = nil
  ) throws -> StreamingDecompressionResult {
    guard configuration.inputChunkSize > 0, configuration.outputChunkSize > 0 else {
      throw ArchiveServiceError.operationFailed(format)
    }
    let fileSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let compressedBytes = UInt64(max(fileSize, 0))
    guard compressedBytes <= limits.maximumUncompressedBytes else {
      throw ArchiveServiceError.tooLarge(format)
    }
    try ArchiveCancellation.check(cancellationProgress)

    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
      throw ArchiveServiceError.operationFailed(format)
    }
    let inputHandle = try FileHandle(forReadingFrom: archiveURL)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer {
      try? inputHandle.close()
      try? outputHandle.close()
    }
    let sink = StreamingDecompressionSink(
      outputHandle: outputHandle,
      compressedBytes: compressedBytes,
      limits: limits,
      format: format,
      cancellationProgress: cancellationProgress,
      configuration: configuration)

    switch format {
    case .gzip, .tarGzip:
      try decompressZlib(
        inputHandle: inputHandle,
        sink: sink,
        totalInputBytes: compressedBytes,
        cancellationProgress: cancellationProgress,
        configuration: configuration,
        inputProgress: inputProgress)
    case .bzip2, .tarBzip2:
      try decompressBzip2(
        inputHandle: inputHandle,
        sink: sink,
        totalInputBytes: compressedBytes,
        cancellationProgress: cancellationProgress,
        configuration: configuration,
        inputProgress: inputProgress)
    case .xz, .tarXz:
      try decompressLZMA(
        inputHandle: inputHandle,
        sink: sink,
        totalInputBytes: compressedBytes,
        cancellationProgress: cancellationProgress,
        configuration: configuration,
        inputProgress: inputProgress)
    case .zip, .sevenZip, .tar, .rar:
      throw ArchiveServiceError.unsupportedFormat(format.fileExtension)
    }

    try sink.finish()
    inputProgress?(compressedBytes, compressedBytes)
    return StreamingDecompressionResult(
      compressedBytes: compressedBytes,
      uncompressedBytes: sink.writtenBytes)
  }

  private static func decompressZlib(
    inputHandle: FileHandle,
    sink: StreamingDecompressionSink,
    totalInputBytes: UInt64,
    cancellationProgress: Progress,
    configuration: StreamingDecompressionConfiguration,
    inputProgress: InputProgress?
  ) throws {
    var stream = z_stream()
    guard
      inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else {
      throw ArchiveServiceError.operationFailed(sink.format)
    }
    defer { inflateEnd(&stream) }

    var outputBuffer = [UInt8](repeating: 0, count: configuration.outputChunkSize)
    var consumedBytes: UInt64 = 0
    var reachedStreamEnd = false
    while !reachedStreamEnd {
      try ArchiveCancellation.check(cancellationProgress)
      let input = try inputHandle.read(upToCount: configuration.inputChunkSize) ?? Data()
      let isFinalInput = input.isEmpty
      configuration.didAllocateBuffers?(input.count + outputBuffer.count)

      try input.withUnsafeBytes { rawInput in
        stream.next_in = UnsafeMutablePointer<Bytef>(
          mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = UInt32(rawInput.count)
        repeat {
          let previousInput = stream.avail_in
          let status = try outputBuffer.withUnsafeMutableBytes { rawOutput -> Int32 in
            stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = UInt32(rawOutput.count)
            let status = inflate(&stream, isFinalInput ? Z_FINISH : Z_NO_FLUSH)
            let produced = rawOutput.count - Int(stream.avail_out)
            if produced > 0 {
              try sink.write(UnsafeRawBufferPointer(rebasing: rawOutput[..<produced]))
            }
            return status
          }
          let consumed = previousInput - stream.avail_in
          consumedBytes += UInt64(consumed)
          inputProgress?(consumedBytes, totalInputBytes)
          if status == Z_STREAM_END {
            reachedStreamEnd = true
            break
          }
          guard status == Z_OK || status == Z_BUF_ERROR else {
            throw ArchiveServiceError.operationFailed(sink.format)
          }
          let produced = configuration.outputChunkSize - Int(stream.avail_out)
          guard consumed > 0 || produced > 0 else {
            if !isFinalInput, stream.avail_in == 0 { break }
            throw ArchiveServiceError.operationFailed(sink.format)
          }
        } while stream.avail_in > 0 || isFinalInput || stream.avail_out == 0
      }
      if isFinalInput, !reachedStreamEnd {
        throw ArchiveServiceError.operationFailed(sink.format)
      }
    }
  }

  private static func decompressBzip2(
    inputHandle: FileHandle,
    sink: StreamingDecompressionSink,
    totalInputBytes: UInt64,
    cancellationProgress: Progress,
    configuration: StreamingDecompressionConfiguration,
    inputProgress: InputProgress?
  ) throws {
    var stream = bz_stream()
    guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else {
      throw ArchiveServiceError.operationFailed(sink.format)
    }
    defer { BZ2_bzDecompressEnd(&stream) }

    var outputBuffer = [UInt8](repeating: 0, count: configuration.outputChunkSize)
    var consumedBytes: UInt64 = 0
    var reachedStreamEnd = false
    while !reachedStreamEnd {
      try ArchiveCancellation.check(cancellationProgress)
      let input = try inputHandle.read(upToCount: configuration.inputChunkSize) ?? Data()
      let isFinalInput = input.isEmpty
      configuration.didAllocateBuffers?(input.count + outputBuffer.count)

      try input.withUnsafeBytes { rawInput in
        stream.next_in = UnsafeMutablePointer<CChar>(
          mutating: rawInput.bindMemory(to: CChar.self).baseAddress)
        stream.avail_in = UInt32(rawInput.count)
        repeat {
          let previousInput = stream.avail_in
          let status = try outputBuffer.withUnsafeMutableBytes { rawOutput -> Int32 in
            stream.next_out = rawOutput.bindMemory(to: CChar.self).baseAddress
            stream.avail_out = UInt32(rawOutput.count)
            let status = BZ2_bzDecompress(&stream)
            let produced = rawOutput.count - Int(stream.avail_out)
            if produced > 0 {
              try sink.write(UnsafeRawBufferPointer(rebasing: rawOutput[..<produced]))
            }
            return status
          }
          let consumed = previousInput - stream.avail_in
          consumedBytes += UInt64(consumed)
          inputProgress?(consumedBytes, totalInputBytes)
          if status == BZ_STREAM_END {
            reachedStreamEnd = true
            break
          }
          guard status == BZ_OK else {
            throw ArchiveServiceError.operationFailed(sink.format)
          }
          let produced = configuration.outputChunkSize - Int(stream.avail_out)
          guard consumed > 0 || produced > 0 else {
            if !isFinalInput, stream.avail_in == 0 { break }
            throw ArchiveServiceError.operationFailed(sink.format)
          }
        } while stream.avail_in > 0 || isFinalInput || stream.avail_out == 0
      }
      if isFinalInput, !reachedStreamEnd {
        throw ArchiveServiceError.operationFailed(sink.format)
      }
    }
  }

  private static func decompressLZMA(
    inputHandle: FileHandle,
    sink: StreamingDecompressionSink,
    totalInputBytes: UInt64,
    cancellationProgress: Progress,
    configuration: StreamingDecompressionConfiguration,
    inputProgress: InputProgress?
  ) throws {
    let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    defer { placeholder.deallocate() }
    var stream = compression_stream(
      dst_ptr: placeholder,
      dst_size: 0,
      src_ptr: UnsafePointer(placeholder),
      src_size: 0,
      state: nil)
    guard
      compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
        != COMPRESSION_STATUS_ERROR
    else {
      throw ArchiveServiceError.operationFailed(sink.format)
    }
    defer { compression_stream_destroy(&stream) }

    var outputBuffer = [UInt8](repeating: 0, count: configuration.outputChunkSize)
    var consumedBytes: UInt64 = 0
    var reachedStreamEnd = false
    while !reachedStreamEnd {
      try ArchiveCancellation.check(cancellationProgress)
      let input = try inputHandle.read(upToCount: configuration.inputChunkSize) ?? Data()
      let isFinalInput = input.isEmpty
      configuration.didAllocateBuffers?(input.count + outputBuffer.count)

      try input.withUnsafeBytes { rawInput in
        stream.src_ptr =
          rawInput.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(placeholder)
        stream.src_size = rawInput.count
        repeat {
          let previousInput = stream.src_size
          let status = try outputBuffer.withUnsafeMutableBytes { rawOutput -> compression_status in
            stream.dst_ptr = rawOutput.bindMemory(to: UInt8.self).baseAddress ?? placeholder
            stream.dst_size = rawOutput.count
            let flags = isFinalInput ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)
            let produced = rawOutput.count - stream.dst_size
            if produced > 0 {
              try sink.write(UnsafeRawBufferPointer(rebasing: rawOutput[..<produced]))
            }
            return status
          }
          let consumed = previousInput - stream.src_size
          consumedBytes += UInt64(consumed)
          inputProgress?(consumedBytes, totalInputBytes)
          if status == COMPRESSION_STATUS_END {
            reachedStreamEnd = true
            break
          }
          guard status == COMPRESSION_STATUS_OK else {
            throw ArchiveServiceError.operationFailed(sink.format)
          }
          let produced = configuration.outputChunkSize - stream.dst_size
          guard consumed > 0 || produced > 0 else {
            if !isFinalInput, stream.src_size == 0 { break }
            throw ArchiveServiceError.operationFailed(sink.format)
          }
        } while stream.src_size > 0 || isFinalInput || stream.dst_size == 0
      }
      if isFinalInput, !reachedStreamEnd {
        throw ArchiveServiceError.operationFailed(sink.format)
      }
    }
  }
}

private final class StreamingDecompressionSink {
  let format: ArchiveFormat
  private let outputHandle: FileHandle
  private let compressedBytes: UInt64
  private let limits: ArchiveSafetyLimits
  private let cancellationProgress: Progress
  private let configuration: StreamingDecompressionConfiguration
  private(set) var writtenBytes: UInt64 = 0

  init(
    outputHandle: FileHandle,
    compressedBytes: UInt64,
    limits: ArchiveSafetyLimits,
    format: ArchiveFormat,
    cancellationProgress: Progress,
    configuration: StreamingDecompressionConfiguration
  ) {
    self.outputHandle = outputHandle
    self.compressedBytes = compressedBytes
    self.limits = limits
    self.format = format
    self.cancellationProgress = cancellationProgress
    self.configuration = configuration
  }

  func write(_ bytes: UnsafeRawBufferPointer) throws {
    try ArchiveCancellation.check(cancellationProgress)
    let (newTotal, overflow) = writtenBytes.addingReportingOverflow(UInt64(bytes.count))
    guard !overflow, newTotal <= limits.maximumUncompressedBytes else {
      throw ArchiveServiceError.tooLarge(format)
    }
    try validateCompressionRatio(outputBytes: newTotal, final: false)
    guard let baseAddress = bytes.baseAddress else { return }
    let data = Data(
      bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
      count: bytes.count,
      deallocator: .none)
    try outputHandle.write(contentsOf: data)
    writtenBytes = newTotal
    configuration.didProduceOutput?(writtenBytes)
  }

  func finish() throws {
    try ArchiveCancellation.check(cancellationProgress)
    try validateCompressionRatio(outputBytes: writtenBytes, final: true)
    try outputHandle.synchronize()
  }

  private func validateCompressionRatio(outputBytes: UInt64, final: Bool) throws {
    guard outputBytes > 0 else { return }
    guard final || outputBytes >= configuration.ratioCheckMinimumOutputBytes else { return }
    guard compressedBytes > 0 else {
      throw ArchiveServiceError.suspiciousCompressionRatio("展開データ", format)
    }
    let (maximumExpandedSize, overflow) = compressedBytes.multipliedReportingOverflow(
      by: limits.maximumCompressionRatio)
    guard overflow || outputBytes <= maximumExpandedSize else {
      throw ArchiveServiceError.suspiciousCompressionRatio("展開データ", format)
    }
  }
}
