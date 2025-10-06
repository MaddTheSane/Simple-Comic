//
//  ColorSecureUnarchiveFromDataTransformer.swift
//  Simple Comic
//
//  Created by C.W. Betts on 1/21/25.
//  Copyright © 2025 Dancing Tortoise Software. All rights reserved.
//

import Cocoa

@objc(TSSTColorSecureUnarchiveFromDataTransformer)
class TSSTColorSecureUnarchiveFromDataTransformer: NSSecureUnarchiveFromDataTransformer {
	override class var allowedTopLevelClasses: [AnyClass] {
		[NSColor.self]
	}
}
