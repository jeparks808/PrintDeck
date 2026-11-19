#import "PDSparklineView.h"

@implementation PDSparklineView

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		self.contentMode = UIViewContentModeRedraw;
		self.userInteractionEnabled = NO;
		self.color = [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1.0];
	}
	return self;
}

- (void)setValues:(NSArray *)values { _values = [values copy]; [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)rect {
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.08].CGColor);
	CGContextSetLineWidth(ctx, 1.0);
	CGContextMoveToPoint(ctx, 0, CGRectGetMaxY(self.bounds) - 0.5);
	CGContextAddLineToPoint(ctx, CGRectGetMaxX(self.bounds), CGRectGetMaxY(self.bounds) - 0.5);
	CGContextStrokePath(ctx);

	NSUInteger n = [self.values count];
	if (n < 2) return;
	CGFloat lo = CGFLOAT_MAX, hi = -CGFLOAT_MAX;
	for (NSNumber *v in self.values) { lo = MIN(lo, [v floatValue]); hi = MAX(hi, [v floatValue]); }
	CGFloat span = hi - lo, pad = MAX(span * 0.15, MAX(fabs(hi) * 0.01, 0.5));
	lo -= pad; hi += pad; span = hi - lo;

	CGRect r = CGRectInset(self.bounds, 1, 2);
	CGFloat step = r.size.width / (CGFloat)(n - 1);
	CGMutablePathRef line = CGPathCreateMutable();
	for (NSUInteger i = 0; i < n; i++) {
		CGFloat v = ([[self.values objectAtIndex:i] floatValue] - lo) / span;
		CGFloat x = r.origin.x + step * i, y = CGRectGetMaxY(r) - v * r.size.height;
		if (i == 0) CGPathMoveToPoint(line, NULL, x, y); else CGPathAddLineToPoint(line, NULL, x, y);
	}
	CGMutablePathRef fill = CGPathCreateMutableCopy(line);
	CGPathAddLineToPoint(fill, NULL, CGRectGetMaxX(r), CGRectGetMaxY(r));
	CGPathAddLineToPoint(fill, NULL, r.origin.x, CGRectGetMaxY(r));
	CGPathCloseSubpath(fill);
	CGContextAddPath(ctx, fill);
	CGContextSetFillColorWithColor(ctx, [self.color colorWithAlphaComponent:0.18].CGColor);
	CGContextFillPath(ctx);
	CGContextAddPath(ctx, line);
	CGContextSetStrokeColorWithColor(ctx, self.color.CGColor);
	CGContextSetLineWidth(ctx, 2.0);
	CGContextSetLineJoin(ctx, kCGLineJoinRound);
	CGContextStrokePath(ctx);
	CGPathRelease(fill);
	CGPathRelease(line);
}

@end
