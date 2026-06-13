#pragma once

#ifdef __OBJC__

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

@class AVPlayer;
@class AVPlayerItem;

typedef void (^SMMotionOnlineProgressHandler)(NSDictionary<NSString*, id>* status);

@interface SMMotionOnlineProcessor : NSObject

@property(atomic, assign, getter=isRunning) BOOL running;

- (void)startCaptureWithRect:(CGRect)rect
                   targetFPS:(double)targetFPS
                  flowHeight:(uint32_t)flowHeight
                  gpuBudgetMs:(double)gpuBudgetMs
               frameMultiple:(double)frameMultiple
                   modelMode:(NSString*)modelMode
             settingsSummary:(NSString*)settingsSummary
                  outputLayer:(CAMetalLayer*)outputLayer
                    progress:(SMMotionOnlineProgressHandler)progress;

- (void)startLocalPlaybackWithPlayer:(AVPlayer*)player
                                 item:(AVPlayerItem*)item
                            targetFPS:(double)targetFPS
                           flowHeight:(uint32_t)flowHeight
                          gpuBudgetMs:(double)gpuBudgetMs
                        frameMultiple:(double)frameMultiple
                            modelMode:(NSString*)modelMode
                      settingsSummary:(NSString*)settingsSummary
                          outputLayer:(CAMetalLayer*)outputLayer
                             progress:(SMMotionOnlineProgressHandler)progress;

- (void)stop;

@end

#endif
