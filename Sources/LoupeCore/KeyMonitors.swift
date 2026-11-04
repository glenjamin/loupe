import AppKit

/// The app's key monitors, asked in a set order until one takes the key: AppKit asks its own
/// local monitors in no order it promises, and varies it from run to run.
@MainActor
public enum KeyMonitors {
    public enum Order: Int, Comparable {
        /// Ahead of the app's own keys, as the text-editing keys are.
        case first
        case app
        /// After every other, as a snapshot run's delivery of keys no view would get.
        case last

        public static func < (lhs: Order, rhs: Order) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Handler {
        let order: Order
        let keyUps: Bool
        /// Whether it took the key.
        let handle: @MainActor (NSEvent) -> Bool
    }

    private static var handlers: [Handler] = []
    private static var monitor: Any?

    /// Asks `handle` of each key down, and each key up too if `keyUps`, after those added
    /// earlier at its `order`. It returns whether it took the key, which then goes no further.
    public static func add(_ order: Order = .app, keyUps: Bool = false, _ handle: @escaping @MainActor (NSEvent) -> Bool) {
        let index = handlers.firstIndex { $0.order > order } ?? handlers.endIndex
        handlers.insert(Handler(order: order, keyUps: keyUps, handle: handle), at: index)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // Local monitors run on the main thread, where the event came from.
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { taken(event) } ? nil : event
        }
    }

    private static func taken(_ event: NSEvent) -> Bool {
        handlers.contains { ($0.keyUps || event.type == .keyDown) && $0.handle(event) }
    }
}
