#pragma once

#ifdef __OBJC__

#import <Foundation/Foundation.h>

typedef void (^SMMotionOfflineProgressHandler)(double progress, NSString* status);
typedef void (^SMMotionOfflineCompletionHandler)(BOOL success, NSString* message);

@interface SMMotionOfflineProcessor : NSObject

@property(atomic, assign, getter=isCancelled) BOOL cancelled;
@property(atomic, assign) double maxDurationSeconds;
@property(atomic, assign) BOOL includeAudio;

- (void)startExportFromURL:(NSURL*)inputURL
                     toURL:(NSURL*)outputURL
                   upscale:(double)upscale
                 targetFPS:(double)targetFPS
                  progress:(SMMotionOfflineProgressHandler)progress
                completion:(SMMotionOfflineCompletionHandler)completion;

- (void)cancel;

@end

#endif
