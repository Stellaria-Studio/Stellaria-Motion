#pragma once

#ifdef __OBJC__

#import <Foundation/Foundation.h>

typedef void (^SMBrowserStreamBridgeProgress)(NSDictionary<NSString*, id>* status);

@interface SMBrowserStreamBridge : NSObject

@property(atomic, assign, readonly, getter=isRunning) BOOL running;
@property(atomic, assign, readonly, getter=isClientConnected) BOOL clientConnected;
@property(atomic, assign, readonly) uint16_t port;

- (BOOL)startWithPort:(uint16_t)port progress:(SMBrowserStreamBridgeProgress)progress;
- (void)stop;
- (NSDictionary<NSString*, id>*)snapshot;

@end

#endif
