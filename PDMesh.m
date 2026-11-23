#import "PDMesh.h"
#import "PDUtil.h"
#import "PDPrinter.h"
#include <math.h>

NSString *const PDMeshDidUpdateNotification = @"PDMeshDidUpdateNotification";
static NSString *const PDMeshCacheKey = @"PDMeshCache";
static NSString *const PDMeshHelperKey = @"PDMeshHelperURL";
static NSString *const PDMeshOriginKey = @"PDMeshOrigin";

@interface PDMesh () {
	double *_z;  // nx*ny, row-major: index(gx,gy) = gy*nx + gx
}
@property (nonatomic, readwrite) NSUInteger nx, ny;
@property (nonatomic, readwrite) double minX, minY, maxX, maxY;
@property (nonatomic, readwrite, copy) NSString *profileName;
@property (nonatomic, readwrite) double min, max, mean, range;
- (id)initWithRows:(NSArray *)rows minX:(double)minX minY:(double)minY maxX:(double)maxX maxY:(double)maxY profile:(NSString *)profile;
@end

@implementation PDMesh

// rows = NSArray of NSArray of NSNumber (ny rows of nx), row 0 = front (min Y).
- (id)initWithRows:(NSArray *)rows minX:(double)minX minY:(double)minY maxX:(double)maxX maxY:(double)maxY
           profile:(NSString *)profile {
	if (!(self = [super init])) return nil;
	NSUInteger ny = [rows count];
	NSUInteger nx = 0;
	for (NSArray *r in rows) if ([r isKindOfClass:[NSArray class]]) nx = MAX(nx, [r count]);
	if (nx < 2 || ny < 2) return nil;
	_nx = nx; _ny = ny;
	_minX = minX; _minY = minY;
	_maxX = (maxX > minX) ? maxX : minX + 1;
	_maxY = (maxY > minY) ? maxY : minY + 1;
	_profileName = [profile copy] ?: @"default";
	_z = malloc(sizeof(double) * nx * ny);
	double lo = INFINITY, hi = -INFINITY, sum = 0;
	for (NSUInteger gy = 0; gy < ny; gy++) {
		NSArray *r = [rows objectAtIndex:gy];
		BOOL ok = [r isKindOfClass:[NSArray class]];
		for (NSUInteger gx = 0; gx < nx; gx++) {
			double v = (ok && gx < [r count] && [[r objectAtIndex:gx] isKindOfClass:[NSNumber class]]) ? [[r objectAtIndex:gx] doubleValue] : 0.0;
			_z[gy * nx + gx] = v;
			lo = MIN(lo, v); hi = MAX(hi, v); sum += v;
		}
	}
	_min = lo; _max = hi; _mean = sum / (nx * ny); _range = hi - lo;
	return self;
}

- (void)dealloc { free(_z); }

- (double)zAtCol:(NSUInteger)gx row:(NSUInteger)gy {
	if (gx >= _nx || gy >= _ny) return 0;
	return _z[gy * _nx + gx];
}

- (double)heightAtX:(double)x y:(double)y {
	double fx = (x - _minX) / (_maxX - _minX) * (_nx - 1);
	double fy = (y - _minY) / (_maxY - _minY) * (_ny - 1);
	fx = MAX(0.0, MIN((double)(_nx - 1), fx));
	fy = MAX(0.0, MIN((double)(_ny - 1), fy));
	NSUInteger x0 = (NSUInteger)floor(fx), y0 = (NSUInteger)floor(fy);
	NSUInteger x1 = MIN(x0 + 1, _nx - 1), y1 = MIN(y0 + 1, _ny - 1);
	double tx = fx - x0, ty = fy - y0;
	double a = _z[y0 * _nx + x0], b = _z[y0 * _nx + x1], c = _z[y1 * _nx + x0], d = _z[y1 * _nx + x1];
	return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
}

#pragma mark - Parsers

static NSArray *PDNumRows(NSArray *rows) {  // coerce array-of-arrays to NSNumber rows, nil if not usable
	if (![rows isKindOfClass:[NSArray class]] || [rows count] < 2) return nil;
	NSMutableArray *out = [NSMutableArray array];
	for (id r in rows) {
		if (![r isKindOfClass:[NSArray class]] || [r count] < 2) return nil;
		NSMutableArray *row = [NSMutableArray array];
		for (id v in r) [row addObject:[v isKindOfClass:[NSNumber class]] ? v : [NSNumber numberWithDouble:0]];
		[out addObject:row];
	}
	return out;
}

+ (PDMesh *)meshFromJSON:(NSDictionary *)json {
	if (![json isKindOfClass:[NSDictionary class]]) return nil;
	NSArray *z = PDNumRows(PDArr(json, @"z"));
	if (!z) return nil;
	NSArray *mn = PDArr(json, @"min"), *mx = PDArr(json, @"max");
	double minX = mn && [mn count] > 0 ? [[mn objectAtIndex:0] doubleValue] : 0;
	double minY = mn && [mn count] > 1 ? [[mn objectAtIndex:1] doubleValue] : 0;
	double maxX = mx && [mx count] > 0 ? [[mx objectAtIndex:0] doubleValue] : [[z objectAtIndex:0] count] - 1;
	double maxY = mx && [mx count] > 1 ? [[mx objectAtIndex:1] doubleValue] : [z count] - 1;
	return [[PDMesh alloc] initWithRows:z minX:minX minY:minY maxX:maxX maxY:maxY profile:PDStr(json, @"profile")];
}

+ (PDMesh *)meshFromMoonraker:(NSDictionary *)bm {
	if (![bm isKindOfClass:[NSDictionary class]]) return nil;
	NSArray *m = PDArr(bm, @"probed_matrix");
	if (![m count]) m = PDArr(bm, @"mesh_matrix");
	NSArray *rows = PDNumRows(m);
	if (!rows) return nil;
	NSArray *mn = PDArr(bm, @"mesh_min"), *mx = PDArr(bm, @"mesh_max");
	double minX = [mn count] > 0 ? [[mn objectAtIndex:0] doubleValue] : 0;
	double minY = [mn count] > 1 ? [[mn objectAtIndex:1] doubleValue] : 0;
	double maxX = [mx count] > 0 ? [[mx objectAtIndex:0] doubleValue] : [[rows objectAtIndex:0] count] - 1;
	double maxY = [mx count] > 1 ? [[mx objectAtIndex:1] doubleValue] : [rows count] - 1;
	return [[PDMesh alloc] initWithRows:rows minX:minX minY:minY maxX:maxX maxY:maxY profile:PDStr(bm, @"profile_name")];
}

// A line's numbers (comma or whitespace separated), ignoring a leading "// ", "Recv:", "#" etc. nil if none.
static NSArray *PDLineNumbers(NSString *line) {
	NSCharacterSet *seps = [NSCharacterSet characterSetWithCharactersInString:@", \t"];
	NSArray *parts = [line componentsSeparatedByCharactersInSet:seps];
	NSMutableArray *nums = [NSMutableArray array];
	NSCharacterSet *numch = [NSCharacterSet characterSetWithCharactersInString:@"0123456789+-.eE"];
	for (NSString *p in parts) {
		if (![p length]) continue;
		if ([[p stringByTrimmingCharactersInSet:numch] length]) return nil;  // a non-numeric token -> not a data row
		NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if ([t length]) [nums addObject:[NSNumber numberWithDouble:[t doubleValue]]];
	}
	return [nums count] >= 2 ? nums : nil;
}

static double PDKeyValue(NSString *text, NSString *key, double dflt) {
	NSRange r = [text rangeOfString:key];
	if (r.location == NSNotFound) return dflt;
	NSString *rest = [text substringFromIndex:NSMaxRange(r)];
	rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t=:"]];
	return [rest doubleValue];
}

// "key : a, b" (Klipper mesh_min/mesh_max) -> the first two numbers. NO if the key isn't there.
static BOOL PDPairValue(NSString *text, NSString *key, double *a, double *b) {
	NSRange r = [text rangeOfString:key];
	if (r.location == NSNotFound) return NO;
	NSString *rest = [text substringFromIndex:NSMaxRange(r)];
	NSRange nl = [rest rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
	if (nl.location != NSNotFound) rest = [rest substringToIndex:nl.location];
	rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t=:"]];
	NSMutableArray *nums = [NSMutableArray array];
	for (NSString *p in [rest componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", \t"]]) {
		NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if ([t length]) [nums addObject:[NSNumber numberWithDouble:[t doubleValue]]];
	}
	if ([nums count] < 2) return NO;
	*a = [[nums objectAtIndex:0] doubleValue]; *b = [[nums objectAtIndex:1] doubleValue];
	return YES;
}

// A pure number grid (a BED_MESH_OUTPUT dump: rows of whitespace-separated Z values, no "points" keyword).
+ (PDMesh *)meshFromNumericRows:(NSArray *)lines text:(NSString *)text {
	NSMutableArray *rows = [NSMutableArray array];
	BOOL inGrid = NO;
	for (NSString *raw in lines) {
		NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if ([line hasPrefix:@"//"]) line = [[line substringFromIndex:2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if ([line hasPrefix:@"Recv:"]) line = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSArray *nums = PDLineNumbers(line);
		if (nums) { [rows addObject:nums]; inGrid = YES; }
		else if (inGrid && [rows count] >= 2) break;
		else { [rows removeAllObjects]; inGrid = NO; }
	}
	NSArray *grid = PDNumRows(rows);
	if (!grid) return nil;
	NSUInteger nx = [[grid objectAtIndex:0] count], ny = [grid count];
	double minX = PDKeyValue(text, @"min_x", 0), maxX = PDKeyValue(text, @"max_x", nx - 1);
	double minY = PDKeyValue(text, @"min_y", 0), maxY = PDKeyValue(text, @"max_y", ny - 1);
	return [[PDMesh alloc] initWithRows:grid minX:minX minY:minY maxX:maxX maxY:maxY profile:@"pasted"];
}

// A Klipper `[bed_mesh …]` block. The Centauri's firmware writes the grid on one `points :` line with
// `x_count`/`y_count` and `mesh_min`/`mesh_max` pairs; standard Klipper writes `points =` then indented rows.
// Both are handled, and only the first profile in a multi-profile paste is read.
+ (PDMesh *)meshFromKlipperText:(NSString *)text {
	if (![text isKindOfClass:[NSString class]] || ![text length]) return nil;
	NSArray *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
	NSUInteger start = NSNotFound, end = [lines count];
	for (NSUInteger i = 0; i < [lines count]; i++) {
		NSString *low = [[[lines objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
		if ([low hasPrefix:@"points"] && ([low rangeOfString:@":"].location != NSNotFound || [low rangeOfString:@"="].location != NSNotFound)) { start = i; break; }
	}
	if (start == NSNotFound) return [self meshFromNumericRows:lines text:text];  // a bare dump

	NSMutableArray *pts = [NSMutableArray array];
	NSString *first = [lines objectAtIndex:start];
	NSRange d = [first rangeOfString:@":"]; if (d.location == NSNotFound) d = [first rangeOfString:@"="];
	if (d.location != NSNotFound) { NSArray *n = PDLineNumbers([first substringFromIndex:NSMaxRange(d)]); if (n) [pts addObjectsFromArray:n]; }
	for (NSUInteger i = start + 1; i < [lines count]; i++) {
		NSString *l = [[lines objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSArray *n = PDLineNumbers(l);
		if (n) [pts addObjectsFromArray:n];
		else { end = i; break; }  // first non-number line after the points -> keys start here
	}
	if ([pts count] < 4) return nil;

	// counts and extents, scoped to this profile (from the points line to the next "points"/section)
	NSUInteger scopeEnd = [lines count];
	for (NSUInteger i = end; i < [lines count]; i++) {
		NSString *low = [[[lines objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
		if (([low hasPrefix:@"points"] && [low rangeOfString:@":"].location != NSNotFound) || [low hasPrefix:@"[bed_mesh"]) { scopeEnd = i; break; }
	}
	NSString *scope = [[lines subarrayWithRange:NSMakeRange(start, scopeEnd - start)] componentsJoinedByString:@"\n"];
	int xc = (int)PDKeyValue(scope, @"x_count", 0), yc = (int)PDKeyValue(scope, @"y_count", 0);
	if (xc <= 0 && yc <= 0) { xc = yc = (int)lround(sqrt((double)[pts count])); }
	else if (xc <= 0) xc = (int)([pts count] / MAX(1, yc));
	else if (yc <= 0) yc = (int)([pts count] / MAX(1, xc));
	if (xc < 2 || yc < 2 || (NSUInteger)(xc * yc) > [pts count]) return nil;
	double minX, minY, maxX, maxY;
	if (!PDPairValue(scope, @"mesh_min", &minX, &minY)) { minX = PDKeyValue(scope, @"min_x", 0); minY = PDKeyValue(scope, @"min_y", 0); }
	if (!PDPairValue(scope, @"mesh_max", &maxX, &maxY)) { maxX = PDKeyValue(scope, @"max_x", xc - 1); maxY = PDKeyValue(scope, @"max_y", yc - 1); }

	NSMutableArray *rows = [NSMutableArray array];  // row 0 = min Y (front), col 0 = min X (left), as Klipper stores it
	for (int r = 0; r < yc; r++) {
		NSMutableArray *row = [NSMutableArray array];
		for (int c = 0; c < xc; c++) {
			NSUInteger idx = (NSUInteger)(r * xc + c);
			[row addObject:(idx < [pts count] ? [pts objectAtIndex:idx] : [NSNumber numberWithDouble:0])];
		}
		[rows addObject:row];
	}
	return [[PDMesh alloc] initWithRows:rows minX:minX minY:minY maxX:maxX maxY:maxY profile:@"pasted"];
}

- (NSDictionary *)toJSON {
	NSMutableArray *z = [NSMutableArray array];
	for (NSUInteger gy = 0; gy < _ny; gy++) {
		NSMutableArray *row = [NSMutableArray array];
		for (NSUInteger gx = 0; gx < _nx; gx++) [row addObject:[NSNumber numberWithDouble:_z[gy * _nx + gx]]];
		[z addObject:row];
	}
	return [NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithUnsignedInteger:_nx], @"nx",
		[NSNumber numberWithUnsignedInteger:_ny], @"ny",
		[NSArray arrayWithObjects:[NSNumber numberWithDouble:_minX], [NSNumber numberWithDouble:_minY], nil], @"min",
		[NSArray arrayWithObjects:[NSNumber numberWithDouble:_maxX], [NSNumber numberWithDouble:_maxY], nil], @"max",
		z, @"z", _profileName ?: @"default", @"profile", nil];
}

@end


#pragma mark - PDMeshSource

@interface PDMeshSource () <NSURLConnectionDataDelegate>
@property (nonatomic, readwrite, strong) PDMesh *mesh;
@property (nonatomic, readwrite, copy) NSString *lastError;
@property (nonatomic, readwrite) BOOL fetching;
@property (nonatomic, readwrite, copy) NSString *origin;
@property (nonatomic, readwrite) BOOL lastFetchUnchanged;
@property (nonatomic) BOOL wasLeveling;
@property (nonatomic, strong) NSURLConnection *conn;
@property (nonatomic, strong) NSMutableData *buf;
@end

@implementation PDMeshSource

+ (PDMeshSource *)shared {
	static PDMeshSource *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [[PDMeshSource alloc] init]; });
	return s;
}

- (id)init {
	if ((self = [super init])) {
		NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
		_helperURL = [[d stringForKey:PDMeshHelperKey] copy];
		NSDictionary *cached = [d objectForKey:PDMeshCacheKey];
		if ([cached isKindOfClass:[NSDictionary class]]) _mesh = [PDMesh meshFromJSON:cached];
		_origin = [[d stringForKey:PDMeshOriginKey] copy];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(printerChanged) name:PDPrinterDidUpdateNotification object:nil];
	}
	return self;
}

// A bed levelling just finished: the printer may have saved a new mesh, so ask the helper again (after a pause
// for the firmware to write it out).
- (void)printerChanged {
	NSString *state = [PDPrinter shared].jobStateText;
	BOOL leveling = [state isEqualToString:@"Leveling bed"] || [state isEqualToString:@"Calibrating"];
	if (self.wasLeveling && !leveling && [self.helperURL length])
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self fetch]; });
	self.wasLeveling = leveling;
}

- (void)setOriginText:(NSString *)o {
	self.origin = o;
	[[NSUserDefaults standardUserDefaults] setObject:o forKey:PDMeshOriginKey];
}

static NSString *PDMeshStamp(void) {
	NSDateFormatter *f = [[NSDateFormatter alloc] init];
	f.dateFormat = @"d MMM HH:mm";
	return [f stringFromDate:[NSDate date]];
}

- (void)setHelperURL:(NSString *)u {
	_helperURL = [u copy];
	[[NSUserDefaults standardUserDefaults] setObject:(u ?: @"") forKey:PDMeshHelperKey];
}

- (void)applyMesh:(PDMesh *)mesh error:(NSString *)err {
	self.fetching = NO;
	if (mesh) {
		self.lastFetchUnchanged = self.mesh && [[self.mesh toJSON] isEqualToDictionary:[mesh toJSON]];
		self.mesh = mesh;
		self.lastError = nil;
		[[NSUserDefaults standardUserDefaults] setObject:[mesh toJSON] forKey:PDMeshCacheKey];
	} else {
		self.lastError = err ?: @"Couldn't read a mesh.";
	}
	[[NSNotificationCenter defaultCenter] postNotificationName:PDMeshDidUpdateNotification object:self];
}

- (void)fetch {
	if (self.fetching) return;
	if (![self.helperURL length]) { [self applyMesh:nil error:@"No mesh source set. Paste a mesh, or set a helper URL."]; return; }
	self.fetching = YES;
	self.buf = [NSMutableData data];
	NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:self.helperURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
	self.conn = [[NSURLConnection alloc] initWithRequest:req delegate:self];
	[[NSNotificationCenter defaultCenter] postNotificationName:PDMeshDidUpdateNotification object:self];   // shows "refreshing…"
}

- (void)loadDemo {
	// A 7x7 bed with a gentle saddle, one high back-right corner and a low front-left — enough to exercise
	// the colour scale and all four screw hints. Heights in mm over a 20..200 bed.
	NSUInteger n = 7;
	NSMutableArray *rows = [NSMutableArray array];
	for (NSUInteger gy = 0; gy < n; gy++) {
		NSMutableArray *row = [NSMutableArray array];
		double v = (double)gy / (n - 1) * 2 - 1;        // -1 front .. +1 back
		for (NSUInteger gx = 0; gx < n; gx++) {
			double u = (double)gx / (n - 1) * 2 - 1;    // -1 left .. +1 right
			double z = 0.06 * (u * v)                    // saddle
				+ 0.05 * (u + v) / 2                     // tilt up toward back-right
				- 0.04 * exp(-((u + 1) * (u + 1) + (v + 1) * (v + 1)) * 2);  // dip at front-left
			[row addObject:[NSNumber numberWithDouble:z]];
		}
		[rows addObject:row];
	}
	PDMesh *m = [[PDMesh alloc] initWithRows:rows minX:20 minY:20 maxX:200 maxY:200 profile:@"demo"];
	[self setOriginText:@"demo mesh"];
	[self applyMesh:m error:nil];
	self.lastFetchUnchanged = NO;
}

- (BOOL)setPastedText:(NSString *)text error:(NSString **)err {
	PDMesh *m = [PDMesh meshFromKlipperText:text];
	if (!m) {
		// maybe they pasted JSON
		NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
		id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
		m = [self meshFromAnyJSON:j];
	}
	if (!m) { if (err) *err = @"Couldn't read that as a Klipper bed_mesh or JSON."; return NO; }
	[self setOriginText:[@"pasted " stringByAppendingString:PDMeshStamp()]];
	[self applyMesh:m error:nil];
	self.lastFetchUnchanged = NO;
	return YES;
}

// Accept our format, a raw Moonraker bed_mesh object, or a full Moonraker query reply.
- (PDMesh *)meshFromAnyJSON:(id)j {
	if (![j isKindOfClass:[NSDictionary class]]) return nil;
	PDMesh *m = [PDMesh meshFromJSON:j];
	if (m) return m;
	NSDictionary *bm = PDDict(j, @"bed_mesh");
	if (!bm) bm = PDDict(PDDict(PDDict(j, @"result"), @"status"), @"bed_mesh");
	return bm ? [PDMesh meshFromMoonraker:bm] : nil;
}

- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)data { [self.buf appendData:data]; }

- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)error {
	self.conn = nil;
	[self applyMesh:nil error:[NSString stringWithFormat:@"Can't reach the mesh helper at %@ (%@). Is meshbridge running on the printer?",
		[[NSURL URLWithString:self.helperURL] host] ?: self.helperURL, [error localizedDescription]]];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)c {
	self.conn = nil;
	id j = self.buf ? [NSJSONSerialization JSONObjectWithData:self.buf options:0 error:NULL] : nil;
	PDMesh *m = [self meshFromAnyJSON:j];
	if (m) [self setOriginText:[@"fetched " stringByAppendingString:PDMeshStamp()]];
	[self applyMesh:m error:m ? nil : @"The helper's reply wasn't a mesh."];
}

@end
