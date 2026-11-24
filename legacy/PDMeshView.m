#import "PDMeshView.h"
#import "PDMesh.h"
#import "PDViews.h"
#import "PDUtil.h"
#import "PDPrinter.h"
#import <QuartzCore/QuartzCore.h>
#import "PDBedShape.h"
#include <math.h>

static NSString *const PDMeshInvertKey = @"PDMeshInvertScrew";
static const double PDMeshPlate = 256.0;  // mm, the printable square
static const double PDScrewPitch = 0.5;  // mm per full turn (M3 leveling screw; most of these beds)

// Diverging colour: t in [-1,1], blue (low) -> green (on plane) -> red (high).
static UIColor *PDMeshColor(double t) {
	t = MAX(-1.0, MIN(1.0, t));
	double r, g, b;
	if (t < 0) { double k = t + 1; r = 0.20 + (0.40 - 0.20) * k; g = 0.52 + (0.85 - 0.52) * k; b = 1.00 + (0.45 - 1.00) * k; }
	else       { double k = t;     r = 0.40 + (1.00 - 0.40) * k; g = 0.85 + (0.40 - 0.85) * k; b = 0.45 + (0.35 - 0.45) * k; }
	return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

// Magnitude of turns -> a friendly fraction ("⅛", "¼", "1½"), "" below an eighth.
static NSString *PDTurns(double turns) {
	int eighths = (int)llround(turns * 8);
	if (eighths <= 0) return @"";
	int whole = eighths / 8, rem = eighths % 8;
	NSString *fr = @"";
	switch (rem) {
		case 1: fr = @"⅛"; break; case 2: fr = @"¼"; break; case 3: fr = @"⅜"; break;
		case 4: fr = @"½"; break; case 5: fr = @"⅝"; break; case 6: fr = @"¾"; break; case 7: fr = @"⅞"; break;
	}
	if (whole > 0 && rem) return [NSString stringWithFormat:@"%d%@", whole, fr];
	if (whole > 0) return [NSString stringWithFormat:@"%d", whole];
	return fr;
}

#pragma mark - Canvas (software 3D)

@interface PDMeshCanvas : UIView
@property (nonatomic, strong) PDMesh *mesh;
@property (nonatomic) CGFloat azimuth, elevation, zoom;
- (void)resetView;
@end

@implementation PDMeshCanvas

- (id)initWithFrame:(CGRect)f {
	if ((self = [super initWithFrame:f])) {
		self.backgroundColor = [UIColor clearColor];
		self.contentMode = UIViewContentModeRedraw;
		[self resetView];
		[self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
		[self addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)]];
		UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resetView)];
		dt.numberOfTapsRequired = 2;
		[self addGestureRecognizer:dt];
	}
	return self;
}

- (void)resetView { self.azimuth = M_PI - 0.45; self.elevation = 0.95;  // from the front-left, as you stand at the printer
	 self.zoom = 1.0; [self setNeedsDisplay]; }

- (void)pan:(UIPanGestureRecognizer *)g {
	CGPoint t = [g translationInView:self];
	[g setTranslation:CGPointZero inView:self];
	self.azimuth -= t.x * 0.010;
	self.elevation = MAX(0.15, MIN(1.45, self.elevation + t.y * 0.008));
	[self setNeedsDisplay];
}

- (void)pinch:(UIPinchGestureRecognizer *)g {
	self.zoom = MAX(0.5, MIN(2.5, self.zoom * g.scale));
	g.scale = 1.0;
	[self setNeedsDisplay];
}

// The whole plate is drawn to scale (the Centauri Carbon's real outline from PDBedShape.h and its 256 mm printable
// square), and the probed area sits where it really is on it: one grid line and one dot per probe point, at the
// X/Y the printer probed (mesh_min..mesh_max, x_count × y_count), so the spacing and the unprobed margins are true.
- (void)drawRect:(CGRect)rect {
	PDMesh *m = self.mesh;
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGRect b = self.bounds;
	if (!m || m.nx < 2 || m.ny < 2) return;
	NSUInteger nx = m.nx, ny = m.ny, N = nx * ny;
	const double S = PDMeshPlate, cx = S / 2, cy = S / 2;
	double mean = m.mean;
	double maxAbs = MAX(fabs(m.max - mean), fabs(mean - m.min));
	if (maxAbs < 1e-6) maxAbs = 1e-6;
	double zExagg = 0.12 * S / maxAbs;   // auto: the relief is about a quarter of the plate width, top to bottom
	double az = self.azimuth, el = self.elevation, ca = cos(az), sa = sin(az), ce = cos(el), se = sin(el);
	double scale = MIN(b.size.width, b.size.height) * 0.56 * self.zoom;
	double ox = b.size.width / 2, oy = b.size.height * 0.54;
	#define PROJ(X, Y, Z, OUTP, OUTDEPTH) do { \
		double rx = (X) * ca - (Y) * sa, ry = (X) * sa + (Y) * ca, rz = (Z); \
		double sx = rx, sy = rz * ce - ry * se; OUTDEPTH = ry * ce + rz * se; \
		OUTP = CGPointMake(ox + scale * sx, oy - scale * sy); } while (0)
	// printer mm -> model units. PROJ is a mirror image (its screen axes are left-handed), so X is negated to
	// undo that: the bed's left stays on the left as seen from the front.
	#define BED(XMM, YMM, ZU, OUTP) do { double _d; PROJ(-((XMM) - cx) / S, ((YMM) - cy) / S, (ZU), OUTP, _d); (void)_d; } while (0)

	double baseZ = (m.min - mean) * zExagg / S - 0.02;

	// the plate: printable square filled faintly, the physical outline (tabs and all) and the 0/256 corner marks
	CGPoint sq[4];
	double sxv[4] = {0, S, S, 0}, syv[4] = {0, 0, S, S};
	for (int i = 0; i < 4; i++) BED(sxv[i], syv[i], baseZ, sq[i]);
	CGContextMoveToPoint(ctx, sq[0].x, sq[0].y);
	for (int i = 1; i < 4; i++) CGContextAddLineToPoint(ctx, sq[i].x, sq[i].y);
	CGContextClosePath(ctx);
	CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.05].CGColor);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.16].CGColor);
	CGContextSetLineWidth(ctx, 1.0);
	CGContextDrawPath(ctx, kCGPathFillStroke);
	for (int i = 0; i < PDBedEdgeCount; i++) {
		CGPoint p0, p1;
		BED(PDBedOutline[i * 4], PDBedOutline[i * 4 + 1], baseZ, p0);
		BED(PDBedOutline[i * 4 + 2], PDBedOutline[i * 4 + 3], baseZ, p1);
		CGContextMoveToPoint(ctx, p0.x, p0.y);
		CGContextAddLineToPoint(ctx, p1.x, p1.y);
	}
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.30].CGColor);
	CGContextStrokePath(ctx);
	// the probed area's footprint on the plate (dashed)
	CGPoint fp[4];
	double fxv[4] = {m.minX, m.maxX, m.maxX, m.minX}, fyv[4] = {m.minY, m.minY, m.maxY, m.maxY};
	for (int i = 0; i < 4; i++) BED(fxv[i], fyv[i], baseZ, fp[i]);
	CGFloat dash[2] = {4, 4};
	CGContextSetLineDash(ctx, 0, dash, 2);
	CGContextMoveToPoint(ctx, fp[0].x, fp[0].y);
	for (int i = 1; i < 4; i++) CGContextAddLineToPoint(ctx, fp[i].x, fp[i].y);
	CGContextClosePath(ctx);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.22].CGColor);
	CGContextStrokePath(ctx);
	CGContextSetLineDash(ctx, 0, NULL, 0);
	// the plate's origin (drawn now so the surface covers them when it's in front)
	[[UIColor colorWithWhite:1 alpha:0.40] set];
	UIFont *small = [UIFont systemFontOfSize:11];
	[@"0, 0" drawAtPoint:CGPointMake(sq[0].x - 12, sq[0].y + 4) withFont:small];

	// surface vertices: exactly the probe points
	CGPoint *P = malloc(sizeof(CGPoint) * N);
	double *dev = malloc(sizeof(double) * N);
	for (NSUInteger gy = 0; gy < ny; gy++)
		for (NSUInteger gx = 0; gx < nx; gx++) {
			double x = m.minX + (m.maxX - m.minX) * gx / (double)(nx - 1);
			double y = m.minY + (m.maxY - m.minY) * gy / (double)(ny - 1);
			double zv = [m zAtCol:gx row:gy];
			NSUInteger i = gy * nx + gx;
			BED(x, y, (zv - mean) * zExagg / S, P[i]);
			dev[i] = zv - mean;
		}

	// posts from the footprint corners up to the surface corners
	NSUInteger cornerIdx[4] = {0, nx - 1, N - 1, N - nx};  // FL, FR, BR, BL in grid terms
	for (int i = 0; i < 4; i++) {
		CGContextMoveToPoint(ctx, fp[i].x, fp[i].y);
		CGContextAddLineToPoint(ctx, P[cornerIdx[i]].x, P[cornerIdx[i]].y);
	}
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.14].CGColor);
	CGContextStrokePath(ctx);

	// quads between neighbouring probe points, painter's algorithm (far first); each quad's dots are drawn
	// with it, so dots behind a fold are covered like the surface is
	NSUInteger qn = (nx - 1) * (ny - 1), qi = 0;
	typedef struct { NSUInteger a, bb, c, d; double depth, dev; } Quad;
	Quad *Q = malloc(sizeof(Quad) * qn);
	for (NSUInteger gy = 0; gy + 1 < ny; gy++)
		for (NSUInteger gx = 0; gx + 1 < nx; gx++) {
			NSUInteger a = gy * nx + gx, bb = gy * nx + gx + 1, c = (gy + 1) * nx + gx + 1, d = (gy + 1) * nx + gx;
			double X = -(m.minX + (m.maxX - m.minX) * (gx + 0.5) / (nx - 1) - cx) / S;
			double Y = (m.minY + (m.maxY - m.minY) * (gy + 0.5) / (ny - 1) - cy) / S;
			double qd = (dev[a] + dev[bb] + dev[c] + dev[d]) / 4;
			double depth; CGPoint pp; PROJ(X, Y, qd * zExagg / S, pp, depth); (void)pp;
			Q[qi].a = a; Q[qi].bb = bb; Q[qi].c = c; Q[qi].d = d; Q[qi].depth = depth; Q[qi].dev = qd;
			qi++;
		}
	for (NSUInteger i = 0; i + 1 < qn; i++)  // selection sort, far first: PROJ's depth grows toward the viewer
		for (NSUInteger j = i + 1; j < qn; j++)
			if (Q[j].depth < Q[i].depth) { Quad t = Q[i]; Q[i] = Q[j]; Q[j] = t; }

	CGFloat r = MAX(1.2, MIN(2.4, scale * 0.0028 * 11 / MAX(nx, ny)));  // dot size follows the zoom and the probe spacing
	CGContextSetLineWidth(ctx, 1.0);
	for (NSUInteger i = 0; i < qn; i++) {
		Quad q = Q[i];
		CGContextMoveToPoint(ctx, P[q.a].x, P[q.a].y);
		CGContextAddLineToPoint(ctx, P[q.bb].x, P[q.bb].y);
		CGContextAddLineToPoint(ctx, P[q.c].x, P[q.c].y);
		CGContextAddLineToPoint(ctx, P[q.d].x, P[q.d].y);
		CGContextClosePath(ctx);
		CGContextSetFillColorWithColor(ctx, [PDMeshColor(q.dev / maxAbs) colorWithAlphaComponent:0.90].CGColor);
		CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
		CGContextDrawPath(ctx, kCGPathFillStroke);
		NSUInteger v[4] = {q.a, q.bb, q.c, q.d};
		CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.75].CGColor);
		for (int k = 0; k < 4; k++) CGContextFillEllipseInRect(ctx, CGRectMake(P[v[k]].x - r, P[v[k]].y - r, 2 * r, 2 * r));
	}

	// corner letters at the probed corners
	NSArray *labels = [NSArray arrayWithObjects:@"FL", @"FR", @"BR", @"BL", nil];
	[[UIColor colorWithWhite:1 alpha:0.85] set];
	for (int i = 0; i < 4; i++) {
		CGPoint p = P[cornerIdx[i]];
		[[labels objectAtIndex:i] drawAtPoint:CGPointMake(p.x - 8, p.y - 24) withFont:[UIFont boldSystemFontOfSize:13]];
	}
	free(P); free(dev); free(Q);
	#undef BED
	#undef PROJ
}

@end

#pragma mark - Page

@interface PDMeshView () <UIGestureRecognizerDelegate> {
	UITextView *_pasteField;
	UIView *_pasteOverlay;
}
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UILabel *titleLabel, *clockLabel, *profileLabel, *devLabel, *hintLabel, *probeLabel;
@property (nonatomic, strong) PDMeshCanvas *canvas;
@property (nonatomic, strong) UIView *legend;
@property (nonatomic, strong) UILabel *legendLo, *legendHi;
@property (nonatomic, strong) NSArray *screwRows;   // 4 UILabels
@property (nonatomic, strong) UIButton *refreshBtn, *pasteBtn, *demoBtn, *flipBtn;
@property (nonatomic, strong) NSTimer *clockTimer;
@property (nonatomic, strong) UISwipeGestureRecognizer *swipe;
@end

@implementation PDMeshView

- (id)init {
	if ((self = [super initWithFrame:[[UIScreen mainScreen] bounds]])) {
		self.backgroundColor = PD_BG;
		self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

		self.backButton = [UIButton buttonWithType:UIButtonTypeCustom];
		[self.backButton setTitle:@"‹  PrintDeck" forState:UIControlStateNormal];
		[self.backButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
		[self.backButton setTitleColor:PD_DIM forState:UIControlStateHighlighted];
		self.backButton.titleLabel.font = [UIFont systemFontOfSize:21];
		self.backButton.backgroundColor = PD_TILE;
		self.backButton.layer.cornerRadius = 12;
		[self.backButton addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];

		self.titleLabel = PDLabel(PDLightFont(32), [UIColor whiteColor]);
		self.titleLabel.text = @"Bed mesh";
		self.titleLabel.textAlignment = NSTextAlignmentCenter;
		self.clockLabel = PDLabel(PDLightFont(28), PD_DIM);
		self.clockLabel.textAlignment = NSTextAlignmentRight;
		self.profileLabel = PDLabel([UIFont systemFontOfSize:14], PD_FAINT);

		self.canvas = [[PDMeshCanvas alloc] initWithFrame:CGRectZero];

		self.devLabel = PDLabel(PDLightFont(30), [UIColor whiteColor]);
		self.hintLabel = PDLabel([UIFont systemFontOfSize:13], PD_FAINT);
		self.probeLabel = PDLabel([UIFont systemFontOfSize:14], PD_DIM);
		self.probeLabel.numberOfLines = 2;
		self.hintLabel.numberOfLines = 3;
		self.legend = [[UIView alloc] initWithFrame:CGRectZero];
		self.legend.layer.cornerRadius = 4;
		self.legend.clipsToBounds = YES;
		self.legendLo = PDLabel([UIFont systemFontOfSize:12], PD_DIM);
		self.legendHi = PDLabel([UIFont systemFontOfSize:12], PD_DIM);
		self.legendHi.textAlignment = NSTextAlignmentRight;

		NSMutableArray *rows = [NSMutableArray array];
		for (int i = 0; i < 4; i++) {
			UILabel *l = PDLabel([UIFont systemFontOfSize:17], [UIColor whiteColor]);
			l.numberOfLines = 1;
			[rows addObject:l];
		}
		self.screwRows = rows;

		self.refreshBtn = PDButton(@"Refresh", PD_ACCENT);
		[self.refreshBtn addTarget:self action:@selector(doRefresh) forControlEvents:UIControlEventTouchUpInside];
		self.pasteBtn = PDButton(@"Paste…", PD_DIM);
		[self.pasteBtn addTarget:self action:@selector(promptPaste) forControlEvents:UIControlEventTouchUpInside];
		self.demoBtn = PDButton(@"Demo", PD_DIM);
		[self.demoBtn addTarget:self action:@selector(doDemo) forControlEvents:UIControlEventTouchUpInside];
		self.flipBtn = PDButton(@"Flip ↕", PD_DIM);
		[self.flipBtn addTarget:self action:@selector(flipScrew) forControlEvents:UIControlEventTouchUpInside];

		for (UIView *v in [NSArray arrayWithObjects:self.backButton, self.titleLabel, self.clockLabel, self.profileLabel,
				self.canvas, self.devLabel, self.probeLabel, self.hintLabel, self.legend, self.legendLo, self.legendHi,
				self.refreshBtn, self.pasteBtn, self.demoBtn, self.flipBtn, nil]) [self addSubview:v];
		for (UILabel *l in rows) [self addSubview:l];

		self.swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(back)];
		self.swipe.direction = UISwipeGestureRecognizerDirectionRight;
		self.swipe.delegate = self;
		[self addGestureRecognizer:self.swipe];

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(meshUpdated) name:PDMeshDidUpdateNotification object:[PDMeshSource shared]];
		self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tickClock) userInfo:nil repeats:YES];
		[self tickClock];

		PDMeshSource *src = [PDMeshSource shared];
		if (!src.mesh) [src loadDemo];       // never show an empty page
		else [self meshUpdated];
		if ([src.helperURL length]) [src fetch];  // try for something fresher
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self.clockTimer invalidate];
}

- (void)removeFromSuperview { [self.clockTimer invalidate]; self.clockTimer = nil; [super removeFromSuperview]; }

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
	if (g == self.swipe) return !CGRectContainsPoint(self.canvas.frame, [t locationInView:self]);
	return YES;
}

- (void)back { if (self.backHandler) self.backHandler(); }

- (void)tickClock {
	NSDateFormatter *df = [[NSDateFormatter alloc] init];
	[df setDateFormat:@"h:mm"];
	self.clockLabel.text = [df stringFromDate:[NSDate date]];
}

- (void)doRefresh { [[PDMeshSource shared] fetch]; }
- (void)doDemo { [[PDMeshSource shared] loadDemo]; }
- (void)flipScrew {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	[d setBool:![d boolForKey:PDMeshInvertKey] forKey:PDMeshInvertKey];
	[self meshUpdated];
}

- (void)meshUpdated {
	PDMesh *m = [PDMeshSource shared].mesh;
	self.canvas.mesh = m;
	[self.canvas setNeedsDisplay];
	PDMeshSource *src = [PDMeshSource shared];
	// Always say where the mesh is from, and if the last refresh failed say so: an old mesh must not pass for new.
	NSString *state = src.fetching ? @"refreshing…" : src.lastError ? [@"couldn't refresh: " stringByAppendingString:src.lastError]
		: src.lastFetchUnchanged ? @"unchanged since last fetch" : @"";
	self.profileLabel.text = m ? [NSString stringWithFormat:@"profile: %@   %lux%lu   ·  %@%@%@", m.profileName, (unsigned long)m.nx, (unsigned long)m.ny,
		src.origin ?: @"cached", [state length] ? @"  ·  " : @"", state] : (src.lastError ?: @"");
	self.profileLabel.textColor = src.lastError && m ? PD_AMBER : PD_FAINT;
	self.profileLabel.adjustsFontSizeToFitWidth = YES;
	if (!m) { self.devLabel.text = @"–"; return; }
	self.devLabel.text = [NSString stringWithFormat:@"range %.3f mm", m.range];
	double stepX = (m.maxX - m.minX) / (m.nx - 1), stepY = (m.maxY - m.minY) / (m.ny - 1);
	NSString *step = fabs(stepX - stepY) < 0.05 ? [NSString stringWithFormat:@"%.1f mm", stepX] : [NSString stringWithFormat:@"%.1f × %.1f mm", stepX, stepY];
	self.probeLabel.text = [NSString stringWithFormat:@"%lu × %lu probe points, every %@\nX %.0f–%.0f mm, Y %.0f–%.0f mm of the 256 mm plate",
		(unsigned long)m.nx, (unsigned long)m.ny, step, m.minX, m.maxX, m.minY, m.maxY];
	double maxAbs = MAX(fabs(m.max - m.mean), fabs(m.mean - m.min));
	self.legendLo.text = [NSString stringWithFormat:@"%+.3f", -maxAbs];
	self.legendHi.text = [NSString stringWithFormat:@"%+.3f", maxAbs];

	// four corners: FL FR BR BL (front = min Y, left = min X)
	double hFL = [m heightAtX:m.minX y:m.minY], hFR = [m heightAtX:m.maxX y:m.minY];
	double hBR = [m heightAtX:m.maxX y:m.maxY], hBL = [m heightAtX:m.minX y:m.maxY];
	double h[4] = {hFL, hFR, hBR, hBL};
	NSArray *names = [NSArray arrayWithObjects:@"Front-left", @"Front-right", @"Back-right", @"Back-left", nil];
	int ref = 0; for (int i = 1; i < 4; i++) if (h[i] > h[ref]) ref = i;  // highest corner = reference
	BOOL invert = [[NSUserDefaults standardUserDefaults] boolForKey:PDMeshInvertKey];
	for (int i = 0; i < 4; i++) {
		UILabel *l = [self.screwRows objectAtIndex:i];
		double dz = h[ref] - h[i];  // how much this corner must rise to match the reference
		UIColor *c = PDMeshColor((h[i] - m.mean) / (maxAbs < 1e-6 ? 1e-6 : maxAbs));
		if (i == ref || dz < 0.01) {
			l.text = [NSString stringWithFormat:@"%@ — reference, leave", [names objectAtIndex:i]];
			l.textColor = PD_DIM;
		} else {
			NSString *turns = PDTurns(dz / PDScrewPitch);
			NSString *dir = invert ? @"tighten" : @"loosen";  // default: loosening a spring screw raises the corner
			l.text = [NSString stringWithFormat:@"%@  raise %.3f  → %@ %@", [names objectAtIndex:i], dz, dir, [turns length] ? turns : @"<⅛"];
			l.textColor = c;
		}
	}
	self.hintLabel.text = [NSString stringWithFormat:@"Highest corner is the reference. %@ each other corner to bring it up (M%g screw, %.1f mm/turn). Re-probe after; use Flip if your screws raise when tightened.",
		invert ? @"Tighten" : @"Loosen", PDScrewPitch == 0.5 ? 3.0 : 4.0, PDScrewPitch];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	// redraw the legend gradient at the current size
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 20;
	self.backButton.frame = CGRectMake(pad, 16, 168, 48);
	self.titleLabel.frame = CGRectMake(200, 16, W - 400, 48);
	self.clockLabel.frame = CGRectMake(W - pad - 160, 16, 160, 48);

	CGFloat panelW = 330, cx = pad, cy = 78;
	CGFloat canvasW = W - panelW - pad - pad - 16;
	self.canvas.frame = CGRectMake(cx, cy, canvasW, H - cy - pad);
	self.profileLabel.frame = CGRectMake(cx + 6, H - pad - 4, canvasW - 12, 18);

	CGFloat px = cx + canvasW + 16, pw = panelW, y = cy;
	self.devLabel.frame = CGRectMake(px, y, pw, 36); y += 42;
	self.legend.frame = CGRectMake(px, y, pw, 16);
	[self paintLegend];
	y += 18;
	self.legendLo.frame = CGRectMake(px, y, pw / 2, 16);
	self.legendHi.frame = CGRectMake(px + pw / 2, y, pw / 2, 16);
	y += 24;
	self.probeLabel.frame = CGRectMake(px, y, pw, 38); y += 48;
	for (int i = 0; i < 4; i++) { [(UILabel *)[self.screwRows objectAtIndex:i] setFrame:CGRectMake(px, y, pw, 26)]; y += 28; }
	y += 6;
	self.hintLabel.frame = CGRectMake(px, y, pw, 66); y += 74;
	CGFloat bw = (pw - 2 * 10) / 3, bh = 48, by = H - pad - bh;
	self.refreshBtn.frame = CGRectMake(px, by, bw, bh);
	self.pasteBtn.frame = CGRectMake(px + bw + 10, by, bw, bh);
	self.demoBtn.frame = CGRectMake(px + 2 * (bw + 10), by, bw, bh);
	self.flipBtn.frame = CGRectMake(px, by - bh - 10, pw, bh);
}

- (void)paintLegend {
	CGRect r = self.legend.bounds;
	if (r.size.width < 2) return;
	[self.legend.layer.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
	CAGradientLayer *g = [CAGradientLayer layer];
	g.frame = r;
	g.startPoint = CGPointMake(0, 0.5); g.endPoint = CGPointMake(1, 0.5);
	g.colors = [NSArray arrayWithObjects:(id)PDMeshColor(-1).CGColor, (id)PDMeshColor(0).CGColor, (id)PDMeshColor(1).CGColor, nil];
	[self.legend.layer addSublayer:g];
}

#pragma mark - Paste overlay

- (void)promptPaste {
	if (_pasteOverlay) return;
	_pasteOverlay = [[UIView alloc] initWithFrame:self.bounds];
	_pasteOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_pasteOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
	UILabel *t = PDLabel([UIFont boldSystemFontOfSize:18], [UIColor whiteColor]);
	t.text = @"Paste a Klipper bed_mesh (BED_MESH_OUTPUT or a [bed_mesh default] block) or mesh JSON";
	t.numberOfLines = 2;
	t.frame = CGRectMake(40, 30, self.bounds.size.width - 80, 50);
	_pasteField = [[UITextView alloc] initWithFrame:CGRectMake(40, 86, self.bounds.size.width - 80, self.bounds.size.height - 180)];
	_pasteField.font = [UIFont fontWithName:@"Courier" size:13] ?: [UIFont systemFontOfSize:13];
	_pasteField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
	_pasteField.textColor = [UIColor whiteColor];
	_pasteField.autocorrectionType = UITextAutocorrectionTypeNo;
	UIButton *load = PDButton(@"Load", PD_ACCENT), *cancel = PDButton(@"Cancel", PD_DIM);
	[load addTarget:self action:@selector(loadPaste) forControlEvents:UIControlEventTouchUpInside];
	[cancel addTarget:self action:@selector(closePaste) forControlEvents:UIControlEventTouchUpInside];
	CGFloat by = self.bounds.size.height - 76, bw = 160;
	load.frame = CGRectMake(self.bounds.size.width - 40 - bw, by, bw, 52);
	cancel.frame = CGRectMake(self.bounds.size.width - 40 - 2 * bw - 12, by, bw, 52);
	for (UIView *v in [NSArray arrayWithObjects:t, _pasteField, load, cancel, nil]) [_pasteOverlay addSubview:v];
	[self addSubview:_pasteOverlay];
	[_pasteField becomeFirstResponder];
}

- (void)loadPaste {
	NSString *err = nil;
	if ([[PDMeshSource shared] setPastedText:_pasteField.text error:&err]) { [self closePaste]; }
	else {
		UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Couldn't read that" message:err delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
		[a show];
	}
}

- (void)closePaste {
	[_pasteField resignFirstResponder];
	[_pasteOverlay removeFromSuperview];
	_pasteOverlay = nil; _pasteField = nil;
}

@end
