#import "PDScreenMirrorView.h"
#import "PDUtil.h"

static const int PDMirrorPort = 8091;

@interface PDScreenMirrorView ()
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *placeholder;
@property (nonatomic, copy) NSString *etag;
@property (nonatomic, assign) NSUInteger gen;          // bumped on every start/stop: stale replies are dropped
@property (nonatomic, readwrite) BOOL available;
@property (nonatomic, assign) CGSize screen;           // printer pixels (480 x 272)
@property (nonatomic, strong) NSMutableArray *touchQueue;   // sent one at a time, in order
@property (nonatomic, assign) BOOL touchBusy;
@property (nonatomic, assign) CFAbsoluteTime lastMove;
@end

@implementation PDScreenMirrorView

+ (int)port { return PDMirrorPort; }

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor blackColor];
		self.clipsToBounds = YES;
		self.multipleTouchEnabled = NO;
		_screen = CGSizeMake(480, 272);
		_touchQueue = [NSMutableArray array];
		_imageView = [[UIImageView alloc] initWithFrame:self.bounds];
		_imageView.contentMode = UIViewContentModeScaleToFill;   // the view is laid out at the screen's own shape
		_imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self addSubview:_imageView];
		_placeholder = PDLabel([UIFont systemFontOfSize:15], PD_DIM);
		_placeholder.textAlignment = NSTextAlignmentCenter;
		_placeholder.numberOfLines = 0;
		_placeholder.frame = CGRectInset(self.bounds, 16, 0);
		_placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self addSubview:_placeholder];
	}
	return self;
}

- (void)setHost:(NSString *)host {
	if (host == _host || [host isEqualToString:_host]) return;
	_host = [host copy];
	self.gen++;
	self.etag = nil;
	[self.touchQueue removeAllObjects];
	self.touchBusy = NO;
	if (!_host) return;
	self.placeholder.text = @"Connecting to the printer's screen…";
	self.placeholder.hidden = NO;
	[self fetch];
}

- (NSURL *)url:(NSString *)pathAndQuery {
	return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%d%@", self.host, PDMirrorPort, pathAndQuery]];
}

// One request at a time: with the last frame's tag the service holds the request until the screen changes (up to 4 s).
- (void)fetch {
	if (!self.host) return;
	NSUInteger gen = self.gen;
	NSString *q = self.etag ? [@"/screen.png?after=" stringByAppendingString:self.etag] : @"/screen.png";
	NSURLRequest *req = [NSURLRequest requestWithURL:[self url:q] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
	[NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
		if (gen != self.gen) return;
		NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)r statusCode] : 0;
		if (code == 200 && [d length]) {
			UIImage *img = [UIImage imageWithData:d];
			if (img) {
				self.imageView.image = img;
				self.screen = img.size;
				self.placeholder.hidden = YES;
				self.available = YES;
			}
			self.etag = nil;
			NSDictionary *h = [(NSHTTPURLResponse *)r allHeaderFields];
			for (NSString *k in h) if ([k caseInsensitiveCompare:@"ETag"] == NSOrderedSame) self.etag = [h objectForKey:k];
			[self fetch];
		} else if (code == 304) {
			[self fetch];
		} else {
			// Not installed, or the printer is away: say so and try again in a while.
			self.available = NO;
			self.etag = nil;
			self.imageView.image = nil;
			self.placeholder.hidden = NO;
			self.placeholder.text = code == 0
				? @"The printer's screen isn't answering.\n\nOn COSMOS, install PrintDeck's screen mirror on the printer:\ntools/screen-mirror/install.sh <printer-ip>"
				: [NSString stringWithFormat:@"The screen mirror answered %ld.", (long)code];
			[self performSelector:@selector(retry:) withObject:[NSNumber numberWithUnsignedInteger:gen] afterDelay:5];
		}
	}];
}

- (void)retry:(NSNumber *)gen { if ([gen unsignedIntegerValue] == self.gen) [self fetch]; }

#pragma mark Touch

- (CGPoint)screenPoint:(UITouch *)t {
	CGPoint p = [t locationInView:self];
	CGSize b = self.bounds.size;
	return CGPointMake(MAX(0, MIN(self.screen.width - 1, p.x / MAX(1, b.width) * self.screen.width)),
	                   MAX(0, MIN(self.screen.height - 1, p.y / MAX(1, b.height) * self.screen.height)));
}

- (void)queue:(NSString *)action at:(CGPoint)p {
	if (!self.available) return;
	// Moves only matter as the latest position: replace a waiting move instead of piling them up.
	NSDictionary *last = [self.touchQueue lastObject];
	if ([action isEqualToString:@"move"] && [[last objectForKey:@"a"] isEqualToString:@"move"]) [self.touchQueue removeLastObject];
	[self.touchQueue addObject:@{@"a": action, @"x": @(lround(p.x)), @"y": @(lround(p.y))}];
	[self sendTouches];
}

- (void)sendTouches {
	if (self.touchBusy || ![self.touchQueue count] || !self.host) return;
	NSDictionary *t = [self.touchQueue objectAtIndex:0];
	[self.touchQueue removeObjectAtIndex:0];
	self.touchBusy = YES;
	NSUInteger gen = self.gen;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self url:[NSString stringWithFormat:@"/touch?a=%@&x=%@&y=%@",
		[t objectForKey:@"a"], [t objectForKey:@"x"], [t objectForKey:@"y"]]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
	req.HTTPMethod = @"POST";
	[NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
		if (gen != self.gen) return;
		self.touchBusy = NO;
		[self sendTouches];
	}];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
	[self queue:@"down" at:[self screenPoint:[touches anyObject]]];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - self.lastMove < 0.05) return;   // ~20 a second is plenty for scrolling a list
	self.lastMove = now;
	[self queue:@"move" at:[self screenPoint:[touches anyObject]]];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
	[self queue:@"up" at:[self screenPoint:[touches anyObject]]];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
	[self queue:@"up" at:[self screenPoint:[touches anyObject]]];
}

@end
