//
//  FileManager+clone.swift
//  Feather
//

import Foundation
import Darwin

extension FileManager {
	/// Uses APFS copy-on-write when it is available, then falls back to a normal
	/// recursive copy. Temporary packaging never uses hard links, so mutations
	/// cannot affect the stored signed application.
	func copyItemPreferClone(at sourceURL: URL, to destinationURL: URL) throws {
		let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
		if copyfile(sourceURL.path, destinationURL.path, nil, flags) == 0 {
			return
		}

		try? removeItem(at: destinationURL)
		try copyItem(at: sourceURL, to: destinationURL)
	}
}
