//
//  PreviewViewController.swift
//  Preview2
//
//  Created by C.W. Betts on 8/14/24.
//  Copyright © 2024 Dancing Tortoise Software. All rights reserved.
//

import Cocoa
import Quartz
import XADMaster

let thumbViewIdentifier = NSUserInterfaceItemIdentifier("TSSTThumbViewIdentifier")

class PreviewViewController: NSViewController, QLPreviewingController, NSCollectionViewDataSource, NSCollectionViewDelegate {
	
	private var archive: XADArchive?
	private var filesList: [[String: Any]] = []
	private var baseSize = NSSize.zero
	
	@IBOutlet var imageView: NSImageView!
	@IBOutlet var collectionView: NSCollectionView!
	
	override var nibName: NSNib.Name? {
		return NSNib.Name("PreviewViewController")
	}
	
	override func loadView() {
		super.loadView()
		collectionView.register(ThumbViewItem.self, forItemWithIdentifier: thumbViewIdentifier)
		// Do any additional setup after loading the view.
	}
	
	func preparePreviewOfFile(at url: URL) async throws {
		
		// Add the supported content types to the QLSupportedContentTypes array in the Info.plist of the extension.
		
		// Perform any setup necessary in order to prepare the view.
		
		// Call the completion handler so Quick Look knows that the preview is fully loaded.
		// Quick Look will display a loading spinner while the completion handler is not called.
		archive = try XADArchive(fileURL: url, delegate: nil)
		let archiv = archive!
		var fList = fileList(for: archiv)
		
		guard fList.count > 0 else {
			throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
		}
		do {
			let flist2 = (fList as NSArray).sortedArray(using: fileSort)
			fList = flist2 as! [[String: Any]]
		}
		filesList = fList
		
		// Load the first image. Assume all pages are at least that big.
		let pdfSize: CGSize
		if let firstIdx = fList.first?["index"] as? Int,
		   let fileData = try? archiv.contents(ofEntry: firstIdx),
		   let image = NSImage(data: fileData) {
			pdfSize = image.size
		} else {
			pdfSize = CGSize(width: 800, height: 600)
		}
		baseSize = pdfSize
		collectionView.reloadData()
	}
	
	// MARK: - NSCollectionViewDataSource
	
	func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
		assert(self.collectionView === collectionView)
		return filesList.count
	}
	
	func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
		assert(self.collectionView === collectionView)
		let item = collectionView.makeItem(withIdentifier: thumbViewIdentifier, for: indexPath) as! ThumbViewItem
		let idx = indexPath.first!
		item.archive = archive
		item.entryIndex = filesList[idx]["index"] as! Int
		return item
	}
	
	// MARK: - NSCollectionViewDelegate

	func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
		assert(self.collectionView === collectionView)
		(item as! ThumbViewItem).loadImageFromArchive()
	}
	
}
