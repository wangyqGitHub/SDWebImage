/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDAnimatedImage.h"
#import "NSImage+Compatibility.h"
#import "SDImageCoder.h"
#import "SDImageCodersManager.h"
#import "SDImageFrame.h"
#import "UIImage+MemoryCacheCost.h"
#import "SDImageAssetManager.h"
#import "objc/runtime.h"

static CGFloat SDImageScaleFromPath(NSString *string) {
    if (string.length == 0 || [string hasSuffix:@"/"]) return 1;
    NSString *name = string.stringByDeletingPathExtension;
    __block CGFloat scale = 1;
    
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"@[0-9]+\\.?[0-9]*x$" options:NSRegularExpressionAnchorsMatchLines error:nil];
    [pattern enumerateMatchesInString:name options:kNilOptions range:NSMakeRange(0, name.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
        if (result.range.location >= 3) {
            scale = [string substringWithRange:NSMakeRange(result.range.location + 1, result.range.length - 2)].doubleValue;
        }
    }];
    
    return scale;
}

@interface SDAnimatedImage ()

@property (nonatomic, strong) id<SDAnimatedImageCoder> coder;
@property (nonatomic, assign, readwrite) SDImageFormat animatedImageFormat;
@property (atomic, copy) NSArray<SDImageFrame *> *loadedAnimatedImageFrames; // Mark as atomic to keep thread-safe
@property (atomic, copy) NSDictionary<NSNumber* ,SDImageFrame*> * cachedFramesDictionary;//Save already cached frames and indexes

@property (nonatomic, assign, getter=isAllFramesLoaded) BOOL allFramesLoaded;

@end

@implementation SDAnimatedImage
@dynamic scale; // call super

#pragma mark - UIImage override method
+ (instancetype)imageNamed:(NSString *)name {
#if __has_include(<UIKit/UITraitCollection.h>)
    return [self imageNamed:name inBundle:nil compatibleWithTraitCollection:nil];
#else
    return [self imageNamed:name inBundle:nil];
#endif
}

#if __has_include(<UIKit/UITraitCollection.h>)
+ (instancetype)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    if (!traitCollection) {
        traitCollection = UIScreen.mainScreen.traitCollection;
    }
    CGFloat scale = traitCollection.displayScale;
    return [self imageNamed:name inBundle:bundle scale:scale];
}
#else
+ (instancetype)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle {
    return [self imageNamed:name inBundle:bundle scale:0];
}
#endif

// 0 scale means automatically check
+ (instancetype)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle scale:(CGFloat)scale {
    if (!name) {
        return nil;
    }
    if (!bundle) {
        bundle = [NSBundle mainBundle];
    }
    SDImageAssetManager *assetManager = [SDImageAssetManager sharedAssetManager];
    SDAnimatedImage *image = (SDAnimatedImage *)[assetManager imageForName:name];
    if ([image isKindOfClass:[SDAnimatedImage class]]) {
        return image;
    }
    NSString *path = [assetManager getPathForName:name bundle:bundle preferredScale:&scale];
    if (!path) {
        return image;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return image;
    }
    image = [[self alloc] initWithData:data scale:scale];
    if (image) {
        [assetManager storeImage:image forName:name];
    }
    
    return image;
}

+ (instancetype)imageWithContentsOfFile:(NSString *)path {
    return [[self alloc] initWithContentsOfFile:path];
}

+ (instancetype)imageWithData:(NSData *)data {
    return [[self alloc] initWithData:data];
}

+ (instancetype)imageWithData:(NSData *)data scale:(CGFloat)scale {
    return [[self alloc] initWithData:data scale:scale];
}

- (instancetype)initWithContentsOfFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return [self initWithData:data scale:SDImageScaleFromPath(path)];
}

- (instancetype)initWithData:(NSData *)data {
    return [self initWithData:data scale:1];
}

- (instancetype)initWithData:(NSData *)data scale:(CGFloat)scale {
    return [self initWithData:data scale:scale options:nil];
}

- (instancetype)initWithData:(NSData *)data scale:(CGFloat)scale options:(SDImageCoderOptions *)options {
    if (!data || data.length == 0) {
        return nil;
    }
    data = [data copy]; // avoid mutable data
    id<SDAnimatedImageCoder> animatedCoder = nil;
    for (id<SDImageCoder>coder in [SDImageCodersManager sharedManager].coders) {
        if ([coder conformsToProtocol:@protocol(SDAnimatedImageCoder)]) {
            if ([coder canDecodeFromData:data]) {
                if (!options) {
                    options = @{SDImageCoderDecodeScaleFactor : @(scale)};
                }
                animatedCoder = [[[coder class] alloc] initWithAnimatedImageData:data options:options];
                break;
            }
        }
    }
    if (!animatedCoder) {
        return nil;
    }
    return [self initWithAnimatedCoder:animatedCoder scale:scale];
}

- (instancetype)initWithAnimatedCoder:(id<SDAnimatedImageCoder>)animatedCoder scale:(CGFloat)scale {
    if (!animatedCoder) {
        return nil;
    }
    if (scale <= 0) {
        scale = 1;
    }
    UIImage *image = [animatedCoder animatedImageFrameAtIndex:0];
    if (!image) {
        return nil;
    }
#if SD_MAC
    self = [super initWithCGImage:image.CGImage scale:scale orientation:kCGImagePropertyOrientationUp];
#else
    self = [super initWithCGImage:image.CGImage scale:scale orientation:image.imageOrientation];
#endif
    if (self) {
        _coder = animatedCoder;
        NSData *data = [animatedCoder animatedImageData];
        SDImageFormat format = [NSData sd_imageFormatForImageData:data];
        _animatedImageFormat = format;
    }
    return self;
}

#pragma mark - Preload
- (void)preloadAllFrames {
    if (!self.isAllFramesLoaded) {
        NSMutableArray<SDImageFrame *> *frames = [NSMutableArray arrayWithCapacity:self.animatedImageFrameCount];
        for (size_t i = 0; i < self.animatedImageFrameCount; i++) {
            UIImage *image = [self animatedImageFrameAtIndex:i];
            NSTimeInterval duration = [self animatedImageDurationAtIndex:i];
            SDImageFrame *frame = [SDImageFrame frameWithImage:image duration:duration]; // through the image should be nonnull, used as nullable for `animatedImageFrameAtIndex:`
            [frames addObject:frame];
        }
        self.loadedAnimatedImageFrames = frames;
        self.allFramesLoaded = YES;
    }
}

- (void)autoCacheFrameDuringPlayback:(UIImage *)image atIndex:(NSInteger)index{
    if (!self.isAllFramesLoaded) {
        NSNumber *indexNum = [NSNumber numberWithInteger:index];
        if ([self.cachedFramesDictionary.allKeys containsObject: indexNum]) {
            return;
        }
        //        NSLog(@"will cache a new frame at index : --> %ld",index);
        NSTimeInterval duration = [self animatedImageDurationAtIndex:index];
        SDImageFrame *frame = [SDImageFrame frameWithImage:image duration:duration];
        NSMutableDictionary<NSNumber*,SDImageFrame*> *tempCachedFrameDict = [NSMutableDictionary dictionaryWithDictionary:self.cachedFramesDictionary];
        [tempCachedFrameDict setObject:frame forKey:indexNum];
        self.cachedFramesDictionary = [NSDictionary dictionaryWithDictionary:tempCachedFrameDict];
        self.loadedAnimatedImageFrames = tempCachedFrameDict.allValues;
        
        //Check is first frame has cached.
        //'SDAnimatedimageView'decode first frame when animated image download by default,we donot cached it.
        NSInteger firstFrameIndex = 0;
        NSNumber *firstIndexNum = [NSNumber numberWithInteger:firstFrameIndex];
        if (![self.cachedFramesDictionary.allKeys containsObject:firstIndexNum]){
            if (self.loadedAnimatedImageFrames.count + 1 == self.animatedImageFrameCount){
                UIImage *image = [self animatedImageFrameAtIndex:firstFrameIndex];
                NSTimeInterval duration = [self animatedImageDurationAtIndex:firstFrameIndex];
                SDImageFrame *firstFrame = [SDImageFrame frameWithImage:image duration:duration];
                [tempCachedFrameDict setObject:firstFrame forKey:firstIndexNum];
                self.cachedFramesDictionary = [NSDictionary dictionaryWithDictionary:tempCachedFrameDict];
                self.loadedAnimatedImageFrames = [self sortAllCachedFrames:tempCachedFrameDict];
                self.allFramesLoaded = YES;
            }
        }else{
            if (self.loadedAnimatedImageFrames.count == self.animatedImageFrameCount){
                self.loadedAnimatedImageFrames = [self sortAllCachedFrames:tempCachedFrameDict];
                self.allFramesLoaded = YES;
            }
        }
    }
}

- (NSArray<SDImageFrame*> *)sortAllCachedFrames:(NSDictionary<NSNumber*,SDImageFrame*>*)targetDic{
    NSComparator keysSort = ^(id numIndex1,id numIndex2){
        if (numIndex1 > numIndex2) {
            return (NSComparisonResult)NSOrderedDescending;
        }else if (numIndex1 < numIndex2){
            return (NSComparisonResult)NSOrderedAscending;
        }else{
            return (NSComparisonResult)NSOrderedSame;
        }
    };
    NSArray *allKeysSorted = [targetDic.allKeys sortedArrayUsingComparator:keysSort];
    NSMutableArray<SDImageFrame*> *allValueSorted = [NSMutableArray array];
    for (NSString *key in allKeysSorted) {
        [allValueSorted addObject:targetDic[key]];
    }
    return allValueSorted.copy;
}

- (void)unloadAllFrames {
    if (self.isAllFramesLoaded) {
        self.loadedAnimatedImageFrames = nil;
        self.allFramesLoaded = NO;
    }
}

#pragma mark - NSSecureCoding
- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        NSData *animatedImageData = [aDecoder decodeObjectOfClass:[NSData class] forKey:NSStringFromSelector(@selector(animatedImageData))];
        CGFloat scale = self.scale;
        if (!animatedImageData) {
            return self;
        }
        id<SDAnimatedImageCoder> animatedCoder = nil;
        for (id<SDImageCoder>coder in [SDImageCodersManager sharedManager].coders) {
            if ([coder conformsToProtocol:@protocol(SDAnimatedImageCoder)]) {
                if ([coder canDecodeFromData:animatedImageData]) {
                    animatedCoder = [[[coder class] alloc] initWithAnimatedImageData:animatedImageData options:@{SDImageCoderDecodeScaleFactor : @(scale)}];
                    break;
                }
            }
        }
        if (!animatedCoder) {
            return self;
        }
        _coder = animatedCoder;
        SDImageFormat format = [NSData sd_imageFormatForImageData:animatedImageData];
        _animatedImageFormat = format;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [super encodeWithCoder:aCoder];
    NSData *animatedImageData = self.animatedImageData;
    if (animatedImageData) {
        [aCoder encodeObject:animatedImageData forKey:NSStringFromSelector(@selector(animatedImageData))];
    }
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

#pragma mark - SDAnimatedImage

- (NSData *)animatedImageData {
    return [self.coder animatedImageData];
}

- (NSUInteger)animatedImageLoopCount {
    return [self.coder animatedImageLoopCount];
}

- (NSUInteger)animatedImageFrameCount {
    return [self.coder animatedImageFrameCount];
}

- (UIImage *)animatedImageFrameAtIndex:(NSUInteger)index {
    if (index >= self.animatedImageFrameCount) {
        return nil;
    }
    if (self.isAllFramesLoaded) {
        SDImageFrame *frame = [self.loadedAnimatedImageFrames objectAtIndex:index];
        return frame.image;
    }
    return [self.coder animatedImageFrameAtIndex:index];
}

- (NSTimeInterval)animatedImageDurationAtIndex:(NSUInteger)index {
    if (index >= self.animatedImageFrameCount) {
        return 0;
    }
    if (self.isAllFramesLoaded) {
        SDImageFrame *frame = [self.loadedAnimatedImageFrames objectAtIndex:index];
        return frame.duration;
    }
    return [self.coder animatedImageDurationAtIndex:index];
}

@end

@implementation SDAnimatedImage (MemoryCacheCost)

- (NSUInteger)sd_memoryCost {
    NSNumber *value = objc_getAssociatedObject(self, @selector(sd_memoryCost));
    if (value != nil) {
        return value.unsignedIntegerValue;
    }
    
    CGImageRef imageRef = self.CGImage;
    if (!imageRef) {
        return 0;
    }
    NSUInteger bytesPerFrame = CGImageGetBytesPerRow(imageRef) * CGImageGetHeight(imageRef);
    NSUInteger frameCount = 1;
    if (self.isAllFramesLoaded) {
        frameCount = self.animatedImageFrameCount;
    }
    frameCount = frameCount > 0 ? frameCount : 1;
    NSUInteger cost = bytesPerFrame * frameCount;
    return cost;
}

@end
