import Foundation
import Testing

@testable import PKPane

@Suite("お気に入りの挿入順")
@MainActor
struct SidebarFavoriteOrderTests {
  @Test func mixedOrderSurvivesRestartAndKeepsNewItems() throws {
    let suite = "SidebarFavoriteOrderTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = SidebarFavoriteOrderModel(defaults: defaults)
    let ids = ["favorite-local", "sftp-favorite-remote", "ftp-favorite-tls"]
    model.insert([ids[2]], before: ids[0], available: ids)
    #expect(model.orderedIDs(available: ids) == [ids[2], ids[0], ids[1]])
    #expect(
      SidebarFavoriteOrderModel(defaults: defaults).orderedIDs(available: ids + ["new"])
        == [ids[2], ids[0], ids[1], "new"])
  }

  @Test func insertsMultipleFoldersInInputOrderWithoutDuplicates() throws {
    let suite = "SidebarFavoriteOrderTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = SidebarFavoriteOrderModel(defaults: defaults)
    model.insert(["c", "d", "c"], before: "b", available: ["a", "b", "c", "d"])
    #expect(model.orderedIDs(available: ["a", "b", "c", "d"]) == ["a", "c", "d", "b"])
    model.insert(["c"], before: "c", available: ["a", "b", "c", "d"])
    #expect(model.orderedIDs(available: ["a", "b", "c", "d"]) == ["a", "c", "d", "b"])
  }

  @Test func internalFavoriteDragIsRecognizedOnlyForExistingIDs() {
    let url = SidebarFavoriteOrderModel.dragURL(for: "sftp-favorite-123")
    #expect(
      SidebarFavoriteOrderModel.draggedIDs(urls: [url], available: ["sftp-favorite-123"])
        == ["sftp-favorite-123"])
    #expect(SidebarFavoriteOrderModel.draggedIDs(urls: [url], available: []).isEmpty)
    #expect(SidebarFavoriteOrderModel.isFavoriteDrag(url))
    #expect(!SidebarFavoriteOrderModel.isFavoriteDrag(URL(filePath: "/tmp/folder")))
  }
  @Test func internalDragNeverInvokesFolderRegistration() throws {
    let suite = "SidebarFavoriteOrderTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = SidebarFavoriteOrderModel(defaults: defaults)
    var registrations = 0
    let accepted = model.performDrop(
      [SidebarFavoriteOrderModel.dragURL(for: "remote")], before: "local",
      available: { ["local", "remote"] },
      register: { _ in
        registrations += 1
        return nil
      })
    #expect(accepted)
    #expect(registrations == 0)
    #expect(model.orderedIDs(available: ["local", "remote"]) == ["remote", "local"])
    #expect(
      !model.performDrop(
        [SidebarFavoriteOrderModel.dragURL(for: "missing")], before: nil,
        available: { ["local", "remote"] },
        register: { _ in
          registrations += 1
          return nil
        }))
    #expect(registrations == 0)
  }

  @Test func partialRepositoryLoadingDoesNotEraseOtherProtocolOrder() throws {
    let suite = "SidebarFavoriteOrderTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = SidebarFavoriteOrderModel(defaults: defaults)
    model.insert(["remote"], before: "local", available: ["local", "remote"])
    #expect(model.orderedIDs(available: ["local"]) == ["local"])
    model.insert(["new"], before: "local", available: ["local", "new"])
    #expect(
      SidebarFavoriteOrderModel(defaults: defaults).orderedIDs(available: [
        "local", "remote", "new",
      ])
        == ["remote", "new", "local"])
  }

  @Test func twoWindowsMergeReorderingWithLatestPersistentOrder() throws {
    let suite = "SidebarFavoriteOrderTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = SidebarFavoriteOrderModel(defaults: defaults)
    let second = SidebarFavoriteOrderModel(defaults: defaults)
    let ids = ["a", "b", "c"]
    first.insert(["b"], before: "a", available: ids)
    second.insert(["c"], before: "a", available: ids)
    #expect(second.orderedIDs(available: ids) == ["b", "c", "a"])
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    #expect(first.orderedIDs(available: ids) == ["b", "c", "a"])
  }

}
