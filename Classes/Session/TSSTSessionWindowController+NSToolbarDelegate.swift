//
//  TSSTSessionWindowController+NSToolbarDelegate.swift
//  Simple Comic
//
//  Created by J-rg on 13.09.21.
//  Copyright © 2021 Dancing Tortoise Software. All rights reserved.
//

import Cocoa

private extension NSToolbarItem.Identifier {
	static let turnPage    = NSToolbarItem.Identifier("ADD2836D-8728-474F-9355-80FA8EA9972C")
	static let turnPageEnd = NSToolbarItem.Identifier("D01E117F-B172-435D-8B8C-CFC587DA6020")
	static let pageOrder   = NSToolbarItem.Identifier("9C25BD8E-6129-4874-917D-C4C5F75BD24F")
	static let pageLayout  = NSToolbarItem.Identifier("57633342-20D2-433A-9828-1C85F79205A8")
	static let pageScaling = NSToolbarItem.Identifier("E33C7D17-8160-4B40-8EDF-78600C84FE8C")
	static let thumbnails  = NSToolbarItem.Identifier("AB4BCD46-EE79-45CC-9A97-733E3740BA34")
	static let rotation    = NSToolbarItem.Identifier("2FEB6E2E-5C3E-4725-B4B7-D5204BC8F2A8")
	static let zoom        = NSToolbarItem.Identifier("C8491130-5672-4D81-9D91-76BB3F03D233")
	static let imageZoom   = NSToolbarItem.Identifier("A580F497-94D7-4752-971B-01FBBAD86DEF")
	static let loupe       = NSToolbarItem.Identifier("55B2F7CD-2E3A-405A-BF65-65B5A68E94BD")
	static let capturePage = NSToolbarItem.Identifier("7D6CA1DF-7F26-421E-874E-21596C513A14")
	static let setIcon     = NSToolbarItem.Identifier("7ACC3052-A491-4940-83A9-B40928F5C001")
}

extension TSSTSessionWindowController: NSToolbarDelegate, NSToolbarItemValidation {
	public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
		if pageSelectionInProgress {
			if item.itemIdentifier == .turnPageEnd {
				if let item = item as? NSToolbarItemGroup {
					item.subitems[0].isEnabled = false
					item.subitems[1].isEnabled = false
				}
			}
			
			if item.itemIdentifier == .turnPage {
				if let item = item as? NSToolbarItemGroup {
					item.subitems[0].isEnabled = false
					item.subitems[1].isEnabled = false
				}
			}

			return false
		}
		if item.itemIdentifier == .turnPageEnd {
			if let item = item as? NSToolbarItemGroup {
				item.subitems[0].isEnabled = canTurnPageLeft
				item.subitems[1].isEnabled = canTurnPageRight
			}
		}
		
		if item.itemIdentifier == .turnPage {
			if let item = item as? NSToolbarItemGroup {
				item.subitems[0].isEnabled = canTurnPageLeft
				item.subitems[1].isEnabled = canTurnPageRight
			}
		}
		
		return true
	}
	
	public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		return [
			.turnPage,
			.pageOrder,
			.pageLayout,
			.pageScaling,
			.flexibleSpace,
			.thumbnails,
		]
	}
	
	public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		return [
			.turnPage,
			.turnPageEnd,
			.pageScaling,
			.pageOrder,
			.pageLayout,
			.thumbnails,
			.rotation,
			.zoom,
			.imageZoom,
			.loupe,
			.capturePage,
			.setIcon,
			.space,
			.flexibleSpace,
		]
	}
	
	public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
		switch itemIdentifier {
		case .turnPage:
			let images = [NSImage(named: NSImage.leftFacingTriangleTemplateName)!,
						  NSImage(named: NSImage.rightFacingTriangleTemplateName)!]
			
			let labels = [NSLocalizedString("555.ibShadowedToolTips[0]", tableName: "TSSTSessionWindowToolbar", value: "Left Page Turn", comment: "Left Page Turn"),
						  NSLocalizedString("555.ibShadowedToolTips[1]", tableName: "TSSTSessionWindowToolbar", value: "Right Page Turn", comment: "Right Page Turn")]
			
			let item = NSToolbarItemGroup(itemIdentifier: .turnPage, images: images, selectionMode: .momentary, labels: labels, target: self, action: #selector(self.turnPage(_:)))
			item.label = NSLocalizedString("553.label", tableName: "TSSTSessionWindowToolbar", value: "Turn Page", comment: "Turn Page label")
			item.paletteLabel = NSLocalizedString("553.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Turn Page", comment: "Turn Page palette label")
			item.subitems[0].autovalidates = false
			item.subitems[1].autovalidates = false
			item.subitems[0].tag = 701
			item.subitems[1].tag = 702
			item.isNavigational = true
			item.selectionMode = .momentary

			return item

		case .turnPageEnd:
			let images = [NSImage(resource: .firstPageTemplate),
						  NSImage(resource: .lastPageTemplate)]
			
			let labels = [NSLocalizedString("msg-5l-0tY.ibShadowedToolTips[0]", tableName: "TSSTSessionWindowToolbar", value: "Left End Page", comment: "Left End Page"),
						  NSLocalizedString("msg-5l-0tY.ibShadowedToolTips[1]", tableName: "TSSTSessionWindowToolbar", value: "Right End Page", comment: "Right End Page")]
			
			let item = NSToolbarItemGroup(itemIdentifier: .turnPageEnd, images: images, selectionMode: .momentary, labels: labels, target: self, action: #selector(self.pageEnd(_:)))
			item.label = NSLocalizedString("dMP-Th-vKR.label", tableName: "TSSTSessionWindowToolbar", value: "Page End", comment: "Page End label")
			item.paletteLabel = NSLocalizedString("dMP-Th-vKR.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Page End", comment: "Page End palette label")
			item.isNavigational = true
			item.subitems[0].autovalidates = false
			item.subitems[1].autovalidates = false
			item.subitems[0].tag = 701
			item.subitems[1].tag = 702
			item.selectionMode = .momentary

			return item

		case .pageOrder:
			let images = [NSImage(resource: .rightLeftOrderTemplate),
						  NSImage(resource: .leftRightOrderTemplate)]
			let labels = [NSLocalizedString("519.ibShadowedToolTips[0]", tableName: "TSSTSessionWindowToolbar", value: "Right to Left Page Order", comment: "Right to Left Page Order"),
						  NSLocalizedString("519.ibShadowedToolTips[1]", tableName: "TSSTSessionWindowToolbar", value: "Left to Right Page Order", comment: "Left to Right Page Order")]

			let item = NSToolbarItemGroup(itemIdentifier: .pageOrder, images: images, selectionMode: .selectOne, labels: labels, target: self, action: #selector(self.changePageOrder(_:)))
			item.label = NSLocalizedString("520.label", tableName: "TSSTSessionWindowToolbar", value: "Page Order", comment: "Page Order")
			item.paletteLabel = NSLocalizedString("520.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Page Order", comment: "Page Order")
			item.selectionMode = .selectOne

			if flag {
				item.bind(.selectedIndex, to: self, withKeyPath: "session.pageOrder")
			}
			
			return item

		case .pageLayout:
			let images = [NSImage(resource: .onePageTemplate),
						  NSImage(resource: .twoPageTemplate)]
			let labels = [NSLocalizedString("522.ibShadowedToolTips[0]", tableName: "TSSTSessionWindowToolbar", value: "Single Page Layout", comment: "Single Page Layout"),
						  NSLocalizedString("522.ibShadowedToolTips[1]", tableName: "TSSTSessionWindowToolbar", value: "Two Page Layout", comment: "Two Page Layout")]

			let item = NSToolbarItemGroup(itemIdentifier: .pageLayout, images: images, selectionMode: .selectOne, labels: labels, target: self, action: #selector(self.changeTwoPage(_:)))
			item.label = NSLocalizedString("523.label", tableName: "TSSTSessionWindowToolbar", value: "Page Layout", comment: "Page Layout label")
			item.paletteLabel = NSLocalizedString("523.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Page Layout", comment: "Page Layout palette label")
			item.selectionMode = .selectOne

			if flag {
				item.bind(.selectedIndex, to: self, withKeyPath: "session.twoPageSpread")
			}

			return item
			
		case .pageScaling:
			let images = [NSImage(resource: .equalTemplate),
						  NSImage(resource: .winScaleTemplate),
						  NSImage(resource: .horScaleTemplate)]
			let labels = [NSLocalizedString("516.ibShadowedToolTips[0]", tableName: "TSSTSessionWindowToolbar", value: "Original Size", comment: "Original Size"),
						  NSLocalizedString("516.ibShadowedToolTips[1]", tableName: "TSSTSessionWindowToolbar", value: "Scale to Window", comment: "Scale to Window"),
						  NSLocalizedString("516.ibShadowedToolTips[2]", tableName: "TSSTSessionWindowToolbar", value: "Horizontal Scaling", comment: "Horizontal Scaling")]

			let item = NSToolbarItemGroup(itemIdentifier: .pageScaling, images: images, selectionMode: .selectOne, labels: labels, target: self, action: #selector(self.changeScalingNewToolbar(_:)))
			item.label = NSLocalizedString("517.label", tableName: "TSSTSessionWindowToolbar", value: "Page Scaling", comment: "Page Scaling label")
			item.paletteLabel = NSLocalizedString("517.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Page Scaling", comment: "Page Scaling palette label")
			item.selectionMode = .selectOne

			if flag {
				item.bind(.selectedIndex, to: self, withKeyPath: "session.scaleOptions")
			}

			return item
			
		case .loupe:
			let item = DTToolbarItem(itemIdentifier: .loupe)
			item.image = NSImage(systemSymbolName: "loupe", accessibilityDescription: nil)
			item.label = NSLocalizedString("575.label", tableName: "TSSTSessionWindowToolbar", value: "Loupe", comment: "Loupe label")
			item.paletteLabel = NSLocalizedString("575.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Loupe", comment: "Loupe palette label")
			item.toolTip = NSLocalizedString("573.ibShadowedToolTip", tableName: "TSSTSessionWindowToolbar", value: "Magnifying Glass", comment: "Magnifying Glass tool tip")
			if flag {
				item.bind(.value, to: self, withKeyPath: "session.loupe")
			}

			return item
			
		case .thumbnails:
			let item = DTToolbarItem(itemIdentifier: .thumbnails)
			item.image = NSImage(named: NSImage.iconViewTemplateName)
			item.target = self
			item.action = #selector(self.togglePageExpose(_:))
			item.label = NSLocalizedString("577.label", tableName: "TSSTSessionWindowToolbar", value: "Thumbnails", comment: "Thumbnails")
			item.paletteLabel = NSLocalizedString("577.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Thumbnails", comment: "Thumbnails")
			item.toolTip = NSLocalizedString("578.ibShadowedToolTip", tableName: "TSSTSessionWindowToolbar", value: "Thumbnail View", comment: "Thumbnail View")

			return item
			
		case .capturePage:
			let item = DTToolbarItem(itemIdentifier: .capturePage)
			item.image = NSImage(resource: .extractTemplate)
			item.target = self
			item.action = #selector(self.extractPage(_:))
			item.label = NSLocalizedString("688.label", tableName: "TSSTSessionWindowToolbar", value: "Capture Page", comment: #""Capture Page" Label"#)
			item.paletteLabel = NSLocalizedString("688.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Capture Page", comment: #""Capture Page" Palette Label"#)
			item.toolTip = NSLocalizedString("689.ibShadowedToolTip", tableName: "TSSTSessionWindowToolbar", value: "Capture Page", comment: #""Capture Page" Tool Tip"#)

			return item
			
		case .setIcon:
			let item = DTToolbarItem(itemIdentifier: .setIcon)
			item.image = NSImage(named: NSImage.quickLookTemplateName)
			item.target = self
			item.action = #selector(self.setArchiveIcon(_:))
			item.label = NSLocalizedString("693.label", tableName: "TSSTSessionWindowToolbar", value: "Set Icon", comment: #""Set Icon" Label"#)
			item.paletteLabel = NSLocalizedString("693.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Set Icon", comment: #""Set Icon" Palette Label"#)
			item.toolTip = NSLocalizedString("694.ibShadowedToolTip", tableName: "TSSTSessionWindowToolbar", value: "Set Icon", comment: #""Set Icon" Shadowed Tooltip"#)

			return item
			
		case .imageZoom:
			let images = [NSImage(named: NSImage.removeTemplateName)!,
						  NSImage(named: NSImage.addTemplateName)!]
			
			let labels = [NSLocalizedString("558.ibShadowedToolTips[0]", tableName: "TSSTSessionWindowToolbar", value: "Zoom Out", comment: "Zoom Out"),
						  NSLocalizedString("558.ibShadowedToolTips[1]", tableName: "TSSTSessionWindowToolbar", value: "Zoom In", comment: "Zoom In")]
			
			let item = NSToolbarItemGroup(itemIdentifier: .imageZoom, images: images, selectionMode: .momentary, labels: labels, target: self, action: #selector(self.zoom(_:)))
			item.label = NSLocalizedString("559.label", tableName: "TSSTSessionWindowToolbar", value: "Zoom", comment: "\"Zoom\" label")
			item.paletteLabel = NSLocalizedString("559.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Zoom", comment: "\"Zoom\" Palette Label")
			item.subitems[0].tag = 802
			item.subitems[1].tag = 801
			item.selectionMode = .momentary
			return item

		case .zoom:
			let images = [NSImage(named: NSImage.removeTemplateName)!,
						  NSImage(named: NSImage.addTemplateName)!,
						  NSImage(resource: .equalTemplate)]
			
			let labels = [NSLocalizedString("558.ibShadowedToolTips[0]", tableName: "TSSTSessionWindowToolbar", value: "Zoom Out", comment: "Zoom Out"),
						  NSLocalizedString("558.ibShadowedToolTips[1]", tableName: "TSSTSessionWindowToolbar", value: "Zoom In", comment: "Zoom In"),
						  NSLocalizedString("558.ibShadowedToolTips[2]", tableName: "TSSTSessionWindowToolbar", value: "Zoom Reset", comment: "Zoom Reset")]
			
			let item = NSToolbarItemGroup(itemIdentifier: .zoom, images: images, selectionMode: .momentary, labels: labels, target: self, action: #selector(self.zoom(_:)))
			item.label = NSLocalizedString("559.label", tableName: "TSSTSessionWindowToolbar", value: "Zoom", comment: "\"Zoom\" label")
			item.paletteLabel = NSLocalizedString("559.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Zoom", comment: "\"Zoom\" Palette Label")
			item.subitems[0].tag = 802
			item.subitems[1].tag = 801
			item.subitems[2].tag = 803
			item.selectionMode = .momentary
			return item
			
		case .rotation:
			let images = [NSImage(systemSymbolName: "arrow.trianglehead.counterclockwise.rotate.90", accessibilityDescription: nil) ?? NSImage(resource: .arrowTriangleheadCounterclockwiseRotate90),
						  NSImage(systemSymbolName: "arrow.trianglehead.clockwise.rotate.90", accessibilityDescription: nil) ?? NSImage(resource: .arrowTriangleheadClockwiseRotate90)]
			
			let labels = [NSLocalizedString("587.ibShadowedToolTips[0]", tableName: "TSSTSessionWindowToolbar", value: "Rotate Left", comment: "Rotate Left"),
						  NSLocalizedString("587.ibShadowedToolTips[1]", tableName: "TSSTSessionWindowToolbar", value: "Rotate Right", comment: "Rotate Right")]
			
			let item = NSToolbarItemGroup(itemIdentifier: .rotation, images: images, selectionMode: .momentary, labels: labels, target: self, action: #selector(self.rotate(_:)))
			item.label = NSLocalizedString("585.label", tableName: "TSSTSessionWindowToolbar", value: "Rotate", comment: "Rotate label")
			item.paletteLabel = NSLocalizedString("585.paletteLabel", tableName: "TSSTSessionWindowToolbar", value: "Rotate", comment: "Rotate palette label")
			item.subitems[0].tag = 901
			item.subitems[1].tag = 902
			item.selectionMode = .momentary
			return item


		default:
			return nil
		}
	}
}
