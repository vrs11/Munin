import SwiftUI

struct ClipboardListView: View {
    @ObservedObject var store: ClipboardStore
    @State private var scrollLockedEntryID: ClipboardEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.entries) { entry in
                            ClipboardEntryRow(
                                entry: entry,
                                onCopy: { store.copyEntryToPasteboard(entry) },
                                onDelete: { store.deleteEntry(id: entry.id) },
                                onExpandedScrollHoverChanged: { isHovering in
                                    if isHovering {
                                        scrollLockedEntryID = entry.id
                                    } else if scrollLockedEntryID == entry.id {
                                        scrollLockedEntryID = nil
                                    }
                                }
                            )
                        }
                    }
                    .padding(12)
                }
                .scrollDisabled(scrollLockedEntryID != nil)
            }
        }
        .frame(width: 480, height: 560)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Copy text or an image to start building history")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}

private struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onExpandedScrollHoverChanged: (Bool) -> Void
    private let collapsedLineLimit = 6
    private let maxExpandedTextHeight: CGFloat = 220
    private let actionColumnWidth: CGFloat = 22
    private let actionColumnInset: CGFloat = 8
    private let minimumRowHeight: CGFloat = 70
    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var isShowingCopyFeedback = false
    @State private var canExpand = false
    @State private var measuredTextWidth: CGFloat = 0
    @State private var copyFeedbackResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content

            Text(entry.createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, actionColumnWidth + actionColumnInset)
        .padding(10)
        .frame(minHeight: minimumRowHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isShowingCopyFeedback
                        ? Color.accentColor.opacity(0.14)
                        : Color(nsColor: .windowBackgroundColor)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isShowingCopyFeedback
                        ? Color.accentColor.opacity(0.65)
                        : Color(nsColor: .separatorColor),
                    lineWidth: isShowingCopyFeedback ? 1 : 0.5
                )
        )
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 6) {
                if entry.kind == .text && canExpand {
                    actionIconTapControl(
                        systemName: isExpanded ? "chevron.up" : "chevron.down",
                        hint: isExpanded ? "Collapse" : "Expand",
                        action: { isExpanded.toggle() }
                    )
                }

                Spacer(minLength: 0)

                if isHovered {
                    actionIconTapControl(systemName: "trash", hint: "Delete", destructive: true, action: onDelete)
                }
            }
            .padding(.trailing, 10)
            .padding(.vertical, 10)
        }
        .overlay(alignment: .bottomTrailing) {
            if isShowingCopyFeedback {
                Label("Copied", systemImage: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            onCopy()
            showCopyFeedback()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: isExpanded) { expanded in
            if !expanded {
                onExpandedScrollHoverChanged(false)
            }
        }
        .onDisappear {
            onExpandedScrollHoverChanged(false)
            copyFeedbackResetTask?.cancel()
        }
        .scaleEffect(isShowingCopyFeedback ? 0.992 : 1)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
        .animation(.easeOut(duration: 0.18), value: isShowingCopyFeedback)
    }

    @ViewBuilder
    private var content: some View {
        if let image = entry.nsImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 140, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            if isExpanded && canExpand {
                ScrollView(.vertical) {
                    textContent(lineLimit: nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxExpandedTextHeight, alignment: .topLeading)
                .onHover { hovering in
                    onExpandedScrollHoverChanged(hovering)
                }
                .onDisappear {
                    onExpandedScrollHoverChanged(false)
                }
            } else {
                textContent(lineLimit: collapsedLineLimit)
            }
        }
    }

    private func textContent(lineLimit: Int?) -> some View {
        Text(entry.text ?? "")
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            updateExpandAvailability(textWidth: proxy.size.width)
                        }
                        .onChange(of: proxy.size.width) { newWidth in
                            updateExpandAvailability(textWidth: newWidth)
                        }
                }
            )
    }

    private func actionIconTapControl(
        systemName: String,
        hint: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        actionIcon(systemName: systemName, destructive: destructive)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .focusable(false)
            .help(hint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hint)
            .accessibilityAddTraits(.isButton)
    }

    private func actionIcon(systemName: String, destructive: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .frame(width: 22, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }

    private func updateExpandAvailability(textWidth: CGFloat) {
        guard entry.kind == .text else { return }
        guard textWidth > 0 else { return }
        guard abs(textWidth - measuredTextWidth) > 0.5 else { return }

        measuredTextWidth = textWidth

        let text = entry.text ?? ""
        let font = NSFont.preferredFont(forTextStyle: .body)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let fullHeight = NSString(string: text).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).height
        let collapsedHeight = (font.ascender - font.descender + font.leading) * CGFloat(collapsedLineLimit)
        let shouldAllowExpand = ceil(fullHeight) > ceil(collapsedHeight + 1)

        canExpand = shouldAllowExpand
        if !shouldAllowExpand {
            isExpanded = false
        }
    }

    private func showCopyFeedback() {
        copyFeedbackResetTask?.cancel()
        isShowingCopyFeedback = true

        copyFeedbackResetTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                isShowingCopyFeedback = false
            }
        }
    }
}

@MainActor
final class QuickPasteViewModel: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var selectedIndex: Int = 0

    var selectedEntry: ClipboardEntry? {
        guard entries.indices.contains(selectedIndex) else { return nil }
        return entries[selectedIndex]
    }

    func setEntries(_ entries: [ClipboardEntry]) {
        self.entries = Array(entries.prefix(10))
        if self.entries.isEmpty {
            selectedIndex = 0
            return
        }

        selectedIndex = 0
    }

    func moveSelection(delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), entries.count - 1)
    }

    func select(index: Int) {
        guard entries.indices.contains(index) else { return }
        selectedIndex = index
    }
}

struct QuickPastePopupView: View {
    @ObservedObject var viewModel: QuickPasteViewModel
    let onChoose: (ClipboardEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.entries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clipboard")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("No clipboard items yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                                QuickPasteEntryPreviewRow(entry: entry, isSelected: index == viewModel.selectedIndex)
                                    .id(entry.id)
                                    .onTapGesture {
                                        viewModel.select(index: index)
                                        onChoose(entry)
                                    }
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: viewModel.selectedIndex) { index in
                        guard viewModel.entries.indices.contains(index) else { return }
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(viewModel.entries[index].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 420)
    }
}

private struct QuickPasteEntryPreviewRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = entry.nsImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 110, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(entry.text ?? "")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(entry.createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 1 : 0.5
                )
        )
    }
}
