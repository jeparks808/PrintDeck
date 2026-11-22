#import "PDCardPage.h"
#import "PDPrinter.h"
#import "PDViews.h"
#import "PDMJPEGView.h"
#import "PDUtil.h"
#import "PDToolpath.h"
#import "PDToolpathView.h"
#import "PDFilesCard.h"
#import <QuartzCore/QuartzCore.h>

static const int PDSpeedVals[] = {50, 100, 130, 160};
static NSString *const PDSpeedNames[] = {@"Silent", @"Balanced", @"Sport", @"Ludicrous"};
static NSString *const PDSpeedDesc[] = {@"50% · quiet", @"100% · normal", @"130% · fast", @"160% · max"};
// Jog distances per axis (mm). X/Y share a set; Z gets finer steps (it's for touching off, not travel).
static const double PDJogStepsXY[] = {0.1, 1, 10, 50};
static const double PDJogStepsZ[] = {0.05, 0.1, 1, 10};
static const int PDJogDefault[] = {2, 2, 2};   // 10 mm, 10 mm, 1 mm
static NSString *const PDAxisNames[] = {@"X", @"Y", @"Z"};

static NSString *PDSlicerTime(NSString *path);

static UILabel *PDPL(UIFont *f, UIColor *c, NSTextAlignment a) {
	UILabel *l = PDLabel(f, c); l.textAlignment = a; return l;
}

@interface PDCardPage () <UIGestureRecognizerDelegate, UIAlertViewDelegate, UITableViewDataSource, UITableViewDelegate> {
	NSString *_kind;
	int _alertKind;          // 1 = stop, 2 = print file
	NSString *_pendingFile;
	BOOL _following;         // job viewer follows the print (vs. the user scrubbing layers)
}
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UILabel *titleLabel, *clockLabel, *statusLabel;
@property (nonatomic, strong) NSTimer *clockTimer;
@property (nonatomic, strong) UISwipeGestureRecognizer *swipe;
// camera
@property (nonatomic, strong) PDMJPEGView *camera;
@property (nonatomic, strong) UILabel *fpsLabel, *camNote;
@property (nonatomic, strong) UIButton *camToggle;
@property (nonatomic, assign) BOOL camOn;
// job
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, strong) UILabel *jobName, *percentLabel, *layerLabel, *elapsedLabel, *remainLabel, *doneAtLabel, *speedLabel, *jobState;
@property (nonatomic, strong) PDProgressBar *bar;
@property (nonatomic, strong) UIButton *pauseBtn, *stopBtn;
@property (nonatomic, copy) NSString *thumbURL;
// fans
@property (nonatomic, strong) NSArray *fanName, *fanSub, *fanVal, *fanSlider;  // 3 each
// speed
@property (nonatomic, strong) NSArray *speedBtns;      // 4
@property (nonatomic, strong) UILabel *speedNow;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel *speedSliderVal;
// job: 3D toolpath viewer
@property (nonatomic, strong) PDToolpathView *viewer;
@property (nonatomic, strong) UILabel *viewerInfo, *viewerMsg, *viewerStats;
@property (nonatomic, strong) UISlider *layerSlider;
@property (nonatomic, strong) UIButton *followBtn, *retryBtn;
@property (nonatomic, copy) NSString *viewerPath;
// file: the selected stored file in detail
@property (nonatomic, strong) UILabel *fileInfo;
@property (nonatomic, strong) UIButton *printFileBtn;
// machine
@property (nonatomic, strong) NSArray *jogBtns;        // X- X+ Y- Y+ Z- Z+
@property (nonatomic, strong) NSArray *stepCtls;       // per axis X Y Z
@property (nonatomic, strong) NSArray *axisNames, *axisPos;  // per axis labels
@property (nonatomic, strong) NSArray *homeBtns;       // X Y Z All
@property (nonatomic, strong) UILabel *moveTitle, *filesTitle;
@property (nonatomic, strong) NSArray *tiles;          // status tiles: each @[name, value] labels on a tile view
@property (nonatomic, strong) NSArray *quickBtns;      // Preheat PLA, Preheat PETG, Cool down
@property (nonatomic, strong) UIButton *lightBtn;
@property (nonatomic, strong) UILabel *machineNote;
@property (nonatomic, strong) UITableView *filesTable;
@property (nonatomic, strong) NSTimer *attrTimer;
@end

@implementation PDCardPage

- (NSString *)kind { return _kind; }

- (id)initWithKind:(NSString *)kind {
	if ((self = [super initWithFrame:[[UIScreen mainScreen] bounds]])) {
		_kind = [kind copy];
		_camOn = YES;
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
		self.titleLabel = PDPL(PDLightFont(32), [UIColor whiteColor], NSTextAlignmentCenter);
		self.titleLabel.text = [self title];
		self.clockLabel = PDPL(PDLightFont(28), PD_DIM, NSTextAlignmentRight);
		self.statusLabel = PDPL([UIFont systemFontOfSize:14], PD_FAINT, NSTextAlignmentLeft);
		for (UIView *v in [NSArray arrayWithObjects:self.backButton, self.titleLabel, self.clockLabel, self.statusLabel, nil]) [self addSubview:v];

		if ([kind isEqualToString:@"camera"]) [self buildCamera];
		else if ([kind isEqualToString:@"job"]) [self buildJob];
		else if ([kind isEqualToString:@"file"]) [self buildFile];
		else if ([kind isEqualToString:@"fans"]) [self buildFans];
		else if ([kind isEqualToString:@"speed"]) [self buildSpeed];
		else if ([kind isEqualToString:@"machine"]) [self buildMachine];

		self.swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(back)];
		self.swipe.direction = UISwipeGestureRecognizerDirectionRight;
		self.swipe.delegate = self;
		[self addGestureRecognizer:self.swipe];

		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserver:self selector:@selector(refresh) name:PDPrinterDidUpdateNotification object:[PDPrinter shared]];
		[nc addObserver:self selector:@selector(refresh) name:PDPrinterConnectionNotification object:[PDPrinter shared]];
		[nc addObserver:self selector:@selector(filesChanged) name:PDPrinterFilesNotification object:[PDPrinter shared]];
		self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tickClock) userInfo:nil repeats:YES];
		[self tickClock];
		[self refresh];
		if ([kind isEqualToString:@"machine"]) {
			[[PDPrinter shared] refreshFiles];
			[[PDPrinter shared] refreshAttributes];
			// Motor/camera state lives in the attributes, which the printer only sends when asked.
			self.attrTimer = [NSTimer scheduledTimerWithTimeInterval:6 target:[PDPrinter shared] selector:@selector(refreshAttributes) userInfo:nil repeats:YES];
		}
		if ([kind isEqualToString:@"job"] || [kind isEqualToString:@"file"]) {
			[nc addObserver:self selector:@selector(toolpathChanged) name:PDToolpathNotification object:[self viewerLoader]];
			[nc addObserver:self selector:@selector(refresh) name:PDFilesSelectionNotification object:nil];
			[self toolpathChanged];
		}
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self.clockTimer invalidate];
	[self.attrTimer invalidate];
}

- (void)removeFromSuperview {
	[self.clockTimer invalidate]; self.clockTimer = nil;
	[self.attrTimer invalidate]; self.attrTimer = nil;
	self.camera.url = nil;
	[super removeFromSuperview];
}

- (NSString *)title {
	if ([_kind isEqualToString:@"camera"]) return @"Camera";
	if ([_kind isEqualToString:@"job"]) return @"Print job";
	if ([_kind isEqualToString:@"file"]) return @"File";
	if ([_kind isEqualToString:@"fans"]) return @"Fans";
	if ([_kind isEqualToString:@"speed"]) return @"Print speed";
	if ([_kind isEqualToString:@"machine"]) return @"Move / Home";
	return @"";
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
	if (g != self.swipe) return YES;
	CGPoint p = [t locationInView:self];
	if (self.filesTable && CGRectContainsPoint(self.filesTable.frame, p)) return NO;  // let the list scroll
	for (UISlider *s in (self.fanSlider ?: [NSArray array])) if (CGRectContainsPoint([s.superview convertRect:s.frame toView:self], p)) return NO;
	if (self.speedSlider && CGRectContainsPoint(self.speedSlider.frame, p)) return NO;
	if (self.viewer && CGRectContainsPoint(self.viewer.frame, p)) return NO;          // drag rotates the model
	if (self.layerSlider && CGRectContainsPoint(CGRectInset(self.layerSlider.frame, -10, -10), p)) return NO;
	return YES;
}

- (void)back { if (self.backHandler) self.backHandler(); }

- (void)tickClock {
	NSDateFormatter *df = [[NSDateFormatter alloc] init];
	[df setDateFormat:@"h:mm"];
	self.clockLabel.text = [df stringFromDate:[NSDate date]];
}

#pragma mark - Build

- (void)makeCamera {
	self.camera = [[PDMJPEGView alloc] initWithFrame:CGRectZero];
	self.camera.layer.cornerRadius = 12;
	self.camera.clipsToBounds = YES;
	self.camera.prepare = ^(void (^go)(void)) { [[PDPrinter shared] enableVideoStream:go]; };
	self.fpsLabel = PDPL([UIFont boldSystemFontOfSize:14], [UIColor colorWithWhite:1 alpha:0.8], NSTextAlignmentRight);
	self.fpsLabel.shadowColor = [UIColor blackColor]; self.fpsLabel.shadowOffset = CGSizeMake(0, 1);
	[self addSubview:self.camera];
	[self addSubview:self.fpsLabel];
}

- (void)buildCamera {
	[self makeCamera];
	self.camNote = PDPL([UIFont systemFontOfSize:15], PD_DIM, NSTextAlignmentLeft);
	self.camNote.numberOfLines = 2;
	self.camToggle = PDButton(@"Pause camera", PD_AMBER);
	[self.camToggle addTarget:self action:@selector(toggleCam) forControlEvents:UIControlEventTouchUpInside];
	for (UIView *v in [NSArray arrayWithObjects:self.camNote, self.camToggle, nil]) [self addSubview:v];
}

// The 3D viewer with its overlays, layer slider and Follow/Reset button (job and file pages).
- (void)buildViewer {
	_following = YES;
	self.viewer = [[PDToolpathView alloc] initWithFrame:CGRectMake(0, 0, 560, 600)];
	self.viewer.layer.cornerRadius = 12;
	self.viewer.clipsToBounds = YES;
	__weak PDCardPage *weakSelf = self;
	self.viewer.interacted = ^{ [weakSelf updateFollowButton]; };
	self.viewerInfo = PDPL([UIFont boldSystemFontOfSize:16], [UIColor whiteColor], NSTextAlignmentLeft);
	self.viewerInfo.shadowColor = [UIColor blackColor]; self.viewerInfo.shadowOffset = CGSizeMake(0, 1);
	self.viewerStats = PDPL([UIFont systemFontOfSize:12], PD_FAINT, NSTextAlignmentLeft);
	self.viewerMsg = PDPL([UIFont systemFontOfSize:18], PD_DIM, NSTextAlignmentCenter);
	self.viewerMsg.numberOfLines = 3;
	self.retryBtn = PDButton(@"Retry", PD_ACCENT);
	[self.retryBtn addTarget:self action:@selector(retryToolpath) forControlEvents:UIControlEventTouchUpInside];
	self.layerSlider = [[UISlider alloc] initWithFrame:CGRectZero];
	self.layerSlider.minimumValue = 0; self.layerSlider.maximumValue = 1;
	[self.layerSlider addTarget:self action:@selector(scrubLayers) forControlEvents:UIControlEventValueChanged];
	self.followBtn = PDButton(@"Reset view", PD_ACCENT);
	self.followBtn.titleLabel.font = PDBoldFont(15);
	[self.followBtn addTarget:self action:@selector(followTapped) forControlEvents:UIControlEventTouchUpInside];
	for (UIView *v in [NSArray arrayWithObjects:self.viewer, self.viewerInfo, self.viewerStats, self.viewerMsg, self.retryBtn,
			self.layerSlider, self.followBtn, nil]) [self addSubview:v];
}

- (void)buildJob {
	[self buildViewer];
	self.thumb = [[UIImageView alloc] initWithFrame:CGRectZero];
	self.thumb.contentMode = UIViewContentModeScaleAspectFit;
	self.thumb.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
	self.thumb.layer.cornerRadius = 8; self.thumb.clipsToBounds = YES;
	self.jobName = PDPL(PDBoldFont(30), [UIColor whiteColor], NSTextAlignmentLeft);
	self.jobName.numberOfLines = 2;
	self.percentLabel = PDPL(PDLightFont(72), [UIColor whiteColor], NSTextAlignmentLeft);
	self.bar = [[PDProgressBar alloc] initWithFrame:CGRectZero];
	self.layerLabel = PDPL([UIFont systemFontOfSize:19], PD_DIM, NSTextAlignmentLeft);
	self.elapsedLabel = PDPL([UIFont systemFontOfSize:19], PD_DIM, NSTextAlignmentLeft);
	self.remainLabel = PDPL(PDLightFont(34), [UIColor whiteColor], NSTextAlignmentLeft);
	self.doneAtLabel = PDPL([UIFont systemFontOfSize:19], PD_DIM, NSTextAlignmentLeft);
	self.speedLabel = PDPL([UIFont systemFontOfSize:19], PD_DIM, NSTextAlignmentLeft);
	self.jobState = PDPL([UIFont boldSystemFontOfSize:18], PD_ACCENT, NSTextAlignmentLeft);
	self.pauseBtn = PDButton(@"Pause", PD_AMBER);
	[self.pauseBtn addTarget:self action:@selector(pauseResume) forControlEvents:UIControlEventTouchUpInside];
	self.stopBtn = PDButton(@"Stop", PD_RED);
	[self.stopBtn addTarget:self action:@selector(confirmStop) forControlEvents:UIControlEventTouchUpInside];
	for (UIView *v in [NSArray arrayWithObjects:self.thumb, self.jobName, self.percentLabel, self.bar, self.layerLabel,
			self.elapsedLabel, self.remainLabel, self.doneAtLabel, self.speedLabel, self.jobState, self.pauseBtn, self.stopBtn, nil]) [self addSubview:v];
}

- (void)buildFans {
	NSArray *names = [NSArray arrayWithObjects:@"Part", @"Aux", @"Chamber", nil];
	NSArray *desc = [NSArray arrayWithObjects:@"cools the printed layer", @"auxiliary side fan", @"enclosure exhaust", nil];
	NSMutableArray *ns = [NSMutableArray array], *subs = [NSMutableArray array], *vs = [NSMutableArray array], *ss = [NSMutableArray array];
	for (int i = 0; i < 3; i++) {
		UILabel *n = PDPL(PDBoldFont(22), [UIColor whiteColor], NSTextAlignmentLeft);
		n.text = [names objectAtIndex:i];
		UILabel *sub = PDPL([UIFont systemFontOfSize:14], PD_FAINT, NSTextAlignmentLeft);
		sub.text = [desc objectAtIndex:i];
		UILabel *v = PDPL(PDLightFont(40), [UIColor whiteColor], NSTextAlignmentRight);
		UISlider *s = [[UISlider alloc] initWithFrame:CGRectZero];
		s.minimumValue = 0; s.maximumValue = 100; s.tag = i;
		[s addTarget:self action:@selector(fanDrag:) forControlEvents:UIControlEventValueChanged];
		[s addTarget:self action:@selector(fanSet:) forControlEvents:UIControlEventTouchUpInside];
		[s addTarget:self action:@selector(fanSet:) forControlEvents:UIControlEventTouchUpOutside];
		[ns addObject:n]; [subs addObject:sub]; [vs addObject:v]; [ss addObject:s];
		for (UIView *w in [NSArray arrayWithObjects:n, sub, v, s, nil]) [self addSubview:w];
	}
	self.fanName = ns; self.fanSub = subs; self.fanVal = vs; self.fanSlider = ss;
}

- (void)buildSpeed {
	NSMutableArray *bs = [NSMutableArray array];
	for (int i = 0; i < 4; i++) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
		b.tag = i;
		b.titleLabel.font = PDBoldFont(22);
		b.titleLabel.numberOfLines = 2;
		b.titleLabel.textAlignment = NSTextAlignmentCenter;
		[b setTitle:[NSString stringWithFormat:@"%@\n%@", PDSpeedNames[i], PDSpeedDesc[i]] forState:UIControlStateNormal];
		[b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
		b.layer.cornerRadius = 12;
		b.backgroundColor = PD_TILE;
		[b addTarget:self action:@selector(pickSpeed:) forControlEvents:UIControlEventTouchUpInside];
		[bs addObject:b]; [self addSubview:b];
	}
	self.speedBtns = bs;
	self.speedNow = PDPL(PDLightFont(26), [UIColor whiteColor], NSTextAlignmentCenter);
	self.speedSlider = [[UISlider alloc] initWithFrame:CGRectZero];
	self.speedSlider.minimumValue = 30; self.speedSlider.maximumValue = 200;
	[self.speedSlider addTarget:self action:@selector(speedDrag) forControlEvents:UIControlEventValueChanged];
	[self.speedSlider addTarget:self action:@selector(speedSliderSet) forControlEvents:UIControlEventTouchUpInside];
	[self.speedSlider addTarget:self action:@selector(speedSliderSet) forControlEvents:UIControlEventTouchUpOutside];
	self.speedSliderVal = PDPL([UIFont systemFontOfSize:16], PD_DIM, NSTextAlignmentCenter);
	for (UIView *v in [NSArray arrayWithObjects:self.speedNow, self.speedSlider, self.speedSliderVal, nil]) [self addSubview:v];
}

- (UIView *)tileNamed:(NSString *)name {
	UIView *t = [[UIView alloc] initWithFrame:CGRectZero];
	t.backgroundColor = PD_TILE;
	t.layer.cornerRadius = 10;
	UILabel *n = PDPL([UIFont boldSystemFontOfSize:12], PD_FAINT, NSTextAlignmentLeft);
	n.text = [name uppercaseString]; n.tag = 1;
	UILabel *v = PDPL(PDLightFont(26), [UIColor whiteColor], NSTextAlignmentLeft);
	v.tag = 2;
	[t addSubview:n]; [t addSubview:v];
	[self addSubview:t];
	return t;
}

- (void)buildMachine {
	// left: live camera, status tiles, quick actions
	[self makeCamera];
	self.camera.userInteractionEnabled = YES;
	[self.camera addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleCam)]];
	self.camNote = PDPL([UIFont boldSystemFontOfSize:15], [UIColor whiteColor], NSTextAlignmentCenter);
	self.camNote.shadowColor = [UIColor blackColor]; self.camNote.shadowOffset = CGSizeMake(0, 1);
	[self addSubview:self.camNote];
	NSArray *tn = [NSArray arrayWithObjects:@"Nozzle", @"Bed", @"Chamber", @"Part fan", @"Aux fan", @"Chamber fan", @"Motors", @"Z offset", @"Speed", nil];
	NSMutableArray *tiles = [NSMutableArray array];
	for (NSString *n in tn) [tiles addObject:[self tileNamed:n]];
	self.tiles = tiles;
	NSArray *ql = [NSArray arrayWithObjects:@"Preheat PLA", @"Preheat PETG", @"Cool down", nil];
	NSMutableArray *qb = [NSMutableArray array];
	for (int i = 0; i < 3; i++) {
		UIButton *b = PDButton([ql objectAtIndex:i], i == 2 ? PD_ACCENT : PD_HOT);
		b.titleLabel.font = PDBoldFont(16); b.tag = i;
		[b addTarget:self action:@selector(quickAction:) forControlEvents:UIControlEventTouchUpInside];
		[qb addObject:b]; [self addSubview:b];
	}
	self.quickBtns = qb;
	self.lightBtn = PDButton(@"Light", PD_AMBER);
	self.lightBtn.titleLabel.font = PDBoldFont(16);
	[self.lightBtn addTarget:self action:@selector(toggleLight) forControlEvents:UIControlEventTouchUpInside];
	self.machineNote = PDPL([UIFont systemFontOfSize:14], PD_FAINT, NSTextAlignmentLeft);
	self.machineNote.numberOfLines = 3;

	// right: per-axis jog rows, home, files
	self.moveTitle = PDPL(PDLightFont(28), [UIColor whiteColor], NSTextAlignmentLeft);
	self.moveTitle.text = @"Move";
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	NSMutableArray *jb = [NSMutableArray array], *sc = [NSMutableArray array], *an = [NSMutableArray array], *ap = [NSMutableArray array], *hb = [NSMutableArray array];
	for (int a = 0; a < 3; a++) {
		UILabel *n = PDPL(PDBoldFont(30), PD_ACCENT, NSTextAlignmentLeft);
		n.text = PDAxisNames[a];
		UILabel *pos = PDPL(PDLightFont(34), [UIColor whiteColor], NSTextAlignmentLeft);
		[an addObject:n]; [ap addObject:pos];
		const double *steps = a == 2 ? PDJogStepsZ : PDJogStepsXY;
		NSMutableArray *items = [NSMutableArray array];
		for (int i = 0; i < 4; i++) [items addObject:[NSString stringWithFormat:@"%g mm", steps[i]]];
		UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:items];
		seg.segmentedControlStyle = UISegmentedControlStyleBar;
		seg.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
		NSString *key = [NSString stringWithFormat:@"PDJogStep%@", PDAxisNames[a]];
		int sel = [ud objectForKey:key] ? (int)[ud integerForKey:key] : PDJogDefault[a];
		seg.selectedSegmentIndex = MAX(0, MIN(3, sel));
		seg.tag = a;
		[seg addTarget:self action:@selector(stepChanged:) forControlEvents:UIControlEventValueChanged];
		[sc addObject:seg];
		for (int d = 0; d < 2; d++) {
			UIButton *b = PDButton(d ? @"+" : @"−", PD_ACCENT);
			b.titleLabel.font = PDBoldFont(30); b.tag = a * 2 + d;
			[b addTarget:self action:@selector(jog:) forControlEvents:UIControlEventTouchUpInside];
			[jb addObject:b];
		}
		UIButton *h = PDButton([NSString stringWithFormat:@"⌂ Home %@", PDAxisNames[a]], PD_DIM);
		h.titleLabel.font = PDBoldFont(15); h.tag = a;
		[h addTarget:self action:@selector(home:) forControlEvents:UIControlEventTouchUpInside];
		[hb addObject:h];
		for (UIView *v in [NSArray arrayWithObjects:n, pos, seg, [jb objectAtIndex:a * 2], [jb objectAtIndex:a * 2 + 1], h, nil]) [self addSubview:v];
	}
	UIButton *all = PDButton(@"⌂ Home all", PD_GREEN);
	all.titleLabel.font = PDBoldFont(16); all.tag = 3;
	[all addTarget:self action:@selector(home:) forControlEvents:UIControlEventTouchUpInside];
	[hb addObject:all];
	self.jogBtns = jb; self.stepCtls = sc; self.axisNames = an; self.axisPos = ap; self.homeBtns = hb;
	self.filesTitle = PDPL([UIFont boldSystemFontOfSize:13], PD_FAINT, NSTextAlignmentLeft);
	self.filesTitle.text = @"STORED FILES · TAP ONE TO PRINT";
	self.filesTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	self.filesTable.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
	self.filesTable.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
	self.filesTable.layer.cornerRadius = 10; self.filesTable.clipsToBounds = YES;
	self.filesTable.dataSource = self; self.filesTable.delegate = self; self.filesTable.rowHeight = 50;
	for (UIView *v in [NSArray arrayWithObjects:self.lightBtn, self.machineNote, self.moveTitle, all, self.filesTitle, self.filesTable, nil]) [self addSubview:v];
}

#pragma mark - Refresh

- (void)filesChanged { [self.filesTable reloadData]; [self refresh]; }

- (void)refresh {
	PDPrinter *p = [PDPrinter shared];
	self.statusLabel.text = p.connected ? @"" : @"Printer offline";
	if ([_kind isEqualToString:@"camera"]) [self refreshCamera];
	else if ([_kind isEqualToString:@"job"]) [self refreshJob];
	else if ([_kind isEqualToString:@"file"]) [self refreshFile];
	else if ([_kind isEqualToString:@"fans"]) [self refreshFans];
	else if ([_kind isEqualToString:@"speed"]) [self refreshSpeed];
	else if ([_kind isEqualToString:@"machine"]) [self refreshMachine];
}

- (void)refreshCamera {
	PDPrinter *p = [PDPrinter shared];
	BOOL run = self.camOn && p.connected && p.videoURL && [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
	self.camera.url = run ? [NSURL URLWithString:p.videoURL] : nil;
	self.fpsLabel.text = (self.camera.hasFrame && self.camOn && self.camera.fps >= 0.5) ? [NSString stringWithFormat:@"%.0f fps", self.camera.fps] : @"";
	if ([_kind isEqualToString:@"machine"]) {
		self.camNote.text = !p.connected ? @"" : self.camOn ? @"" : @"Camera paused · tap to resume";
		self.camera.alpha = self.camOn ? 1 : 0.45;
		return;
	}
	self.camNote.text = p.connected ? @"Live view of the print. The printer allows four viewers at once." : @"Printer offline.";
	[self.camToggle setTitle:self.camOn ? @"Pause camera" : @"Resume camera" forState:UIControlStateNormal];
}

- (void)refreshJob {
	PDPrinter *p = [PDPrinter shared];
	NSDictionary *st = p.status, *pi = PDDict(st, @"PrintInfo"), *task = p.lastTask;
	PDJobState js = p.jobState;
	BOOL active = p.isBusy || js == PDJobComplete || js == PDJobStopped;
	NSString *file = PDStr(pi, @"Filename"); if (![file length]) file = PDStr(task, @"TaskName");
	self.jobName.text = [file length] ? PDPrettyFileName(file) : (p.connected ? @"No jobs yet" : @"–");
	self.jobState.text = p.jobStateText;
	int cl = [PDNum(pi, @"CurrentLayer") intValue], tl = [PDNum(pi, @"TotalLayer") intValue];
	int pct = [PDNum(pi, @"PrintSpeedPct") intValue];
	self.speedLabel.text = (active && pct) ? [NSString stringWithFormat:@"Speed %d%%", pct] : @"";
	if (active) {
		double prog = p.progress;
		self.percentLabel.text = [NSString stringWithFormat:@"%.0f%%", prog * 100];
		self.bar.hidden = NO; self.bar.progress = prog;
		self.bar.color = js == PDJobPaused ? PD_AMBER : js == PDJobComplete ? PD_GREEN : js == PDJobStopped ? PD_RED : PD_ACCENT;
		self.layerLabel.text = tl ? [NSString stringWithFormat:@"Layer %d of %d", cl, tl] : @"";
		self.elapsedLabel.text = [NSString stringWithFormat:@"Elapsed %@", PDDuration(p.elapsed)];
		if (js == PDJobComplete || js == PDJobStopped) { self.remainLabel.text = js == PDJobComplete ? @"Done" : @"Stopped"; self.doneAtLabel.text = @""; }
		else {
			double rem = p.remaining;
			self.remainLabel.text = [NSString stringWithFormat:@"%@ left", PDDuration(rem)];
			NSDateFormatter *df = [[NSDateFormatter alloc] init]; [df setDateFormat:@"h:mm a"];
			self.doneAtLabel.text = rem > 0 ? [NSString stringWithFormat:@"done ≈ %@", [df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:rem]]] : @"";
		}
		[self loadThumb:PDStr(task, @"Thumbnail")];
	} else {
		self.percentLabel.text = @""; self.bar.hidden = YES; self.remainLabel.text = @""; self.doneAtLabel.text = @"";
		if (task) {
			double b = [PDNum(task, @"BeginTime") doubleValue], e = [PDNum(task, @"EndTime") doubleValue];
			NSDateFormatter *df = [[NSDateFormatter alloc] init]; [df setDateFormat:@"EEE MMM d, h:mm a"];
			int reason = [PDNum(task, @"ErrorStatusReason") intValue];
			self.remainLabel.text = reason ? @"Stopped" : @"Finished";
			self.doneAtLabel.text = e > 0 ? [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:e]] : @"";
			int layers = [PDNum(task, @"AlreadyPrintLayer") intValue];
			self.layerLabel.text = layers ? [NSString stringWithFormat:@"%d layers", layers] : @"";
			self.elapsedLabel.text = (b > 0 && e > b) ? [NSString stringWithFormat:@"Took %@", PDDuration(e - b)] : @"";
			[self loadThumb:PDStr(task, @"Thumbnail")];
		} else { self.layerLabel.text = @""; self.elapsedLabel.text = @""; [self loadThumb:nil]; }
	}
	BOOL paused = js == PDJobPaused;
	[self.pauseBtn setTitle:paused ? @"Resume" : @"Pause" forState:UIControlStateNormal];
	self.pauseBtn.enabled = p.connected && (js == PDJobPrinting || paused);
	self.stopBtn.enabled = p.connected && p.isBusy && js != PDJobStopping;
	self.pauseBtn.alpha = self.pauseBtn.enabled ? 1 : 0.4;
	self.stopBtn.alpha = self.stopBtn.enabled ? 1 : 0.4;
	[self refreshViewer];
}

#pragma mark - Job / file 3D viewer

- (BOOL)isFilePage { return [_kind isEqualToString:@"file"]; }
- (PDToolpathLoader *)viewerLoader { return [PDToolpathLoader loaderForSlot:[self isFilePage] ? @"files" : @"job"]; }

- (void)refreshViewer {
	PDPrinter *p = [PDPrinter shared];
	NSString *path = [self isFilePage] ? [PDFilesCard selectedPath] : [p jobFilePath];
	if ([self isFilePage] && !path) { self.viewerPath = nil; self.viewer.toolpath = nil; }
	if (path && p.connected && ![path isEqualToString:self.viewerPath]) {
		self.viewerPath = path;
		_following = YES;
		[self.viewer resetView];
		[[self viewerLoader] loadPath:path url:[p urlForFile:path] size:[p sizeOfFile:path]];
	}
	[self updateViewerState];
}

- (void)toolpathChanged { [self updateViewerState]; }

- (void)retryToolpath {
	PDPrinter *p = [PDPrinter shared];
	if (!self.viewerPath) return;
	PDToolpathLoader *L = [self viewerLoader];
	if ([L.requestedPath isEqualToString:self.viewerPath]) [L reload];
	else [L loadPath:self.viewerPath url:[p urlForFile:self.viewerPath] size:[p sizeOfFile:self.viewerPath]];
}

// Map the printer's layer counter onto the parsed layers (the counts match for Elegoo/Orca files; scale if not).
static NSInteger PDMapLayer(int printerLayer, int printerTotal, NSInteger parsed) {
	if (printerTotal > 0 && printerTotal != parsed) return (NSInteger)llround(printerLayer * (double)parsed / printerTotal);
	return printerLayer;
}

// The live picture: how many layers are done and which one is printing (-1 none), from status or the last task.
- (void)liveDone:(NSInteger *)done current:(NSInteger *)cur partial:(BOOL *)partial forLayers:(NSInteger)nl {
	PDPrinter *p = [PDPrinter shared];
	NSDictionary *pi = PDDict(p.status, @"PrintInfo"), *task = p.lastTask;
	*done = nl; *cur = -1; *partial = NO;
	BOOL sameFile = [[p jobFilePath] isEqualToString:self.viewerPath];
	if (p.isBusy && sameFile && [PDStr(pi, @"Filename") length]) {
		int cl = [PDNum(pi, @"CurrentLayer") intValue], tl = [PDNum(pi, @"TotalLayer") intValue];
		if (cl <= 0) { *done = 0; return; }   // heating / leveling: nothing printed yet
		NSInteger idx = MAX(0, MIN(nl - 1, PDMapLayer(cl, tl, nl) - 1));
		*done = idx; *cur = idx;
		return;
	}
	if (p.jobState == PDJobComplete && sameFile) return;
	if ([PDStr(task, @"TaskName") isEqualToString:self.viewerPath]) {
		int already = [PDNum(task, @"AlreadyPrintLayer") intValue];
		int total = [PDNum(PDDict(task, @"SliceInformation"), @"total_layer_numbers") intValue];
		if (already > 0 && total > 0 && already < total) {
			*done = MAX(0, MIN(nl, PDMapLayer(already, total, nl)));
			*partial = YES;
		}
	}
}

- (void)updateViewerState {
	if (!self.viewer) return;
	PDPrinter *p = [PDPrinter shared];
	PDToolpathLoader *L = [self viewerLoader];
	PDToolpath *tp = [L.toolpath.path isEqualToString:self.viewerPath] ? L.toolpath : nil;
	self.viewer.toolpath = tp;
	NSString *msg = @"";
	BOOL showRetry = NO;
	if (!self.viewerPath) msg = !p.connected ? @"Printer offline." : [self isFilePage] ? @"Pick a file from the list." : @"No print job yet.\nStart one from the Files card.";
	else if ([L.loadingPath isEqualToString:self.viewerPath])
		msg = L.progress > 0.01 ? [NSString stringWithFormat:@"Loading the toolpath… %.0f%%", L.progress * 100] : @"Loading the toolpath…";
	else if (!tp && L.error && [L.requestedPath isEqualToString:self.viewerPath]) { msg = L.error; showRetry = YES; }
	self.viewerMsg.text = msg;
	self.viewerMsg.hidden = ![msg length];
	self.retryBtn.hidden = !showRetry;

	NSInteger nl = tp ? (NSInteger)tp.layerCount : 0;
	self.layerSlider.hidden = nl == 0;
	self.layerSlider.maximumValue = MAX(1, nl);
	if (!nl) {
		self.viewerInfo.text = @""; self.viewerStats.text = @"";
		[self updateFollowButton];
		return;
	}
	NSInteger done, cur; BOOL partial;
	[self liveDone:&done current:&cur partial:&partial forLayers:nl];
	const float *lz = tp.layerZ;
	if (_following) {
		self.viewer.doneLayers = done;
		self.viewer.currentLayer = cur;
		if (!self.layerSlider.tracking) self.layerSlider.value = cur >= 0 ? cur + 1 : done;
		if (cur >= 0) self.viewerInfo.text = [NSString stringWithFormat:@"Layer %d of %d · Z %.2f mm", (int)cur + 1, (int)nl, lz[cur]];
		else if (partial) self.viewerInfo.text = [NSString stringWithFormat:@"Stopped at layer %d of %d · Z %.2f mm", (int)done, (int)nl, lz[MAX(0, done - 1)]];
		else if (done == 0) self.viewerInfo.text = [NSString stringWithFormat:@"%d layers · waiting for the first", (int)nl];
		else self.viewerInfo.text = [NSString stringWithFormat:@"%d layers · %.1f mm tall", (int)nl, tp.maxZ];
	} else {
		NSInteger v = MAX(1, MIN(nl, (NSInteger)lroundf(self.layerSlider.value)));
		self.viewer.doneLayers = v - 1;
		self.viewer.currentLayer = v - 1;
		self.viewerInfo.text = [NSString stringWithFormat:@"Preview · layer %d of %d · Z %.2f mm", (int)v, (int)nl, lz[v - 1]];
	}
	self.viewerStats.text = [NSString stringWithFormat:@"%@ · outer walls, %.1fk lines (≥%.1f mm) · %.1f MB G-code",
		PDPrettyFileName(tp.path), tp.segmentCount / 1000.0, tp.minLen, tp.fileBytes / 1048576.0];
	[self updateFollowButton];
}

- (void)updateFollowButton {
	BOOL live = [PDPrinter shared].isBusy;
	NSString *t = _following ? @"Reset view" : (live ? @"Follow print" : @"Show all");
	[self.followBtn setTitle:t forState:UIControlStateNormal];
	self.followBtn.hidden = self.layerSlider.hidden;
}

- (void)scrubLayers {
	_following = NO;
	[self updateViewerState];
}

- (void)followTapped {
	if (_following) [self.viewer resetView];
	_following = YES;
	[self updateViewerState];
}

- (void)loadThumb:(NSString *)url {
	if ((url == nil && self.thumbURL == nil) || [url isEqualToString:self.thumbURL]) return;
	self.thumbURL = url;
	self.thumb.image = nil;
	if (![url length]) return;
	// File-detail thumbnails come back with raw spaces in the path, which NSURL refuses.
	NSURL *u = [NSURL URLWithString:url] ?: [NSURL URLWithString:[url stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
	if (!u) return;
	NSURLRequest *req = [NSURLRequest requestWithURL:u cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:10];
	[NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
		UIImage *img = d ? [UIImage imageWithData:d] : nil;
		if (img && [url isEqualToString:self.thumbURL]) self.thumb.image = img;
	}];
}

- (void)refreshFans {
	PDPrinter *p = [PDPrinter shared];
	NSDictionary *fans = PDDict(p.status, @"CurrentFanSpeed");
	NSString *keys[] = {@"ModelFan", @"AuxiliaryFan", @"BoxFan"};
	for (int i = 0; i < 3; i++) {
		NSNumber *v = PDNum(fans, keys[i]);
		UILabel *vl = [self.fanVal objectAtIndex:i];
		vl.text = v ? [NSString stringWithFormat:@"%d%%", [v intValue]] : @"–";
		vl.textColor = [v intValue] > 0 ? PD_ACCENT : [UIColor whiteColor];
		UISlider *s = [self.fanSlider objectAtIndex:i];
		s.enabled = p.connected;
		if (!s.tracking) s.value = [v intValue];
	}
}

- (void)refreshSpeed {
	PDPrinter *p = [PDPrinter shared];
	int pct = [PDNum(PDDict(p.status, @"PrintInfo"), @"PrintSpeedPct") intValue];
	BOOL printing = p.jobState == PDJobPrinting || p.jobState == PDJobPaused || p.jobState == PDJobPreparing;
	for (int i = 0; i < 4; i++) {
		UIButton *b = [self.speedBtns objectAtIndex:i];
		BOOL cur = PDSpeedVals[i] == pct;
		b.backgroundColor = cur ? [PD_ACCENT colorWithAlphaComponent:0.25] : PD_TILE;
		b.layer.borderWidth = cur ? 2 : 0;
		b.layer.borderColor = PD_ACCENT.CGColor;
		b.enabled = p.connected && printing; b.alpha = b.enabled ? 1 : 0.5;
	}
	self.speedNow.text = !p.connected ? @"Printer offline" : printing ? [NSString stringWithFormat:@"Now printing at %d%%", pct] : @"No job running — speed sets while printing";
	self.speedSlider.enabled = p.connected && printing;
	if (!self.speedSlider.tracking && pct) self.speedSlider.value = pct;
	self.speedSliderVal.text = [NSString stringWithFormat:@"Custom: %d%%", (int)self.speedSlider.value];
}

- (void)setTile:(NSUInteger)i text:(NSString *)text color:(UIColor *)color {
	UILabel *v = (UILabel *)[[self.tiles objectAtIndex:i] viewWithTag:2];
	v.text = text;
	v.textColor = color ?: [UIColor whiteColor];
}

static NSString *PDTempText(NSNumber *cur, NSNumber *target) {
	if (!cur) return @"–";
	int t = [target intValue];
	return t > 0 ? [NSString stringWithFormat:@"%.0f° → %d°", [cur doubleValue], t] : [NSString stringWithFormat:@"%.0f°", [cur doubleValue]];
}

- (void)refreshMachine {
	PDPrinter *p = [PDPrinter shared];
	NSDictionary *st = p.status;
	BOOL idle = p.connected && !p.isBusy;
	[self refreshCamera];
	for (UIButton *b in self.jogBtns) { b.enabled = idle; b.alpha = idle ? 1 : 0.4; }
	for (UIButton *b in self.homeBtns) { b.enabled = idle; b.alpha = idle ? 1 : 0.4; }
	for (UISegmentedControl *c in self.stepCtls) c.enabled = idle;
	for (UIButton *b in self.quickBtns) { b.enabled = idle; b.alpha = idle ? 1 : 0.4; }

	double xyz[3];
	BOOL havePos = st && [p getPosition:xyz];
	for (int a = 0; a < 3; a++)
		[(UILabel *)[self.axisPos objectAtIndex:a] setText:havePos ? [NSString stringWithFormat:@"%.2f mm", xyz[a]] : @"–"];

	// temperatures, coloured while heating toward a target
	NSString *tk[3][2] = {{@"TempOfNozzle", @"TempTargetNozzle"}, {@"TempOfHotbed", @"TempTargetHotbed"}, {@"TempOfBox", @"TempTargetBox"}};
	for (int i = 0; i < 3; i++) {
		NSNumber *cur = PDNum(st, tk[i][0]), *tgt = PDNum(st, tk[i][1]);
		UIColor *c = [tgt intValue] > 0 ? ((fabs([cur doubleValue] - [tgt doubleValue]) < 3) ? PD_GREEN : PD_HOT) : nil;
		[self setTile:i text:PDTempText(cur, tgt) color:c];
	}
	NSDictionary *fans = PDDict(st, @"CurrentFanSpeed");
	NSString *fk[3] = {@"ModelFan", @"AuxiliaryFan", @"BoxFan"};
	for (int i = 0; i < 3; i++) {
		NSNumber *v = PDNum(fans, fk[i]);
		[self setTile:3 + i text:v ? [NSString stringWithFormat:@"%d%%", [v intValue]] : @"–" color:[v intValue] > 0 ? PD_ACCENT : nil];
	}
	// motors: Attributes.DevicesStatus {X,Y,Z}MotorStatus, 1 = driver answering
	NSDictionary *dev = PDDict(p.attributes, @"DevicesStatus");
	if (dev) {
		NSMutableArray *bad = [NSMutableArray array];
		for (int a = 0; a < 3; a++)
			if ([PDNum(dev, [NSString stringWithFormat:@"%@MotorStatus", PDAxisNames[a]]) intValue] != 1) [bad addObject:PDAxisNames[a]];
		if ([bad count]) [self setTile:6 text:[NSString stringWithFormat:@"%@ fault", [bad componentsJoinedByString:@" "]] color:PD_RED];
		else [self setTile:6 text:@"X Y Z ok" color:PD_GREEN];
	} else [self setTile:6 text:@"–" color:nil];
	NSNumber *zo = PDNum(st, @"ZOffset");
	[self setTile:7 text:zo ? [NSString stringWithFormat:@"%.3f mm", fabs([zo doubleValue]) < 0.0005 ? 0.0 : [zo doubleValue]] : @"–" color:nil];
	NSNumber *sp = PDNum(PDDict(st, @"PrintInfo"), @"PrintSpeedPct");
	[self setTile:8 text:sp ? [NSString stringWithFormat:@"%d%%", [sp intValue]] : @"–" color:nil];

	self.lightBtn.enabled = p.connected;
	BOOL lightOn = [PDNum(PDDict(st, @"LightStatus"), @"SecondLight") intValue] != 0;
	[self.lightBtn setTitle:lightOn ? @"Light on" : @"Light off" forState:UIControlStateNormal];
	[self.lightBtn setTitleColor:lightOn ? PD_AMBER : PD_DIM forState:UIControlStateNormal];
	self.lightBtn.backgroundColor = [(lightOn ? PD_AMBER : PD_DIM) colorWithAlphaComponent:lightOn ? 0.2 : 0.1];
	if (!p.connected) self.machineNote.text = @"Printer offline.";
	else if (p.isBusy) self.machineNote.text = [NSString stringWithFormat:@"%@ — moves, homing, preheat and printing are disabled while a job runs.", p.jobStateText];
	else self.machineNote.text = @"Home before jogging: the printer refuses moves on an unhomed axis. Positions are in printer coordinates.";
}

#pragma mark - Actions

- (void)toggleCam { self.camOn = !self.camOn; [self refreshCamera]; }

- (void)pauseResume {
	PDPrinter *p = [PDPrinter shared];
	if (p.jobState == PDJobPaused) [p resume]; else [p pause];
}

- (void)confirmStop {
	_alertKind = 1;
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Stop this print?" message:@"The job can't be resumed after stopping."
		delegate:self cancelButtonTitle:@"Keep printing" otherButtonTitles:@"Stop print", nil];
	[a show];
}

- (void)fanDrag:(UISlider *)s {
	UILabel *vl = [self.fanVal objectAtIndex:s.tag];
	vl.text = [NSString stringWithFormat:@"%d%%", (int)s.value];
	vl.textColor = s.value > 0 ? PD_ACCENT : [UIColor whiteColor];
}
- (void)fanSet:(UISlider *)s {
	NSString *keys[] = {@"ModelFan", @"AuxiliaryFan", @"BoxFan"};
	[[PDPrinter shared] setFan:keys[s.tag] percent:(int)roundf(s.value)];
}

- (void)pickSpeed:(UIButton *)b { [[PDPrinter shared] setSpeedPercent:PDSpeedVals[b.tag]]; }
- (void)speedDrag { self.speedSliderVal.text = [NSString stringWithFormat:@"Custom: %d%%", (int)self.speedSlider.value]; }
- (void)speedSliderSet { [[PDPrinter shared] setSpeedPercent:(int)roundf(self.speedSlider.value)]; }

- (void)jog:(UIButton *)b {
	int a = (int)b.tag / 2;
	double dir = (b.tag % 2 == 0) ? -1 : 1;
	UISegmentedControl *seg = [self.stepCtls objectAtIndex:a];
	int i = seg.selectedSegmentIndex >= 0 ? (int)seg.selectedSegmentIndex : PDJogDefault[a];
	double step = (a == 2 ? PDJogStepsZ : PDJogStepsXY)[i];
	[[PDPrinter shared] jog:PDAxisNames[a] by:dir * step];
}
- (void)stepChanged:(UISegmentedControl *)seg {
	[[NSUserDefaults standardUserDefaults] setInteger:seg.selectedSegmentIndex forKey:[NSString stringWithFormat:@"PDJogStep%@", PDAxisNames[seg.tag]]];
}
- (void)home:(UIButton *)b {
	NSString *axes[] = {@"X", @"Y", @"Z", @"XYZ"};
	[[PDPrinter shared] home:axes[b.tag]];
}
- (void)quickAction:(UIButton *)b {
	PDPrinter *p = [PDPrinter shared];
	if (p.isBusy) return;
	switch (b.tag) {
		case 0: [p setNozzleTarget:210]; [p setBedTarget:60]; break;   // PLA
		case 1: [p setNozzleTarget:240]; [p setBedTarget:70]; break;   // PETG
		default: [p setNozzleTarget:0]; [p setBedTarget:0]; break;
	}
}
- (void)toggleLight {
	PDPrinter *p = [PDPrinter shared];
	BOOL on = [PDNum(PDDict(p.status, @"LightStatus"), @"SecondLight") intValue] != 0;
	[p setLight:!on];
}

- (void)alertView:(UIAlertView *)a clickedButtonAtIndex:(NSInteger)i {
	if (i == a.cancelButtonIndex) { _pendingFile = nil; return; }
	if (_alertKind == 1) [[PDPrinter shared] stop];
	else if (_alertKind == 2 && [_pendingFile length]) [[PDPrinter shared] startFile:_pendingFile];
	_pendingFile = nil;
}

#pragma mark - Files table

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
	NSInteger n = [[PDPrinter shared].files count];
	return n ? n : 1;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"f"];
	if (!c) {
		c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
		c.backgroundColor = [UIColor clearColor];
		c.textLabel.textColor = [UIColor whiteColor];
		c.detailTextLabel.textColor = PD_DIM;
		c.selectionStyle = UITableViewCellSelectionStyleGray;
		UIView *sel = [[UIView alloc] init];
		sel.backgroundColor = [PD_ACCENT colorWithAlphaComponent:0.28];
		c.selectedBackgroundView = sel;
	}
	NSArray *files = [PDPrinter shared].files;
	if (![files count]) {
		c.textLabel.text = [PDPrinter shared].connected ? @"No files on the printer" : @"Printer offline";
		c.detailTextLabel.text = @""; c.userInteractionEnabled = NO; return c;
	}
	c.userInteractionEnabled = YES;
	NSDictionary *f = [files objectAtIndex:ip.row];
	c.textLabel.text = PDPrettyFileName(PDStr(f, @"name"));
	int layers = [PDNum(f, @"TotalLayers") intValue];
	double mb = [PDNum(f, @"FileSize") doubleValue] / 1048576.0;
	NSString *slicer = PDSlicerTime(PDStr(f, @"name"));   // tells same-named slices apart
	c.detailTextLabel.text = [NSString stringWithFormat:@"%@%@%@", slicer ? [slicer stringByAppendingString:@"  "] : @"",
		layers ? [NSString stringWithFormat:@"%d layers  ", layers] : @"", mb > 0 ? [NSString stringWithFormat:@"%.1f MB", mb] : @""];
	return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	PDPrinter *p = [PDPrinter shared];
	if ([self isFilePage]) {   // inspect it (the Files card follows); Print is a separate button here
		if ((NSUInteger)ip.row < [p.files count]) [PDFilesCard setSelectedPath:PDStr([p.files objectAtIndex:(NSUInteger)ip.row], @"name")];
		return;
	}
	[t deselectRowAtIndexPath:ip animated:YES];
	if (![p.files count] || p.isBusy) return;
	NSDictionary *f = [p.files objectAtIndex:ip.row];
	_pendingFile = [PDStr(f, @"name") copy];
	_alertKind = 2;
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Print this file?" message:PDPrettyFileName(_pendingFile)
		delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Print", nil];
	[a show];
}

#pragma mark - File page

- (void)buildFile {
	[self buildViewer];
	self.thumb = [[UIImageView alloc] initWithFrame:CGRectZero];
	self.thumb.contentMode = UIViewContentModeScaleAspectFit;
	self.thumb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
	self.thumb.layer.cornerRadius = 8; self.thumb.clipsToBounds = YES;
	self.jobName = PDPL(PDBoldFont(24), [UIColor whiteColor], NSTextAlignmentLeft);
	self.jobName.numberOfLines = 3;
	self.fileInfo = PDPL([UIFont systemFontOfSize:16], PD_DIM, NSTextAlignmentLeft);
	self.fileInfo.numberOfLines = 0;
	self.fileInfo.adjustsFontSizeToFitWidth = NO;
	self.filesTitle = PDPL([UIFont boldSystemFontOfSize:13], PD_FAINT, NSTextAlignmentLeft);
	self.filesTitle.text = @"FILES ON THE PRINTER · TAP TO INSPECT";
	self.filesTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	self.filesTable.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
	self.filesTable.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
	self.filesTable.layer.cornerRadius = 10; self.filesTable.clipsToBounds = YES;
	self.filesTable.dataSource = self; self.filesTable.delegate = self; self.filesTable.rowHeight = 50;
	self.printFileBtn = PDButton(@"Print this file", PD_GREEN);
	[self.printFileBtn addTarget:self action:@selector(confirmPrintSelected) forControlEvents:UIControlEventTouchUpInside];
	for (UIView *v in [NSArray arrayWithObjects:self.thumb, self.jobName, self.fileInfo, self.filesTitle, self.filesTable, self.printFileBtn, nil]) [self addSubview:v];
	[[PDPrinter shared] refreshFiles];
}

static NSString *PDSlicerTime(NSString *path) {
	NSString *last = [[[[path lastPathComponent] stringByDeletingPathExtension] componentsSeparatedByString:@"_"] lastObject];
	return ([last rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == 0 && [last length] <= 9) ? last : nil;
}

- (void)refreshFile {
	PDPrinter *p = [PDPrinter shared];
	NSString *path = [PDFilesCard selectedPath];
	NSDictionary *f = nil;
	for (NSDictionary *x in p.files) if ([PDStr(x, @"name") isEqualToString:path]) f = x;
	if (path) [p requestFileDetail:path];
	NSDictionary *det = [p.fileDetailPath isEqualToString:path] ? p.fileDetail : nil;
	self.jobName.text = path ? PDPrettyFileName(path) : (p.connected ? @"No file selected" : @"Printer offline");

	NSMutableArray *lines = [NSMutableArray array];
	if (path) {
		double est = [PDNum(det, @"EstTime") doubleValue], g = [PDNum(det, @"EstWeight") doubleValue];
		NSString *slicer = PDSlicerTime(path);
		if (est > 0) [lines addObject:[NSString stringWithFormat:@"Slicer estimate %@%@", PDDuration(est), g > 0 ? [NSString stringWithFormat:@" · %.1f g filament", g] : @""]];
		else if (slicer) [lines addObject:[NSString stringWithFormat:@"Slicer estimate %@", slicer]];
		int layers = [PDNum(f, @"TotalLayers") intValue];
		double mb = [PDNum(f, @"FileSize") doubleValue] / 1048576.0;
		PDToolpath *tp = self.viewer.toolpath;
		NSMutableArray *bits = [NSMutableArray array];
		if (layers || tp.layerCount) [bits addObject:[NSString stringWithFormat:@"%d layers", layers ?: (int)tp.layerCount]];
		if (tp) [bits addObject:[NSString stringWithFormat:@"%.1f mm tall", tp.maxZ]];
		if (mb > 0) [bits addObject:[NSString stringWithFormat:@"%.1f MB", mb]];
		if ([bits count]) [lines addObject:[bits componentsJoinedByString:@" · "]];
		if (tp) [lines addObject:[NSString stringWithFormat:@"Footprint %.0f × %.0f mm, at X %.0f–%.0f, Y %.0f–%.0f",
			tp.maxX - tp.minX, tp.maxY - tp.minY, tp.minX, tp.maxX, tp.minY, tp.maxY]];
		int colours = (int)[PDArr(det, @"ColorMapping") count];
		if (colours > 1) [lines addObject:[NSString stringWithFormat:@"%d filament colours", colours]];
		NSDateFormatter *df = [[NSDateFormatter alloc] init]; [df setDateFormat:@"EEE MMM d, h:mm a"];
		double ct = [PDNum(f, @"CreateTime") doubleValue];
		if (ct > 0) [lines addObject:[NSString stringWithFormat:@"Uploaded %@", [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:ct]]]];
		NSDictionary *task = p.lastTask;
		if ([PDStr(task, @"TaskName") isEqualToString:path] && [PDNum(task, @"EndTime") doubleValue] > 0)
			[lines addObject:[NSString stringWithFormat:@"Last printed %@", [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:[PDNum(task, @"EndTime") doubleValue]]]]];
	}
	self.fileInfo.text = [lines componentsJoinedByString:@"\n"];
	[self loadThumb:PDStr(det, @"Thumbnail")];
	BOOL can = p.connected && !p.isBusy && f != nil;
	self.printFileBtn.enabled = can;
	self.printFileBtn.alpha = can ? 1 : 0.4;
	[self.printFileBtn setTitle:p.isBusy ? @"Printer busy" : @"Print this file" forState:UIControlStateNormal];
	[self selectRowForPath:path];
	[self refreshViewer];
	[self setNeedsLayout];
}

- (void)selectRowForPath:(NSString *)path {
	NSArray *files = [PDPrinter shared].files;
	for (NSUInteger i = 0; i < [files count]; i++)
		if ([PDStr([files objectAtIndex:i], @"name") isEqualToString:path]) {
			NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)i inSection:0];
			if (![[self.filesTable indexPathForSelectedRow] isEqual:ip])
				[self.filesTable selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionMiddle];
			return;
		}
}

- (void)confirmPrintSelected {
	NSString *path = [PDFilesCard selectedPath];
	if (!path || [PDPrinter shared].isBusy) return;
	_pendingFile = [path copy];
	_alertKind = 2;
	[[[UIAlertView alloc] initWithTitle:@"Print this file?" message:[NSString stringWithFormat:@"%@\nMake sure the bed is clear.", PDPrettyFileName(path)]
		delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Print", nil] show];
}

- (void)layoutFile:(CGFloat)top {
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 24;
	CGFloat rx = [self layoutViewer:top], rw = W - rx - pad;
	self.thumb.frame = CGRectMake(rx, top, 96, 96);
	self.jobName.frame = CGRectMake(rx + 110, top, rw - 110, 96);
	CGSize fs = [self.fileInfo.text sizeWithFont:self.fileInfo.font constrainedToSize:CGSizeMake(rw, 200) lineBreakMode:NSLineBreakByWordWrapping];
	self.fileInfo.frame = CGRectMake(rx, top + 108, rw, MAX(20, fs.height));
	CGFloat ty = top + 108 + MAX(20, fs.height) + 14;
	self.filesTitle.frame = CGRectMake(rx + 2, ty, rw, 18);
	CGFloat by = H - pad - 56;
	self.filesTable.frame = CGRectMake(rx, ty + 22, rw, by - 12 - (ty + 22));
	self.printFileBtn.frame = CGRectMake(rx, by, rw, 56);
}

#pragma mark - Layout

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 20;
	self.backButton.frame = CGRectMake(pad, 16, 168, 48);
	self.titleLabel.frame = CGRectMake(200, 16, W - 400, 48);
	self.clockLabel.frame = CGRectMake(W - pad - 160, 16, 160, 48);
	self.statusLabel.frame = CGRectMake(pad + 4, H - 26, W - 2 * pad, 18);
	CGFloat top = 84;
	if ([_kind isEqualToString:@"camera"]) [self layoutCamera:top];
	else if ([_kind isEqualToString:@"job"]) [self layoutJob:top];
	else if ([_kind isEqualToString:@"file"]) [self layoutFile:top];
	else if ([_kind isEqualToString:@"fans"]) [self layoutFans:top];
	else if ([_kind isEqualToString:@"speed"]) [self layoutSpeed:top];
	else if ([_kind isEqualToString:@"machine"]) [self layoutMachine:top];
}

- (void)layoutCamera:(CGFloat)top {
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 20;
	CGFloat cw = W - 2 * pad, ch = cw * 9 / 16;
	if (ch > H - top - 120) { ch = H - top - 120; cw = ch * 16 / 9; }
	CGFloat cx = (W - cw) / 2;
	self.camera.frame = CGRectMake(cx, top, cw, ch);
	self.fpsLabel.frame = CGRectMake(cx + cw - 110, top + ch - 24, 100, 18);
	self.camNote.frame = CGRectMake(cx, top + ch + 16, cw - 220, 44);
	self.camToggle.frame = CGRectMake(cx + cw - 200, top + ch + 16, 200, 52);
}

// Lays out the viewer block on the left; returns where the right column starts.
- (CGFloat)layoutViewer:(CGFloat)top {
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 24;
	CGFloat vw = MIN(560, W * 0.55), vh = H - top - pad - 56;
	CGRect v = CGRectMake(pad, top, vw, vh);
	self.viewer.frame = v;
	self.viewerInfo.frame = CGRectMake(v.origin.x + 14, v.origin.y + 10, vw - 140, 22);
	self.viewerStats.frame = CGRectMake(v.origin.x + 14, CGRectGetMaxY(v) - 26, vw - 28, 18);
	self.viewerMsg.frame = CGRectMake(v.origin.x + 30, v.origin.y + vh / 2 - 60, vw - 60, 80);
	self.retryBtn.frame = CGRectMake(v.origin.x + vw / 2 - 70, v.origin.y + vh / 2 + 30, 140, 48);
	self.thumb.frame = CGRectMake(CGRectGetMaxX(v) - 110, v.origin.y + 10, 100, 100);
	CGFloat sy = CGRectGetMaxY(v) + 10;
	self.followBtn.frame = CGRectMake(CGRectGetMaxX(v) - 130, sy, 130, 44);
	self.layerSlider.frame = CGRectMake(pad + 4, sy + 5, vw - 150, 34);
	return pad + vw + 28;
}

- (void)layoutJob:(CGFloat)top {
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 24;
	CGFloat rx = [self layoutViewer:top], rw = W - rx - pad;
	self.jobName.frame = CGRectMake(rx, top, rw, 72);
	self.jobState.frame = CGRectMake(rx, top + 76, rw, 24);
	self.percentLabel.frame = CGRectMake(rx, top + 104, rw, 80);
	self.bar.frame = CGRectMake(rx, top + 192, rw, 18);
	self.remainLabel.frame = CGRectMake(rx, top + 220, rw, 40);
	self.doneAtLabel.frame = CGRectMake(rx, top + 262, rw, 24);
	self.layerLabel.frame = CGRectMake(rx, top + 300, rw, 24);
	self.elapsedLabel.frame = CGRectMake(rx, top + 328, rw, 24);
	self.speedLabel.frame = CGRectMake(rx, top + 356, rw, 24);
	CGFloat bw = (rw - 16) / 2, by = H - pad - 60;
	self.pauseBtn.frame = CGRectMake(rx, by, bw, 60);
	self.stopBtn.frame = CGRectMake(rx + bw + 16, by, bw, 60);
}

- (void)layoutFans:(CGFloat)top {
	CGFloat W = self.bounds.size.width, pad = 40;
	CGFloat rowH = 120, y = top + 20;
	for (int i = 0; i < 3; i++) {
		UILabel *n = [self.fanName objectAtIndex:i];
		n.frame = CGRectMake(pad, y, 300, 30);
		[(UILabel *)[self.fanSub objectAtIndex:i] setFrame:CGRectMake(pad, y + 32, 300, 20)];
		[(UILabel *)[self.fanVal objectAtIndex:i] setFrame:CGRectMake(W - pad - 160, y, 160, 44)];
		[(UISlider *)[self.fanSlider objectAtIndex:i] setFrame:CGRectMake(pad, y + 62, W - 2 * pad, 34)];
		y += rowH;
	}
}

- (void)layoutSpeed:(CGFloat)top {
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 30;
	CGFloat gw = (W - 2 * pad - 3 * 16) / 4, gh = MIN(200, H - top - 200);
	for (int i = 0; i < 4; i++) [(UIButton *)[self.speedBtns objectAtIndex:i] setFrame:CGRectMake(pad + i * (gw + 16), top + 20, gw, gh)];
	CGFloat y = top + 40 + gh;
	self.speedNow.frame = CGRectMake(pad, y, W - 2 * pad, 34); y += 50;
	self.speedSliderVal.frame = CGRectMake(pad, y, W - 2 * pad, 22); y += 26;
	self.speedSlider.frame = CGRectMake(pad + 60, y, W - 2 * pad - 120, 34);
}

- (void)layoutMachine:(CGFloat)top {
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 24;
	// left column: camera, 3x3 status tiles, quick actions
	CGFloat lw = MIN(488, (W - 3 * pad) * 0.5), ch = floor(lw * 9 / 16);
	self.camera.frame = CGRectMake(pad, top, lw, ch);
	self.fpsLabel.frame = CGRectMake(pad + lw - 110, top + ch - 24, 100, 18);
	self.camNote.frame = CGRectMake(pad, top + ch / 2 - 12, lw, 24);
	CGFloat g = 10, tw = floor((lw - 2 * g) / 3), th = 62, ty = top + ch + 12;
	for (NSUInteger i = 0; i < [self.tiles count]; i++) {
		UIView *t = [self.tiles objectAtIndex:i];
		t.frame = CGRectMake(pad + (i % 3) * (tw + g), ty + (i / 3) * (th + g), tw, th);
		[t viewWithTag:1].frame = CGRectMake(10, 7, tw - 20, 15);
		[t viewWithTag:2].frame = CGRectMake(10, 23, tw - 20, 34);
	}
	CGFloat qy = ty + 3 * (th + g) + 2;
	for (int i = 0; i < 3; i++) [(UIButton *)[self.quickBtns objectAtIndex:i] setFrame:CGRectMake(pad + i * (tw + g), qy, tw, 50)];
	CGFloat ly = qy + 60;
	self.lightBtn.frame = CGRectMake(pad, ly, tw, 50);
	self.machineNote.frame = CGRectMake(pad + tw + g + 2, ly, lw - tw - g - 2, MIN(54, H - ly - 30));

	// right column: per-axis rows, then files
	CGFloat rx = pad + lw + pad, rw = W - rx - pad;
	self.moveTitle.frame = CGRectMake(rx, top, rw - 170, 44);
	[(UIButton *)[self.homeBtns objectAtIndex:3] setFrame:CGRectMake(rx + rw - 160, top, 160, 44)];
	CGFloat y = top + 56, rowH = 112, bw = 84;
	for (int a = 0; a < 3; a++) {
		[(UILabel *)[self.axisNames objectAtIndex:a] setFrame:CGRectMake(rx, y, 34, 44)];
		[(UILabel *)[self.axisPos objectAtIndex:a] setFrame:CGRectMake(rx + 40, y, rw - 180, 44)];
		[(UIButton *)[self.homeBtns objectAtIndex:a] setFrame:CGRectMake(rx + rw - 130, y + 2, 130, 40)];
		[(UIButton *)[self.jogBtns objectAtIndex:a * 2] setFrame:CGRectMake(rx, y + 50, bw, 52)];
		[(UIButton *)[self.jogBtns objectAtIndex:a * 2 + 1] setFrame:CGRectMake(rx + rw - bw, y + 50, bw, 52)];
		[(UISegmentedControl *)[self.stepCtls objectAtIndex:a] setFrame:CGRectMake(rx + bw + 12, y + 56, rw - 2 * bw - 24, 40)];
		y += rowH;
	}
	self.filesTitle.frame = CGRectMake(rx + 2, y + 2, rw, 18);
	self.filesTable.frame = CGRectMake(rx, y + 24, rw, H - (y + 24) - 30);
}

@end
