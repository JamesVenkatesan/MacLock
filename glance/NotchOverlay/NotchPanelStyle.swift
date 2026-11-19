//
//  NotchPanelStyle.swift
//  glance
//
//  Which silhouette the overlay panel wears on a given screen — passed down
//  through the environment so onboarding's step views can adapt without a parameter.
//

import SwiftUI

enum NotchPanelStyle {
    /// Inverted top corners, flush with the screen's top edge.
    case notch
    /// Fully-rounded pill / floating rounded rectangle, detached from the edge.
    case pill
}

extension EnvironmentValues {
    @Entry var notchPanelStyle: NotchPanelStyle = .notch
    /// True when a pill-style panel is parked over the hardware camera island, so
    /// content near the panel's top edge needs clearance like it does under a notch.
    @Entry var notchPanelCoversIsland: Bool = false
}
