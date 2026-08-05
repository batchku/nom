import AppKit
import os

/// Detects the start of a 3/4-finger horizontal trackpad swipe — the earliest
/// possible "space switch may be starting" signal. SkyLight offers nothing at
/// swipe begin: SLSGetActiveSpace commits only when the transition ends, and
/// SLSManagedDisplayIsAnimating never fires on this macOS version (verified by
/// polling it at 10ms through real swipes).
///
/// Uses a listen-only CGEvent tap for gesture events, which rides on the
/// Accessibility permission the app already needs for space jumping. If the
/// tap can't be created the app just degrades to end-of-switch updates.
@MainActor
final class SwipeDetector {
    var onSwipeBegan: (() -> Void)?
    /// Fires on every tracked gesture event after a swipe began — used to
    /// extend the transition timeout while fingers are still down.
    var onSwipeActivity: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var fired = false
    private var lastDockSwipeAt = Date.distantPast
    private var lastHIDType: Int64 = -1

    /// Raw gesture fields on CGEvent (private, stable since 10.7-era).
    /// NSEvent(cgEvent:).touches() drops multi-finger data for system
    /// gestures (verified: never reports >1 touch during a 3-finger swipe),
    /// so the raw HID gesture type is the only reliable classifier.
    private static let gestureHIDTypeField: UInt32 = 110
    /// IOHIDEventTypes.h: kIOHIDEventTypeDockSwipe — the 3/4-finger
    /// space-switch / Mission Control gesture.
    private static let dockSwipeHIDType: Int64 = 23
    /// Gap that separates two distinct swipe gestures.
    private static let sequenceGap: TimeInterval = 0.3

    private static let log = Logger(subsystem: "com.teambrilliant.nom", category: "swipe")

    func start() {
        // NSEventType gesture range: 29 = gesture, 30 = magnify, 31 = swipe
        let mask: CGEventMask = (1 << 29) | (1 << 30) | (1 << 31)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let detector = Unmanaged<SwipeDetector>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    detector.reenable()
                } else {
                    detector.handle(event)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        )
        if tap == nil {
            // Listen-only HID taps can require Input Monitoring on some
            // configurations; an active tap works with plain Accessibility.
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: selfPtr
            )
        }

        guard let tap else {
            Self.log.error("gesture tap creation failed — swipe detection disabled")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.log.info("gesture tap active")
    }

    private func reenable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            Self.log.info("gesture tap re-enabled after timeout")
        }
    }

    private func handle(_ cgEvent: CGEvent) {
        guard let hidTypeField = CGEventField(rawValue: Self.gestureHIDTypeField) else { return }
        let hidType = cgEvent.getIntegerValueField(hidTypeField)

        if hidType != lastHIDType {
            Self.log.debug("gesture hidType -> \(hidType)")
            lastHIDType = hidType
        }

        guard hidType == Self.dockSwipeHIDType else { return }

        let now = Date()
        if now.timeIntervalSince(lastDockSwipeAt) > Self.sequenceGap {
            fired = false
        }
        lastDockSwipeAt = now

        if fired {
            onSwipeActivity?()
        } else {
            fired = true
            Self.log.info("dock swipe began — \(Self.diagnosticFields(of: cgEvent))")
            onSwipeBegan?()
        }
    }

    /// Field dump used to identify direction/progress fields for future
    /// refinement (e.g. distinguishing Mission Control's vertical swipe).
    private static func diagnosticFields(of event: CGEvent) -> String {
        var parts: [String] = []
        for raw in [115, 116, 123, 132, 133, 134] {
            if let f = CGEventField(rawValue: UInt32(raw)) {
                parts.append("i\(raw)=\(event.getIntegerValueField(f))")
            }
        }
        for raw in [113, 114, 117, 118, 119, 124, 129, 135] {
            if let f = CGEventField(rawValue: UInt32(raw)) {
                let v = event.getDoubleValueField(f)
                if v != 0 { parts.append("d\(raw)=\(String(format: "%.3f", v))") }
            }
        }
        return parts.joined(separator: " ")
    }
}
