//
//  DTToolbarItems.swift
//  Simple Comic
//
//  Created by J-rg on 09.12.20.
//  Copyright © 2020 Dancing Tortoise Software. All rights reserved.
//

import Cocoa

class DTToolbarItem: NSToolbarItem {
	
	override func validate() {
		guard let toolbarDelegate = toolbar?.delegate as? TSSTSessionWindowController else { return }
		
		if toolbarDelegate.responds(to: #selector(getter: TSSTSessionWindowController.pageSelectionInProgress)) {
			(view as? NSControl)?.isEnabled = !(toolbarDelegate.pageSelectionInProgress)
		}
	}
}
