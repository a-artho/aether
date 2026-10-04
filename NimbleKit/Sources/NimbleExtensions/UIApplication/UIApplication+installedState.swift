import UIKit
import ObjectiveC

public struct InstalledApplicationState: Sendable {
	public let installed: Bool
	public let version: String?
	public let registeredAt: Date?
}

extension UIApplication {
	/// nil means the platform could not provide reliable installation evidence.
	public static func installedApplicationState(for identifier: String) -> InstalledApplicationState? {
		let selector = NSSelectorFromString("applicationProxyForIdentifier:")
		guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type,
			class_getClassMethod(proxyClass, selector) != nil else { return nil }
		guard let proxy = proxyClass.perform(selector, with: identifier)?.takeUnretainedValue() as? NSObject else {
			return InstalledApplicationState(installed: false, version: nil, registeredAt: nil)
		}
		guard proxy.responds(to: NSSelectorFromString("isInstalled")),
			proxy.responds(to: NSSelectorFromString("isPlaceholder")),
			proxy.responds(to: NSSelectorFromString("shortVersionString")) else { return nil }
		let installed = (proxy.value(forKey: "isInstalled") as? NSNumber)?.boolValue
		let placeholder = (proxy.value(forKey: "isPlaceholder") as? NSNumber)?.boolValue
		guard let installed, let placeholder else { return nil }
		let date = proxy.responds(to: NSSelectorFromString("registeredDate")) ? proxy.value(forKey: "registeredDate") as? Date : nil
		return InstalledApplicationState(installed: installed && !placeholder,
			version: proxy.value(forKey: "shortVersionString") as? String, registeredAt: date)
	}
}
