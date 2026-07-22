/// Adjustable hub-window opacity (issue #6). Only the background material
/// fades — text and cards render at full alpha on top. The floor keeps the
/// window findable and its content unreadable-through, and the system
/// Reduce Transparency setting always wins.
public enum HubOpacityPolicy {

    /// The window can never go below this — a fully invisible window is
    /// unfindable, and glance-reading whatever is behind it through the
    /// content area is an accidental-exposure risk.
    public static let floor = 0.3

    public static func effective(
        userOpacity: Double,
        reduceTransparency: Bool,
        isInactive: Bool,
        fadeWhenInactive: Bool
    ) -> Double {
        guard !reduceTransparency else { return 1 }
        var alpha = min(1, max(floor, userOpacity))
        if fadeWhenInactive, isInactive {
            alpha = max(floor, alpha - 0.15)
        }
        return alpha
    }
}
