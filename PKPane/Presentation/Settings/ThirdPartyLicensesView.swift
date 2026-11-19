import Foundation
import SwiftUI

struct ThirdPartyLicenseEntry: Identifiable, Sendable {
  let title: String
  let resourceName: String

  var id: String { resourceName }

  static let all: [Self] = [
    .init(title: "BigInt", resourceName: "BigInt-LICENSE"),
    .init(title: "BitByteData", resourceName: "BitByteData-LICENSE"),
    .init(title: "Citadel", resourceName: "Citadel-LICENSE"),
    .init(title: "PLzmaSDK", resourceName: "PLzmaSDK-LICENSE"),
    .init(title: "SMBClient", resourceName: "SMBClient-LICENSE"),
    .init(title: "SWCompression", resourceName: "SWCompression-LICENSE"),
    .init(title: "Unrar.swift", resourceName: "UnrarSwift-LICENSE"),
    .init(title: "UnRAR", resourceName: "UnRAR-LICENSE"),
    .init(title: "ZIPFoundation", resourceName: "ZIPFoundation-LICENSE"),
    .init(title: "Swift ASN.1", resourceName: "SwiftASN1-LICENSE"),
    .init(title: "Swift ASN.1 NOTICE", resourceName: "SwiftASN1-NOTICE"),
    .init(title: "Swift Atomics", resourceName: "SwiftAtomics-LICENSE"),
    .init(title: "Swift Collections", resourceName: "SwiftCollections-LICENSE"),
    .init(title: "Swift Crypto", resourceName: "SwiftCrypto-LICENSE"),
    .init(title: "Swift Crypto NOTICE", resourceName: "SwiftCrypto-NOTICE"),
    .init(title: "Swift Log", resourceName: "SwiftLog-LICENSE"),
    .init(title: "Swift Log NOTICE", resourceName: "SwiftLog-NOTICE"),
    .init(title: "SwiftNIO SSH", resourceName: "SwiftNIOSSH-LICENSE"),
    .init(title: "SwiftNIO", resourceName: "SwiftNIO-LICENSE"),
    .init(title: "SwiftNIO NOTICE", resourceName: "SwiftNIO-NOTICE"),
    .init(title: "Swift System", resourceName: "SwiftSystem-LICENSE"),
  ]

  func text(in bundle: Bundle = .main) -> String {
    guard let url = bundle.url(forResource: resourceName, withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else {
      return String(localized: "ライセンス文書を読み込めませんでした。")
    }
    return text
  }
}

struct ThirdPartyLicensesView: View {
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        Text("PKPaneは次のオープンソースソフトウェアを利用しています。")
          .foregroundStyle(.secondary)
        ForEach(ThirdPartyLicenseEntry.all) { entry in
          DisclosureGroup(entry.title) {
            Text(entry.text())
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 8)
          }
        }
      }
      .padding()
    }
  }
}
