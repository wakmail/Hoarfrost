//
//  LayoutPlanner.swift
//  Project: Hoarfrost
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Copyright (Hoarfrost) © 2026 wakmail
//  Licensed under the GNU GPLv3

import Foundation

/// A pure planner for restoring saved menu bar membership and order.
///
/// Item arrays use right to left order. This is the order used by the cache
/// and by savedSectionOrder. Section boundaries are represented by divider
/// identifiers at the end of each section run.
nonisolated enum LayoutPlanner {
    struct CurrentItem: Equatable {
        let identifier: String
        let sectionID: String
    }

    struct Section: Equatable {
        let id: String
        let savedIdentifiers: [String]
        let dividerIdentifier: String?
    }

    enum Destination: Equatable {
        case leftOf(String)
        case rightOf(String)
        case sectionBoundary(String)
    }

    struct PlannedMove: Equatable {
        let itemIdentifier: String
        let destination: Destination
    }

    /// Plans the minimum moves needed for known items to reach their saved
    /// sections and relative order. Items absent from the saved layout stay
    /// out of the plan. Dividers are stable anchors and are never moved.
    static func plan(
        currentItems: [CurrentItem],
        sections: [Section]
    ) -> [PlannedMove] {
        var sectionByIdentifier = [String: String]()
        for section in sections {
            for identifier in section.savedIdentifiers {
                sectionByIdentifier[identifier] = section.id
            }
        }

        let dividerIDs = Set(sections.compactMap(\.dividerIdentifier))
        let currentIDs = currentItems.map(\.identifier)
        let desiredIDs = sections.flatMap { section in
            section.savedIdentifiers + (section.dividerIdentifier.map { [$0] } ?? [])
        }
        let currentSet = Set(currentIDs)
        let desiredSet = Set(desiredIDs)
        let currentOverlap = currentIDs.filter { desiredSet.contains($0) }
        let desiredOverlap = desiredIDs.filter { currentSet.contains($0) }
        let stable = longestCommonSubsequence(currentOverlap, desiredOverlap)
        let moving = desiredOverlap.filter { !stable.contains($0) && !dividerIDs.contains($0) }

        var moved = Set<String>()
        var result = [PlannedMove]()

        for identifier in moving {
            guard let desiredIndex = desiredOverlap.firstIndex(of: identifier),
                  let sectionID = sectionByIdentifier[identifier]
            else { continue }

            var destination: Destination?

            if desiredIndex + 1 < desiredOverlap.count {
                for index in (desiredIndex + 1) ..< desiredOverlap.count {
                    let candidate = desiredOverlap[index]
                    guard sectionByIdentifier[candidate] == sectionID else { break }
                    guard !dividerIDs.contains(candidate) else { continue }
                    if stable.contains(candidate) || moved.contains(candidate) {
                        destination = .leftOf(candidate)
                        break
                    }
                }
            }

            if destination == nil, desiredIndex > 0 {
                for index in stride(from: desiredIndex - 1, through: 0, by: -1) {
                    let candidate = desiredOverlap[index]
                    guard sectionByIdentifier[candidate] == sectionID else { break }
                    guard !dividerIDs.contains(candidate) else { continue }
                    if stable.contains(candidate) || moved.contains(candidate) {
                        destination = .rightOf(candidate)
                        break
                    }
                }
            }

            let finalDestination = destination ?? .sectionBoundary(sectionID)
            result.append(PlannedMove(itemIdentifier: identifier, destination: finalDestination))
            moved.insert(identifier)
        }

        return result
    }

    /// Computes the longest common subsequence. Every identifier in the
    /// returned set remains in place, so only the other known identifiers move.
    private static func longestCommonSubsequence(_ lhs: [String], _ rhs: [String]) -> Set<String> {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }
        var lengths = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for i in 1 ... lhs.count {
            for j in 1 ... rhs.count {
                lengths[i][j] = lhs[i - 1] == rhs[j - 1]
                    ? lengths[i - 1][j - 1] + 1
                    : max(lengths[i - 1][j], lengths[i][j - 1])
            }
        }

        var result = Set<String>()
        var i = lhs.count
        var j = rhs.count
        while i > 0, j > 0 {
            if lhs[i - 1] == rhs[j - 1] {
                result.insert(lhs[i - 1])
                i -= 1
                j -= 1
            } else if lengths[i - 1][j] > lengths[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }
}
