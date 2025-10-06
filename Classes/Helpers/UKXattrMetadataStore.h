//
//  UKXattrMetadataStore.h
//  BubbleBrowser
//	LICENSE: MIT License
//
//  Created by Uli Kusterer on 12.03.06.
//  Copyright 2006 Uli Kusterer. All rights reserved.
//

// -----------------------------------------------------------------------------
//	Headers:
// -----------------------------------------------------------------------------

#import <Foundation/Foundation.h>

/*!
 @header UKXattrMetadataStore.h
 
 @discussion
	This is a wrapper around The Mac OS X 10.4 and later xattr API that lets
	you attach arbitrary metadata to a file. Currently it allows querying and
	changing the attributes of a file, as well as retrieving a list of attribute
	names.
	
	It also includes some conveniences for storing/retrieving UTF8 strings,
	and objects as property lists in addition to the raw data.
	
	NOTE: keys (i.e. xattr names) are strings of 127 characters or less and
	should be made like bundle identifiers, e.g. @"de.zathras.myattribute".
*/

#define UKXDEPRECATED(x, y) __attribute__((availability(swift, unavailable, message="Use '" x "' instead"))) __attribute__((deprecated("Use '" y "' instead")))

// -----------------------------------------------------------------------------
//	Class declaration:
// -----------------------------------------------------------------------------

NS_ASSUME_NONNULL_BEGIN

/// `xattr` wrapper class.
///
/// This is a wrapper around The Mac OS X 10.4 and later xattr
/// API that lets you attach arbitrary metadata to a file. Currently it
/// allows querying and changing the attributes of a file, as well as
/// retrieving a list of attribute names.
///
/// It also includes some conveniences for storing/retrieving UTF8 strings,
/// and objects as property lists in addition to the raw data.
///
/// NOTE: keys (i.e. xattr names) are strings of 127 characters or less and
/// should be made like bundle identifiers, e.g. @"de.zathras.myattribute".
@interface UKXattrMetadataStore : NSObject

/*!
 *	@method		allKeysAtPath:traverseLink:
 *	@param		path
 *				The file to get xattr names from.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@return		An \c NSArray of <code>NSString</code>s, or an empty \c NSArray on failure.
 *	@discussion	Returns an \c NSArray of <code>NSString</code>s containing all xattr names currently set
 *				for the file at the specified path.
 *	@deprecated	This method does not do any error checking.
 */
+(NSArray<NSString*>*) allKeysAtPath:(NSString*)path traverseLink:(BOOL)travLnk UKXDEPRECATED("allKeys(atPath:traverseLink:) throws", "+allKeysAtPath:traverseLink:error:");

/// Returns an `NSArray` of `NSString`s containing all xattr names currently set
/// for the file at the specified path.
/// - parameter path: The file to get xattr names from.
/// - parameter travLnk: If `YES`, follows symlinks.
/// - parameter error: If the method does not complete successfully, upon return contains an
/// `NSError` object that describes the problem.
/// - throws: If the method does not complete successfully.
/// - returns: An `NSArray` of `NSString`s, or `nil` on failure.
+(nullable NSArray<NSString*>*) allKeysAtPath:(NSString*)path traverseLink:(BOOL)travLnk error:(NSError*__autoreleasing*)error;

#pragma mark Store UTF8 strings:
/*!
 *	@method		setString:forKey:atPath:traverseLink:
 *	@brief		Set the xattr with name \c key to the UTF8 representation of <code>str</code>.
 *	@param		str
 *				The string to set.
 *	@param		key
 *				the key to set \c str to.
 *	@param		path
 *				The file whose xattr you want to set.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@discussion	Set the xattr with name key to an XML property list representation of
 *				the specified object (or object graph).
 *	@deprecated	This method throws an Obj-C exception. No other error information is provided, not even if it was successful.
 */
+(void) setString:(NSString*)str forKey:(NSString*)key
		   atPath:(NSString*)path traverseLink:(BOOL)travLnk UKXDEPRECATED("setString(_:forKey:atPath:traverseLink:) throws", "+setString:forKey:atPath:traverseLink:error:");

/// Set the xattr with name `key` to the UTF8 representation of `str`.
/// - parameter str: The string to set.
/// - parameter key: the key to set `str` to.
/// - parameter path: The file whose xattr you want to set.
/// - parameter travLnk: If `YES`, follows symlinks.
/// - parameter outError: If the method does not complete successfully, upon return
/// contains an `NSError` object that describes the problem.
/// - throws: If the method does not complete successfully.
/// - returns: `YES` on success, `NO` on failure.
+(BOOL) setString:(NSString*)str forKey:(NSString*)key
		   atPath:(NSString*)path traverseLink:(BOOL)travLnk error:(NSError*__autoreleasing*)outError;

/*!
 *	@method		stringForKey:atPath:traverseLink:
 *	@brief		Get the xattr with name \c key as a UTF8 string.
 *	@param		key
 *				the key to set \c str to.
 *	@param		path
 *				The file whose xattr you want to get.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@return		an \c NSString on succes, or \c nil on failure.
 *	@discussion	Get the xattr with name \c key as a UTF8 string.
 *	@deprecated	This method has no error handling.
 */
+(nullable NSString*) stringForKey:(NSString*)key atPath:(NSString*)path
					  traverseLink:(BOOL)travLnk UKXDEPRECATED("string(forKey:atPath:traverseLink:) throws", "+stringForKey:atPath:traverseLink:error:");

/// Get the xattr with name `key` as a UTF8 string.
/// - parameter key: the key to set `str` to.
/// - parameter path: The file whose xattr you want to get.
/// - parameter travLnk: If `YES`, follows symlinks.
/// - parameter error: If the method does not complete successfully, upon return
///contains an `NSError` object that describes the problem.
/// - throws: If the method does not complete successfully.
/// - returns: an `NSString` on succes, or `nil` on failure.
+(nullable NSString*) stringForKey:(NSString*)key atPath:(NSString*)path
					  traverseLink:(BOOL)travLnk error:(NSError*__autoreleasing*)error;

#pragma mark Store raw data:
/*!
 *	@method		setData:forKey:atPath:traverseLink:
 *	@brief		Set the xattr with name \c key to the raw data in <code>data</code>.
 *	@param		data
 *				The data to set.
 *	@param		key
 *				the key to set \c data to.
 *	@param		path
 *				The file whose xattr you want to set.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@deprecated	This method has no way of indicating success or failure.
 */
+(void) setData:(NSData*)data forKey:(NSString*)key
		 atPath:(NSString*)path traverseLink:(BOOL)travLnk UKXDEPRECATED("setData(_:forKey:atPath:traverseLink:) throws", "+setData:forKey:atPath:traverseLink:error:");

/// Set the xattr with name `key` to the raw data in `data`.
/// - parameter data: The data to set.
/// - parameter key: the key to set `data` to.
/// - parameter path: The file whose xattr you want to set.
/// - parameter travLnk: If `YES`, follows symlinks.
/// - parameter error: If the method does not complete successfully, upon return
/// contains an  `NSError` object that describes the problem.
/// - throws: If the method does not complete successfully.
/// - returns: `YES` on success, `NO` on failure.
+(BOOL) setData:(NSData*)data forKey:(NSString*)key
		 atPath:(NSString*)path traverseLink:(BOOL)travLnk error:(NSError*__autoreleasing*)error;

/*!
 *	@method		dataForKey:atPath:traverseLink:
 *	@brief		Get the xattr with name \c key as raw data.
 *	@param		key
 *				the key to set \c str to.
 *	@param		path
 *				The file whose xattr you want to get.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@return		an \c NSData containing the contents of \c key on succes, or \c nil on failure
 *	@discussion	Get the xattr with name \c key as a UTF8 string
 *	@deprecated	This method throws an Obj-C exception. No other error information is provoded on failure.
 */
+(nullable NSData*) dataForKey:(NSString*)key atPath:(NSString*)path
				  traverseLink:(BOOL)travLnk UKXDEPRECATED("data(forKey:atPath:traverseLink:) throws", "+dataForKey:atPath:traverseLink:error:");

/// Get the xattr with name `key` as raw data.
/// - parameter key: the key to set `str` to.
/// - parameter path: The file whose xattr you want to get.
/// - parameter travLnk: If `YES`, follows symlinks.
/// - parameter error: If the method does not complete successfully, upon return
/// contains an `NSError` object that describes the problem.
/// - throws: If the method does not complete successfully.
/// - returns: an `NSData` containing the contents of `key` on succes, or `nil` on failure.
+(nullable NSData*) dataForKey:(NSString*)key atPath:(NSString*)path
				  traverseLink:(BOOL)travLnk error:(NSError*__autoreleasing*)error;

#pragma mark Store objects: (Only can get/set plist-type objects for now)‚
/*!
 *	@method		setObject:forKey:atPath:traverseLink:
 *	@param		obj
 *				The property list object to set.
 *	@param		key
 *				the key to set \c obj to.
 *	@param		path
 *				The file whose xattr you want to set.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@discussion	Set the xattr with name key to an XML property list representation of
 *				the specified object (or object graph).
 *	@deprecated	This method throws an Obj-C exception. No other error information is provided,
 *				not even if it was successful.
 */
+(void) setObject:(id)obj forKey:(NSString*)key atPath:(NSString*)path
	 traverseLink:(BOOL)travLnk UKXDEPRECATED("setObject(_:forKey:atPath:traverseLink:format:) throws", "+setObject:forKey:atPath:traverseLink:format:error:");

/// Sets the xattr with name `key` to an XML property list representation of the specified object (or object graph).
/// - parameter obj: The Property List object to set.
/// - parameter key: The key to set `obj` to.
/// - parameter path: The file whose xattr you want to set.
/// - parameter travLnk: If `YES`, follows symlinks.
/// - parameter error: If the method does not complete successfully, upon return contains an `NSError`
/// object that describes the problem.
/// - throws: If the method does not complete successfully.
/// - returns: `YES` on success, `NO` on failure.
///
/// This is the same as calling `+setObject:forKey:atPath:traverseLink:format:error:`
/// with `NSPropertyListXMLFormat_v1_0` as the `format`.
+(BOOL) setObject:(id)obj forKey:(NSString*)key atPath:(NSString*)path
	 traverseLink:(BOOL)travLnk error:(NSError*__autoreleasing*)error;

/// Sets the xattr with name `key` to a property list representation of the specified object (or object graph)
/// using the specified format.
/// - parameter obj: The Property List object to set.
/// - parameter key: the key to set `obj` to.
/// - parameter path: The file whose xattr you want to set.
/// - parameter travLnk: If `YES`, follows symlinks.
/// - parameter error: If the method does not complete successfully, upon return
/// contains an `NSError` object that describes the problem.
/// - parameter format: The property list format to save the encoded data.
/// Remember: Foundation does not support generating `NSPropertyListOpenStepFormat` property lists.
/// - throws: If the method does not complete successfully.
/// - returns: `YES` on success, `NO` on failure.
///
/// The Property list format is specified by the `format` parameter.
+(BOOL) setObject:(id)obj forKey:(NSString*)key atPath:(NSString*)path
	 traverseLink:(BOOL)travLnk format:(NSPropertyListFormat)format error:(NSError*__autoreleasing*)error;

/*!
 *	@method		objectForKey:atPath:traverseLink:
 *	@param		key
 *				the key to get the Property List object from.
 *	@param		path
 *				The file whose xattr you want to get.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@return		a Property List object from contents of \c key
 *	@discussion	Retrieve the xattr with name key, which is an XML property list
 *				and unserialize it back into an object or object graph.
 *	@deprecated	This method throws an Obj-C exception on failure.
 */
+(nullable id) objectForKey:(NSString*)key atPath:(NSString*)path
			   traverseLink:(BOOL)travLnk UKXDEPRECATED("object(forKey:atPath:traverseLink:) throws", "+objectForKey:atPath:traverseLink:error:");

/// Get the xattr with name `key` as a property list object (`NSString`, `NSArray`, etc...)
/// - parameter key: the key to get the Property List object from.
/// - parameter path: The file whose xattr you want to get.
/// - parameter travLnk: If `YES`, follows symlinks.
/// - parameter outError: If the method does not complete successfully, upon return contains an `NSError` object
/// that describes the problem.
/// - throws: If the method does not complete successfully.
/// - returns: a Property List object from contents of `key` on succes, or `nil` on failure.
///
/// The data has to be stored as a property list.
+(nullable id) objectForKey:(NSString*)key atPath:(NSString*)path
			   traverseLink:(BOOL)travLnk error:(NSError*__autoreleasing*)outError;

/// Removes the xattr with name `key`.
/// - parameter key: the key to delete.
/// - parameter path: The file whose xattr you want to remove.
/// - parameter travLnk: If `YES`, follows symlinks.
/// - parameter outError: If the method does not complete successfully, upon return contains
/// an `NSError` object that describes the problem.
/// - throws: If the method does not complete successfully.
/// - returns: `YES` on success, `NO` on failure.
+(BOOL) removeKey:(NSString*)key atPath:(NSString*)path
	 traverseLink:(BOOL)travLnk error:(NSError*__autoreleasing*)outError;

@end

NS_ASSUME_NONNULL_END
