import Foundation

@MainActor
final class FavoriteSyncIntegrationController {
  private let coordinator: FavoriteSyncCoordinator
  private weak var folderSelection: FolderSelectionModel?
  private weak var sftpConnections: SFTPConnectionListModel?

  init(
    coordinator: FavoriteSyncCoordinator,
    folderSelection: FolderSelectionModel,
    sftpConnections: SFTPConnectionListModel
  ) {
    self.coordinator = coordinator
    self.folderSelection = folderSelection
    self.sftpConnections = sftpConnections

    let publishFavorites: @MainActor () -> Void = {
      [weak coordinator, weak folderSelection, weak sftpConnections] in
      guard let coordinator, let folderSelection, let sftpConnections else { return }
      do {
        let favorites =
          try folderSelection.portableFavorites() + sftpConnections.portableFavorites()
        coordinator.localFavoritesDidChange(favorites)
      } catch {
        AppLog.error(
          "お気に入りの読み込みに失敗したためiCloud同期の発行をスキップしました: \(PKPaneErrorClassifier.classify(error).displayMessage)",
          category: "FavoriteSyncIntegration")
      }
    }
    folderSelection.setFavoriteChangeHandler(publishFavorites)
    sftpConnections.setFavoriteChangeHandler(publishFavorites)
  }

  func start() {
    guard let folderSelection, let sftpConnections else { return }
    do {
      let favorites =
        try folderSelection.portableFavorites() + sftpConnections.portableFavorites()
      coordinator.start(localFavorites: favorites) {
        [weak folderSelection, weak sftpConnections] document in
        folderSelection?.applySyncedFavorites(document)
        sftpConnections?.applySyncedFavorites(document)
      }
    } catch {
      AppLog.error(
        "お気に入りの読み込みに失敗したためiCloud同期の開始をスキップしました: \(PKPaneErrorClassifier.classify(error).displayMessage)",
        category: "FavoriteSyncIntegration")
    }
  }
}
