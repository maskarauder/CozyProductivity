import SwiftUI

enum RecurrenceKind: String, Codable, CaseIterable, Identifiable {
    case once
    case daily
    case weekly
    case biweekly
    case monthly
    case customDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: return "Once"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 Weeks"
        case .monthly: return "Monthly"
        case .customDays: return "Every N Days"
        }
    }

    var shortLabel: String {
        switch self {
        case .once: return "Once"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .biweekly: return "Biweekly"
        case .monthly: return "Monthly"
        case .customDays: return "Custom"
        }
    }

    var systemImage: String {
        switch self {
        case .once: return "sparkle"
        case .daily: return "sun.max"
        case .weekly: return "calendar.badge.clock"
        case .biweekly: return "arrow.triangle.2.circlepath"
        case .monthly: return "moon.stars"
        case .customDays: return "repeat"
        }
    }

    var supportsFlexibleDaySelection: Bool {
        self != .daily
    }

    var pillBackground: Color {
        switch self {
        case .once: return CozyTheme.pastelButter
        case .daily: return CozyTheme.petalPill
        case .weekly: return CozyTheme.pastelLavender
        case .biweekly: return CozyTheme.pastelSky
        case .monthly: return CozyTheme.pastelPeach
        case .customDays: return CozyTheme.pastelMint
        }
    }

    var pillForeground: Color {
        switch self {
        case .once: return CozyTheme.pastelButterInk
        case .daily: return CozyTheme.deepRose
        case .weekly: return CozyTheme.pastelLavenderInk
        case .biweekly: return CozyTheme.pastelSkyInk
        case .monthly: return CozyTheme.pastelPeachInk
        case .customDays: return CozyTheme.pastelMintInk
        }
    }
}

enum TaskCategory: String, Codable, CaseIterable, Identifiable {
    case home
    case selfCare
    case lifeAdmin
    case focus
    case errands
    case creative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Cozy Home"
        case .selfCare: return "Self-Care"
        case .lifeAdmin: return "Life Admin"
        case .focus: return "Gentle Focus"
        case .errands: return "Errands"
        case .creative: return "Creative"
        }
    }

    var defaultEmoji: String {
        switch self {
        case .home: return "🏡"
        case .selfCare: return "🌸"
        case .lifeAdmin: return "💌"
        case .focus: return "✨"
        case .errands: return "🧺"
        case .creative: return "🎀"
        }
    }
}

enum OccurrenceStatus: String, Codable {
    case pending
    case completed
    case skipped
}

enum CalendarDeductionMode: String, Codable, CaseIterable, Identifiable {
    case subtractFromBudget
    case capByUnbookedWakingHours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtractFromBudget:
            return "Subtract events from daily budget"
        case .capByUnbookedWakingHours:
            return "Cap budget by free waking hours"
        }
    }

    var subtitle: String {
        switch self {
        case .subtractFromBudget:
            return "Best if your calendar mainly holds personal appointments or evening plans."
        case .capByUnbookedWakingHours:
            return "Best if 9–5 work blocks are on your calendar; compares total unbooked hours."
        }
    }
}
