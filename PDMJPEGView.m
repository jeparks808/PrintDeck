#import "PDMJPEGView.h"
#import "PDUtil.h"

@interface PDMJPEGView () <NSURLConnectionDataDelegate>
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *placeholder;
@property (nonatomic, strong) NSURLConnection *conn;
@property (nonatomic, strong) NSMutableData *buf;
@property (nonatomic, assign) BOOL decoding, running;
@property (nonatomic, readwrite) BOOL hasFrame;
@property (nonatomic, readwrite) double fps;
@property (nonatomic, assign) NSUInteger framesThisSecond;
@property (nonatomic, assign) CFAbsoluteTime fpsStart, lastData;
@property (nonatomic, strong) NSTimer *watchdog;
@end

@implementation PDMJPEGView

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor blackColor];
		self.clipsToBounds = YES;
		_imageView = [[UIImageView alloc] initWithFrame:self.bounds];
		_imageView.contentMode = UIViewContentModeScaleAspectFill;
		_imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self addSubview:_imageView];
		_placeholder = PDLabel([UIFont systemFontOfSize:16], PD_DIM);
		_placeholder.textAlignment = NSTextAlignmentCenter;
		_placeholder.text = @"Camera connecting…";
		_placeholder.frame = self.bounds;
		_placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self addSubview:_placeholder];
	}
	return self;
}

- (void)setUrl:(NSURL *)url {
	if ((url == nil && _url == nil) || [url isEqual:_url]) return;
	_url = [url copy];
	[self stop];
	if (url) [self start];
}

- (void)start {
	if (!self.url || self.running) return;
	self.running = YES;
	[self connect];
	self.watchdog = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(checkAlive) userInfo:nil repeats:YES];
}

- (void)stop {
	self.running = NO;
	[self.watchdog invalidate];
	self.watchdog = nil;
	[self.conn cancel];
	self.conn = nil;
	self.buf = nil;
}

- (void)connect {
	[self.conn cancel];
	self.buf = [NSMutableData data];
	self.lastData = CFAbsoluteTimeGetCurrent();
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
	self.conn = [[NSURLConnection alloc] initWithRequest:req delegate:self startImmediately:NO];
	[self.conn scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	[self.conn start];
}

// No data for 6 s (stream stalled, printer rebooted, Wi-Fi blip): reconnect.
- (void)checkAlive {
	if (!self.running) return;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - self.fpsStart >= 2) {
		self.fps = self.framesThisSecond / (now - self.fpsStart);
		self.framesThisSecond = 0;
		self.fpsStart = now;
	}
	if (now - self.lastData > 6) {
		self.placeholder.text = @"Camera reconnecting…";
		self.placeholder.hidden = NO;
		self.imageView.alpha = 0.35;
		[self connect];
	}
}

- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)data {
	self.lastData = CFAbsoluteTimeGetCurrent();
	[self.buf appendData:data];
	// Cut complete JPEGs (FFD8 ... FFD9) out of the buffer; keep only the newest one.
	NSData *latest = nil;
	for (;;) {
		const uint8_t *b = [self.buf bytes];
		NSUInteger n = [self.buf length], s = NSNotFound, e = NSNotFound;
		for (NSUInteger i = 0; i + 1 < n; i++) if (b[i] == 0xFF && b[i + 1] == 0xD8) { s = i; break; }
		if (s == NSNotFound) { if (n > 1) [self.buf replaceBytesInRange:NSMakeRange(0, n - 1) withBytes:NULL length:0]; break; }
		for (NSUInteger i = s + 2; i + 1 < n; i++) if (b[i] == 0xFF && b[i + 1] == 0xD9) { e = i + 2; break; }
		if (e == NSNotFound) {
			if (s > 0) [self.buf replaceBytesInRange:NSMakeRange(0, s) withBytes:NULL length:0];
			if ([self.buf length] > 2 * 1024 * 1024) [self.buf setLength:0]; // garbage; resync
			break;
		}
		latest = [self.buf subdataWithRange:NSMakeRange(s, e - s)];
		[self.buf replaceBytesInRange:NSMakeRange(0, e) withBytes:NULL length:0];
	}
	if (latest && !self.decoding) [self decode:latest];
}

- (void)decode:(NSData *)jpeg {
	self.decoding = YES;
	CGSize target = self.bounds.size;
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		UIImage *img = [UIImage imageWithData:jpeg];
		UIImage *drawn = nil;
		if (img) {
			// Decode now (UIImage decodes lazily on the main thread otherwise), at display size.
			CGFloat scale = MAX(target.width / img.size.width, target.height / img.size.height);
			if (scale > 1 || scale <= 0) scale = 1;
			CGSize sz = CGSizeMake(floor(img.size.width * scale), floor(img.size.height * scale));
			UIGraphicsBeginImageContextWithOptions(sz, YES, 1.0);
			[img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
			drawn = UIGraphicsGetImageFromCurrentImageContext();
			UIGraphicsEndImageContext();
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			self.decoding = NO;
			if (!drawn || !self.running) return;
			self.imageView.image = drawn;
			self.imageView.alpha = 1;
			self.placeholder.hidden = YES;
			self.hasFrame = YES;
			self.framesThisSecond++;
		});
	});
}

- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)error {
	self.placeholder.text = @"Camera unavailable — retrying";
	self.placeholder.hidden = NO;
	self.imageView.alpha = 0.35;
	self.lastData = CFAbsoluteTimeGetCurrent() - 4; // watchdog retries in ~2 s
}

- (void)connectionDidFinishLoading:(NSURLConnection *)c {
	self.lastData = CFAbsoluteTimeGetCurrent() - 4;
}

@end
