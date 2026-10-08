//
//  PreviewProvider.swift
//  QuickComic Preview
//
//  Created by C.W. Betts on 12/11/22.
//  Copyright © 2022 Dancing Tortoise Software. All rights reserved.
//

import Cocoa
import Quartz
import XADMaster
import UniformTypeIdentifiers

private func newPDFPage(from image: NSImage) -> PDFPage? {
	if #available(macOSApplicationExtension 13.0, *) {
		return PDFPage(image: image, options: [.compressionQuality: 0.5])
	} else {
		return PDFPage(image: image)
	}
}

class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
		let archive = try XADArchive(fileURL: request.fileURL, delegate: nil)
		var fList = fileList(for: archive)
		
		guard !fList.isEmpty else {
			throw CocoaError(.fileReadCorruptFile,
							 userInfo:
								[NSURLErrorKey: request.fileURL,
					 NSLocalizedDescriptionKey: NSLocalizedString("No images found in archive.", comment: "No images found in archive.")])
		}
		do {
			let flist2 = (fList as NSArray).sortedArray(using: fileSort)
			fList = flist2 as! [[String: Any]]
		}
		
		// Load the first image.
		let pdfSize: CGSize
		if let firstIdx = fList[0]["index"] as? Int,
		   let fileData = try? archive.contents(ofEntry: firstIdx),
		   let image = NSImage(data: fileData) {
			pdfSize = image.size
		} else {
			pdfSize = CGSize(width: 800, height: 600)
		}
		
		let reply = QLPreviewReply(forPDFWithPageSize: pdfSize) { replyToUpdate in
			let document = PDFDocument()
			// Only load so many pages, plus the last one. Pages are appended: the old code
			// inserted at the entry's offset in the archive, which is past the end of the
			// (still short) document and made PDFDocument throw, crashing the extension.
			for offset in TSSTPreviewPageOffsets(UInt(fList.count), 25) {
				let list = fList[offset.intValue]
				guard let index = list["index"] as? Int,
					  let fileData = try? archive.contents(ofEntry: index),
					  let image = NSImage(data: fileData),
					  let page = newPDFPage(from: image) else {
					let badPage = PDFPage()
					badPage.setBounds(NSRect(origin: .zero, size: pdfSize), for: .mediaBox)
					//TODO: tell the user that generating the page failed?
					document.insert(badPage, at: document.pageCount)
					continue
				}
				document.insert(page, at: document.pageCount)
			}
			
			return document
		}
        
        return reply
    }
}
