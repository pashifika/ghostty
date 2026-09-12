import Cocoa
import Carbon
import Testing
@testable import Ghostty

@MainActor
struct ApplicationTerminationTests {
    @Test func systemQuitEventsSkipConfirmation() {
        for reason in [kAEShutDown, kAERestart, kAEReallyLogOut] {
            #expect(AppDelegate.isSystemTermination(quitEvent(reason: reason)))
        }
    }

    @Test func missingAndUnknownReasonsRetainConfirmation() {
        #expect(!AppDelegate.isSystemTermination(nil))
        #expect(!AppDelegate.isSystemTermination(quitEvent()))
        #expect(!AppDelegate.isSystemTermination(quitEvent(reason: kAEOpenDocuments)))
    }

    @Test func reasonOnANonQuitEventDoesNotSkipConfirmation() {
        let event = NSAppleEventDescriptor(
            eventClass: kCoreEventClass, eventID: kAEOpenDocuments,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setAttribute(NSAppleEventDescriptor(typeCode: kAERestart), forKeyword: AEKeyword(kEventParamReason))
        #expect(!AppDelegate.isSystemTermination(event))
    }

    private func quitEvent(reason: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: kCoreEventClass, eventID: kAEQuitApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            event.setAttribute(NSAppleEventDescriptor(typeCode: reason), forKeyword: AEKeyword(kEventParamReason))
        }
        return event
    }
}
