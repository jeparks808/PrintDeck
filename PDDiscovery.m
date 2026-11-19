#import "PDDiscovery.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

@interface PDDiscovery ()
@property (nonatomic, assign) int fd;
@property (nonatomic, assign) dispatch_source_t reader; // iOS 5: dispatch objects are not ObjC objects, so manual release
@property (nonatomic, strong) NSTimer *resend, *finish;
@property (nonatomic, copy) void (^found)(NSDictionary *);
@property (nonatomic, copy) void (^done)(void);
@end

@implementation PDDiscovery

- (id)init { if ((self = [super init])) _fd = -1; return self; }
- (void)dealloc { [self stop]; }

- (void)searchForSeconds:(NSTimeInterval)seconds found:(void (^)(NSDictionary *))found done:(void (^)(void))done {
	[self stop];
	self.found = found;
	self.done = done;
	int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (fd < 0) { if (done) done(); return; }
	int yes = 1;
	setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof yes);
	fcntl(fd, F_SETFL, O_NONBLOCK);
	self.fd = fd;
	dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
	__weak PDDiscovery *weakSelf = self;
	dispatch_source_set_event_handler(src, ^{ [weakSelf readReplies]; });
	dispatch_resume(src);
	self.reader = src;
	[self broadcast];
	self.resend = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(broadcast) userInfo:nil repeats:YES];
	self.finish = [NSTimer scheduledTimerWithTimeInterval:seconds target:self selector:@selector(timeUp) userInfo:nil repeats:NO];
}

- (void)broadcast {
	if (self.fd < 0) return;
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_len = sizeof a;
	a.sin_family = AF_INET;
	a.sin_port = htons(3000);
	a.sin_addr.s_addr = htonl(INADDR_BROADCAST);
	sendto(self.fd, "M99999", 6, 0, (struct sockaddr *)&a, sizeof a);
}

- (void)readReplies {
	char buf[8192];
	for (;;) {
		struct sockaddr_in from;
		socklen_t fl = sizeof from;
		ssize_t n = recvfrom(self.fd, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
		if (n <= 0) break;
		NSData *d = [NSData dataWithBytes:buf length:(NSUInteger)n];
		id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
		if (![json isKindOfClass:[NSDictionary class]]) continue;
		NSMutableDictionary *info = [NSMutableDictionary dictionary];
		id inner = [json objectForKey:@"Data"];
		if ([inner isKindOfClass:[NSDictionary class]]) [info addEntriesFromDictionary:inner];
		else [info addEntriesFromDictionary:json];
		if (![info objectForKey:@"MainboardIP"])
			[info setObject:[NSString stringWithUTF8String:inet_ntoa(from.sin_addr)] forKey:@"MainboardIP"];
		if (self.found) self.found(info);
	}
}

- (void)timeUp {
	void (^done)(void) = self.done;
	[self stop];
	if (done) done();
}

- (void)stop {
	[self.resend invalidate];
	[self.finish invalidate];
	self.resend = nil;
	self.finish = nil;
	if (self.reader) {
		int fd = self.fd;
		dispatch_source_set_cancel_handler(self.reader, ^{ close(fd); });
		dispatch_source_cancel(self.reader);
		dispatch_release(self.reader);
		self.reader = NULL;
	} else if (self.fd >= 0) {
		close(self.fd);
	}
	self.fd = -1;
	self.found = nil;
	self.done = nil;
}

@end
