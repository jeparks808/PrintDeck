#import "PDCanvasView.h"
#import "PDUtil.h"

UIColor *PDColorFromHex(NSString *hex) {
	NSString *h = [hex stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"# "]];
	if ([h hasPrefix:@"0x"] || [h hasPrefix:@"0X"]) h = [h substringFromIndex:2];
	unsigned v = 0;
	if ([h length] != 6 || ![[NSScanner scannerWithString:h] scanHexInt:&v]) return [UIColor colorWithWhite:0.5 alpha:1];
	return [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
}

static CGFloat PDLuma(UIColor *c) {
	CGFloat r = 0.5, g = 0.5, b = 0.5, a = 1;
	const CGFloat *k = CGColorGetComponents(c.CGColor);
	if (CGColorGetNumberOfComponents(c.CGColor) >= 3) { r = k[0]; g = k[1]; b = k[2]; }
	(void)a;
	return 0.299 * r + 0.587 * g + 0.114 * b;
}

@implementation PDCanvasView

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		self.opaque = NO;
		self.userInteractionEnabled = NO;
		self.contentMode = UIViewContentModeRedraw;
		_emptyText = @"Waiting for the CANVAS…";
	}
	return self;
}

- (void)setInfo:(NSDictionary *)info {
	if (info == _info || [info isEqual:_info]) return;
	_info = info;
	[self setNeedsDisplay];
}

- (void)setLarge:(BOOL)large { _large = large; [self setNeedsDisplay]; }

+ (NSDictionary *)unitIn:(NSDictionary *)info {
	NSArray *units = PDArr(info, @"canvas_list");
	int want = [PDNum(info, @"active_canvas_id") intValue];
	NSDictionary *first = nil;
	for (NSDictionary *u in units) {
		if (![u isKindOfClass:[NSDictionary class]]) continue;
		if ([PDNum(u, @"canvas_id") intValue] == want && [PDNum(u, @"connected") intValue]) return u;
		if (!first && [PDNum(u, @"connected") intValue]) first = u;
	}
	return first;
}

+ (NSString *)stateTextFor:(NSDictionary *)info {
	if (!info) return @"";
	NSDictionary *u = [self unitIn:info];
	if (!u) return @"Not connected";
	int active = [PDNum(info, @"active_tray_id") intValue];
	if (active >= 0 && [PDNum(info, @"active_canvas_id") intValue] == [PDNum(u, @"canvas_id") intValue]) return [NSString stringWithFormat:@"Slot %d feeding", active + 1];
	return @"Idle";
}

// Concentric spool: the filament colour, a dark hub, a faint ring so black reads on the dark card.
static void PDDrawSpool(CGContextRef g, CGPoint c, CGFloat r, UIColor *col, BOOL empty, BOOL active) {
	CGRect o = CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r);
	if (empty) {
		CGFloat dash[2] = {4, 3};
		CGContextSetLineDash(g, 0, dash, 2);
		CGContextSetStrokeColorWithColor(g, [UIColor colorWithWhite:1 alpha:0.35].CGColor);
		CGContextSetLineWidth(g, 1.5);
		CGContextStrokeEllipseInRect(g, CGRectInset(o, 1, 1));
		CGContextSetLineDash(g, 0, NULL, 0);
	} else {
		CGContextSetFillColorWithColor(g, col.CGColor);
		CGContextFillEllipseInRect(g, o);
		CGContextSetStrokeColorWithColor(g, [UIColor colorWithWhite:1 alpha:PDLuma(col) < 0.25 ? 0.35 : 0.12].CGColor);
		CGContextSetLineWidth(g, 1);
		CGContextStrokeEllipseInRect(g, CGRectInset(o, 0.5, 0.5));
		CGFloat hr = r * 0.32;
		CGContextSetFillColorWithColor(g, [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1].CGColor);
		CGContextFillEllipseInRect(g, CGRectMake(c.x - hr, c.y - hr, 2 * hr, 2 * hr));
	}
	if (active) {
		CGContextSetStrokeColorWithColor(g, PD_ACCENT.CGColor);
		CGContextSetLineWidth(g, 3);
		CGContextStrokeEllipseInRect(g, CGRectInset(o, -5, -5));
	}
}

static void PDText(NSString *t, CGRect r, UIFont *f, UIColor *c, NSTextAlignment a) {
	[c set];
	[t drawInRect:r withFont:f lineBreakMode:NSLineBreakByTruncatingTail alignment:a];
}

- (void)drawRect:(CGRect)rect {
	CGContextRef g = UIGraphicsGetCurrentContext();
	CGRect b = self.bounds;
	NSDictionary *u = [PDCanvasView unitIn:self.info];
	NSArray *trays = PDArr(u, @"tray_list");
	if (![trays count]) {
		NSString *t = !self.info ? self.emptyText : @"CANVAS not connected";
		UIFont *f = [UIFont systemFontOfSize:self.large ? 20 : 13];
		PDText(t, CGRectMake(0, b.size.height / 2 - f.lineHeight, b.size.width, f.lineHeight * 2 + 4), f, PD_DIM, NSTextAlignmentCenter);
		return;
	}
	int active = [PDNum(self.info, @"active_canvas_id") intValue] == [PDNum(u, @"canvas_id") intValue] ? [PDNum(self.info, @"active_tray_id") intValue] : -1;
	NSUInteger n = MIN((NSUInteger)8, [trays count]);
	for (NSUInteger i = 0; i < n; i++) {
		NSDictionary *t = [trays objectAtIndex:i];
		if (![t isKindOfClass:[NSDictionary class]]) continue;
		int tid = PDNum(t, @"tray_id") ? [PDNum(t, @"tray_id") intValue] : (int)i;
		BOOL empty = [PDNum(t, @"status") intValue] == 0, on = tid == active;
		UIColor *col = PDColorFromHex(PDStr(t, @"filament_color"));
		NSString *type = [PDStr(t, @"filament_type") length] ? PDStr(t, @"filament_type") : @"—";
		NSString *name = PDStr(t, @"filament_name") ?: @"", *brand = PDStr(t, @"brand") ?: @"";
		NSString *full = [name length] && ![name isEqualToString:type] ? [NSString stringWithFormat:@"%@ %@", brand, name] : brand;
		if (!self.large) {
			// card: one row per slot
			CGFloat rh = b.size.height / n, y = i * rh, r = MIN(15, rh / 2 - 6);
			PDDrawSpool(g, CGPointMake(8 + r, y + rh / 2), r, col, empty, on);
			CGFloat tx = 8 + 2 * r + 14, tw = b.size.width - tx;
			PDText([NSString stringWithFormat:@"%d  %@", tid + 1, empty ? @"Empty" : type], CGRectMake(tx, y + rh / 2 - 17, tw, 19), [UIFont boldSystemFontOfSize:15],
				on ? PD_ACCENT : (empty ? PD_FAINT : [UIColor whiteColor]), NSTextAlignmentLeft);
			PDText(empty ? @"no filament" : (on ? @"feeding" : full), CGRectMake(tx, y + rh / 2 + 2, tw, 15), [UIFont systemFontOfSize:11], on ? PD_ACCENT : PD_DIM, NSTextAlignmentLeft);
		} else {
			// page: one tile per slot, side by side
			CGFloat gap = 16, tw = (b.size.width - gap * (n - 1)) / n, x = i * (tw + gap);
			CGRect tile = CGRectMake(x, 0, tw, b.size.height);
			UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:tile cornerRadius:14];
			[(on ? [PD_ACCENT colorWithAlphaComponent:0.14] : PD_TILE) setFill];
			[bp fill];
			CGFloat r = MIN(tw * 0.3, b.size.height * 0.2);
			// centre the slot label, spool and text block in a tall tile
			CGFloat oy = MAX(0, floor((b.size.height - (2 * r + 200)) / 2));
			CGPoint c = CGPointMake(CGRectGetMidX(tile), oy + 36 + 18 + r);
			PDText([NSString stringWithFormat:@"SLOT %d", tid + 1], CGRectMake(x, oy + 16, tw, 18), [UIFont boldSystemFontOfSize:13], PD_FAINT, NSTextAlignmentCenter);
			PDDrawSpool(g, c, r, col, empty, on);
			CGFloat y = c.y + r + 22;
			PDText(empty ? @"Empty" : type, CGRectMake(x + 8, y, tw - 16, 34), PDBoldFont(28), empty ? PD_FAINT : [UIColor whiteColor], NSTextAlignmentCenter); y += 38;
			if (!empty) {
				PDText(full, CGRectMake(x + 8, y, tw - 16, 20), [UIFont systemFontOfSize:16], PD_DIM, NSTextAlignmentCenter); y += 24;
				NSString *hex = [[PDStr(t, @"filament_color") ?: @"" uppercaseString] stringByReplacingOccurrencesOfString:@"#" withString:@""];
				PDText([NSString stringWithFormat:@"#%@", hex], CGRectMake(x + 8, y, tw - 16, 18), [UIFont systemFontOfSize:14], PD_FAINT, NSTextAlignmentCenter); y += 26;
				int lo = [PDNum(t, @"min_nozzle_temp") intValue], hi = [PDNum(t, @"max_nozzle_temp") intValue];
				if (lo > 0 || hi > 0) PDText([NSString stringWithFormat:@"Nozzle %d–%d °C", lo, hi], CGRectMake(x + 8, y, tw - 16, 20), [UIFont systemFontOfSize:15], PD_DIM, NSTextAlignmentCenter);
				y += 26;
			}
			if (on) PDText(@"FEEDING THE NOZZLE", CGRectMake(x + 8, CGRectGetMaxY(tile) - 34, tw - 16, 18), [UIFont boldSystemFontOfSize:13], PD_ACCENT, NSTextAlignmentCenter);
		}
	}
}

@end
