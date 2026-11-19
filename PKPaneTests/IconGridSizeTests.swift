import Foundation
import Testing

@testable import PKPane

struct IconGridSizeTests {
  @Test("larger()は小→中→大→特大の順に1段階ずつ拡大する")
  func largerStepsThroughAllStages() {
    #expect(IconGridSize.small.larger() == .medium)
    #expect(IconGridSize.medium.larger() == .large)
    #expect(IconGridSize.large.larger() == .extraLarge)
  }

  @Test("smaller()は特大→大→中→小の順に1段階ずつ縮小する")
  func smallerStepsThroughAllStages() {
    #expect(IconGridSize.extraLarge.smaller() == .large)
    #expect(IconGridSize.large.smaller() == .medium)
    #expect(IconGridSize.medium.smaller() == .small)
  }

  @Test("最大段階でlarger()を呼んでも変化しない(端で飽和)")
  func largerSaturatesAtMaximum() {
    #expect(IconGridSize.extraLarge.larger() == .extraLarge)
  }

  @Test("最小段階でsmaller()を呼んでも変化しない(端で飽和)")
  func smallerSaturatesAtMinimum() {
    #expect(IconGridSize.small.smaller() == .small)
  }

  @Test("4段階の並び順はsmall<medium<large<extraLarge")
  func stagesAreOrderedByRawValue() {
    #expect(IconGridSize.allCases == [.small, .medium, .large, .extraLarge])
    #expect(IconGridSize.small < .medium)
    #expect(IconGridSize.medium < .large)
    #expect(IconGridSize.large < .extraLarge)
  }

  @Test("リスト/カラム用のアイコンサイズと行高は4段階の設計値に一致する")
  func listMetricsMatchDesignValues() {
    let expected: [(IconGridSize, CGFloat, CGFloat, CGSize)] = [
      (.small, 14, 20, CGSize(width: 28, height: 28)),
      (.medium, 16, 22, CGSize(width: 32, height: 32)),
      (.large, 24, 30, CGSize(width: 48, height: 48)),
      (.extraLarge, 32, 40, CGSize(width: 64, height: 64)),
    ]

    for (size, pointSize, rowHeight, resolvedSize) in expected {
      #expect(size.listIconPointSize == pointSize)
      #expect(size.listRowHeight == rowHeight)
      #expect(size.listResolvedIconSize == resolvedSize)
    }
  }

  @Test("中サイズのリスト外観は従来の16ptアイコンと22pt行高を維持する")
  func mediumListMetricsPreservePreviousAppearance() {
    #expect(IconGridSize.medium.listIconPointSize == 16)
    #expect(IconGridSize.medium.listRowHeight == 22)
    #expect(IconGridSize.medium.listResolvedIconSize == CGSize(width: 32, height: 32))
  }

  @Test("リスト/カラム用のアイコンサイズと行高は段階に対して単調増加する")
  func listMetricsIncreaseMonotonically() {
    let sizes = IconGridSize.allCases
    for (current, next) in zip(sizes, sizes.dropFirst()) {
      #expect(current.listIconPointSize < next.listIconPointSize)
      #expect(current.listRowHeight < next.listRowHeight)
    }
  }
}
