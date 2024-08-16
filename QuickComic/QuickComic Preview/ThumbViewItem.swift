//
//  ThumbViewItem.swift
//  QuickComic Preview
//
//  Created by C.W. Betts on 8/16/24.
//  Copyright © 2024 Dancing Tortoise Software. All rights reserved.
//

import Cocoa
import XADMaster

class ThumbViewItem: NSCollectionViewItem {
	@IBOutlet weak var throbber: NSProgressIndicator!
	
	weak var archive: XADArchive?
	var entryIndex: Int = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
    }
    
	func loadImageFromArchive() {
		//TODO: this looks ugly to my untrained eye. Have someone else go over it or learn more about concurrency
		Task.detached(priority: .background) {
			guard let archive = await self.archive else {
				return
			}
			do {
				let fileData = try await archive.contents(ofEntry: self.entryIndex)
				// NSImage is not sendable...
				Task { @MainActor in
					if let img = NSImage(data: fileData) {
						self.imageView?.image = img
					} else {
						self.imageView?.image = NSImage(named: NSImage.cautionName)
					}
				}
			} catch {
				Task { @MainActor in
					self.imageView?.image = NSImage(named: NSImage.cautionName)
				}
			}
		}
	}	
}
