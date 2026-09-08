//
//  FirebaseIntegration.swift
//  IntegrationKit
//

import FirebaseCore
import FirebaseCrashlytics

public enum FirebaseIntegration {

	public static func configure() {
		FirebaseApp.configure()
		#if DEBUG
			Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
		#endif
	}
}
