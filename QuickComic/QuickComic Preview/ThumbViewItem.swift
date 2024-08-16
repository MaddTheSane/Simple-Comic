//
//  ThumbViewItem.swift
//  QuickComic Preview
//
//  Created by C.W. Betts on 8/16/24.
//  Copyright © 2024 Dancing Tortoise Software. All rights reserved.
//

import Cocoa
import XADMaster

let theQueue = DispatchQueue(label: "com.ToWatchList.SimpleComic.QuickComic-Preview.archiver", qos: .background, target: nil)

class ThumbViewItem: NSCollectionViewItem {
	@IBOutlet weak var throbber: NSProgressIndicator!
	
	weak var archive: XADArchive?
	var entryIndex: Int = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
    }
    
	func loadImageFromArchive() {
		theQueue.async {
			do {
				guard let archive = self.archive else {
					return
				}

				let fileData = try archive.contents(ofEntry: self.entryIndex)
				
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
