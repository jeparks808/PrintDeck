#import "PDSparklineView.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

#define PD_MAXQ 8

@interface PDSparklineView () {
	float *_raw;          // timeline samples: _nLines rows of _nSamples, oldest first, NAN = no data
	NSUInteger _nLines, _nSamples;
	double _window, _gridStep, _q[PD_MAXQ];
	int _nq;
	CGFloat *_px, *_pv, *_ox, *_ov;  // point buffers before / after merging columns
	NSUInteger _cap;
	CAShapeLayer *_gridLayer;
	double _shownMax, _shownMin, _shownAt;  // the scale as drawn; it eases instead of jumping
	NSMutableArray *_lineLayers;  // per line, first line last (on top): fill, stroke
}
@end

@implementation PDSparklineView

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		self.contentMode = UIViewContentModeRedraw;
		self.userInteractionEnabled = NO;
		self.color = [UIColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1.0];
		self.fillAlpha = 0.07;
		self.timeGrid = YES;
	}
	return self;
}

- (void)dealloc {
	free(_raw);
	free(_px); free(_pv); free(_ox); free(_ov);
}

- (CGFloat)shownMin { return _shownMin; }
- (CGFloat)shownMax { return _shownMax; }

- (void)setValues:(NSArray *)values { _values = [values copy]; if (!_timelineT) [self setNeedsDisplay]; }
- (void)setLineColors:(NSArray *)lineColors { _lineColors = [lineColors copy]; [self updateTimelineLayers]; }
- (void)setDisplayTime:(double)t { _displayTime = t; [self updateTimelineLayers]; }
- (void)setMaxValue:(CGFloat)m { _maxValue = m; [self updateTimelineLayers]; }
- (void)layoutSubviews { [super layoutSubviews]; [self updateTimelineLayers]; }

- (void)setTimeline:(NSDictionary *)tl {
	NSArray *raw = [tl isKindOfClass:[NSDictionary class]] ? [tl objectForKey:@"raw"] : nil;
	NSArray *q = [tl isKindOfClass:[NSDictionary class]] ? [tl objectForKey:@"quarters"] : nil;
	id t = [tl isKindOfClass:[NSDictionary class]] ? [tl objectForKey:@"t"] : nil;
	BOOL was = _timelineT > 0;
	free(_raw);
	_raw = NULL;
	_nLines = _nSamples = 0;
	_timelineT = 0;
	_nq = 0;
	if ([raw isKindOfClass:[NSArray class]] && [raw count] && [q isKindOfClass:[NSArray class]] && [q count]
	    && [t isKindOfClass:[NSNumber class]]) {
		for (id x in q) if ([x isKindOfClass:[NSNumber class]] && [x doubleValue] > 0 && _nq < PD_MAXQ) _q[_nq++] = [x doubleValue];
		_window = [[tl objectForKey:@"window"] doubleValue];
		_gridStep = [[tl objectForKey:@"grid"] doubleValue];
		for (NSArray *l in raw) if ([l isKindOfClass:[NSArray class]]) _nSamples = MAX(_nSamples, [l count]);
		if (_nq && _window > 0 && _nSamples >= 2) {
			_nLines = [raw count];
			_raw = malloc(sizeof(float) * _nLines * _nSamples);
			for (NSUInteger i = 0; i < _nLines; i++) {
				NSArray *l = [raw objectAtIndex:i];
				if (![l isKindOfClass:[NSArray class]]) l = nil;
				NSUInteger n = [l count], pad = _nSamples - n;  // short rows: missing at the old end
				for (NSUInteger j = 0; j < _nSamples; j++) {
					id v = j >= pad ? [l objectAtIndex:j - pad] : nil;
					_raw[i * _nSamples + j] = [v isKindOfClass:[NSNumber class]] ? [v floatValue] : NAN;
				}
			}
			_timelineT = [t doubleValue];
		}
	}
	if (was != (_timelineT > 0)) [self setNeedsDisplay];
	[self updateTimelineLayers];
}

static CGFloat PDMax(NSArray *a) {
	CGFloat m = 0;
	for (id n in a) if ([n isKindOfClass:[NSNumber class]]) m = MAX(m, [n floatValue]);
	return m;
}

- (CGFloat)baseline {
	return (_autoRange && _timelineT > 0) ? _shownMin : self.minValue;
}

// One of several lines from points (x, value), left to right: the line, and the area under it, gap where NAN.
- (void)pathsForXs:(const CGFloat *)xs values:(const CGFloat *)vs count:(NSUInteger)n max:(CGFloat)max
              line:(CGMutablePathRef *)lineOut fill:(CGMutablePathRef *)fillOut {
	CGRect r = CGRectInset(self.bounds, 1, 2);
	CGMutablePathRef line = CGPathCreateMutable(), fill = CGPathCreateMutable();
	*lineOut = line;
	*fillOut = fill;
	CGFloat base = [self baseline];
	if (n < 2 || max <= base) return;
	CGFloat runStart = 0, lastX = 0;
	BOOL inRun = NO;
	for (NSUInteger i = 0; i <= n; i++) {
		if (i == n || isnan(vs[i])) {
			if (inRun) {
				CGPathAddLineToPoint(fill, NULL, lastX, CGRectGetMaxY(r));
				CGPathAddLineToPoint(fill, NULL, runStart, CGRectGetMaxY(r));
				CGPathCloseSubpath(fill);
			}
			inRun = NO;
			continue;
		}
		CGFloat v = MAX(0.0, MIN((vs[i] - base) / (max - base), 1.0));
		CGFloat x = xs[i], y = CGRectGetMaxY(r) - v * r.size.height;
		if (!inRun) {
			CGPathMoveToPoint(line, NULL, x, y);
			CGPathMoveToPoint(fill, NULL, x, CGRectGetMaxY(r));
			CGPathAddLineToPoint(fill, NULL, x, y);
			runStart = x;
			inRun = YES;
		} else {
			CGPathAddLineToPoint(line, NULL, x, y);
			CGPathAddLineToPoint(fill, NULL, x, y);
		}
		lastX = x;
	}
}

- (void)reserve:(NSUInteger)n {
	if (n <= _cap) return;
	_cap = n;
	_px = realloc(_px, sizeof(CGFloat) * n);
	_pv = realloc(_pv, sizeof(CGFloat) * n);
	_ox = realloc(_ox, sizeof(CGFloat) * n);
	_ov = realloc(_ov, sizeof(CGFloat) * n);
}

#pragma mark - Timeline maths (shared with DeskDash's host and view)

static double PDTimelineX(double age, double window, const double *q, int nq) {
	double total = 0, done = 0;
	for (int i = 0; i < nq; i++) total += q[i];
	double unit = window / total;
	for (int i = 0; i < nq; i++) {
		if (age <= (done + q[i]) * unit || i == nq - 1)
			return 1.0 - (i + MIN((age / unit - done) / q[i], 1.0)) / nq;
		done += q[i];
	}
	return 0;
}

static double PDTangent(const float *v, NSInteger n, NSInteger k) {
	#define AT(i) (((i) >= 0 && (i) < n) ? (double)v[(i)] : NAN)
	double x = AT(k), d0 = x - AT(k - 1), d1 = AT(k + 1) - x;
	#undef AT
	if (isnan(d0)) return isnan(d1) ? 0 : d1;
	if (isnan(d1)) return d0;
	return d0 * d1 <= 0 ? 0 : (d0 + d1) / 2;
}

static CGFloat PDInterp(const float *v, NSInteger n, double f) {
	NSInteger lo = (NSInteger)floor(f);
	double fr = f - lo;
	#define AT(k) (((k) >= 0 && (k) < n) ? (double)v[(k)] : NAN)
	double a = AT(lo);
	if (fr < 1e-6) return a;
	double b = AT(lo + 1);
	#undef AT
	if (fr > 1 - 1e-6) return b;
	if (isnan(a) || isnan(b)) return NAN;
	double d = b - a;
	if (d == 0) return a;
	double m0 = PDTangent(v, n, lo), m1 = PDTangent(v, n, lo + 1);
	double r = (m0 / d) * (m0 / d) + (m1 / d) * (m1 / d);
	if (r > 9) {
		m0 *= 3 / sqrt(r);
		m1 *= 3 / sqrt(r);
	}
	double f2 = fr * fr, f3 = f2 * fr;
	return (2 * f3 - 3 * f2 + 1) * a + (f3 - 2 * f2 + fr) * m0 + (3 * f2 - 2 * f3) * b + (f3 - f2) * m1;
}

- (NSUInteger)timelinePoints:(const float *)v rect:(CGRect)r {
	NSInteger n = (NSInteger)_nSamples;
	double off = self.displayTime - _timelineT;
	double f0 = MAX(0.0, (n - 1) + off - _window);
	double f1 = MIN((double)(n - 1), (n - 1) + off);
	if (f1 <= f0) return 0;
	[self reserve:(NSUInteger)(n + r.size.width) + 8];
	#define XAT(f) (r.origin.x + r.size.width * PDTimelineX(off + (n - 1 - (f)), _window, _q, _nq))
	NSUInteger k = 0;
	double prevF = f0, prevX = XAT(f0);
	_px[k] = prevX; _pv[k++] = PDInterp(v, n, f0);
	for (NSInteger j = (NSInteger)floor(f0) + 1; ; j++) {
		double f = j < f1 ? j : f1;
		double x = XAT(f);
		NSInteger steps = (NSInteger)((x - prevX) / 3.0);
		for (NSInteger s = 1; s < steps; s++) {
			double g = prevF + (f - prevF) * s / (double)steps;
			_px[k] = prevX + (x - prevX) * s / (double)steps;
			_pv[k++] = PDInterp(v, n, g);
		}
		_px[k] = x; _pv[k++] = PDInterp(v, n, f);
		prevF = f; prevX = x;
		if (f >= f1) break;
	}
	#undef XAT
	NSUInteger out = 0, i = 0;
	while (i < k) {
		NSUInteger e = i + 1;
		while (e < k && floor(_px[e]) == floor(_px[i])) e++;
		BOOL gap = NO;
		for (NSUInteger m = i; m < e; m++) gap |= isnan(_pv[m]);
		if (e - i <= 2 || gap) {
			for (NSUInteger m = i; m < e; m++) { _ox[out] = _px[m]; _ov[out++] = _pv[m]; }
		} else {
			NSUInteger lo = i, hi = i;
			for (NSUInteger m = i; m < e; m++) {
				if (_pv[m] < _pv[lo]) lo = m;
				if (_pv[m] > _pv[hi]) hi = m;
			}
			NSUInteger a = MIN(lo, hi), b = MAX(lo, hi);
			_ox[out] = _px[i]; _ov[out++] = _pv[a];
			if (b != a) { _ox[out] = _px[e - 1]; _ov[out++] = _pv[b]; }
		}
		i = e;
	}
	return out;
}

- (void)drawGridAt:(const double *)xs count:(NSUInteger)n inContext:(CGContextRef)ctx {
	if (!n) return;
	CGRect r = CGRectInset(self.bounds, 1, 2);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.06].CGColor);
	CGContextSetLineWidth(ctx, 1.0);
	for (NSUInteger i = 0; i < n; i++) {
		if (xs[i] < 0 || xs[i] > 1) continue;
		CGFloat x = floorf(r.origin.x + r.size.width * xs[i]) + 0.5;
		CGContextMoveToPoint(ctx, x, r.origin.y);
		CGContextAddLineToPoint(ctx, x, CGRectGetMaxY(r));
	}
	CGContextStrokePath(ctx);
}

#pragma mark - Static drawing (no timeline)

- (void)drawSeries:(NSArray *)values color:(UIColor *)color max:(CGFloat)max inContext:(CGContextRef)ctx {
	NSUInteger n = [values count];
	CGFloat base = [self baseline];
	if (n < 2 || max <= base) return;
	CGRect r = CGRectInset(self.bounds, 1, 2);
	CGFloat step = r.size.width / (CGFloat)(n - 1);
	CGMutablePathRef line = CGPathCreateMutable();
	for (NSUInteger i = 0; i < n; i++) {
		id o = [values objectAtIndex:i];
		CGFloat f = [o isKindOfClass:[NSNumber class]] ? [o floatValue] : base;
		CGFloat v = MAX(0.0, MIN((f - base) / (max - base), 1.0));
		CGFloat x = r.origin.x + step * i;
		CGFloat y = CGRectGetMaxY(r) - v * r.size.height;
		if (i == 0) CGPathMoveToPoint(line, NULL, x, y); else CGPathAddLineToPoint(line, NULL, x, y);
	}
	CGMutablePathRef fill = CGPathCreateMutableCopy(line);
	CGPathAddLineToPoint(fill, NULL, CGRectGetMaxX(r), CGRectGetMaxY(r));
	CGPathAddLineToPoint(fill, NULL, r.origin.x, CGRectGetMaxY(r));
	CGPathCloseSubpath(fill);
	CGContextAddPath(ctx, fill);
	CGContextSetFillColorWithColor(ctx, [color colorWithAlphaComponent:0.18].CGColor);
	CGContextFillPath(ctx);
	CGContextAddPath(ctx, line);
	CGContextSetStrokeColorWithColor(ctx, color.CGColor);
	CGContextSetLineWidth(ctx, 2.0);
	CGContextSetLineJoin(ctx, kCGLineJoinRound);
	CGContextStrokePath(ctx);
	CGPathRelease(fill);
	CGPathRelease(line);
}

// Auto-ranged bottom/top for a static (no-timeline) series, like the old PDSparklineView.
- (void)staticRangeFor:(NSArray *)values lo:(CGFloat *)loOut hi:(CGFloat *)hiOut {
	CGFloat lo = CGFLOAT_MAX, hi = -CGFLOAT_MAX;
	for (id v in values) if ([v isKindOfClass:[NSNumber class]]) { lo = MIN(lo, [v floatValue]); hi = MAX(hi, [v floatValue]); }
	if (lo > hi) { lo = 0; hi = 1; }
	CGFloat span = hi - lo, pad = MAX(span * 0.15, MAX(fabs(hi) * 0.01, 0.5));
	lo -= pad; hi += pad;
	if (self.minSpan > 0 && hi - lo < self.minSpan) { CGFloat mid = (hi + lo) / 2; lo = mid - self.minSpan / 2; hi = mid + self.minSpan / 2; }
	*loOut = lo; *hiOut = hi;
}

- (CGFloat)scaleTop {
	if (_timelineT > 0 && _shownMax > 0) return _shownMax;
	if (self.autoRange && [self.values count] >= 2) { CGFloat lo, hi; [self staticRangeFor:self.values lo:&lo hi:&hi]; return hi; }
	CGFloat max = self.maxValue;
	if (max <= 0) {
		CGFloat peak = PDMax(self.values);
		max = MAX(peak * 1.15, 1.0);
	}
	return max;
}

#pragma mark - Smooth timeline layers

- (void)updateTimelineLayers {
	BOOL on = _timelineT > 0 && self.displayTime > 0 && self.bounds.size.width > 0;
	if (!on && !_gridLayer) return;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	if (!_gridLayer) {
		_gridLayer = [CAShapeLayer layer];
		_gridLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.06].CGColor;
		_gridLayer.fillColor = NULL;
		_gridLayer.lineWidth = 1.0;
		[self.layer addSublayer:_gridLayer];
		_lineLayers = [NSMutableArray array];
	}
	NSUInteger want = on ? _nLines : 0;
	while ([_lineLayers count] > want * 2) {
		[[_lineLayers lastObject] removeFromSuperlayer];
		[_lineLayers removeLastObject];
	}
	while ([_lineLayers count] < want * 2) {
		CAShapeLayer *l = [CAShapeLayer layer];
		l.lineJoin = kCALineJoinRound;
		[self.layer addSublayer:l];
		[_lineLayers addObject:l];
	}
	_gridLayer.hidden = !on;
	if (on) {
		double now = CACurrentMediaTime(), off = self.displayTime - _timelineT;
		NSInteger first = MAX(0, (NSInteger)ceil((_nSamples - 1) + off - _window));
		// scale targets from the samples still on screen
		double hiTarget = self.maxValue, loTarget = self.minValue;
		if (self.autoRange) { hiTarget = -INFINITY; loTarget = INFINITY; }
		for (NSUInteger i = 0; i < _nLines; i++)
			for (NSInteger j = first; j < (NSInteger)_nSamples; j++) {
				float vv = _raw[i * _nSamples + j];
				if (isnan(vv)) continue;
				if (vv > hiTarget) hiTarget = vv;
				if (self.autoRange && vv < loTarget) loTarget = vv;
			}
		if (self.autoRange) {
			if (!isfinite(hiTarget) || !isfinite(loTarget)) { loTarget = _shownMin; hiTarget = _shownMax > 0 ? _shownMax : 1; }
			double span = hiTarget - loTarget, pad = MAX(span * 0.15, 0.5);
			loTarget -= pad; hiTarget += pad;
			if (self.minSpan > 0 && hiTarget - loTarget < self.minSpan) {
				double mid = (hiTarget + loTarget) / 2; loTarget = mid - self.minSpan / 2; hiTarget = mid + self.minSpan / 2;
			}
		} else if (self.maxValue <= 0) {
			hiTarget = MAX(hiTarget * 1.15, 1.0);
		}
		double e = (_shownMax <= 0 && _shownMin <= 0) || now - _shownAt > 2 ? 1.0 : (1 - exp(-MIN(now - _shownAt, 0.06) / 0.22));
		if (_shownMax <= 0 || now - _shownAt > 2) { _shownMax = hiTarget; _shownMin = self.autoRange ? loTarget : self.minValue; }
		else {
			_shownMax += (hiTarget - _shownMax) * e;
			if (self.autoRange) _shownMin += (loTarget - _shownMin) * e; else _shownMin = self.minValue;
		}
		_shownAt = now;
		CGRect r = CGRectInset(self.bounds, 1, 2);
		_gridLayer.frame = self.bounds;
		CGMutablePathRef grid = CGPathCreateMutable();
		if (_gridStep > 0 && self.timeGrid)
			for (double age = fmod(self.displayTime, _gridStep); age <= _window; age += _gridStep) {
				CGFloat x = floorf(r.origin.x + r.size.width * PDTimelineX(age, _window, _q, _nq)) + 0.5;
				CGPathMoveToPoint(grid, NULL, x, r.origin.y);
				CGPathAddLineToPoint(grid, NULL, x, CGRectGetMaxY(r));
			}
		_gridLayer.path = grid;
		CGPathRelease(grid);
		CGFloat max = _shownMax;
		for (NSUInteger i = 0; i < _nLines; i++) {
			UIColor *c = i < [self.lineColors count] ? [self.lineColors objectAtIndex:i] : self.color;
			NSUInteger slot = (_nLines - 1 - i) * 2;
			CAShapeLayer *fillL = [_lineLayers objectAtIndex:slot], *lineL = [_lineLayers objectAtIndex:slot + 1];
			NSUInteger k = [self timelinePoints:_raw + i * _nSamples rect:r];
			CGMutablePathRef line, fill;
			[self pathsForXs:_ox values:_ov count:k max:max line:&line fill:&fill];
			fillL.frame = lineL.frame = self.bounds;
			fillL.path = fill;
			fillL.fillColor = [c colorWithAlphaComponent:self.fillAlpha].CGColor;
			fillL.strokeColor = NULL;
			lineL.path = line;
			lineL.fillColor = NULL;
			lineL.strokeColor = c.CGColor;
			lineL.lineWidth = 2.0;
			CGPathRelease(line);
			CGPathRelease(fill);
		}
	}
	[CATransaction commit];
}

- (void)drawRect:(CGRect)rect {
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	BOOL timeline = _timelineT > 0;
	CGFloat max = [self scaleTop];
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.08].CGColor);
	CGContextSetLineWidth(ctx, 1.0);
	CGContextMoveToPoint(ctx, 0, CGRectGetMaxY(self.bounds) - 0.5);
	CGContextAddLineToPoint(ctx, CGRectGetMaxX(self.bounds), CGRectGetMaxY(self.bounds) - 0.5);
	CGContextStrokePath(ctx);
	if (self.gridLines > 0) {
		CGRect r = CGRectInset(self.bounds, 1, 2);
		CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.06].CGColor);
		for (NSInteger i = 0; i < self.gridLines; i++) {
			CGFloat y = floorf(r.origin.y + r.size.height * i / (CGFloat)self.gridLines) + 0.5;
			CGContextMoveToPoint(ctx, 0, y);
			CGContextAddLineToPoint(ctx, CGRectGetMaxX(self.bounds), y);
		}
		CGContextStrokePath(ctx);
	}
	if (timeline) return;  // grid and lines are the shape layers
	if (self.autoRange && [self.values count] >= 2) {
		CGFloat lo, hi; [self staticRangeFor:self.values lo:&lo hi:&hi];
		CGFloat saved = self.minValue; self.minValue = lo;
		[self drawSeries:self.values color:self.color max:hi inContext:ctx];
		self.minValue = saved;
		return;
	}
	[self drawSeries:self.values color:self.color max:max inContext:ctx];
}

@end

#pragma mark - PDGraphClock

static const double PDGraphLag = 1.3, PDGraphDrift = 0.02;

@interface PDGraphClock ()
@property (nonatomic, assign) double hostT, hostOffset, displayTime, lastTick;
@end

@implementation PDGraphClock

- (void)noteNewest:(double)t {
	if (t <= self.hostT) return;
	double now = CACurrentMediaTime(), offset = t - now;
	if (self.hostT == 0 || fabs(offset - self.hostOffset) > 3) self.hostOffset = offset;
	else self.hostOffset = MAX(self.hostOffset, offset);
	self.hostT = t;
	double target = now + self.hostOffset - PDGraphLag;
	if (self.displayTime == 0 || fabs(target - self.displayTime) > 3) {
		self.displayTime = target;
		self.lastTick = now;
	}
}

- (BOOL)advance {
	if (self.hostT == 0) return NO;
	double now = CACurrentMediaTime(), dt = MIN(MAX(now - self.lastTick, 0), 0.25);
	self.lastTick = now;
	self.hostOffset -= PDGraphDrift * dt;
	double err = (now + self.hostOffset - PDGraphLag) - self.displayTime;
	double d = fabs(err) > 2 ? self.displayTime + err : self.displayTime + dt * (1 + MAX(-0.1, MIN(0.1, err)));
	d = MIN(d, self.hostT + 1.5);
	if (fabs(d - self.displayTime) < 1e-4) return NO;
	self.displayTime = d;
	return YES;
}

@end
