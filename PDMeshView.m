#import "PDMeshView.h"
#import "PDMesh.h"
#import "PDViews.h"
#import "PDUtil.h"
#import "PDPrinter.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static NSString *const PDMeshInvertKey = @"PDMeshInvertScrew";
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

- (void)resetView { self.azimuth = 0.62; self.elevation = 0.95; self.zoom = 1.0; [self setNeedsDisplay]; }

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

- (void)drawRect:(CGRect)rect {
	PDMesh *m = self.mesh;
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	CGRect b = self.bounds;
	if (!m || m.nx < 2 || m.ny < 2) return;
	NSUInteger nx = m.nx, ny = m.ny, N = nx * ny;
	double cx = (m.minX + m.maxX) / 2, cy = (m.minY + m.maxY) / 2, mean = m.mean;
	double bedMax = MAX(m.maxX - m.minX, m.maxY - m.minY);
	double maxAbs = MAX(fabs(m.max - mean), fabs(mean - m.min));
	if (maxAbs < 1e-6) maxAbs = 1e-6;
	double zExagg = 0.26 * bedMax / maxAbs;   // auto: relief fills ~a quarter of the model height
	double az = self.azimuth, el = self.elevation, ca = cos(az), sa = sin(az), ce = cos(el), se = sin(el);
	double scale = MIN(b.size.width, b.size.height) * 0.34 * self.zoom;
	double ox = b.size.width / 2, oy = b.size.height * 0.54;

	CGPoint *P = malloc(sizeof(CGPoint) * N);
	double *dev = malloc(sizeof(double) * N);
	#define PROJ(X, Y, Z, OUTP, OUTDEPTH) do { \
		double rx = (X) * ca - (Y) * sa, ry = (X) * sa + (Y) * ca, rz = (Z); \
		double sx = rx, sy = rz * ce - ry * se; OUTDEPTH = ry * ce + rz * se; \
		OUTP = CGPointMake(ox + scale * sx, oy - scale * sy); } while (0)

	for (NSUInteger gy = 0; gy < ny; gy++)
		for (NSUInteger gx = 0; gx < nx; gx++) {
			double x = m.minX + (m.maxX - m.minX) * gx / (double)(nx - 1);
			double y = m.minY + (m.maxY - m.minY) * gy / (double)(ny - 1);
			double zv = [m zAtCol:gx row:gy];
			double X = -(x - cx) / bedMax, Y = (y - cy) / bedMax, Z = (zv - mean) * zExagg / bedMax;  // -X: bed left on the viewer's left
			double depth; CGPoint p; PROJ(X, Y, Z, p, depth);
			NSUInteger i = gy * nx + gx; P[i] = p; dev[i] = zv - mean;
		}

	// faint base plane (at the lowest surface level) for depth, with posts up to the surface corners
	double baseZ = (m.min - mean) * zExagg / bedMax - 0.02;
	CGPoint corners[4]; double cd;
	double hx[4] = {-0.5, 0.5, 0.5, -0.5}, hy[4] = {-0.5, -0.5, 0.5, 0.5};
	for (int i = 0; i < 4; i++) PROJ(-hx[i] * (m.maxX - m.minX) / bedMax, hy[i] * (m.maxY - m.minY) / bedMax, baseZ, corners[i], cd);
	CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.14].CGColor);
	CGContextSetLineWidth(ctx, 1.0);
	CGContextMoveToPoint(ctx, corners[0].x, corners[0].y);
	for (int i = 1; i < 4; i++) CGContextAddLineToPoint(ctx, corners[i].x, corners[i].y);
	CGContextClosePath(ctx); CGContextStrokePath(ctx);
	NSUInteger cornerIdx[4] = {0, nx - 1, N - 1, N - nx};  // FL, FR, BR, BL in grid terms
	for (int i = 0; i < 4; i++) {
		CGContextMoveToPoint(ctx, corners[i].x, corners[i].y);
		CGContextAddLineToPoint(ctx, P[cornerIdx[i]].x, P[cornerIdx[i]].y);
	}
	CGContextStrokePath(ctx);

	// quads, painter's algorithm (far first)
	NSUInteger qn = (nx - 1) * (ny - 1), qi = 0;
	typedef struct { NSUInteger a, bb, c, d; double depth, dev; } Quad;
	Quad *Q = malloc(sizeof(Quad) * qn);
	for (NSUInteger gy = 0; gy + 1 < ny; gy++)
		for (NSUInteger gx = 0; gx + 1 < nx; gx++) {
			NSUInteger a = gy * nx + gx, bb = gy * nx + gx + 1, c = (gy + 1) * nx + gx + 1, d = (gy + 1) * nx + gx;
			double X = -(m.minX + (m.maxX - m.minX) * (gx + 0.5) / (nx - 1) - cx) / bedMax;
			double Y = (m.minY + (m.maxY - m.minY) * (gy + 0.5) / (ny - 1) - cy) / bedMax;
			double Z = ((dev[a] + dev[bb] + dev[c] + dev[d]) / 4) * zExagg / bedMax;
			double depth; CGPoint pp; PROJ(X, Y, Z, pp, depth); (void)pp;
			Q[qi].a = a; Q[qi].bb = bb; Q[qi].c = c; Q[qi].d = d; Q[qi].depth = depth;
			Q[qi].dev = (dev[a] + dev[bb] + dev[c] + dev[d]) / 4;
			qi++;
		}
	for (NSUInteger i = 0; i + 1 < qn; i++)  // insertion sort by depth desc (qn tiny)
		for (NSUInteger j = i + 1; j < qn; j++)
			if (Q[j].depth > Q[i].depth) { Quad t = Q[i]; Q[i] = Q[j]; Q[j] = t; }

	for (NSUInteger i = 0; i < qn; i++) {
		Quad q = Q[i];
		CGContextMoveToPoint(ctx, P[q.a].x, P[q.a].y);
		CGContextAddLineToPoint(ctx, P[q.bb].x, P[q.bb].y);
		CGContextAddLineToPoint(ctx, P[q.c].x, P[q.c].y);
		CGContextAddLineToPoint(ctx, P[q.d].x, P[q.d].y);
		CGContextClosePath(ctx);
		CGContextSetFillColorWithColor(ctx, [PDMeshColor(q.dev / maxAbs) colorWithAlphaComponent:0.88].CGColor);
		CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.28].CGColor);
		CGContextSetLineWidth(ctx, 1.0);
		CGContextDrawPath(ctx, kCGPathFillStroke);
	}

	// corner letters
	NSArray *labels = [NSArray arrayWithObjects:@"FL", @"FR", @"BR", @"BL", nil];
	for (int i = 0; i < 4; i++) {
		UILabel *tmp = nil; (void)tmp;
		NSString *s = [labels objectAtIndex:i];
		CGPoint p = P[cornerIdx[i]];
		[[UIColor colorWithWhite:1 alpha:0.85] set];
		[s drawAtPoint:CGPointMake(p.x - 8, p.y - 24) withFont:[UIFont boldSystemFontOfSize:13]];
	}
	free(P); free(dev); free(Q);
}

@end

#pragma mark - Page

@interface PDMeshView () <UIGestureRecognizerDelegate> {
	UITextView *_pasteField;
	UIView *_pasteOverlay;
}
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UILabel *titleLabel, *clockLabel, *profileLabel, *devLabel, *hintLabel;
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
				self.canvas, self.devLabel, self.hintLabel, self.legend, self.legendLo, self.legendHi,
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
	self.profileLabel.text = m ? [NSString stringWithFormat:@"profile: %@   %lux%lu   %@", m.profileName,
		(unsigned long)m.nx, (unsigned long)m.ny, src.fetching ? @"refreshing…" : @""] : (src.lastError ?: @"");
	if (!m) { self.devLabel.text = @"–"; return; }
	self.devLabel.text = [NSString stringWithFormat:@"range %.3f mm", m.range];
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
	y += 28;
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
