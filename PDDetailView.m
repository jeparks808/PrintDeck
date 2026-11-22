#import "PDDetailView.h"
#import "PDPrinter.h"
#import "PDSparklineView.h"
#import "PDViews.h"
#import "PDUtil.h"
#import <QuartzCore/QuartzCore.h>

@interface PDDetailView () <UIGestureRecognizerDelegate, UIAlertViewDelegate> {
	NSString *_kind;
}
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UILabel *titleLabel, *clockLabel;
@property (nonatomic, strong) UILabel *bigValue, *stateLabel;
@property (nonatomic, strong) PDSparklineView *graph;
@property (nonatomic, strong) UILabel *yTop, *yBot, *xLeft, *xRight;
@property (nonatomic, strong) NSArray *statTitles, *statValues;  // UILabels
@property (nonatomic, strong) NSArray *presetButtons;           // UIButtons (nozzle/bed)
@property (nonatomic, strong) UILabel *note;                    // chamber
@property (nonatomic, strong) UIButton *meshButton;            // bed
@property (nonatomic, strong) UIColor *accent;
@property (nonatomic, strong) NSTimer *clockTimer;
@end

@implementation PDDetailView

- (NSString *)kind { return _kind; }

static UILabel *PDDLabel(UIFont *f, UIColor *c, NSTextAlignment a) {
	UILabel *l = PDLabel(f, c);
	l.textAlignment = a;
	return l;
}

- (id)initWithKind:(NSString *)kind {
	if ((self = [super initWithFrame:[[UIScreen mainScreen] bounds]])) {
		_kind = [kind copy];
		BOOL nozzle = [kind isEqualToString:@"nozzle"], bed = [kind isEqualToString:@"bed"];
		self.accent = nozzle ? PD_HOT : bed ? PD_AMBER : PD_ACCENT;
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

		NSString *title = nozzle ? @"Nozzle" : bed ? @"Bed" : @"Chamber";
		self.titleLabel = PDDLabel(PDLightFont(32), [UIColor whiteColor], NSTextAlignmentCenter);
		self.titleLabel.text = title;
		self.clockLabel = PDDLabel(PDLightFont(28), PD_DIM, NSTextAlignmentRight);

		self.bigValue = PDDLabel(PDLightFont(96), [UIColor whiteColor], NSTextAlignmentLeft);
		self.stateLabel = PDDLabel([UIFont systemFontOfSize:22], PD_DIM, NSTextAlignmentLeft);

		self.graph = [[PDSparklineView alloc] initWithFrame:CGRectZero];
		self.graph.color = self.accent;
		self.graph.autoRange = YES;
		self.graph.minSpan = 10;
		self.graph.gridLines = 4;
		self.graph.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.03];
		self.graph.layer.cornerRadius = 10;
		self.yTop = PDDLabel([UIFont systemFontOfSize:13], PD_FAINT, NSTextAlignmentRight);
		self.yBot = PDDLabel([UIFont systemFontOfSize:13], PD_FAINT, NSTextAlignmentRight);
		self.xLeft = PDDLabel([UIFont systemFontOfSize:13], PD_FAINT, NSTextAlignmentLeft);
		self.xLeft.text = @"60 s ago";
		self.xRight = PDDLabel([UIFont systemFontOfSize:13], PD_FAINT, NSTextAlignmentRight);
		self.xRight.text = @"now";

		NSArray *titles = [NSArray arrayWithObjects:@"NOW", @"TARGET", @"MIN", @"MAX", @"AVG", nil];
		NSMutableArray *ts = [NSMutableArray array], *vs = [NSMutableArray array];
		for (NSString *t in titles) {
			UILabel *tl = PDDLabel([UIFont boldSystemFontOfSize:12], PD_DIM, NSTextAlignmentCenter);
			tl.text = t;
			UILabel *vl = PDDLabel(PDLightFont(30), [UIColor whiteColor], NSTextAlignmentCenter);
			vl.text = @"–";
			[ts addObject:tl];
			[vs addObject:vl];
		}
		self.statTitles = ts;
		self.statValues = vs;

		for (UIView *v in [NSArray arrayWithObjects:self.backButton, self.titleLabel, self.clockLabel, self.bigValue,
				self.stateLabel, self.graph, self.yTop, self.yBot, self.xLeft, self.xRight, nil]) [self addSubview:v];
		for (UILabel *l in ts) [self addSubview:l];
		for (UILabel *l in vs) [self addSubview:l];

		if (nozzle || bed) {
			NSArray *labels = nozzle
				? [NSArray arrayWithObjects:@"Off", @"200°", @"220°", @"240°", @"260°", @"Custom…", nil]
				: [NSArray arrayWithObjects:@"Off", @"55°", @"60°", @"70°", @"90°", @"Custom…", nil];
			NSMutableArray *btns = [NSMutableArray array];
			for (NSUInteger i = 0; i < [labels count]; i++) {
				UIButton *b = PDButton([labels objectAtIndex:i], i == 0 ? PD_DIM : self.accent);
				b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
				b.tag = (NSInteger)i;
				[b addTarget:self action:@selector(preset:) forControlEvents:UIControlEventTouchUpInside];
				[self addSubview:b];
				[btns addObject:b];
			}
			self.presetButtons = btns;
		} else {
			self.note = PDDLabel([UIFont systemFontOfSize:18], PD_DIM, NSTextAlignmentCenter);
			self.note.numberOfLines = 2;
			self.note.text = @"The enclosure is passively warmed by the bed and hotend — there is no separate chamber heater to set.";
			[self addSubview:self.note];
		}
		if (bed) {
			self.meshButton = PDButton(@"Bed mesh ›", PD_ACCENT);
			self.meshButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
			[self.meshButton addTarget:self action:@selector(tapMesh) forControlEvents:UIControlEventTouchUpInside];
			[self addSubview:self.meshButton];
		}

		UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(back)];
		swipe.direction = UISwipeGestureRecognizerDirectionRight;
		swipe.delegate = self;
		[self addGestureRecognizer:swipe];

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:PDPrinterDidUpdateNotification object:[PDPrinter shared]];
		self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tickClock) userInfo:nil repeats:YES];
		[self tickClock];
		[self refresh];
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self.clockTimer invalidate];
}

- (void)removeFromSuperview {
	[self.clockTimer invalidate];
	self.clockTimer = nil;
	[super removeFromSuperview];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g { return YES; }

- (void)back {
	if (self.backHandler) self.backHandler();
}

- (void)tapMesh {
	if (self.openMeshHandler) self.openMeshHandler();
}

- (void)tickClock {
	NSDateFormatter *df = [[NSDateFormatter alloc] init];
	[df setDateFormat:@"h:mm"];
	self.clockLabel.text = [df stringFromDate:[NSDate date]];
}

- (void)setTimeline:(NSDictionary *)tl { [self.graph setTimeline:tl]; }

- (void)setDisplayTime:(double)t {
	_displayTime = t;
	self.graph.displayTime = t;
	// tie the y-axis labels to the eased scale
	if (self.graph.shownMax > self.graph.shownMin) {
		self.yTop.text = [NSString stringWithFormat:@"%.0f°", self.graph.shownMax];
		self.yBot.text = [NSString stringWithFormat:@"%.0f°", self.graph.shownMin];
	}
}

- (NSString *)field { return [_kind isEqualToString:@"nozzle"] ? @"TempOfNozzle" : [_kind isEqualToString:@"bed"] ? @"TempOfHotbed" : @"TempOfBox"; }
- (NSString *)targetField { return [_kind isEqualToString:@"nozzle"] ? @"TempTargetNozzle" : [_kind isEqualToString:@"bed"] ? @"TempTargetHotbed" : @"TempTargetBox"; }
- (NSArray *)ring {
	PDPrinter *p = [PDPrinter shared];
	return [_kind isEqualToString:@"nozzle"] ? p.nozzleGraph : [_kind isEqualToString:@"bed"] ? p.bedGraph : p.chamberGraph;
}

- (void)refresh {
	PDPrinter *p = [PDPrinter shared];
	NSDictionary *st = p.status;
	NSNumber *cur = PDNum(st, [self field]);
	double target = [PDNum(st, [self targetField]) doubleValue];
	BOOL heating = target > 0;
	self.bigValue.text = cur ? [NSString stringWithFormat:@"%.0f°", [cur doubleValue]] : @"–";
	BOOL near = heating && cur && fabs([cur doubleValue] - target) < 3;
	self.bigValue.textColor = !heating ? [UIColor whiteColor] : (near ? PD_GREEN : self.accent);
	if (!p.connected) self.stateLabel.text = @"Printer offline";
	else if ([_kind isEqualToString:@"chamber"]) self.stateLabel.text = @"passive enclosure";
	else self.stateLabel.text = heating ? [NSString stringWithFormat:@"heating to %.0f°", target] : @"heater off";

	// stats over the window (skip gaps)
	double lo = INFINITY, hi = -INFINITY, sum = 0; int n = 0;
	for (id v in [self ring]) if ([v isKindOfClass:[NSNumber class]]) { double d = [v doubleValue]; lo = MIN(lo, d); hi = MAX(hi, d); sum += d; n++; }
	NSString *nowS = cur ? [NSString stringWithFormat:@"%.0f°", [cur doubleValue]] : @"–";
	NSString *tgtS = heating ? [NSString stringWithFormat:@"%.0f°", target] : @"off";
	NSString *minS = n ? [NSString stringWithFormat:@"%.0f°", lo] : @"–";
	NSString *maxS = n ? [NSString stringWithFormat:@"%.0f°", hi] : @"–";
	NSString *avgS = n ? [NSString stringWithFormat:@"%.0f°", sum / n] : @"–";
	NSArray *vals = [NSArray arrayWithObjects:nowS, tgtS, minS, maxS, avgS, nil];
	for (NSUInteger i = 0; i < [self.statValues count] && i < [vals count]; i++)
		[(UILabel *)[self.statValues objectAtIndex:i] setText:[vals objectAtIndex:i]];

	BOOL idle = p.connected && !p.isBusy;
	for (UIButton *b in self.presetButtons) { b.enabled = p.connected; b.alpha = p.connected ? (idle || b.tag == 0 ? 1 : 1) : 0.4; }
}

- (void)preset:(UIButton *)b {
	PDPrinter *p = [PDPrinter shared];
	BOOL nozzle = [_kind isEqualToString:@"nozzle"];
	static const int nt[] = {0, 200, 220, 240, 260};
	static const int bt[] = {0, 55, 60, 70, 90};
	NSInteger i = b.tag;
	if (i >= 0 && i < 5) {
		if (nozzle) [p setNozzleTarget:nt[i]]; else [p setBedTarget:bt[i]];
	} else {
		UIAlertView *a = [[UIAlertView alloc] initWithTitle:nozzle ? @"Nozzle target (°C)" : @"Bed target (°C)"
			message:nozzle ? @"0 – 300" : @"0 – 110" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Set", nil];
		a.alertViewStyle = UIAlertViewStylePlainTextInput;
		[a textFieldAtIndex:0].keyboardType = UIKeyboardTypeNumberPad;
		[a show];
	}
}

- (void)alertView:(UIAlertView *)a clickedButtonAtIndex:(NSInteger)i {
	if (i == a.cancelButtonIndex) return;
	PDPrinter *p = [PDPrinter shared];
	int v = [[a textFieldAtIndex:0].text intValue];
	if ([_kind isEqualToString:@"nozzle"]) [p setNozzleTarget:MAX(0, MIN(300, v))];
	else [p setBedTarget:MAX(0, MIN(110, v))];
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 20;
	self.backButton.frame = CGRectMake(pad, 16, 168, 48);
	self.titleLabel.frame = CGRectMake(200, 16, W - 400, 48);
	self.clockLabel.frame = CGRectMake(W - pad - 160, 16, 160, 48);

	CGFloat top = 90;
	self.bigValue.frame = CGRectMake(pad + 4, top, 320, 104);
	self.stateLabel.frame = CGRectMake(pad + 6, top + 104, 320, 28);
	self.meshButton.frame = CGRectMake(pad + 6, top + 150, 240, 56);

	// graph on the right of the big reading, with a left y-axis gutter
	CGFloat gx = pad + 360, gw = W - gx - pad - 46, gy = top + 6, gh = 230;
	self.graph.frame = CGRectMake(gx, gy, gw, gh);
	self.yTop.frame = CGRectMake(gx + gw + 4, gy - 8, 40, 18);
	self.yBot.frame = CGRectMake(gx + gw + 4, gy + gh - 10, 40, 18);
	self.xLeft.frame = CGRectMake(gx, gy + gh + 4, 120, 16);
	self.xRight.frame = CGRectMake(gx + gw - 120, gy + gh + 4, 120, 16);

	// stat row, evenly across the width under the graph
	CGFloat rowY = gy + gh + 44, cellW = (W - 2 * pad) / [self.statTitles count];
	for (NSUInteger i = 0; i < [self.statTitles count]; i++) {
		CGFloat x = pad + i * cellW;
		[(UILabel *)[self.statTitles objectAtIndex:i] setFrame:CGRectMake(x, rowY, cellW, 16)];
		[(UILabel *)[self.statValues objectAtIndex:i] setFrame:CGRectMake(x, rowY + 18, cellW, 36)];
	}

	if ([self.presetButtons count]) {
		CGFloat n = [self.presetButtons count], bw = (W - 2 * pad - (n - 1) * 12) / n, bh = 64, by = H - pad - bh;
		for (NSUInteger i = 0; i < [self.presetButtons count]; i++)
			[(UIButton *)[self.presetButtons objectAtIndex:i] setFrame:CGRectMake(pad + i * (bw + 12), by, bw, bh)];
	} else if (self.note) {
		self.note.frame = CGRectMake(pad + 40, H - pad - 90, W - 2 * pad - 80, 60);
	}
}

@end
