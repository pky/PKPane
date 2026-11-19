import SwiftUI

struct QuickOpenView: View {
  let candidates: [QuickOpenCandidate]
  let execute: (QuickOpenCandidate) -> Void
  let cancel: () -> Void

  @State private var query = ""
  @State private var selectedCandidateID: QuickOpenCandidate.ID?
  @FocusState private var isSearchFocused: Bool

  private var results: [QuickOpenCandidate] {
    QuickOpenIndex.search(candidates, query: query)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("場所またはコマンドを検索", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($isSearchFocused)
          .onSubmit(executeSelectedCandidate)
          .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
          }
          .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
          }
      }
      .padding(14)

      Divider()

      if results.isEmpty {
        ContentUnavailableView.search(text: query)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(results, selection: $selectedCandidateID) { candidate in
          QuickOpenCandidateRow(candidate: candidate)
            .tag(candidate.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
              execute(candidate)
            }
        }
        .listStyle(.plain)
      }
    }
    .frame(width: 560, height: 400)
    .onAppear {
      selectedCandidateID = results.first?.id
      isSearchFocused = true
    }
    .onChange(of: query) {
      selectedCandidateID = results.first?.id
    }
    .onChange(of: candidates) {
      guard results.contains(where: { $0.id == selectedCandidateID }) else {
        selectedCandidateID = results.first?.id
        return
      }
    }
    .onExitCommand(perform: cancel)
  }

  private func moveSelection(by offset: Int) {
    guard !results.isEmpty else {
      selectedCandidateID = nil
      return
    }
    let currentIndex =
      selectedCandidateID.flatMap { selectedID in
        results.firstIndex { $0.id == selectedID }
      } ?? 0
    let nextIndex = min(max(currentIndex + offset, 0), results.count - 1)
    selectedCandidateID = results[nextIndex].id
  }

  private func executeSelectedCandidate() {
    guard
      let candidate = results.first(where: { $0.id == selectedCandidateID }) ?? results.first
    else { return }
    execute(candidate)
  }
}

private struct QuickOpenCandidateRow: View {
  let candidate: QuickOpenCandidate

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: candidate.kind.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(candidate.title)
          .lineLimit(1)
        if let subtitle = candidate.subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
      Text(candidate.kind.label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.12), in: Capsule())
    }
    .padding(.vertical, 3)
  }
}
