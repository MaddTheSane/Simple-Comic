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

/*!
 *	@class		UKXattrMetadataStore
 *	@brief		\c xattr wrapper class.
 *	@discussion	This is a wrapper around The Mac OS X 10.4 and later xattr
 *	API that lets you attach arbitrary metadata to a file. Currently it
 *	allows querying and changing the attributes of a file, as well as
 *	retrieving a list of attribute names.
 *
 *	It also includes some conveniences for storing/retrieving UTF8 strings,
 *	and objects as property lists in addition to the raw data.
 *
 *	NOTE: keys (i.e. xattr names) are strings of 127 characters or less and
 *	should be made like bundle identifiers, e.g. @"de.zathras.myattribute".
 */
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
 */
+(NSArray<NSString*>*) allKeysAtPath:(NSString*)path traverseLink:(BOOL)travLnk UKXDEPRECATED("allKeys(atPath:traverseLink:) throws", "+allKeysAtPath:traverseLink:error:");

/*!
 *	@method		allKeysAtPath:traverseLink:
 *	@param		path
 *				The file to get xattr names from.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@param		error
 *				If the method does not complete successfully, upon return
 *				contains an \c NSError object that describes the problem.
 *	@return		An \c NSArray of <code>NSString</code>s, or \c nil on failure.
 *	@discussion	Returns an \c NSArray of <code>NSString</code>s containing all xattr names currently set
 *				for the file at the specified path.
 */
+(nullable NSArray<NSString*>*) allKeysAtPath:(NSString*)path traverseLink:(BOOL)travLnk error:(NSError**)error;

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

/*!
 *	@method		setString:forKey:atPath:traverseLink:error:
 *	@brief		Set the xattr with name \c key to the UTF8 representation of <code>str</code>.
 *	@param		str
 *				The string to set.
 *	@param		key
 *				the key to set \c str to.
 *	@param		path
 *				The file whose xattr you want to set.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@param		outError
 *				If the method does not complete successfully, upon return 
 *				contains an \c NSError object that describes the problem.
 *	@return		\c YES on success, \c NO on failure.
 *	@discussion	Set the xattr with name \c key to the UTF8 representation of <code>str</code>.
 */
+(BOOL) setString:(NSString*)str forKey:(NSString*)key
		   atPath:(NSString*)path traverseLink:(BOOL)travLnk error:(NSError**)outError;

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

/*!
 *	@method		stringForKey:atPath:traverseLink:error:
 *	@brief		Get the xattr with name \c key as a UTF8 string.
 *	@param		key
 *				the key to set \c str to.
 *	@param		path
 *				The file whose xattr you want to get.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@param		error
 *				If the method does not complete successfully, upon return
 *				contains an \c NSError object that describes the problem.
 *	@return		an \c NSString on succes, or \c nil on failure.
 *	@discussion	Get the xattr with name \c key as a UTF-8 string.
 */
+(nullable NSString*) stringForKey:(NSString*)key atPath:(NSString*)path
					  traverseLink:(BOOL)travLnk error:(NSError**)error;

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
/*!
 *	@method		setData:forKey:atPath:traverseLink:error:
 *	@brief		Set the xattr with name \c key to the raw data in <code>data</code>.
 *	@param		data
 *				The data to set.
 *	@param		key
 *				the key to set \c data to.
 *	@param		path
 *				The file whose xattr you want to set.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@param		error
 *				If the method does not complete successfully, upon return
 *				contains an \c NSError object that describes the problem.
 *	@return		\c YES on success, \c NO on failure.
 *	@discussion	Set the xattr with name \c key to the raw data in <code>data</code>.
 */
+(BOOL) setData:(NSData*)data forKey:(NSString*)key
		 atPath:(NSString*)path traverseLink:(BOOL)travLnk error:(NSError**)error;

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
/*!
 *	@method		dataForKey:atPath:traverseLink:error:
 *	@brief		Get the xattr with name \c key as raw data.
 *	@param		key
 *				the key to set \c str to.
 *	@param		path
 *				The file whose xattr you want to get.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@param		error
 *				If the method does not complete successfully, upon return
 *				contains an \c NSError object that describes the problem.
 *	@return		an \c NSData containing the contents of \c key on succes, or \c nil on failure
 */
+(nullable NSData*) dataForKey:(NSString*)key atPath:(NSString*)path
				  traverseLink:(BOOL)travLnk error:(NSError**)error;

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

/*!
 *	@method		setObject:forKey:atPath:traverseLink:error:
 *	@brief		Sets the xattr with name \c key to an XML property list representation of
 *				the specified object (or object graph).
 *	@param		obj
 *				The Property List object to set.
 *	@param		key
 *				The key to set \c obj to.
 *	@param		path
 *				The file whose xattr you want to set.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@param		error
 *				If the method does not complete successfully, upon return
 *				contains an \c NSError object that describes the problem.
 *	@return		\c YES on success, \c NO on failure.
 *	@discussion	Set the xattr with name \c key to an XML property list representation of
 *				the specified object (or object graph).
 *
 *				This is the same as calling \c +setObject:forKey:atPath:traverseLink:format:error: with \c NSPropertyListXMLFormat_v1_0 as the \c format
 */
+(BOOL) setObject:(id)obj forKey:(NSString*)key atPath:(NSString*)path
	 traverseLink:(BOOL)travLnk error:(NSError**)error;

/*!
 *	@method		setObject:forKey:atPath:traverseLink:format:error:
 *	@brief		Sets the xattr with name \c key to a property list representation of
 *				the specified object (or object graph) using the specified format.
 *	@param		obj
 *				The Property List object to set.
 *	@param		key
 *				the key to set \c obj to.
 *	@param		path
 *				The file whose xattr you want to set.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@param		error
 *				If the method does not complete successfully, upon return
 *				contains an \c NSError object that describes the problem.
 *	@param		format
 *				The property list format to save the encoded data.
 *				Remember: Foundation does not support generating
 *				\c NSPropertyListOpenStepFormat property lists.
 *	@return		\c YES on success, \c NO on failure.
 *	@discussion	Set the xattr with name \c key to a property list representation of
 *				the specified object (or object graph). The Property list format is
 *				specified by the \c format parameter.
 */
+(BOOL) setObject:(id)obj forKey:(NSString*)key atPath:(NSString*)path
	 traverseLink:(BOOL)travLnk format:(NSPropertyListFormat)format error:(NSError**)error;

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

/*!
 *	@method		objectForKey:atPath:traverseLink:error:
 *	@brief		Get the xattr with name \c key as a property list
 *	@param		key
 *				the key to get the Property List object from.
 *	@param		path
 *				The file whose xattr you want to get.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@param		outError
 *				If the method does not complete successfully, upon return
 *				contains an \c NSError object that describes the problem.
 *	@return		a Property List object from contents of \c key on succes, or \c nil on failure
 *	@discussion	Get the xattr with name \c key as a property list object (<code>NSString</code>, <code>NSArray</code>, etc...)
 *
 *				The data has to be stored as a property list.
 */
+(nullable id) objectForKey:(NSString*)key atPath:(NSString*)path
			   traverseLink:(BOOL)travLnk error:(NSError**)outError;

/*!
 *	@method		removeKey:atPath:traverseLink:error:
 *	@brief		Removes the xattr with name \c key
 *	@param		key
 *				the key to delete.
 *	@param		path
 *				The file whose xattr you want to remove.
 *	@param		travLnk
 *				If <code>YES</code>, follows symlinks.
 *	@param		outError
 *				If the method does not complete successfully, upon return
 *				contains an \c NSError object that describes the problem.
 *	@return		\c YES on success, \c NO on failure.
 */
+(BOOL) removeKey:(NSString*)key atPath:(NSString*)path
	 traverseLink:(BOOL)travLnk error:(NSError**)outError;

@end

NS_ASSUME_NONNULL_END
