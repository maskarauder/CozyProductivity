import SwiftUI

struct TaskChecklistCardView: View {
    let occurrence: TaskOccurrence
    var onToggleComplete: () -> Void
    var onEditTemplate: () -> Void
    var onMoveToTomorrow: () -> Void
    var onMoveToFreestDay: () -> Void
    var onDeleteTemplate: () -> Void

    @State private var checkScale: CGFloat = 1.0

    private var recurrence: RecurrenceKind {
        occurrence.template?.recurrence ?? .once
    }

    private func triggerToggle() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.55)) {
            checkScale = 1.24
        }
        onToggleComplete()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                checkScale = 1.0
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Tactile Check-Off Button
            Button {
                triggerToggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            occurrence.isCompleted
                                ? AnyShapeStyle(CozyTheme.primaryButtonGradient)
                                : AnyShapeStyle(CozyTheme.softBlushFill)
                        )
                        .frame(width: 34, height: 34)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    occurrence.isCompleted ? CozyTheme.roseAccent : CozyTheme.roseAccent.opacity(0.55),
                                    lineWidth: 2
                                )
                        )

                    if occurrence.isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(checkScale)
                .frame(width: 42, height: 42)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(occurrence.isCompleted ? "Mark \(occurrence.displayTitle) incomplete" : "Complete \(occurrence.displayTitle)")

            // Emoji + Task Details
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(occurrence.displayEmoji)
                        .font(.title3)

                    Text(occurrence.displayTitle)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(occurrence.isCompleted ? CozyTheme.inkMuted : CozyTheme.inkPrimary)
                        .strikethrough(occurrence.isCompleted, color: CozyTheme.inkMuted)
                        .lineLimit(2)

                    Spacer(minLength: 4)
                }

                if !occurrence.displayNotes.isEmpty && !occurrence.isCompleted {
                    Text(occurrence.displayNotes)
                        .font(.footnote)
                        .foregroundStyle(CozyTheme.inkSecondary)
                        .lineLimit(2)
                }

                // Duration + Recurrence Pills
                HStack(spacing: 8) {
                    Label(DateHelpers.formatDuration(minutes: occurrence.displayDurationMinutes), systemImage: "clock")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(CozyTheme.deepRose)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(CozyTheme.softBlushFill)
                        )

                    HStack(spacing: 4) {
                        Image(systemName: recurrence.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                        Text(occurrence.recurrenceLabel)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(recurrence.pillForeground)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(recurrence.pillBackground)
                    )

                    if let category = occurrence.template?.category {
                        Text(category.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(CozyTheme.inkSecondary)
                    }

                    Spacer()
                }
            }

            // Overflow Quick Menu
            Menu {
                Button {
                    onEditTemplate()
                } label: {
                    Label("Edit Task", systemImage: "pencil")
                }

                if !occurrence.isCompleted {
                    Button {
                        onMoveToTomorrow()
                    } label: {
                        Label("Move to Tomorrow", systemImage: "sunrise")
                    }

                    if recurrence.supportsFlexibleDaySelection {
                        Button {
                            onMoveToFreestDay()
                        } label: {
                            Label("Auto-Place on Freest Day", systemImage: "wand.and.stars")
                        }
                    }
                }

                Divider()

                Button(role: .destructive) {
                    onDeleteTemplate()
                } label: {
                    Label("Delete Task", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CozyTheme.inkMuted)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cozyCard(isCompleted: occurrence.isCompleted)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            triggerToggle()
        }
    }
}
