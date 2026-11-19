#import <Foundation/Foundation.h>

// Minimal RFC 6455 websocket client for iOS 5 (plain ws:// only, no TLS). iOS 5 has no websocket API for
// apps, and Safari 5.1 only speaks the old hixie-76 draft, so this does the handshake and framing itself
// over CFStream sockets. Text messages only (what SDCP uses); answers pings; runs on the main run loop.
@class PDWebSocket;

@protocol PDWebSocketDelegate <NSObject>
- (void)webSocketDidOpen:(PDWebSocket *)ws;
- (void)webSocket:(PDWebSocket *)ws didReceiveText:(NSString *)text;
- (void)webSocket:(PDWebSocket *)ws didCloseWithReason:(NSString *)reason;
@end

@interface PDWebSocket : NSObject
@property (nonatomic, weak) id<PDWebSocketDelegate> delegate;
@property (nonatomic, readonly) BOOL isOpen;
- (id)initWithHost:(NSString *)host port:(int)port path:(NSString *)path;
- (void)open;
- (void)sendText:(NSString *)text;
- (void)close;   // no delegate callback after this
@end
