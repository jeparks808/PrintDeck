#import "PDFilesCard.h"
#import "PDPrinter.h"
#import "PDToolpath.h"
#import "PDToolpathView.h"
#import "PDUtil.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const PDFilesSelectedKey = @"PDFilesCardSelected";
NSString *const PDFilesSelectionNotification = @"PDFilesSelectionNotification";

@interface PDFilesCard () <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) PDToolpathView *viewer;
@property (nonatomic, strong) UILabel *nameLabel, *infoLabel, *msgLabel;
@property (nonatomic, strong) UIButton *printButton, *retryButton, *inspectButton, *sliceButton;
@property (nonatomic, copy) NSString *selectedPath;
@property (nonatomic, strong) NSMutableDictionary *thumbs;     // file path -> 36 pt UIImage, or NSNull (none / loading)
@property (nonatomic) int thumbLoads;                          // thumbnails being fetched (a few at a time)
@end

@implementation PDFilesCard

// The remembered selection is per printer address, so trying the simulator doesn't forget the real printer's.
+ (NSString *)selectionKey { return [NSString stringWithFormat:@"%@.%@", PDFilesSelectedKey, [PDPrinter shared].host ?: @""]; }
+ (NSString *)selectedPath { return [[NSUserDefaults standardUserDefaults] stringForKey:[self selectionKey]]; }
+ (void)setSelectedPath:(NSString *)path {
	if ((!path && ![self selectedPath]) || [path isEqualToString:[self selectedPath]]) return;
	if (path) [[NSUserDefaults standardUserDefaults] setObject:path forKey:[self selectionKey]];
	else [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self selectionKey]];
	[[NSNotificationCenter defaultCenter] postNotificationName:PDFilesSelectionNotification object:nil];
	[self loadSelected];
}
+ (void)loadSelected {
	PDPrinter *p = [PDPrinter shared];
	NSString *path = [self selectedPath];
	if (!path || !p.connected) return;
	[[PDToolpathLoader loaderForSlot:@"files"] loadPath:path url:[p urlForFile:path] size:[p sizeOfFile:path]];
}

- (PDToolpathLoader *)loader { return [PDToolpathLoader loaderForSlot:@"files"]; }

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.titleLabel.text = @"FILES";
		self.tappable = NO;
		_table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
		_table.backgroundColor = [UIColor clearColor];
		_table.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
		_table.rowHeight = 46;
		_thumbs = [NSMutableDictionary dictionary];
		_table.dataSource = self; _table.delegate = self;
		[self addSubview:_table];

		_viewer = [[PDToolpathView alloc] initWithFrame:CGRectMake(0, 0, 280, 160)];
		_viewer.layer.cornerRadius = 8;
		_viewer.clipsToBounds = YES;
		_viewer.currentLayer = -1;
		[self addSubview:_viewer];
		_nameLabel = PDLabel([UIFont boldSystemFontOfSize:13], [UIColor whiteColor]);
		_nameLabel.shadowColor = [UIColor blackColor]; _nameLabel.shadowOffset = CGSizeMake(0, 1);
		_infoLabel = PDLabel([UIFont systemFontOfSize:11], PD_DIM);
		_msgLabel = PDLabel([UIFont systemFontOfSize:14], PD_DIM);
		_msgLabel.textAlignment = NSTextAlignmentCenter;
		_msgLabel.numberOfLines = 3;
		_printButton = PDButton(@"Print", PD_GREEN);
		_printButton.titleLabel.font = PDBoldFont(14);
		[_printButton addTarget:self action:@selector(confirmPrint) forControlEvents:UIControlEventTouchUpInside];
		_retryButton = PDButton(@"Retry", PD_ACCENT);
		_retryButton.titleLabel.font = PDBoldFont(14);
		[_retryButton addTarget:self action:@selector(retry) forControlEvents:UIControlEventTouchUpInside];
		_inspectButton = PDButton(@"Inspect", PD_ACCENT);
		_inspectButton.titleLabel.font = PDBoldFont(14);
		[_inspectButton addTarget:self action:@selector(inspect) forControlEvents:UIControlEventTouchUpInside];
		_sliceButton = PDButton(@"Slice…", PD_ACCENT);
		_sliceButton.titleLabel.font = PDBoldFont(13);
		[_sliceButton addTarget:self action:@selector(slice) forControlEvents:UIControlEventTouchUpInside];
		for (UIView *v in [NSArray arrayWithObjects:_nameLabel, _infoLabel, _msgLabel, _printButton, _retryButton, _inspectButton, _sliceButton, nil]) [self addSubview:v];

		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserver:self selector:@selector(filesChanged) name:PDPrinterFilesNotification object:[PDPrinter shared]];
		[nc addObserver:self selector:@selector(update) name:PDToolpathNotification object:[self loader]];
		[nc addObserver:self selector:@selector(selectionChanged) name:PDFilesSelectionNotification object:nil];
		[self update];
	}
	return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (NSDictionary *)fileNamed:(NSString *)path {
	for (NSDictionary *f in [PDPrinter shared].files) if ([PDStr(f, @"name") isEqualToString:path]) return f;
	return nil;
}

- (void)inspect { if (self.openDetail) self.openDetail(); }
- (void)slice { if (self.openSlice) self.openSlice(); }

// Picked here or on the File page: follow it (row highlight, preview).
- (void)selectionChanged {
	NSString *sel = [PDFilesCard selectedPath];
	if ((sel || self.selectedPath) && ![sel isEqualToString:self.selectedPath]) { self.selectedPath = sel; [self.viewer resetView]; }
	[self.table deselectRowAtIndexPath:[self.table indexPathForSelectedRow] animated:NO];
	[self selectRowForSelected];
	[self update];
}

- (void)filesChanged {
	NSString *remembered = [PDFilesCard selectedPath];
	if ((remembered || self.selectedPath) && ![remembered isEqualToString:self.selectedPath]) { self.selectedPath = remembered; [self.viewer resetView]; }
	[self.table reloadData];
	NSArray *files = [PDPrinter shared].files;
	self.titleLabel.text = [files count] ? [NSString stringWithFormat:@"FILES · %u", (unsigned)[files count]] : @"FILES";
	// The remembered selection: show it (from the cache, usually) once the printer confirms it's still there.
	if (self.selectedPath && [self fileNamed:self.selectedPath]) [PDFilesCard loadSelected];
	else if (self.selectedPath && files) { self.selectedPath = nil; [PDFilesCard setSelectedPath:nil]; }
	[self selectRowForSelected];
	[self update];
}

- (void)selectRowForSelected {
	NSArray *files = [PDPrinter shared].files;
	for (NSUInteger i = 0; i < [files count]; i++)
		if ([PDStr([files objectAtIndex:i], @"name") isEqualToString:self.selectedPath]) {
			[self.table selectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:0] animated:NO scrollPosition:UITableViewScrollPositionMiddle];
			return;
		}
}

- (void)retry {
	PDToolpathLoader *L = [self loader];
	if ([L.requestedPath isEqualToString:self.selectedPath]) [L reload]; else [PDFilesCard loadSelected];
}

- (void)refresh {
	PDPrinter *p = [PDPrinter shared];
	BOOL can = p.connected && !p.isBusy && !p.machineBusy && [self fileNamed:self.selectedPath] != nil;
	self.printButton.enabled = can;
	self.printButton.alpha = can ? 1 : 0.4;
	self.inspectButton.hidden = !self.selectedPath;
}

- (void)update {
	PDToolpathLoader *L = [self loader];
	PDToolpath *tp = [L.toolpath.path isEqualToString:self.selectedPath] ? L.toolpath : nil;
	self.viewer.toolpath = tp;
	self.viewer.doneLayers = tp ? (NSInteger)tp.layerCount : 0;
	NSString *msg = @"";
	BOOL retry = NO;
	if (!self.selectedPath) msg = [[PDPrinter shared].files count] ? @"Tap a file to preview it in 3D." : @"";
	else if ([L.loadingPath isEqualToString:self.selectedPath])
		msg = L.progress > 0.01 ? [NSString stringWithFormat:@"Loading… %.0f%%", L.progress * 100] : @"Loading…";
	else if (!tp && L.error && [L.requestedPath isEqualToString:self.selectedPath]) { msg = L.error; retry = YES; }
	self.msgLabel.text = msg;
	self.msgLabel.hidden = ![msg length];
	self.retryButton.hidden = !retry;
	self.nameLabel.text = self.selectedPath ? PDPrettyFileName(self.selectedPath) : @"";
	self.infoLabel.text = tp ? [NSString stringWithFormat:@"%u layers · %.1f mm tall", (unsigned)tp.layerCount, tp.maxZ] : @"";
	[self refresh];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return MAX(1, (NSInteger)[[PDPrinter shared].files count]); }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"f"];
	if (!c) {
		c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
		c.backgroundColor = [UIColor clearColor];
		c.textLabel.font = [UIFont boldSystemFontOfSize:15];
		c.textLabel.textColor = [UIColor whiteColor];
		c.detailTextLabel.font = [UIFont systemFontOfSize:12];
		c.detailTextLabel.textColor = PD_DIM;
		UIView *sel = [[UIView alloc] init];
		sel.backgroundColor = [PD_ACCENT colorWithAlphaComponent:0.28];
		c.selectedBackgroundView = sel;
		c.imageView.layer.cornerRadius = 5;
		c.imageView.clipsToBounds = YES;
	}
	NSArray *files = [PDPrinter shared].files;
	if (![files count]) {
		c.textLabel.text = !files ? @"Loading…" : @"No files on the printer";
		c.detailTextLabel.text = @"";
		c.selectionStyle = UITableViewCellSelectionStyleNone;
		c.imageView.image = nil;
		return c;
	}
	c.selectionStyle = UITableViewCellSelectionStyleBlue;
	NSDictionary *f = [files objectAtIndex:(NSUInteger)ip.row];
	NSString *path = PDStr(f, @"name");
	c.textLabel.text = PDPrettyFileName(path);
	NSMutableArray *bits = [NSMutableArray array];
	// Slicer time is the last "_" part of Elegoo file names (…_2h18m.gcode); it tells same-named slices apart.
	NSString *last = [[[[path lastPathComponent] stringByDeletingPathExtension] componentsSeparatedByString:@"_"] lastObject];
	if ([last rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == 0 && [last length] <= 9) [bits addObject:last];
	int layers = [PDNum(f, @"TotalLayers") intValue];
	if (layers) [bits addObject:[NSString stringWithFormat:@"%d layers", layers]];
	double mb = [PDNum(f, @"FileSize") doubleValue] / 1048576.0;
	if (mb > 0) [bits addObject:[NSString stringWithFormat:@"%.1f MB", mb]];
	c.detailTextLabel.text = [bits componentsJoinedByString:@" · "];
	id th = [self.thumbs objectForKey:path];
	c.imageView.image = [th isKindOfClass:[UIImage class]] ? th : [PDFilesCard placeholderThumb];
	if (!th) [self fetchThumb:path];
	return c;
}

#pragma mark - Thumbnails

static const CGFloat PDFileThumbSize = 36;

// Files sliced by PrintDeck (or without a picture) show this.
+ (UIImage *)placeholderThumb {
	static UIImage *img;
	if (!img) {
		UIGraphicsBeginImageContextWithOptions(CGSizeMake(PDFileThumbSize, PDFileThumbSize), NO, 0);
		[[UIColor colorWithWhite:1 alpha:0.06] setFill];
		UIRectFill(CGRectMake(0, 0, PDFileThumbSize, PDFileThumbSize));
		[[UIColor colorWithWhite:1 alpha:0.22] setStroke];
		UIBezierPath *cube = [UIBezierPath bezierPath];   // a small wireframe box
		CGFloat a = 10, b = 26, d = 5;
		[cube moveToPoint:CGPointMake(a, a + d)]; [cube addLineToPoint:CGPointMake(b - d, a + d)]; [cube addLineToPoint:CGPointMake(b - d, b)];
		[cube addLineToPoint:CGPointMake(a, b)]; [cube closePath];
		[cube moveToPoint:CGPointMake(a, a + d)]; [cube addLineToPoint:CGPointMake(a + d, a)]; [cube addLineToPoint:CGPointMake(b, a)];
		[cube addLineToPoint:CGPointMake(b, b - d)]; [cube addLineToPoint:CGPointMake(b - d, b)];
		[cube moveToPoint:CGPointMake(b - d, a + d)]; [cube addLineToPoint:CGPointMake(b, a)];
		cube.lineWidth = 1.5;
		[cube stroke];
		img = UIGraphicsGetImageFromCurrentImageContext();
		UIGraphicsEndImageContext();
	}
	return img;
}

// A file's picture. The printer serves one at http://<printer>/thumbnail/<file name>.png, but only for files it has
// printed; for the rest, read the start of the G-code (a Range request) and decode the PNG the slicer embedded
// between "; thumbnail begin" and "; thumbnail end". Pictures are kept in Caches (by name and size), so each file
// is fetched once. Rows fetch as they show, three at a time.
static NSData *PDDecodeBase64(const char *s, size_t n) {
	static int8_t map[256];
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		memset(map, -1, sizeof map);
		const char *a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
		for (int i = 0; i < 64; i++) map[(uint8_t)a[i]] = (int8_t)i;
	});
	NSMutableData *out = [NSMutableData dataWithCapacity:n * 3 / 4];
	uint32_t acc = 0; int bits = 0;
	for (size_t i = 0; i < n; i++) {
		int8_t v = map[(uint8_t)s[i]];
		if (v < 0) { if (s[i] == '=') break; continue; }   // skips "; ", newlines
		acc = (acc << 6) | (uint32_t)v; bits += 6;
		if (bits >= 8) { bits -= 8; uint8_t b = (uint8_t)(acc >> bits); [out appendBytes:&b length:1]; }
	}
	return out;
}

static const char *PDFindNewline(const char *p, size_t n) { for (size_t i = 0; i < n; i++) if (p[i] == '\n') return p + i; return NULL; }

// The first embedded picture in a G-code header (PNG, or JPG for "thumbnail_JPG"), or nil.
static UIImage *PDThumbFromGcodeHead(NSData *d) {
	const char *p = [d bytes], *end = p + [d length];
	const char *tags[2] = {"; thumbnail begin ", "; thumbnail_JPG begin "};
	for (int t = 0; t < 2; t++) {
		size_t tl = strlen(tags[t]);
		for (const char *q = p; q + tl < end; q++) {
			if (memcmp(q, tags[t], tl)) continue;
			const char *body = PDFindNewline(q, (size_t)(end - q));
			if (!body) return nil;
			const char *stop = body;
			while (stop + 6 < end && memcmp(stop, "; thumbnail", 11) != 0) {
				const char *nl = PDFindNewline(stop + 1, (size_t)(end - stop - 1));
				if (!nl) return nil;   // cut off by the range
				stop = nl + 1;
			}
			if (stop + 6 >= end) return nil;
			UIImage *img = [UIImage imageWithData:PDDecodeBase64(body, (size_t)(stop - body))];
			if (img) return img;
		}
	}
	return nil;
}

// Pictures of dark filament (black PETG renders near-black) are brightened so the shape shows on the dark card.
static UIImage *PDBrightenDark(UIImage *img) {
	CGImageRef cg = img.CGImage;
	size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
	if (!w || !h || w > 512 || h > 512) return img;
	uint8_t *px = calloc(w * h, 4);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef c = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
	CGColorSpaceRelease(cs);
	if (!c) { free(px); return img; }
	CGContextDrawImage(c, CGRectMake(0, 0, w, h), cg);
	int hi = 0;
	for (size_t i = 0; i < w * h; i++) {
		uint8_t *q = px + i * 4;
		if (q[3] < 200) continue;
		int m = MAX(q[0], MAX(q[1], q[2]));
		if (m > hi) hi = m;
	}
	UIImage *out = img;
	if (hi > 0 && hi < 120) {
		float k = 190.0f / hi;
		for (size_t i = 0; i < w * h; i++) {
			uint8_t *q = px + i * 4;
			for (int ch = 0; ch < 3; ch++) q[ch] = (uint8_t)MIN((float)q[3], q[ch] * k);
		}
		CGImageRef b = CGBitmapContextCreateImage(c);
		out = [UIImage imageWithCGImage:b];
		CGImageRelease(b);
	}
	CGContextRelease(c);
	free(px);
	return out;
}

static NSString *PDThumbCachePath(NSString *path, long long size) {
	static NSString *dir;
	if (!dir) {
		dir = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"PrintDeckThumbs"];
		[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
	}
	NSString *key = [[[path lastPathComponent] stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByAppendingFormat:@"-%lld-b.png", size];
	return [dir stringByAppendingPathComponent:key];
}

- (void)fetchThumb:(NSString *)path {
	if (![path length] || self.thumbLoads >= 3) return;
	long long size = [[PDPrinter shared] sizeOfFile:path];
	NSString *cache = PDThumbCachePath(path, size);
	UIImage *cached = [UIImage imageWithContentsOfFile:cache];
	if (cached) { [self.thumbs setObject:cached forKey:path]; [self showThumb:cached forPath:path]; return; }
	NSURL *file = [[PDPrinter shared] urlForFile:path];   // same web server (and origin) as the file itself
	if (!file) return;
	NSString *name = [[[path lastPathComponent] stringByAppendingString:@".png"] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
	NSString *origin = [NSString stringWithFormat:@"%@://%@%@", [file scheme], [file host], [file port] ? [NSString stringWithFormat:@":%@", [file port]] : @""];
	NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"%@/thumbnail/%@", origin, name]];
	if (!u) { [self.thumbs setObject:[NSNull null] forKey:path]; return; }
	[self.thumbs setObject:[NSNull null] forKey:path];   // in flight
	self.thumbLoads++;
	void (^finish)(UIImage *, BOOL) = ^(UIImage *img, BOOL retry) {
		self.thumbLoads--;
		if (img) {   // scale down once (the printer's are 144 px)
			img = PDBrightenDark(img);
			UIGraphicsBeginImageContextWithOptions(CGSizeMake(PDFileThumbSize, PDFileThumbSize), YES, 0);
			[[UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1] setFill];
			UIRectFill(CGRectMake(0, 0, PDFileThumbSize, PDFileThumbSize));
			[img drawInRect:CGRectMake(0, 0, PDFileThumbSize, PDFileThumbSize)];
			img = UIGraphicsGetImageFromCurrentImageContext();
			UIGraphicsEndImageContext();
			[self.thumbs setObject:img forKey:path];
			[UIImagePNGRepresentation(img) writeToFile:cache atomically:YES];
		} else if (retry) [self.thumbs removeObjectForKey:path];   // network trouble: try again when it shows
		[self showThumb:img forPath:path];
	};
	NSURLRequest *rq = [NSURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
	[NSURLConnection sendAsynchronousRequest:rq queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
		NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)r statusCode] : 0;
		UIImage *img = code == 200 && d ? [UIImage imageWithData:d] : nil;
		if (img || (e && code == 0)) { finish(img, img == nil); return; }
		// Not printed yet: the picture inside the file.
		NSMutableURLRequest *hr = [NSMutableURLRequest requestWithURL:file cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
		[hr setValue:@"bytes=0-98303" forHTTPHeaderField:@"Range"];
		[NSURLConnection sendAsynchronousRequest:hr queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *r2, NSData *d2, NSError *e2) {
			NSInteger c2 = [r2 isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)r2 statusCode] : 0;
			if ((c2 == 200 || c2 == 206) && [d2 length]) {
				NSData *head = [d2 length] > 98304 ? [d2 subdataWithRange:NSMakeRange(0, 98304)] : d2;   // a server that ignores Range
				finish(PDThumbFromGcodeHead(head), NO);
			} else finish(nil, e2 && c2 == 0);
		}];
	}];
}

// Show a picture if its row is on screen, and start the next visible row that has none yet.
- (void)showThumb:(UIImage *)img forPath:(NSString *)path {
	NSArray *files = [PDPrinter shared].files;
	for (NSIndexPath *ip in [self.table indexPathsForVisibleRows]) {
		if ((NSUInteger)ip.row >= [files count]) continue;
		NSString *p = PDStr([files objectAtIndex:(NSUInteger)ip.row], @"name");
		if ([p isEqualToString:path]) { UITableViewCell *c = [self.table cellForRowAtIndexPath:ip]; if (img) c.imageView.image = img; }
		else if (![self.thumbs objectForKey:p]) [self fetchThumb:p];
	}
}

- (NSIndexPath *)tableView:(UITableView *)t willSelectRowAtIndexPath:(NSIndexPath *)ip {
	return [[PDPrinter shared].files count] ? ip : nil;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	NSArray *files = [PDPrinter shared].files;
	if ((NSUInteger)ip.row >= [files count]) return;
	NSString *path = PDStr([files objectAtIndex:(NSUInteger)ip.row], @"name");
	if ([path isEqualToString:self.selectedPath]) return;
	[PDFilesCard setSelectedPath:path];   // -> selectionChanged, and loads it
}

#pragma mark - Print

- (void)confirmPrint {
	if (!self.selectedPath) return;
	NSString *msg = [NSString stringWithFormat:@"Start printing \"%@\"? Make sure the bed is clear.", PDPrettyFileName(self.selectedPath)];
	[[[UIAlertView alloc] initWithTitle:@"Start print" message:msg delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Print", nil] show];
}

- (void)alertView:(UIAlertView *)a clickedButtonAtIndex:(NSInteger)i {
	PDPrinter *p = [PDPrinter shared];
	if (i == a.cancelButtonIndex || !self.selectedPath || p.isBusy) return;
	[p startFile:self.selectedPath];
}

#pragma mark - Layout

- (void)layoutSubviews {
	[super layoutSubviews];
	CGRect c = [self contentBounds];
	CGFloat y = c.origin.y + 22, h = CGRectGetMaxY(c) - y;
	CGFloat lw = floor(c.size.width * 0.48);
	self.table.frame = CGRectMake(c.origin.x - 6, y, lw + 6, h);
	self.sliceButton.frame = CGRectMake(c.origin.x + lw - 70, c.origin.y - 6, 70, 26);
	self.titleLabel.frame = CGRectMake(c.origin.x, c.origin.y, lw - 76, 16);
	CGRect v = CGRectMake(c.origin.x + lw + 12, c.origin.y, c.size.width - lw - 12, c.size.height);
	self.viewer.frame = v;
	self.nameLabel.frame = CGRectMake(v.origin.x + 10, v.origin.y + 8, v.size.width - 90, 16);
	self.infoLabel.frame = CGRectMake(v.origin.x + 10, CGRectGetMaxY(v) - 20, v.size.width - 90, 14);
	self.printButton.frame = CGRectMake(CGRectGetMaxX(v) - 72, v.origin.y + 6, 66, 32);
	self.inspectButton.frame = CGRectMake(CGRectGetMaxX(v) - 72, CGRectGetMaxY(v) - 38, 66, 32);
	self.msgLabel.frame = CGRectMake(v.origin.x + 12, v.origin.y + v.size.height / 2 - 30, v.size.width - 24, 44);
	self.retryButton.frame = CGRectMake(CGRectGetMidX(v) - 45, v.origin.y + v.size.height / 2 + 16, 90, 32);
}

@end
