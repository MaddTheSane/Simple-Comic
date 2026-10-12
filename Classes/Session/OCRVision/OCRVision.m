//  OCRVision.h
//
//  Created by David Phillip Oster on 5/19/2022.  license.txt applies.
//

#import "OCRVision.h"
#import "Simple_Comic-Swift.h"

#import <Vision/Vision.h>
#import <ImageIO/CGImageProperties.h>
#import <float.h>

NSString *const OCRLanguageKey = @"OCRLanguageKey";

static NSString *sOCRLanguage;

static NSArray<NSString *> *sOCRLanguages;

// Omit any VNRecognizedTextObservation that have a confidence value below this threshold.
static CGFloat OCRConfidence = 0.5;

// ocrErrors use this NSError Domain
NSErrorDomain const OCRVisionDomain = @"OCRVisionDomain";

/// Rather than allocate a new object to pass the results, just make the OCRVision object do double duty.
@interface OCRVision()<OCRVisionResults>

/// non nil while processing the request
///
/// Assumes caller will create a new OCRVision for each image to analyze.
@property(nullable) VNRecognizeTextRequest *activeTextRequest;

@property(readwrite) NSArray<VNRecognizedTextObservation *> *textObservations;
@property(readwrite, nullable, setter=setOCRError:) NSError *ocrError;
@property(readwrite, nullable) NSString *rawOCRText;
@end

@implementation OCRVision

+ (void)initialize
{
	[super initialize];
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSString *defaultOCRLanguage = @"";	// i.e., off.
		if (@available(macOS 12.0, *))
		{
			defaultOCRLanguage = @"ja";
		}
		NSDictionary* standardDefaults =
		@{
			OCRLanguageKey: defaultOCRLanguage,
		};
		NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
		[defaults registerDefaults: standardDefaults];
		NSUInteger revision = VNRecognizeTextRequestRevision2;
		if (@available(macOS 13.0, *)) {
			revision = VNRecognizeTextRequestRevision3;
		}
		if (@available(macOS 12.0, *))
		{
			VNRecognizeTextRequest *textRequest = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error){}];
			sOCRLanguages = [textRequest supportedRecognitionLanguagesAndReturnError:nil];
		} else {
			sOCRLanguages = [VNRecognizeTextRequest supportedRecognitionLanguagesForTextRecognitionLevel:VNRequestTextRecognitionLevelAccurate revision:revision error:NULL];
		}
		sOCRLanguage = sOCRLanguages.firstObject ?: @"";
	});
}

+ (NSArray<NSString *> *)ocrLanguages
{
	if (nil == sOCRLanguages){ return @[]; }
	return sOCRLanguages;
}

+ (NSString *)ocrLanguage
{
	NSString *defaultLanguage = [[NSUserDefaults standardUserDefaults] stringForKey:OCRLanguageKey];
	if (defaultLanguage != nil && [self.ocrLanguages containsObject:defaultLanguage]) {
		return defaultLanguage;
	}
	return sOCRLanguage;
}

#pragma mark OCR

- (void)callCompletion:(void (^)(id<OCRVisionResults> _Nonnull))completion
		  observations:(NSArray<VNRecognizedTextObservation *> *)observations
				 error:(NSError *)error
{
	NSString *joinedText = @"";
	if (observations.count != 0) {
		NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:observations.count];
		for (VNRecognizedTextObservation *observation in observations) {
			VNRecognizedText *topText = [observation topCandidates:1].firstObject;
			if (topText.string.length != 0) {
				[lines addObject:topText.string];
			}
		}
		joinedText = [lines componentsJoinedByString:@"\n"];
	}
	self.rawOCRText = joinedText;
	self.textObservations = observations;
	self.ocrError = error;
	completion(self);
	self.rawOCRText = nil;
	self.textObservations = @[];
	self.ocrError = nil;
}

- (void)callCompletion:(void (^)(id<OCRVisionResults> _Nonnull))completion
		  observations:(NSArray<VNRecognizedTextObservation *> *)observations
				 text:(NSString *)text
				 error:(NSError *)error
{
	self.rawOCRText = text ?: @"";
	self.textObservations = observations;
	self.ocrError = error;
	completion(self);
	self.rawOCRText = nil;
	self.textObservations = @[];
	self.ocrError = nil;
}

- (NSString *)allText
{
	if (self.rawOCRText.length != 0) {
		return self.rawOCRText;
	}

	NSMutableArray *a = [NSMutableArray array];
	for (VNRecognizedTextObservation *piece in self.textObservations)
	{
		NSArray<VNRecognizedText *> *text1 = [piece topCandidates:1];
		[a addObject:text1.firstObject.string];
	}
	return [a componentsJoinedByString:@"\n"];
}

- (BOOL)containsJapaneseCharacters:(NSString *)text
{
	for (NSUInteger idx = 0; idx < text.length; idx++) {
		unichar ch = [text characterAtIndex:idx];
		if ((ch >= 0x3040 && ch <= 0x309F) ||
			(ch >= 0x30A0 && ch <= 0x30FF) ||
			(ch >= 0x31F0 && ch <= 0x31FF) ||
			(ch >= 0x4E00 && ch <= 0x9FFF)) {
			return YES;
		}
	}
	return NO;
}

- (NSString *)normalizedOCRString:(NSString *)text
{
	if (text.length == 0) {
		return @"";
	}
	NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:ws];
	return [[parts componentsJoinedByString:@""] lowercaseString];
}

- (double)referenceSimilarityScoreForCandidate:(NSString *)candidate reference:(NSString *)reference
{
	NSString *a = [self normalizedOCRString:candidate];
	NSString *b = [self normalizedOCRString:reference];
	if (a.length == 0 || b.length == 0) {
		return 0.0;
	}

	NSCountedSet *aChars = [[NSCountedSet alloc] init];
	for (NSUInteger i = 0; i < a.length; i++) {
		[aChars addObject:@([a characterAtIndex:i])];
	}

	double overlap = 0.0;
	for (NSUInteger i = 0; i < b.length; i++) {
		NSNumber *ch = @([b characterAtIndex:i]);
		if ([aChars countForObject:ch] > 0) {
			overlap += 1.0;
			[aChars removeObject:ch];
		}
	}

	return overlap / (double)MAX(a.length, b.length);
}

- (BOOL)isLikelyNoiseLine:(NSString *)line
{
	if (line.length == 0) {
		return YES;
	}

	NSUInteger useful = 0;
	for (NSUInteger i = 0; i < line.length; i++) {
		unichar c = [line characterAtIndex:i];
		BOOL isLatin = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
		BOOL isDigit = (c >= '0' && c <= '9');
		BOOL isJapanese = ((c >= 0x3040 && c <= 0x309F) ||
						   (c >= 0x30A0 && c <= 0x30FF) ||
						   (c >= 0x31F0 && c <= 0x31FF) ||
						   (c >= 0x4E00 && c <= 0x9FFF));
		if (isLatin || isDigit || isJapanese) {
			useful += 1;
		}
	}

	double usefulRatio = (double)useful / (double)line.length;
	return usefulRatio < 0.45;
}

- (void)performVisionOCRForImage:(NSImage *)image completion:(void (^)(id<OCRVisionResults> _Nonnull))completion
{
	[self performVisionOCRForImage:image referenceText:nil completion:completion];
}

- (void)performVisionOCRForImage:(NSImage *)image referenceText:(NSString * _Nullable)referenceText completion:(void (^)(id<OCRVisionResults> _Nonnull))completion
{
	NSLog(@"[OCRVision] OCR_ENGINE=Vision");

	NSData *imageData = image.TIFFRepresentation;
	if (imageData == nil) {
		[self callCompletion:completion observations:@[] text:@"" error:nil];
		return;
	}

	CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
	if (imageSource == nil) {
		[self callCompletion:completion observations:@[] text:@"" error:nil];
		return;
	}

	CGImageRef imageRef = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
	CFRelease(imageSource);
	if (imageRef == nil) {
		[self callCompletion:completion observations:@[] text:@"" error:nil];
		return;
	}

	NSArray<NSNumber *> *orientations = @[
		@(kCGImagePropertyOrientationUp),
		@(kCGImagePropertyOrientationLeft),
		@(kCGImagePropertyOrientationRight),
		@(kCGImagePropertyOrientationDown)
	];

	NSArray<VNRecognizedTextObservation *> *bestResults = @[];
	NSString *bestJoinedText = @"";
	double bestScore = -DBL_MAX;
	NSError *lastError = nil;

	for (NSNumber *orientationNumber in orientations) {
		VNRecognizeTextRequest *textRequest = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
		// This pass powers selectable text, so favor quality over raw box count.
		textRequest.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
		textRequest.usesLanguageCorrection = YES;
		textRequest.recognitionLanguages = @[@"ja-JP", @"en-US"];
		if (@available(macOS 13.0, *)) {
			textRequest.automaticallyDetectsLanguage = YES;
		}

		NSError *requestError = nil;
		CGImagePropertyOrientation orientation = (CGImagePropertyOrientation)orientationNumber.integerValue;
		VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:imageRef orientation:orientation options:@{}];
		self.activeTextRequest = textRequest;
		BOOL ok = [handler performRequests:@[textRequest] error:&requestError];
		if (!ok) {
			if (lastError == nil) {
				lastError = requestError;
			}
			continue;
		}

		NSMutableArray<VNRecognizedTextObservation *> *filtered = [NSMutableArray array];
		NSMutableArray<NSString *> *joinedLines = [NSMutableArray array];
		double orientationScore = 0.0;
		for (VNRecognizedTextObservation *observation in textRequest.results) {
			NSArray<VNRecognizedText *> *text1 = [observation topCandidates:1];
			if (text1.count != 0) {
				NSString *line = text1.firstObject.string ?: @"";
				if ([self isLikelyNoiseLine:line]) {
					continue;
				}
				[filtered addObject:observation];
				[joinedLines addObject:line];
				double lineScore = (double)line.length * (double)observation.confidence;
				if ([self containsJapaneseCharacters:line]) {
					lineScore *= 1.5;
				}
				orientationScore += lineScore;
			}
		}

		NSString *joinedText = [joinedLines componentsJoinedByString:@"\n"];
		if (referenceText.length != 0) {
			double similarity = [self referenceSimilarityScoreForCandidate:joinedText reference:referenceText];
			orientationScore *= (1.0 + similarity * 2.0);
			NSLog(@"[OCRVision] OCR_ENGINE=Vision_Orientation_%ld similarity=%.3f", (long)orientation, similarity);
		}

		NSLog(@"[OCRVision] OCR_ENGINE=Vision_Orientation_%ld observations=%lu score=%.2f", (long)orientation, (unsigned long)filtered.count, orientationScore);
		if (orientationScore > bestScore) {
			bestScore = orientationScore;
			bestResults = filtered;
			bestJoinedText = joinedText;
		}
	}

	self.activeTextRequest = nil;
	CGImageRelease(imageRef);
	NSLog(@"[OCRVision] OCR_ENGINE=Vision_BestObservationCount=%lu score=%.2f", (unsigned long)bestResults.count, bestScore);
	if (bestJoinedText.length != 0) {
		NSLog(@"[OCRVision] OCR_ENGINE=Vision_BestText=%@", bestJoinedText);
	}
	[self callCompletion:completion observations:bestResults error:lastError];
}

- (void)performImageAnalyzerOCRForImage:(NSImage *)image completion:(void (^)(id<OCRVisionResults> _Nonnull))completion API_AVAILABLE(macos(13.0))
{
	NSLog(@"[OCRVision] OCR_ENGINE=ImageAnalyzer_Attempt");

	if (![ImageAnalyzerBridge isAvailable]) {
		NSLog(@"[OCRVision] OCR_ENGINE=ImageAnalyzer_Unavailable -> VisionFallback");
		[self performVisionOCRForImage:image completion:completion];
		return;
	}

	ImageAnalyzerBridge *bridge = [[ImageAnalyzerBridge alloc] init];
	[bridge analyzeImage:image completion:^(NSString * _Nullable transcript, NSError * _Nullable error) {
		NSString *safeTranscript = [transcript isKindOfClass:[NSString class]] ? transcript : @"";
		safeTranscript = [safeTranscript stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

		// Mirror ImageOCRApp strategy: if transcript is too short, fall back to Vision OCR.
		if (safeTranscript.length < 24) {
			NSLog(@"[OCRVision] OCR_ENGINE=ImageAnalyzer_WeakResult(%lu) -> VisionFallback", (unsigned long)safeTranscript.length);
			[self performVisionOCRForImage:image referenceText:safeTranscript completion:completion];
			return;
		}

		NSLog(@"[OCRVision] OCR_ENGINE=ImageAnalyzer_Success textLength=%lu", (unsigned long)safeTranscript.length);
		NSLog(@"[OCRVision] OCR_TEXT=%@", safeTranscript);

		// ImageAnalyzer provides great transcript quality, but selection UI needs Vision observations
		// with bounding boxes. Run Vision once and reuse its observations for selectable overlays.
		[self performVisionOCRForImage:image completion:^(id<OCRVisionResults> _Nonnull visionResults) {
			NSArray<VNRecognizedTextObservation *> *observations = visionResults.textObservations ?: @[];
			NSError *combinedError = error ?: visionResults.ocrError;
			NSLog(@"[OCRVision] OCR_ENGINE=ImageAnalyzer_WithVisionSelectionBoxes count=%lu", (unsigned long)observations.count);
			[self callCompletion:completion observations:observations text:safeTranscript error:combinedError];
		}];
	}];
}


/// Called by VNRecognizeTextRequest to process the result.
/// Filter the textObservations that includes actual text, and store in self.textObservations.
///
///  Since this is called on a worker queue, it delivers results on the main queue.
///
/// @param request - The VNRecognizeTextRequest
/// @param error - if non-nil, the VNRecognizeTextRequest is reporting an error.
- (void)handleTextRequest:(nullable VNRequest *)request
			   completion:(void (^)(id<OCRVisionResults> _Nonnull))completion
					error:(nullable NSError *)error
{
	if (error)
	{
		[self callCompletion:completion observations:@[] error:error];
	}
	else if ([request isKindOfClass:[VNRecognizeTextRequest class]])
	{
		VNRecognizeTextRequest *textRequests = (VNRecognizeTextRequest *)request;
		if (textRequests == self.activeTextRequest)
		{
			self.activeTextRequest = nil;
		}
		// Remove the low confidence recognitions.
		NSMutableArray<VNRecognizedTextObservation*> *results = [NSMutableArray array];
		for (VNRecognizedTextObservation *observation in textRequests.results)
		{
			NSArray<VNRecognizedText *> *text1 = [observation topCandidates:1];
			if (OCRConfidence <= observation.confidence && text1.count != 0) {
				[results addObject:observation];
			}
		}
		[self callCompletion:completion observations:results error:nil];
	} else {
		NSString *desc = @"Unrecognized text request";
		NSError *err = [NSError errorWithDomain:@""
										   code:OCRVisionErrUnrecognized
									   userInfo:@{NSLocalizedDescriptionKey : desc}];
		[self callCompletion:completion observations:@[] error:err];
	}
}

- (void)ocrCGImage:(CGImageRef)cgImage completion:(void (^)(id<OCRVisionResults> _Nonnull))completion
{
	__weak typeof(self) weakSelf = self;
	VNRecognizeTextRequest *textRequest =
	[[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error)
	 {
		[weakSelf handleTextRequest:request completion:completion error:error];
	}];
	if (textRequest)
	{
		NSString *ocrLanguage = [[self class] ocrLanguage];
		if (ocrLanguage.length != 0)
		{
			textRequest.recognitionLanguages = @[ocrLanguage];
			textRequest.usesLanguageCorrection = YES;
			if (@available(macOS 13.0, *))
			{
				textRequest.automaticallyDetectsLanguage = YES;
			}
		}
		NSError *error = nil;
		VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
		self.activeTextRequest = textRequest;
		if (![handler performRequests:@[textRequest] error:&error])
		{
			[weakSelf callCompletion:completion observations:@[] error:error];
		}
	} else {
		NSString *desc = @"Could not create text request";
		NSError *err = [NSError errorWithDomain:OCRVisionDomain
										   code:OCRVisionErrNoCreate
									   userInfo:@{NSLocalizedDescriptionKey : desc}];
		[self callCompletion:completion observations:@[] error:err];
	}
}

- (void)ocrImage:(NSImage *)image completion:(void (^)(id<OCRVisionResults> _Nonnull))completion
{
	NSString *ocrLanguage = [[self class] ocrLanguage];
	if (ocrLanguage.length == 0) {
		[self callCompletion:completion observations:@[] text:@"" error:nil];
		return;
	}

	if (@available(macOS 13.0, *)) {
		[self performImageAnalyzerOCRForImage:image completion:completion];
	} else {
		[self performVisionOCRForImage:image completion:completion];
	}
}

- (void)cancel
{
	[self.activeTextRequest cancel];
}

@end
