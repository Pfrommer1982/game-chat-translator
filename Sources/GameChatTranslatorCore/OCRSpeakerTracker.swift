import Foundation

public struct SpeakerState: Codable, Equatable, Identifiable {
    public var id: String { username }
    public let username: String
    public let firstSeenAt: Date
    public var lastSeenAt: Date
    public var appearedAt: Date
    public var disappearedAt: Date?
    public var continuousVisibleDuration: TimeInterval
    public var confidence: Double // Vision confidence
    
    public init(
        username: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        appearedAt: Date,
        disappearedAt: Date? = nil,
        continuousVisibleDuration: TimeInterval = 0.0,
        confidence: Double = 1.0
    ) {
        self.username = username
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.appearedAt = appearedAt
        self.disappearedAt = disappearedAt
        self.continuousVisibleDuration = continuousVisibleDuration
        self.confidence = confidence
    }
}

public final class OCRSpeakerTracker {
    private let lock = NSLock()
    private var activeStates: [String: SpeakerState] = [:]
    private var historicalStates: [SpeakerState] = []
    private let historyRetentionDuration: TimeInterval = 120.0 // Keep 2 minutes of history
    
    public init() {}
    
    /// Updates the tracker with the set of currently visible usernames at a specific time.
    /// - Parameters:
    ///   - detected: Array of (username, confidence) pairs seen in the current OCR frame
    ///   - timestamp: The date/time of the OCR capture
    ///   - profile: The active game profile containing stale threshold, hold time, etc.
    public func update(detected: [(username: String, confidence: Double)], at timestamp: Date, profile: GameProfile) {
        lock.lock()
        defer { lock.unlock() }
        
        let detectedNames = Set(detected.map { $0.username })
        
        // 1. Process detected speakers
        for item in detected {
            let name = item.username
            let conf = item.confidence
            
            if var state = activeStates[name] {
                // If it was marked as disappeared, check if we're resuming within the hold time
                if let disappeared = state.disappearedAt {
                    let gap = timestamp.timeIntervalSince(disappeared)
                    if gap <= profile.speakerHoldTime {
                        // Flicker / short gap: resume continuous visibility
                        state.disappearedAt = nil
                        state.lastSeenAt = timestamp
                        state.continuousVisibleDuration = timestamp.timeIntervalSince(state.appearedAt)
                        state.confidence = (state.confidence + conf) / 2.0
                        activeStates[name] = state
                    } else {
                        // Exceeded hold time, archive the old state to history, start new block
                        historicalStates.append(state)
                        
                        let newState = SpeakerState(
                            username: name,
                            firstSeenAt: state.firstSeenAt,
                            lastSeenAt: timestamp,
                            appearedAt: timestamp,
                            disappearedAt: nil,
                            continuousVisibleDuration: 0.0,
                            confidence: conf
                        )
                        activeStates[name] = newState
                    }
                } else {
                    // Normal continuous update
                    state.lastSeenAt = timestamp
                    state.continuousVisibleDuration = timestamp.timeIntervalSince(state.appearedAt)
                    state.confidence = (state.confidence + conf) / 2.0
                    activeStates[name] = state
                }
            } else {
                // Brand new speaker
                let newState = SpeakerState(
                    username: name,
                    firstSeenAt: timestamp,
                    lastSeenAt: timestamp,
                    appearedAt: timestamp,
                    disappearedAt: nil,
                    continuousVisibleDuration: 0.0,
                    confidence: conf
                )
                activeStates[name] = newState
            }
        }
        
        // 2. Process speakers that were NOT detected in this frame
        for (name, var state) in activeStates {
            if !detectedNames.contains(name) {
                if state.disappearedAt == nil {
                    // Just disappeared
                    state.disappearedAt = timestamp
                    state.continuousVisibleDuration = timestamp.timeIntervalSince(state.appearedAt)
                    activeStates[name] = state
                } else {
                    // Already disappeared, check if we should evict it from active to history
                    if let disappeared = state.disappearedAt,
                       timestamp.timeIntervalSince(disappeared) > profile.speakerHoldTime {
                        historicalStates.append(state)
                        activeStates.removeValue(forKey: name)
                    }
                }
            }
        }
        
        // 3. Clean up old historical states
        let cutoff = timestamp.addingTimeInterval(-historyRetentionDuration)
        historicalStates.removeAll { state in
            if let disappeared = state.disappearedAt {
                return disappeared < cutoff
            }
            return false
        }
    }
    
    /// Retrieves all active and historical speaker states that overlap with a given time range.
    public func getStatesOverlapping(from start: Date, to end: Date) -> [SpeakerState] {
        lock.lock()
        defer { lock.unlock() }
        
        var results: [SpeakerState] = []
        
        // Collect from active and historical
        let allStates = Array(activeStates.values) + historicalStates
        
        for state in allStates {
            let stateStart = state.appearedAt
            let stateEnd = state.disappearedAt ?? Date()
            
            // Check if intervals [stateStart, stateEnd] and [start, end] overlap
            let overlapStart = max(stateStart, start)
            let overlapEnd = min(stateEnd, end)
            
            if overlapStart <= overlapEnd {
                // Overlap exists!
                results.append(state)
            }
        }
        
        return results
    }
    
    /// Gets all current active states (for debug/dashboard UI).
    public func getCurrentActiveStates() -> [SpeakerState] {
        lock.lock()
        defer { lock.unlock() }
        return Array(activeStates.values)
    }
    
    /// Clears the tracker's states (e.g. when resetting the engine).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        activeStates.removeAll()
        historicalStates.removeAll()
    }
}
