import Foundation
import Testing

@testable import PKPane

struct PKPaneErrorClassifierTests {
  @Test("ssh_config読み込みエラーは元の文言を保って分類する")
  func sshConfigReaderErrorsAreClassified() {
    let cases: [(SSHConfigReaderError, PKPaneErrorCategory, String)] = [
      (.configNotFound, .notFound, "~/.ssh/config が見つかりません"),
      (.accessRequired, .accessDenied, "~/.ssh フォルダへのアクセスを許可すると config を読み込めます"),
    ]

    for (error, category, sourceMessage) in cases {
      let classified = PKPaneErrorClassifier.classify(error)
      #expect(classified.category == category)
      #expect(classified.displayMessage.contains(sourceMessage))
      #expect(!classified.displayMessage.contains("もう一度試し"))
    }
  }

  @Test("マウント済み共有の生POSIX権限拒否はSMB認証失敗と区別する")
  func mountedDirectoryPermissionFailureIsNotAuthenticationFailure() throws {
    for code in [EACCES, EPERM] {
      let error = POSIXError(try #require(POSIXErrorCode(rawValue: code)))
      #expect(PKPaneErrorClassifier.classify(error).category == .accessDenied)
      #expect(
        PKPaneErrorClassifier.classify(
          NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        ).category == .accessDenied)
    }
    #expect(
      PKPaneErrorClassifier.classify(
        SMBMountError.connectionFailed(EAUTH)
      ).category == .authenticationFailed)
  }

  @Test("既存ドメインエラーを設計カテゴリへ分類する")
  func classifiesRepresentativeDomainErrors() {
    let partialFailure = TransferJobPartialFailure(
      failedItems: [],
      underlyingErrorDescription: "転送失敗")
    let cases: [(any Error, PKPaneErrorCategory)] = [
      (FolderBookmarkAccessError.accessDenied, .accessDenied),
      (SFTPFileProviderError.directoryNotFound("/missing"), .notFound),
      (CocoaError(.fileWriteFileExists), .alreadyExists),
      (SFTPConnectionServiceError.passwordNotFound, .authenticationFailed),
      (SFTPConnectionServiceError.hostKeyRequiresApproval("secret-key"), .hostKeyUnknown),
      (SFTPConnectionServiceError.hostKeyChanged("secret-key"), .hostKeyChanged),
      (ConnectionReachabilityError.timedOut, .networkUnavailable),
      (SFTPClientSessionError.transferUnavailable, .connectionLost),
      (SFTPTransferStallError(), .timeout),
      (FTPControlConnectionError.passwordNotFound, .authenticationFailed),
      (
        FTPControlConnectionError.unexpectedReply(expected: "230", actual: 530),
        .authenticationFailed
      ),
      (FTPTransportError.timedOut, .timeout),
      (FTPTransportError.tlsCertificateValidationFailed, .authenticationFailed),
      (FTPClientSessionError.permissionsUnavailable, .unsupported),
      (FTPFileProviderError.previewTooLarge, .unsupported),
      (FileBrowserOperationError.trashUnavailable, .unsupported),
      (SMBShareError.invalidHost, .unsupported),
      (NASConnectionProfileError.invalidDisplayName, .unsupported),
      (
        TransferVerificationError.sizeMismatch(
          itemName: "a.txt", expectedBytes: 1, actualBytes: 0),
        .conflict
      ),
      (partialFailure, .partialFailure),
      (CancellationError(), .cancelled),
      (SFTPPipelineInvariantError(), .internalInvariant),
    ]

    for (error, category) in cases {
      #expect(PKPaneErrorClassifier.classify(error).category == category)
    }
  }

  @Test("PKPaneErrorは同じ値のまま返す")
  func preservesPKPaneError() {
    let expected = PKPaneError(category: .conflict, userMessage: "競合しました。")
    #expect(PKPaneErrorClassifier.classify(expected) == expected)
  }

  @Test("既存ドメインエラーの日本語文言を維持する")
  func preservesDomainErrorMessage() {
    let source = FileBrowserSessionError.transferUnavailable
    let classified = PKPaneErrorClassifier.classify(source)

    #expect(classified.category == .unsupported)
    #expect(classified.displayMessage == source.localizedDescription)
  }

  @Test("7zの安全検証エラーを形式名付きでunsupportedへ分類する")
  func classifiesSevenZipErrorsWithFormatSpecificMessages() {
    let cases: [(ArchiveServiceError, PKPaneErrorCategory)] = [
      (.unsafeEntryPath("../outside", .sevenZip), .unsupported),
      (.symbolicLinkEntry("shortcut", .sevenZip), .unsupported),
      (.duplicateEntryPath("same.txt", .sevenZip), .conflict),
      (.tooManyEntries(.sevenZip), .unsupported),
      (.tooLarge(.sevenZip), .unsupported),
      (.suspiciousCompressionRatio("bomb.txt", .sevenZip), .unsupported),
      (.operationFailed(.sevenZip), .unsupported),
    ]

    for (error, expectedCategory) in cases {
      let classified = PKPaneErrorClassifier.classify(error)
      #expect(classified.category == expectedCategory)
      #expect(classified.userMessage.contains("7z"))
      #expect(!classified.userMessage.contains("ZIP"))
    }
  }

  @Test("新しい展開形式とRAR固有の非対応条件を形式名付きで分類する")
  func classifiesExpandedArchiveErrors() {
    let cases: [ArchiveServiceError] = [
      .tooLarge(.tarGzip),
      .unsupportedArchiveEntry("pipe", .fifo, .tar),
      .suspiciousCompressionRatio("report.txt", .gzip),
      .operationFailed(.xz),
      .encryptedArchive(.rar),
      .multiVolumeArchive(.rar),
    ]

    for error in cases {
      let classified = PKPaneErrorClassifier.classify(error)
      #expect(classified.category == .unsupported)
      #expect(classified.userMessage.contains(error.localizedDescription))
    }
  }

  @Test("分類不能な外部エラーの詳細からホームパスを除去する")
  func masksFallbackTechnicalReason() {
    let homePath = NSHomeDirectory()
    let error = NSError(
      domain: "ExternalLibrary",
      code: 99,
      userInfo: [
        NSLocalizedDescriptionKey: "処理失敗: \(homePath)/Documents/秘密.txt",
        NSFilePathErrorKey: "\(homePath)/Documents/秘密.txt",
      ])

    let classified = PKPaneErrorClassifier.classify(error)

    #expect(classified.category == .unknown)
    #expect(classified.displayMessage.contains("~/Documents/秘密.txt"))
    #expect(!classified.displayMessage.contains(homePath))
  }

  @Test("分類不能なクラウドエラーの詳細はアカウント名を含まない")
  func masksCloudStorageAccountInTechnicalReason() {
    let error = NSError(
      domain: "CloudProvider",
      code: 99,
      userInfo: [
        NSLocalizedDescriptionKey:
          "読み込み失敗: \(NSHomeDirectory())/Library/CloudStorage/GoogleDrive-private@example.com/file.txt"
      ])

    let classified = PKPaneErrorClassifier.classify(error)

    #expect(classified.displayMessage.contains("~/Library/CloudStorage/[cloud]/file.txt"))
    #expect(!classified.displayMessage.contains("private@example.com"))
  }

  @Test("Cocoaのキャンセルとファイル系エラーを定型分類する")
  func classifiesCocoaErrors() {
    #expect(PKPaneErrorClassifier.classify(CocoaError(.userCancelled)).category == .cancelled)
    #expect(
      PKPaneErrorClassifier.classify(CocoaError(.fileReadNoPermission)).category == .accessDenied)
    #expect(PKPaneErrorClassifier.classify(CocoaError(.fileNoSuchFile)).category == .notFound)
    #expect(
      PKPaneErrorClassifier.classify(CocoaError(.fileWriteOutOfSpace)).userMessage
        == "空き容量が不足しています。")
  }
}
