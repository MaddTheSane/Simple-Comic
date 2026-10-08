//
//  TSSTUTIDeclarationTests.m
//  Guards the comic file type declarations in the built app and its Quick Look extensions.
//

#import <XCTest/XCTest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "TSSTManagedGroup.h" // declares TSSTManagedArchive

@interface TSSTUTIDeclarationTests : XCTestCase
@property (strong) NSBundle *app;
@property (strong) NSDictionary *appInfo;
@end

@implementation TSSTUTIDeclarationTests

- (void)setUp {
	// The unit tests are hosted in Simple Comic, so this is the built app bundle.
	self.app = [NSBundle bundleForClass:[TSSTManagedArchive class]];
	self.appInfo = self.app.infoDictionary;
}

- (NSArray<NSString *> *)declaredIdentifiersInKey:(NSString *)key {
	return [self.appInfo[key] valueForKey:@"UTTypeIdentifier"] ?: @[];
}

// Every id the app declares or lists in the plist, plus the ones Launch Services knows.
- (BOOL)isResolvable:(NSString *)identifier {
	if ([UTType typeWithIdentifier:identifier] != nil) return YES;
	return [[self declaredIdentifiersInKey:@"UTExportedTypeDeclarations"] containsObject:identifier] ||
		   [[self declaredIdentifiersInKey:@"UTImportedTypeDeclarations"] containsObject:identifier];
}

- (NSDictionary *)extensionInfoNamed:(NSString *)name {
	NSURL *url = [self.app.builtInPlugInsURL URLByAppendingPathComponent:name];
	NSBundle *bundle = [NSBundle bundleWithURL:url];
	XCTAssertNotNil(bundle, @"%@ is not embedded in the app", name);
	return bundle.infoDictionary;
}

- (NSArray<NSString *> *)quickLookTypesOfExtension:(NSString *)name {
	return [self extensionInfoNamed:name][@"NSExtension"][@"NSExtensionAttributes"][@"QLSupportedContentTypes"];
}

// Ids that are referenced but that nobody declares. Anything else that fails to resolve is a missing declaration.
- (NSSet<NSString *> *)knownUnresolved {
	return [NSSet setWithObjects:
			@"cx.c3.lha-archive",                              // old third-party id, never declared
			@"com.simplecomic.cbt-archive",                    // cbt is deliberately not declared
			@"com.rarlab.rar-comic-archive",                   // only RARLab's own apps would declare it
			@"public.cbr-archive", @"public.cbz-archive", @"public.cb7-archive",  // public.* is Apple's namespace,
			@"public.archive.cbr", @"public.archive.cbz",      // so we can't declare these and the system doesn't
			@"public.zip-comic-archive", nil];
}

// A document type or archiveTypes entry with no declaration silently matches nothing.
- (void)testDocumentAndArchiveTypesResolve {
	NSMutableSet *ids = [NSMutableSet setWithArray:[TSSTManagedArchive archiveTypes]];
	for (NSDictionary *docType in self.appInfo[@"CFBundleDocumentTypes"]) {
		[ids addObjectsFromArray:docType[@"LSItemContentTypes"] ?: @[]];
	}
	XCTAssertGreaterThan(ids.count, 10u);
	for (NSString *identifier in ids) {
		if ([[self knownUnresolved] containsObject:identifier]) continue;
		XCTAssertTrue([self isResolvable:identifier], @"%@ is referenced but not declared", identifier);
	}
}

// Each supported comic extension needs an exported com.simplecomic.*-archive type claiming it.
// (cbt is deliberately not declared: it is rare, and the app only opens it as a plain tar.)
- (void)testComicExtensionsHaveExportedTypes {
	for (NSString *ext in @[@"cbz", @"cbr", @"cb7"]) {
		NSString *expected = [NSString stringWithFormat:@"com.simplecomic.%@-archive", ext];
		BOOL found = NO;
		for (NSDictionary *decl in self.appInfo[@"UTExportedTypeDeclarations"]) {
			NSArray *exts = decl[@"UTTypeTagSpecification"][@"public.filename-extension"];
			if ([decl[@"UTTypeIdentifier"] isEqual:expected] && [exts containsObject:ext]) found = YES;
		}
		XCTAssertTrue(found, @"no exported %@ claiming .%@", expected, ext);
	}
}

// Declaring someone else's public.* identifier is not allowed; those belong to Apple.
- (void)testNoPublicIdentifiersAreDeclared {
	for (NSString *key in @[@"UTExportedTypeDeclarations", @"UTImportedTypeDeclarations"]) {
		for (NSString *identifier in [self declaredIdentifiersInKey:key]) {
			// Existing import of a type the system already knows; it only adds the lha/lzh tags.
			if ([identifier isEqual:@"public.archive.lha"]) continue;
			XCTAssertFalse([identifier hasPrefix:@"public."], @"%@ declares %@", key, identifier);
		}
	}
}

// Quick Look only calls the extensions for the ids they list, and it must be able to resolve them.
- (void)testQuickLookExtensionTypesResolve {
	for (NSString *name in @[@"QuickComic Preview.appex", @"QuickComic Thumbnailer.appex"]) {
		NSArray *types = [self quickLookTypesOfExtension:name];
		XCTAssertGreaterThan(types.count, 0u, @"%@", name);
		for (NSString *identifier in types) {
			if ([[self knownUnresolved] containsObject:identifier]) continue;
			XCTAssertTrue([self isResolvable:identifier], @"%@ lists undeclared %@", name, identifier);
		}
	}
}

// The cb7 type must be listed or conform to a listed id, or Quick Look skips .cb7 files.
- (void)testQuickLookExtensionsClaimCb7 {
	UTType *type = [UTType typeWithFilenameExtension:@"cb7"];
	XCTAssertNotNil(type, @".cb7 has no type");
	for (NSString *name in @[@"QuickComic Preview.appex", @"QuickComic Thumbnailer.appex"]) {
		BOOL claimed = NO;
		for (NSString *identifier in [self quickLookTypesOfExtension:name]) {
			UTType *candidate = [UTType typeWithIdentifier:identifier];
			if (candidate && [type conformsToType:candidate]) claimed = YES;
		}
		XCTAssertTrue(claimed, @"%@ does not claim %@", name, type.identifier);
	}
}

// cx.c3.cb7-archive was never a real type; nothing should still refer to it.
- (void)testNoReferencesToBogusCb7Id {
	NSString *bogus = @"cx.c3.cb7-archive";
	XCTAssertFalse([[TSSTManagedArchive archiveTypes] containsObject:bogus]);
	NSMutableArray *plists = [NSMutableArray arrayWithObject:self.appInfo];
	for (NSString *name in @[@"QuickComic Preview.appex", @"QuickComic Thumbnailer.appex"]) {
		[plists addObject:[self extensionInfoNamed:name]];
	}
	for (NSDictionary *plist in plists) {
		XCTAssertFalse([[plist description] containsString:bogus]);
	}
}

@end
