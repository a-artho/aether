//
//  InstallationProxyAppsDelegate.swift
//  Antrag
//
//  Created by samara on 7.06.2025.
//

@MainActor
public protocol InstallationProxyAppsDelegate: AnyObject {
	func updateApplications(with apps: [AppInfo])
}
