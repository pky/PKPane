import Foundation

enum PKPaneErrorClassifier {
  static func classify(_ error: Error) -> PKPaneError {
    if let error = error as? PKPaneError {
      return error
    }
    if error is CancellationError || isUserCancellation(error) {
      return fixed(.cancelled, "キャンセルしました。")
    }
    if let error = error as? SSHConfigReaderError {
      switch error {
      case .configNotFound:
        return preserving(error, as: .notFound)
      case .accessRequired:
        return preserving(error, as: .accessDenied)
      }
    }

    if error is FolderBookmarkAccessError || error is KeychainPasswordDataStoreError {
      return preserving(error, as: .accessDenied)
    }
    if error is SFTPDirectoryListingError {
      return preserving(error, as: .connectionLost)
    }
    if let error = error as? FTPControlConnectionError {
      switch error {
      case .passwordNotFound:
        return preserving(error, as: .authenticationFailed)
      case .secureTransportUnavailable:
        return preserving(error, as: .unsupported)
      case .unexpectedReply(_, let actual) where actual == 530:
        return preserving(error, as: .authenticationFailed)
      case .invalidCommand, .unexpectedReply, .invalidWorkingDirectory, .invalidPassiveReply:
        return preserving(error, as: .connectionLost)
      }
    }
    if let error = error as? FTPTransportError {
      switch error {
      case .timedOut:
        return preserving(error, as: .timeout)
      case .tlsHostnameValidationFailed, .tlsCertificateValidationFailed, .tlsHandshakeFailed,
        .plaintextAfterTLSUpgrade:
        return preserving(error, as: .authenticationFailed)
      case .connectionClosed, .concurrentRead, .invalidTextEncoding, .lineTooLong:
        return preserving(error, as: .connectionLost)
      }
    }
    if let error = error as? FTPClientSessionError {
      switch error {
      case .permissionsUnavailable:
        return preserving(error, as: .unsupported)
      case .unexpectedReply, .invalidSizeReply:
        return preserving(error, as: .connectionLost)
      }
    }
    if let error = error as? FTPFileProviderError {
      switch error {
      case .previewTooLarge:
        return preserving(error, as: .unsupported)
      case .invalidLocation, .invalidName:
        return preserving(error, as: .unknown)
      }
    }
    if error is FTPDirectoryListingParserError || error is FTPReplyParserError {
      return preserving(error, as: .connectionLost)
    }
    if error is FTPConnectionTargetError {
      return preserving(error, as: .notFound)
    }
    if let error = error as? SFTPFileProviderError {
      switch error {
      case .directoryNotFound:
        return preserving(error, as: .notFound)
      case .previewTooLarge:
        return preserving(error, as: .unsupported)
      case .invalidName, .invalidLocation:
        return preserving(error, as: .unknown)
      }
    }
    if error is SFTPConnectionTargetError {
      return preserving(error, as: .notFound)
    }
    if let error = error as? SFTPHopConnectionError {
      let underlying = classify(error.underlying)
      return preserving(error, as: underlying.category)
    }
    if let error = error as? ArchiveFileProviderError {
      switch error {
      case .itemNotFound:
        return preserving(error, as: .notFound)
      case .archiveChanged:
        return preserving(error, as: .conflict)
      case .entryTooLarge, .stagingCapacityExceeded:
        return preserving(error, as: .unsupported)
      case .invalidExtractedSize:
        return preserving(error, as: .internalInvariant)
      case .invalidLocation, .notDirectory:
        return preserving(error, as: .unknown)
      }
    }
    if let error = error as? SFTPConnectionServiceError {
      switch error {
      case .passwordNotFound:
        return preserving(error, as: .authenticationFailed)
      case .privateKeyNotFound:
        return preserving(error, as: .notFound)
      case .unsupportedPrivateKey:
        return preserving(error, as: .unsupported)
      case .hostKeyRequiresApproval:
        return preserving(error, as: .hostKeyUnknown)
      case .hostKeyChanged:
        return preserving(error, as: .hostKeyChanged)
      case .hopAuthenticationFailed, .unsupportedAuthenticationMethods,
        .publicKeyAuthenticationRequired:
        return preserving(error, as: .authenticationFailed)
      case .authenticationCancelled:
        return preserving(error, as: .cancelled)
      }
    }
    if error is SFTPClientSessionError {
      return preserving(error, as: .connectionLost)
    }
    if let error = error as? MountedVolumeProviderError {
      switch error {
      case .unavailable:
        return preserving(error, as: .connectionLost)
      case .outsideVolume:
        return preserving(error, as: .unsupported)
      }
    }
    if error is SFTPTransferStallError {
      return preserving(error, as: .timeout)
    }
    if error is FileBrowserOperationError || error is FileBrowserSessionError
      || error is ProviderFileTransferServiceError || error is LocalFileProviderError
    {
      return preserving(error, as: .unsupported)
    }
    if error is TransferVerificationError {
      return preserving(error, as: .conflict)
    }
    if error is TransferJobPartialFailure {
      return preserving(error, as: .partialFailure)
    }
    if error is SFTPPipelineInvariantError {
      return preserving(error, as: .internalInvariant)
    }
    if let error = error as? ArchiveServiceError {
      switch error {
      case .destinationExists:
        return preserving(error, as: .alreadyExists)
      case .duplicateEntryPath:
        return preserving(error, as: .conflict)
      case .noItems:
        return preserving(error, as: .notFound)
      case .unsafeEntryPath, .symbolicLinkEntry, .unsupportedArchiveEntry, .tooManyEntries,
        .tooLarge,
        .suspiciousCompressionRatio, .encryptedArchive, .multiVolumeArchive, .unsupportedItem,
        .unsupportedFormat, .operationFailed:
        return preserving(error, as: .unsupported)
      }
    }
    if let error = error as? SMBDirectTransferError {
      switch error {
      case .connectionFailed, .unexpectedEndOfFile:
        return preserving(error, as: .connectionLost)
      case .commitRollbackFailed:
        return preserving(error, as: .partialFailure)
      case .invalidChunkSize, .invalidWriteResponse, .internalConsistencyFailure:
        return preserving(error, as: .internalInvariant)
      }
    }
    if error is SMBShareError || error is NASConnectionProfileError {
      return preserving(error, as: .unsupported)
    }
    if error is SFTPConnectionFormError {
      return preserving(error, as: .authenticationFailed)
    }
    if error is RemoteEditControllerError {
      return preserving(error, as: .notFound)
    }
    if let error = error as? RemoteArchiveServiceError {
      switch error {
      case .stagingCapacityExceeded, .unsupportedProvider:
        return preserving(error, as: .unsupported)
      case .invalidRemoteItemName:
        return preserving(error, as: .conflict)
      }
    }

    // マウント済み共有のopendir等が返す権限拒否を、SMBログイン失敗と混同しない。
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain,
      nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
    {
      return fixed(.accessDenied, "項目へアクセスする権限がありません。")
    }

    switch ConnectionErrorClassifier.classify(error) {
    case .unreachable:
      return fixed(
        .networkUnavailable,
        "サーバーに到達できません。ホスト名とネットワーク接続を確認してください。")
    case .authenticationFailed:
      return fixed(
        .authenticationFailed,
        "認証に失敗しました。ユーザー名とパスワードを確認してください。")
    case .hostKeyMismatch:
      return preserving(error, as: .hostKeyChanged)
    case .shareNotFound:
      return fixed(.notFound, "共有が見つかりません。共有名を確認してください。")
    case .other:
      break
    }

    if let cocoaError = error as? CocoaError {
      switch cocoaError.code {
      case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly:
        return fixed(.accessDenied, "項目へアクセスする権限がありません。")
      case .fileNoSuchFile, .fileReadNoSuchFile:
        return fixed(.notFound, "項目が見つかりません。")
      case .fileWriteFileExists:
        return fixed(.alreadyExists, "同じ名前の項目が既に存在します。")
      case .fileWriteOutOfSpace:
        return fixed(.unknown, "空き容量が不足しています。")
      default:
        break
      }
    }

    return PKPaneError(
      category: .unknown,
      userMessage: "操作を完了できませんでした。",
      recoverySuggestion: "同じ操作をもう一度試し、解決しない場合は接続や権限を確認してください。",
      technicalReason: error.localizedDescription)
  }

  private static func isUserCancellation(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSCocoaErrorDomain
      && nsError.code == CocoaError.Code.userCancelled.rawValue
  }

  private static func fixed(_ category: PKPaneErrorCategory, _ message: String) -> PKPaneError {
    PKPaneError(category: category, userMessage: message)
  }

  private static func preserving(_ error: Error, as category: PKPaneErrorCategory) -> PKPaneError {
    PKPaneError(
      category: category,
      userMessage: SecretMasker.maskForDisplay(error.localizedDescription))
  }
}
