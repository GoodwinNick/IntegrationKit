//
//  PremiumNotification.swift
//  IntegrationKit
//

import Foundation

extension Notification.Name {
	/// Posted when the premium flag actually changes value — never on a same-value write.
	public static let premiumDidChange = Notification.Name("premiumDidChange")
}
