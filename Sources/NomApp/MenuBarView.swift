import SwiftUI
import NomCore

struct MenuBarPanel: View {
    let monitor: SpaceMonitor
    @State private var editingSpaceId: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = groupedByDisplay()

            ForEach(Array(groups.enumerated()), id: \.offset) { displayIndex, group in
                if displayIndex > 0 {
                    Divider()
                        .padding(.vertical, 6)
                }

                if groups.count > 1 {
                    Text("Display \(displayIndex + 1)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .padding(.top, displayIndex == 0 ? 2 : 0)
                }

                ForEach(group.spaces) { space in
                    SpaceRow(
                        space: space,
                        isCurrent: space.id == monitor.currentSpace?.id,
                        isEditing: editingSpaceId == space.id,
                        onStartEdit: { editingSpaceId = space.id },
                        onCommit: { name in
                            monitor.setName(name, for: space)
                            editingSpaceId = nil
                        },
                        onCancel: { editingSpaceId = nil },
                        onJump: {
                            monitor.jump(to: space)
                            dismiss()
                        },
                        onMoveWindow: {
                            monitor.moveFrontmostWindow(to: space)
                            dismiss()
                        },
                        onDelete: monitor.canDelete(space) ? {
                            monitor.deleteSpace(space)
                            dismiss()
                        } : nil
                    )
                }
            }

            Divider()
                .padding(.vertical, 6)

            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    private struct DisplayGroup {
        let displayId: String
        let spaces: [SpaceInfo]
    }

    private func groupedByDisplay() -> [DisplayGroup] {
        var seen: [String] = []
        var groups: [String: [SpaceInfo]] = [:]

        for space in monitor.allSpaces {
            if !seen.contains(space.displayId) {
                seen.append(space.displayId)
            }
            groups[space.displayId, default: []].append(space)
        }

        return seen.map { DisplayGroup(displayId: $0, spaces: groups[$0] ?? []) }
    }
}

// MARK: - Space Row

struct SpaceRow: View {
    let space: SpaceInfo
    let isCurrent: Bool
    let isEditing: Bool
    let onStartEdit: () -> Void
    let onCommit: (String?) -> Void
    let onCancel: () -> Void
    let onJump: () -> Void
    let onMoveWindow: () -> Void
    /// nil when the space can't be deleted (last desktop on its display).
    let onDelete: (() -> Void)?

    @State private var editText = ""
    @State private var isHovered = false
    @State private var deleteHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                editingRow
            } else {
                displayRow
            }
        }
        .padding(.horizontal, 8)
    }

    private var displayRow: some View {
        HStack(spacing: 8) {
            Button {
                editText = space.name ?? ""
                onStartEdit()
                isFocused = true
            } label: {
                HStack(spacing: 8) {
                    Text("\(space.index)")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, alignment: .trailing)

                    if space.name != nil {
                        Text(space.displayName)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                    } else {
                        Text(space.displayName)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename this space")

            if isCurrent {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            } else if isHovered {
                Button(action: onMoveWindow) {
                    Image(systemName: "rectangle.portrait.and.arrow.forward")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Move the frontmost window to this space")

                Button(action: onJump) {
                    Image(systemName: "arrow.forward.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Jump to this space")

                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(deleteHovered ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .onHover { deleteHovered = $0 }
                    .help("Delete this space (windows move to a neighboring space)")
                }
            }
        }
        .padding(.horizontal, 8)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var editingRow: some View {
        HStack(spacing: 8) {
            Text("\(space.index)")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)

            TextField("Name this space", text: $editText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit {
                    let trimmed = editText.trimmingCharacters(in: .whitespaces)
                    onCommit(trimmed.isEmpty ? nil : trimmed)
                }
                .onExitCommand {
                    onCancel()
                }

            Button {
                let trimmed = editText.trimmingCharacters(in: .whitespaces)
                onCommit(trimmed.isEmpty ? nil : trimmed)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
        }
        .onAppear {
            isFocused = true
        }
    }
}
