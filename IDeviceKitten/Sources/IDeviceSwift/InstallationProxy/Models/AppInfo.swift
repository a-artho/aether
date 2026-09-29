//
//  AppInfo.swift
//  Antrag
//
//  Created by samara on 7.06.2025.
//

import Foundation

public struct AppInfo: Codable, Identifiable {
	public var id: String { CFBundleIdentifier ?? UUID().uuidString }

	public let CFBundleName: String?
	public let UISupportedInterfaceOrientations: [String]?
	public let DTXcodeBuild: String?
	public let LSRequiresIPhoneOS: Bool?
	public let UIStatusBarStyle: String?
	public let Entitlements: [String: AnyCodable]?
	public let ITSAppUsesNonExemptEncryption: AnyCodable?
	public let DTPlatformVersion: String?
	public let CFBundleURLTypes: [[String: AnyCodable]]?
	public let DTSDKBuild: String?
	public let EnvironmentVariables: [String: String]?
	public let UISupportedDevices: [String]?
	public let IsAppClip: Bool?
	public let CFBundleNumericVersion: Int?
	public let CFBundleInfoDictionaryVersion: String?
	public let SequenceNumber: Int?
	public let CFBundleDisplayName: String?
	public let CFBundleExecutable: String?
	public let ApplicationType: String?
	public let UIApplicationSupportsIndirectInputEvents: Bool?
	public let CFBundleIcons_iPad: [String: AnyCodable]? // Note: keys with ~ipad must be adjusted
	public let IsHostBackupEligible: Bool?
	public let IsDemotedApp: Bool?
	public let DTPlatformName: String?
	public let CFBundleDevelopmentRegion: String?
	public let UISupportsDocumentBrowser: Bool?
	public let SignerIdentity: String?
	public let UISupportedInterfaceOrientations_iPad: [String]?
	public let UIRequiredDeviceCapabilities: [String]?
	public let LSSupportsOpeningDocumentsInPlace: Bool?
	public let DTSDKName: String?
	public let DTAppStoreToolsBuild: String?
	public let Container: String?
	public let MinimumOSVersion: String?
	public let IsUpgradeable: Bool?
	public let ApplicationDSID: Int?
	public let ApplicationSINF: Data?
	public let iTunesMetadata: Data?
	public let UIFileSharingEnabled: Bool?
	public let DTCompiler: String?
	public let DTPlatformBuild: String?
	public let CFBundleIdentifier: String?
	public let Path: String?
	public let CFBundleVersion: String?
	public let CFBundleShortVersionString: String?
	public let CFBundleSupportedPlatforms: [String]?
	public let CFBundleIcons: [String: AnyCodable]?
	public let UILaunchScreen: AnyCodable?
	public let BuildMachineOSBuild: String?
	public let UIApplicationSceneManifest: [String: AnyCodable]?
	public let CFBundlePackageType: String?
	public let UIDeviceFamily: [Int]?
	public let DTXcode: String?

	public init(
		CFBundleName: String? = nil,
		UISupportedInterfaceOrientations: [String]? = nil,
		DTXcodeBuild: String? = nil,
		LSRequiresIPhoneOS: Bool? = nil,
		UIStatusBarStyle: String? = nil,
		Entitlements: [String: AnyCodable]? = nil,
		ITSAppUsesNonExemptEncryption: AnyCodable? = nil,
		DTPlatformVersion: String? = nil,
		CFBundleURLTypes: [[String: AnyCodable]]? = nil,
		DTSDKBuild: String? = nil,
		EnvironmentVariables: [String: String]? = nil,
		UISupportedDevices: [String]? = nil,
		IsAppClip: Bool? = nil,
		CFBundleNumericVersion: Int? = nil,
		CFBundleInfoDictionaryVersion: String? = nil,
		SequenceNumber: Int? = nil,
		CFBundleDisplayName: String? = nil,
		CFBundleExecutable: String? = nil,
		ApplicationType: String? = nil,
		UIApplicationSupportsIndirectInputEvents: Bool? = nil,
		CFBundleIcons_iPad: [String: AnyCodable]? = nil,
		IsHostBackupEligible: Bool? = nil,
		IsDemotedApp: Bool? = nil,
		DTPlatformName: String? = nil,
		CFBundleDevelopmentRegion: String? = nil,
		UISupportsDocumentBrowser: Bool? = nil,
		SignerIdentity: String? = nil,
		UISupportedInterfaceOrientations_iPad: [String]? = nil,
		UIRequiredDeviceCapabilities: [String]? = nil,
		LSSupportsOpeningDocumentsInPlace: Bool? = nil,
		DTSDKName: String? = nil,
		DTAppStoreToolsBuild: String? = nil,
		Container: String? = nil,
		MinimumOSVersion: String? = nil,
		IsUpgradeable: Bool? = nil,
		ApplicationDSID: Int? = nil,
		ApplicationSINF: Data? = nil,
		iTunesMetadata: Data? = nil,
		UIFileSharingEnabled: Bool? = nil,
		DTCompiler: String? = nil,
		DTPlatformBuild: String? = nil,
		CFBundleIdentifier: String? = nil,
		Path: String? = nil,
		CFBundleVersion: String? = nil,
		CFBundleShortVersionString: String? = nil,
		CFBundleSupportedPlatforms: [String]? = nil,
		CFBundleIcons: [String: AnyCodable]? = nil,
		UILaunchScreen: AnyCodable? = nil,
		BuildMachineOSBuild: String? = nil,
		UIApplicationSceneManifest: [String: AnyCodable]? = nil,
		CFBundlePackageType: String? = nil,
		UIDeviceFamily: [Int]? = nil,
		DTXcode: String? = nil
	) {
		self.CFBundleName = CFBundleName
		self.UISupportedInterfaceOrientations = UISupportedInterfaceOrientations
		self.DTXcodeBuild = DTXcodeBuild
		self.LSRequiresIPhoneOS = LSRequiresIPhoneOS
		self.UIStatusBarStyle = UIStatusBarStyle
		self.Entitlements = Entitlements
		self.ITSAppUsesNonExemptEncryption = ITSAppUsesNonExemptEncryption
		self.DTPlatformVersion = DTPlatformVersion
		self.CFBundleURLTypes = CFBundleURLTypes
		self.DTSDKBuild = DTSDKBuild
		self.EnvironmentVariables = EnvironmentVariables
		self.UISupportedDevices = UISupportedDevices
		self.IsAppClip = IsAppClip
		self.CFBundleNumericVersion = CFBundleNumericVersion
		self.CFBundleInfoDictionaryVersion = CFBundleInfoDictionaryVersion
		self.SequenceNumber = SequenceNumber
		self.CFBundleDisplayName = CFBundleDisplayName
		self.CFBundleExecutable = CFBundleExecutable
		self.ApplicationType = ApplicationType
		self.UIApplicationSupportsIndirectInputEvents = UIApplicationSupportsIndirectInputEvents
		self.CFBundleIcons_iPad = CFBundleIcons_iPad
		self.IsHostBackupEligible = IsHostBackupEligible
		self.IsDemotedApp = IsDemotedApp
		self.DTPlatformName = DTPlatformName
		self.CFBundleDevelopmentRegion = CFBundleDevelopmentRegion
		self.UISupportsDocumentBrowser = UISupportsDocumentBrowser
		self.SignerIdentity = SignerIdentity
		self.UISupportedInterfaceOrientations_iPad = UISupportedInterfaceOrientations_iPad
		self.UIRequiredDeviceCapabilities = UIRequiredDeviceCapabilities
		self.LSSupportsOpeningDocumentsInPlace = LSSupportsOpeningDocumentsInPlace
		self.DTSDKName = DTSDKName
		self.DTAppStoreToolsBuild = DTAppStoreToolsBuild
		self.Container = Container
		self.MinimumOSVersion = MinimumOSVersion
		self.IsUpgradeable = IsUpgradeable
		self.ApplicationDSID = ApplicationDSID
		self.ApplicationSINF = ApplicationSINF
		self.iTunesMetadata = iTunesMetadata
		self.UIFileSharingEnabled = UIFileSharingEnabled
		self.DTCompiler = DTCompiler
		self.DTPlatformBuild = DTPlatformBuild
		self.CFBundleIdentifier = CFBundleIdentifier
		self.Path = Path
		self.CFBundleVersion = CFBundleVersion
		self.CFBundleShortVersionString = CFBundleShortVersionString
		self.CFBundleSupportedPlatforms = CFBundleSupportedPlatforms
		self.CFBundleIcons = CFBundleIcons
		self.UILaunchScreen = UILaunchScreen
		self.BuildMachineOSBuild = BuildMachineOSBuild
		self.UIApplicationSceneManifest = UIApplicationSceneManifest
		self.CFBundlePackageType = CFBundlePackageType
		self.UIDeviceFamily = UIDeviceFamily
		self.DTXcode = DTXcode
	}
}
