#import "PDWebSocket.h"
#import <CommonCrypto/CommonDigest.h>
#include <stdlib.h>

static NSString *PDBase64(const uint8_t *bytes, NSUInteger len) {
	static const char *t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	NSMutableString *out = [NSMutableString string];
	for (NSUInteger i = 0; i < len; i += 3) {
		uint32_t v = (uint32_t)bytes[i] << 16;
		if (i + 1 < len) v |= (uint32_t)bytes[i + 1] << 8;
		if (i + 2 < len) v |= bytes[i + 2];
		[out appendFormat:@"%c%c%c%c", t[(v >> 18) & 63], t[(v >> 12) & 63],
			i + 1 < len ? t[(v >> 6) & 63] : '=', i + 2 < len ? t[v & 63] : '='];
	}
	return out;
}

enum { PDOpText = 0x1, PDOpBinary = 0x2, PDOpClose = 0x8, PDOpPing = 0x9, PDOpPong = 0xA, PDOpCont = 0x0 };

@interface PDWebSocket () <NSStreamDelegate>
@property (nonatomic, copy) NSString *host, *path, *key;
@property (nonatomic, assign) int port;
@property (nonatomic, strong) NSInputStream *input;
@property (nonatomic, strong) NSOutputStream *output;
@property (nonatomic, strong) NSMutableData *readBuf, *writeBuf, *fragment;
@property (nonatomic, assign) BOOL handshakeDone, closed;
@property (nonatomic, readwrite) BOOL isOpen;
@property (nonatomic, strong) NSTimer *openTimeout;
@end

@implementation PDWebSocket

- (id)initWithHost:(NSString *)host port:(int)port path:(NSString *)path {
	if ((self = [super init])) {
		_host = [host copy];
		_port = port;
		_path = [path length] ? [path copy] : @"/";
		_readBuf = [NSMutableData data];
		_writeBuf = [NSMutableData data];
	}
	return self;
}

- (void)dealloc { [self teardown]; }

- (void)open {
	CFReadStreamRef r = NULL;
	CFWriteStreamRef w = NULL;
	CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)self.host, (UInt32)self.port, &r, &w);
	if (!r || !w) {
		if (r) CFRelease(r);
		if (w) CFRelease(w);
		[self failWithReason:@"could not create socket"];
		return;
	}
	self.input = (__bridge_transfer NSInputStream *)r;
	self.output = (__bridge_transfer NSOutputStream *)w;
	for (NSStream *s in [NSArray arrayWithObjects:self.input, self.output, nil]) {
		s.delegate = self;
		[s scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		[s open];
	}
	uint8_t nonce[16];
	for (int i = 0; i < 16; i++) nonce[i] = (uint8_t)arc4random();
	self.key = PDBase64(nonce, 16);
	NSString *req = [NSString stringWithFormat:
		@"GET %@ HTTP/1.1\r\nHost: %@:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
		@"Sec-WebSocket-Key: %@\r\nSec-WebSocket-Version: 13\r\n\r\n", self.path, self.host, self.port, self.key];
	[self.writeBuf appendData:[req dataUsingEncoding:NSUTF8StringEncoding]];
	self.openTimeout = [NSTimer scheduledTimerWithTimeInterval:8 target:self selector:@selector(timedOut) userInfo:nil repeats:NO];
}

- (void)timedOut { if (!self.handshakeDone) [self failWithReason:@"connection timed out"]; }

- (void)sendText:(NSString *)text {
	if (!self.isOpen) return;
	[self sendFrame:PDOpText payload:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)sendFrame:(uint8_t)op payload:(NSData *)payload {
	NSUInteger n = [payload length];
	NSMutableData *f = [NSMutableData dataWithCapacity:n + 14];
	uint8_t h[10];
	h[0] = 0x80 | op;
	NSUInteger hl;
	if (n < 126) { h[1] = 0x80 | (uint8_t)n; hl = 2; }
	else if (n <= 0xFFFF) { h[1] = 0x80 | 126; h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; hl = 4; }
	else { h[1] = 0x80 | 127; for (int i = 0; i < 8; i++) h[2 + i] = (uint8_t)((uint64_t)n >> (56 - 8 * i)); hl = 10; }
	[f appendBytes:h length:hl];
	uint8_t mask[4];
	for (int i = 0; i < 4; i++) mask[i] = (uint8_t)arc4random();
	[f appendBytes:mask length:4];
	NSUInteger start = [f length];
	[f appendData:payload];
	uint8_t *p = (uint8_t *)[f mutableBytes] + start;
	for (NSUInteger i = 0; i < n; i++) p[i] ^= mask[i & 3];
	[self.writeBuf appendData:f];
	[self flush];
}

- (void)flush {
	while ([self.writeBuf length] && [self.output hasSpaceAvailable]) {
		NSInteger w = [self.output write:[self.writeBuf bytes] maxLength:[self.writeBuf length]];
		if (w <= 0) break;
		[self.writeBuf replaceBytesInRange:NSMakeRange(0, (NSUInteger)w) withBytes:NULL length:0];
	}
}

- (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)ev {
	if (self.closed) return;
	switch (ev) {
		case NSStreamEventHasSpaceAvailable: [self flush]; break;
		case NSStreamEventHasBytesAvailable: {
			uint8_t buf[16384];
			while ([self.input hasBytesAvailable]) {
				NSInteger r = [self.input read:buf maxLength:sizeof buf];
				if (r <= 0) break;
				[self.readBuf appendBytes:buf length:(NSUInteger)r];
			}
			[self process];
			break;
		}
		case NSStreamEventErrorOccurred:
			[self failWithReason:[[s streamError] localizedDescription] ?: @"network error"];
			break;
		case NSStreamEventEndEncountered:
			[self failWithReason:@"printer closed the connection"];
			break;
		default: break;
	}
}

- (void)process {
	if (!self.handshakeDone) {
		NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
		NSRange r = [self.readBuf rangeOfData:sep options:0 range:NSMakeRange(0, [self.readBuf length])];
		if (r.location == NSNotFound) {
			if ([self.readBuf length] > 8192) [self failWithReason:@"bad handshake"];
			return;
		}
		NSString *hdr = [[NSString alloc] initWithData:[self.readBuf subdataWithRange:NSMakeRange(0, r.location)] encoding:NSISOLatin1StringEncoding];
		[self.readBuf replaceBytesInRange:NSMakeRange(0, NSMaxRange(r)) withBytes:NULL length:0];
		if ([hdr rangeOfString:@" 101 "].location == NSNotFound) {
			[self failWithReason:[[hdr componentsSeparatedByString:@"\r\n"] objectAtIndex:0]];
			return;
		}
		// Check Sec-WebSocket-Accept = base64(sha1(key + GUID)).
		NSString *magic = [self.key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
		NSData *md = [magic dataUsingEncoding:NSASCIIStringEncoding];
		uint8_t digest[CC_SHA1_DIGEST_LENGTH];
		CC_SHA1([md bytes], (CC_LONG)[md length], digest);
		NSString *expect = PDBase64(digest, CC_SHA1_DIGEST_LENGTH);
		if ([hdr rangeOfString:expect].location == NSNotFound) { [self failWithReason:@"bad websocket accept key"]; return; }
		self.handshakeDone = YES;
		self.isOpen = YES;
		[self.openTimeout invalidate];
		self.openTimeout = nil;
		[self.delegate webSocketDidOpen:self];
		if (self.closed) return;
	}
	while (!self.closed) {
		NSUInteger have = [self.readBuf length];
		const uint8_t *b = [self.readBuf bytes];
		if (have < 2) return;
		BOOL fin = (b[0] & 0x80) != 0;
		uint8_t op = b[0] & 0x0F;
		BOOL masked = (b[1] & 0x80) != 0;
		uint64_t n = b[1] & 0x7F;
		NSUInteger off = 2;
		if (n == 126) { if (have < 4) return; n = ((uint64_t)b[2] << 8) | b[3]; off = 4; }
		else if (n == 127) {
			if (have < 10) return;
			n = 0;
			for (int i = 0; i < 8; i++) n = (n << 8) | b[2 + i];
			off = 10;
		}
		if (n > 16 * 1024 * 1024) { [self failWithReason:@"message too large"]; return; }
		uint8_t mask[4] = {0, 0, 0, 0};
		if (masked) { if (have < off + 4) return; memcpy(mask, b + off, 4); off += 4; }
		if (have < off + n) return;
		NSMutableData *payload = [NSMutableData dataWithBytes:b + off length:(NSUInteger)n];
		if (masked) { uint8_t *p = [payload mutableBytes]; for (NSUInteger i = 0; i < n; i++) p[i] ^= mask[i & 3]; }
		[self.readBuf replaceBytesInRange:NSMakeRange(0, off + (NSUInteger)n) withBytes:NULL length:0];
		[self handleOp:op fin:fin payload:payload];
	}
}

- (void)handleOp:(uint8_t)op fin:(BOOL)fin payload:(NSData *)payload {
	switch (op) {
		case PDOpPing: [self sendFrame:PDOpPong payload:payload]; return;
		case PDOpPong: return;
		case PDOpClose: [self failWithReason:@"printer closed the connection"]; return;
		case PDOpText: case PDOpBinary:
			self.fragment = [NSMutableData dataWithData:payload];
			break;
		case PDOpCont:
			if (!self.fragment) return;
			[self.fragment appendData:payload];
			break;
		default: return;
	}
	if (!fin) return;
	NSString *text = [[NSString alloc] initWithData:self.fragment encoding:NSUTF8StringEncoding];
	self.fragment = nil;
	if (text) [self.delegate webSocket:self didReceiveText:text];
}

- (void)failWithReason:(NSString *)reason {
	if (self.closed) return;
	[self teardown];
	[self.delegate webSocket:self didCloseWithReason:reason];
}

- (void)close {
	if (self.closed) return;
	if (self.isOpen) {
		[self sendFrame:PDOpClose payload:[NSData data]];
	}
	[self teardown];
}

- (void)teardown {
	self.closed = YES;
	self.isOpen = NO;
	[self.openTimeout invalidate];
	self.openTimeout = nil;
	for (NSStream *s in [NSArray arrayWithObjects:self.input ?: (id)[NSNull null], self.output ?: (id)[NSNull null], nil]) {
		if ((id)s == [NSNull null]) continue;
		s.delegate = nil;
		[s removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		[s close];
	}
	self.input = nil;
	self.output = nil;
}

@end
