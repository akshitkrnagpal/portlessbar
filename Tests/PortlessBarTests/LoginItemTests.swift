import AppKit
import ServiceManagement
import XCTest
@testable import PortlessBar

@MainActor
final class FakeLoginItem: LoginItemManaging {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var failure: Error?
    var registrations = 0
    var removals = 0
    var settingsOpened = 0

    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = registrationStatus
    }
    func unregister() async throws {
        removals += 1
        if let failure { throw failure }
        status = .notRegistered
    }
    func openLoginItemsSettings() { settingsOpened += 1 }
}

final class LoginItemTests: XCTestCase {
    @MainActor
    func testLoginItemTogglesAndReadsSystemStateWhenRefreshed() async throws {
        let login = FakeLoginItem()
        let store = LoginItemStore(service: login)
        XCTAssertEqual(login.registrations, 0, "Opening the app must not enable launch at login.")
        XCTAssertFalse(store.enabled)
        await store.setEnabled(true)
        XCTAssertEqual(login.registrations, 1)
        XCTAssertTrue(store.enabled)
        await store.setEnabled(true)
        XCTAssertEqual(login.registrations, 1, "An already enabled login item must not be registered twice.")
        await store.setEnabled(false)
        XCTAssertEqual(login.removals, 1)
        XCTAssertFalse(store.enabled)
        login.status = .enabled // A change made in macOS System Settings.
        store.refresh()
        XCTAssertTrue(store.enabled)
    }

    @MainActor
    func testApprovalRequiredDoesNotPretendLoginItemIsEnabled() async throws {
        let login = FakeLoginItem()
        login.registrationStatus = .requiresApproval
        let store = LoginItemStore(service: login)
        await store.setEnabled(true)
        XCTAssertEqual(login.settingsOpened, 1)
        XCTAssertFalse(store.enabled)
        await store.setEnabled(true)
        XCTAssertEqual(login.registrations, 1)
        XCTAssertEqual(login.settingsOpened, 2)
    }

    @MainActor
    func testRegistrationFailureKeepsActualStateAndOffersError() async throws {
        let login = FakeLoginItem()
        login.failure = PortlessError.message("Registration failed")
        let store = LoginItemStore(service: login)
        await store.setEnabled(true)
        XCTAssertFalse(store.enabled)
        XCTAssertEqual(store.error, "Registration failed")
        login.status = .enabled
        store.refresh()
        await store.setEnabled(false)
        XCTAssertTrue(store.enabled, "A failed unregister must leave the enabled state intact.")
        XCTAssertEqual(store.error, "Registration failed")
    }
}
