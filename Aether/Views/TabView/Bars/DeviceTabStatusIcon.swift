import SwiftUI
import UIKit

/// Native tabs extract their image from Label; view overlays on that label are
/// discarded. Render the small indicator into the icon without replacing TabView.
@MainActor
enum DeviceTabStatusIcon {
	private static let images: NSCache<NSString, UIImage> = {
		let cache = NSCache<NSString, UIImage>()
		cache.countLimit = 12
		return cache
	}()

	static func image(symbol: String, ready: Bool, selected: Bool, tint: Color,
		colorScheme: ColorScheme, scale: CGFloat) -> UIImage {
		let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
		let foreground = selected ? UIColor(tint).resolvedColor(with: traits) : UIColor.secondaryLabel.resolvedColor(with: traits)
		let key = "\(symbol)|\(ready)|\(foreground)|\(colorScheme)|\(scale)" as NSString
		if let image = images.object(forKey: key) { return image }
		let format = UIGraphicsImageRendererFormat()
		format.scale = scale
		let size = CGSize(width: 28, height: 28)
		let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
			if let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)) {
				glyph.withTintColor(foreground, renderingMode: .alwaysOriginal).draw(in:
					CGRect(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2,
						width: glyph.size.width, height: glyph.size.height))
			}
			let dot = UIBezierPath(ovalIn: CGRect(x: 23, y: 1, width: 4, height: 4))
			UIColor.systemBackground.resolvedColor(with: traits).setStroke()
			dot.lineWidth = 1.5
			dot.stroke()
			(ready ? UIColor.systemGreen : UIColor.systemRed).setFill()
			dot.fill()
		}
		.withRenderingMode(.alwaysOriginal)
		images.setObject(image, forKey: key)
		return image
	}
}
