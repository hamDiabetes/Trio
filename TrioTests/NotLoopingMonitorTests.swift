import Combine
import Foundation
import LoopKit
import Testing
import UserNotifications

@testable import Trio

/// Records `issueAlert` / `retractAlert` calls in order so tests can assert
/// the retract-then-issue re-arm semantics of `NotLoopingMonitor`. Every
/// other `TrioAlertManager` member is a no-op stub.
final class SpyAlertManager: TrioAlertManager {
    enum Call: Equatable {
        case retract(Alert.Identifier)
        case issue(Alert)
    }

    private(set) var callLog: [Call] = []
    private(set) var issuedAlerts: [Alert] = []
    private(set) var retractedIdentifiers: [Alert.Identifier] = []

    func issueAlert(_ alert: Alert) {
        callLog.append(.issue(alert))
        issuedAlerts.append(alert)
    }

    func retractAlert(identifier: Alert.Identifier) {
        callLog.append(.retract(identifier))
        retractedIdentifiers.append(identifier)
    }

    // MARK: - No-op stubs

    func register(responder _: AlertResponder, for _: String) {}
    func register(soundVendor _: AlertSoundVendor, for _: String) {}
    func unregister(managerIdentifier _: String) {}

    func handleAcknowledgement(identifier _: Alert.Identifier) {}
    func handleNotificationResponse(_: UNNotificationResponse) {}
    func acknowledgeAllOutstanding() {}
    func replayUnacknowledgedAlerts() {}
    @MainActor func applySnooze(for _: TimeInterval) async {}
    func clearPendingNonCriticalNotifications() {}

    var muter: AlertMuter { AlertMuter() }
    let modalScheduler = TrioModalAlertScheduler()

    func soundURL(for _: Alert) -> URL? { nil }
}

@Suite("Trio Alerts: NotLoopingMonitor") struct NotLoopingMonitorTests {
    /// Reconstructed locally from the private statics in the source.
    private let criticalID = Alert.Identifier(
        managerIdentifier: "trio.aps",
        alertIdentifier: "loop.notActive"
    )
    private func warningID(_ step: Int) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: "loop.notActive.w\(step)")
    }

    /// Steps are anchored to the last loop date, so the armed interval is a
    /// few milliseconds short of the nominal value by the time it is built.
    private func expectDelay(_ trigger: Alert.Trigger, _ minutes: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case let .delayed(interval) = trigger else {
            Issue.record("expected a delayed trigger, got \(trigger)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(interval - TimeInterval(minutes * 60)) < 5, sourceLocation: sourceLocation)
    }

    private func armLadder() -> SpyAlertManager {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(
            loopDates: subject.eraseToAnyPublisher(),
            trioAlertManager: spy,
            alertsStore: isolatedStore(.escalating)
        )
        subject.send(Date())
        _ = monitor // retain through the synchronous send
        return spy
    }

    @Test("A loop success arms five warnings and one critical") func armsFullLadder() {
        let spy = armLadder()
        #expect(spy.issuedAlerts.count == 6)

        let warnings = spy.issuedAlerts.filter { $0.identifier != criticalID }
        #expect(warnings.count == 5)
        for (index, minutes) in [20, 40, 60, 80, 100].enumerated() {
            let alert = warnings[index]
            #expect(alert.identifier == warningID(index + 1))
            expectDelay(alert.trigger, minutes)
            #expect(alert.interruptionLevel == .timeSensitive)
        }
    }

    @Test("The sixth step is critical at 120 minutes") func criticalStepAtTwoHours() {
        let spy = armLadder()
        guard let critical = spy.issuedAlerts.first(where: { $0.identifier == criticalID }) else {
            Issue.record("expected a critical escalation alert")
            return
        }
        expectDelay(critical.trigger, 120)
        #expect(critical.interruptionLevel == .critical)
    }

    @Test("Every step is retracted before anything is re-armed") func retractsWholeLadderFirst() {
        let spy = armLadder()
        let firstIssue = spy.callLog.firstIndex { if case .issue = $0 { return true }
            return false }
        let lastRetract = spy.callLog.lastIndex { if case .retract = $0 { return true }
            return false }
        guard let firstIssue, let lastRetract else {
            Issue.record("expected both retracts and issues")
            return
        }
        #expect(lastRetract < firstIssue)
        #expect(spy.retractedIdentifiers.count == 6)
        #expect(Set(spy.retractedIdentifiers) == Set([criticalID] + (1 ... 5).map(warningID)))
    }

    @Test("A recovered loop re-arms the whole ladder again") func reArmsOnEachSuccess() {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(
            loopDates: subject.eraseToAnyPublisher(),
            trioAlertManager: spy,
            alertsStore: isolatedStore(.escalating)
        )

        subject.send(Date())
        subject.send(Date())

        #expect(spy.issuedAlerts.count == 12)
        #expect(spy.retractedIdentifiers.count == 12)
        _ = monitor
    }

    @Test("Warning identifiers resolve to the Time-Sensitive tier") func warningsAreCatalogedTimeSensitive() {
        for step in 1 ... 5 {
            guard let entry = AlertCatalogRegistry.lookup(warningID(step)) else {
                Issue.record("warning step \(step) has no catalog entry")
                return
            }
            #expect(entry.interruptionLevel == .timeSensitive)
            #expect(entry.concept == .notLooping)
        }
        #expect(AlertCatalogRegistry.lookup(criticalID)?.interruptionLevel == .critical)
    }

    @Test("Every step is delayed, never immediate") func allStepsDelayed() {
        for alert in armLadder().issuedAlerts {
            #expect(alert.trigger != .immediate)
        }
    }

    private func isolatedStore(_ mode: NotLoopingAlarmMode) -> DeviceAlertsStore {
        let defaults = UserDefaults(suiteName: "NotLoopingMonitorTests.\(UUID().uuidString)")!
        let store = DeviceAlertsStore(defaults: defaults)
        store.notLoopingAlarm = mode
        return store
    }

    @Test("A single Critical mode arms one alarm at the chosen delay") func singleCriticalMode() {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(
            loopDates: subject.eraseToAnyPublisher(),
            trioAlertManager: spy,
            alertsStore: isolatedStore(.critical(afterMinutes: 45))
        )
        subject.send(Date())

        #expect(spy.issuedAlerts.count == 1)
        #expect(spy.issuedAlerts.first?.identifier == criticalID)
        #expect(spy.issuedAlerts.first?.interruptionLevel == .critical)
        if let trigger = spy.issuedAlerts.first?.trigger { expectDelay(trigger, 45) }
        #expect(spy.retractedIdentifiers.count == 6)
        _ = monitor
    }

    @Test("Off arms nothing and still retracts every step") func offMode() {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(
            loopDates: subject.eraseToAnyPublisher(),
            trioAlertManager: spy,
            alertsStore: isolatedStore(.off)
        )
        subject.send(Date())

        #expect(spy.issuedAlerts.isEmpty)
        #expect(Set(spy.retractedIdentifiers) == Set([criticalID] + (1 ... 5).map(warningID)))
        _ = monitor
    }

    @Test("Changing the mode re-arms at once with the new choice") func modeChangeReArms() {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let store = isolatedStore(.escalating)
        let monitor = NotLoopingMonitor(
            loopDates: subject.eraseToAnyPublisher(),
            trioAlertManager: spy,
            alertsStore: store
        )
        subject.send(Date())
        #expect(spy.issuedAlerts.count == 6)

        store.notLoopingAlarm = .off
        #expect(spy.issuedAlerts.count == 6)
        #expect(spy.retractedIdentifiers.count == 12)

        store.notLoopingAlarm = .critical(afterMinutes: 90)
        #expect(spy.issuedAlerts.count == 7)
        if let trigger = spy.issuedAlerts.last?.trigger { expectDelay(trigger, 90) }
        _ = monitor
    }

    @Test("Switching to a delay that has already passed fires now") func pastDueModeChangeFires() {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let store = isolatedStore(.escalating)
        let monitor = NotLoopingMonitor(
            loopDates: subject.eraseToAnyPublisher(),
            trioAlertManager: spy,
            alertsStore: store
        )
        subject.send(Date().addingTimeInterval(-30 * 60))
        let armed = spy.issuedAlerts.count

        store.notLoopingAlarm = .critical(afterMinutes: 20)
        #expect(spy.issuedAlerts.count == armed + 1)
        #expect(spy.issuedAlerts.last?.identifier == criticalID)
        if case let .delayed(interval)? = spy.issuedAlerts.last?.trigger {
            #expect(interval <= 1)
        } else {
            Issue.record("expected a delayed trigger")
        }
        _ = monitor
    }

    @Test("The mode survives a reload from the same defaults") func modePersists() {
        let defaults = UserDefaults(suiteName: "NotLoopingMonitorTests.\(UUID().uuidString)")!
        DeviceAlertsStore(defaults: defaults).notLoopingAlarm = .critical(afterMinutes: 60)
        #expect(DeviceAlertsStore(defaults: defaults).notLoopingAlarm == .critical(afterMinutes: 60))

        let fresh = UserDefaults(suiteName: "NotLoopingMonitorTests.\(UUID().uuidString)")!
        #expect(DeviceAlertsStore(defaults: fresh).notLoopingAlarm == .escalating)
    }
}
