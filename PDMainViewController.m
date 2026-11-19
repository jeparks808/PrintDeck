#import "PDMainViewController.h"
#import "PDPrinter.h"
#import "PDDiscovery.h"
#import "PDMJPEGView.h"
#import "PDViews.h"
#import "PDPanels.h"
#import "PDUtil.h"
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>

enum { PDSheetNozzle = 1, PDSheetBed, PDSheetFan, PDSheetMenu };
enum { PDAlertStop = 1, PDAlertCustomTemp, PDAlertAddress };

static NSString *const PDFanKeys[] = {@"ModelFan", @"AuxiliaryFan", @"BoxFan"};
static NSString *const PDFanNames[] = {@"Part", @"Aux", @"Chamber"};
static const int PDSpeeds[] = {50, 100, 130, 160};

@interface PDMainViewController () <UIActionSheetDelegate, UIAlertViewDelegate, UIPopoverControllerDelegate>
// header
@property (nonatomic, strong) UILabel *nameLabel, *stateLabel, *clockLabel, *hostLabel;
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UIButton *menuButton;
// left
@property (nonatomic, strong) PDMJPEGView *camera;
@property (nonatomic, strong) UILabel *cameraOff, *fpsLabel;
@property (nonatomic, strong) PDCard *jobCard;
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, strong) UILabel *jobName, *percentLabel, *layerLabel, *elapsedLabel, *remainLabel, *doneAtLabel, *jobHint;
@property (nonatomic, strong) PDProgressBar *bar;
@property (nonatomic, strong) UIButton *pauseButton, *stopButton, *filesButton;
// right
@property (nonatomic, strong) PDTempCard *nozzleCard, *bedCard, *chamberCard;
@property (nonatomic, strong) PDCard *fanCard, *speedCard;
@property (nonatomic, strong) NSArray *fanButtons;
@property (nonatomic, strong) UISegmentedControl *speedControl;
@property (nonatomic, strong) UIButton *lightButton, *moveButton;
// offline
@property (nonatomic, strong) UIView *offline;
@property (nonatomic, strong) UILabel *offlineTitle, *offlineDetail;

@property (nonatomic, strong) PDDiscovery *discovery;
@property (nonatomic, assign) BOOL searching;
@property (nonatomic, strong) UIPopoverController *popover;
@property (nonatomic, strong) NSTimer *clockTimer;
@property (nonatomic, strong) NSMutableDictionary *thumbCache;
@property (nonatomic, copy) NSString *thumbURL;
@property (nonatomic, assign) int sheetFan;
@property (nonatomic, assign) int customTempFor; // PDSheetNozzle / PDSheetBed
@property (nonatomic, assign) SystemSoundID chime, alarm;
@property (nonatomic, assign) CFAbsoluteTime offlineSince;
@end

@implementation PDMainViewController

#pragma mark - Build

- (void)loadView {
	UIView *v = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	v.backgroundColor = PD_BG;
	v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	self.view = v;
	self.thumbCache = [NSMutableDictionary dictionary];

	self.nameLabel = PDLabel(PDBoldFont(26), [UIColor whiteColor]);
	self.stateLabel = PDLabel([UIFont boldSystemFontOfSize:16], PD_ACCENT);
	self.stateLabel.textAlignment = NSTextAlignmentCenter;
	self.stateLabel.layer.cornerRadius = 13;
	self.stateLabel.layer.borderWidth = 1.5;
	self.clockLabel = PDLabel(PDLightFont(30), [UIColor whiteColor]);
	self.clockLabel.textAlignment = NSTextAlignmentRight;
	self.hostLabel = PDLabel([UIFont systemFontOfSize:13], PD_DIM);
	self.hostLabel.textAlignment = NSTextAlignmentRight;
	self.dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
	self.dot.layer.cornerRadius = 5;
	self.menuButton = [UIButton buttonWithType:UIButtonTypeCustom];
	[self.menuButton setTitle:@"•••" forState:UIControlStateNormal];
	self.menuButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
	[self.menuButton setTitleColor:PD_DIM forState:UIControlStateNormal];
	[self.menuButton addTarget:self action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];

	self.camera = [[PDMJPEGView alloc] initWithFrame:CGRectMake(0, 0, 600, 338)];
	self.camera.layer.cornerRadius = 12;
	self.cameraOff = PDLabel([UIFont systemFontOfSize:16], PD_DIM);
	self.cameraOff.textAlignment = NSTextAlignmentCenter;
	self.cameraOff.text = @"Camera off (••• menu to turn on)";
	self.cameraOff.backgroundColor = PD_TILE;
	self.cameraOff.layer.cornerRadius = 12;
	self.fpsLabel = PDLabel([UIFont boldSystemFontOfSize:11], [UIColor colorWithWhite:1 alpha:0.7]);
	self.fpsLabel.textAlignment = NSTextAlignmentRight;
	self.fpsLabel.shadowColor = [UIColor blackColor];
	self.fpsLabel.shadowOffset = CGSizeMake(0, 1);

	self.jobCard = [[PDCard alloc] initWithFrame:CGRectZero];
	self.jobCard.titleLabel.text = @"JOB";
	self.thumb = [[UIImageView alloc] initWithFrame:CGRectZero];
	self.thumb.contentMode = UIViewContentModeScaleAspectFit;
	self.thumb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
	self.thumb.layer.cornerRadius = 8;
	self.thumb.clipsToBounds = YES;
	self.jobName = PDLabel([UIFont boldSystemFontOfSize:22], [UIColor whiteColor]);
	self.percentLabel = PDLabel(PDLightFont(56), [UIColor whiteColor]);
	self.percentLabel.textAlignment = NSTextAlignmentRight;
	self.layerLabel = PDLabel([UIFont systemFontOfSize:17], PD_DIM);
	self.elapsedLabel = PDLabel([UIFont systemFontOfSize:17], PD_DIM);
	self.remainLabel = PDLabel(PDLightFont(34), [UIColor whiteColor]);
	self.doneAtLabel = PDLabel([UIFont systemFontOfSize:17], PD_DIM);
	self.jobHint = PDLabel([UIFont systemFontOfSize:14], PD_FAINT);
	self.bar = [[PDProgressBar alloc] initWithFrame:CGRectZero];
	for (UIView *s in [NSArray arrayWithObjects:self.thumb, self.jobName, self.percentLabel, self.layerLabel, self.elapsedLabel,
			self.remainLabel, self.doneAtLabel, self.jobHint, self.bar, nil]) [self.jobCard addSubview:s];
	self.pauseButton = PDButton(@"Pause", PD_AMBER);
	[self.pauseButton addTarget:self action:@selector(pauseResume) forControlEvents:UIControlEventTouchUpInside];
	self.stopButton = PDButton(@"Stop", PD_RED);
	[self.stopButton addTarget:self action:@selector(confirmStop) forControlEvents:UIControlEventTouchUpInside];
	self.filesButton = PDButton(@"Files", PD_ACCENT);
	[self.filesButton addTarget:self action:@selector(showFiles:) forControlEvents:UIControlEventTouchUpInside];

	self.nozzleCard = [[PDTempCard alloc] initWithFrame:CGRectZero];
	self.nozzleCard.titleLabel.text = @"NOZZLE";
	self.bedCard = [[PDTempCard alloc] initWithFrame:CGRectZero];
	self.bedCard.titleLabel.text = @"BED";
	self.chamberCard = [[PDTempCard alloc] initWithFrame:CGRectZero];
	self.chamberCard.titleLabel.text = @"CHAMBER";
	self.nozzleCard.tappable = self.bedCard.tappable = YES;
	[self.nozzleCard addTarget:self action:@selector(tapNozzle:) forControlEvents:UIControlEventTouchUpInside];
	[self.bedCard addTarget:self action:@selector(tapBed:) forControlEvents:UIControlEventTouchUpInside];

	self.fanCard = [[PDCard alloc] initWithFrame:CGRectZero];
	self.fanCard.titleLabel.text = @"FANS";
	NSMutableArray *fans = [NSMutableArray array];
	for (int i = 0; i < 3; i++) {
		UIButton *b = PDButton(@"", [UIColor whiteColor]);
		b.titleLabel.numberOfLines = 2;
		b.titleLabel.textAlignment = NSTextAlignmentCenter;
		b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
		b.tag = i;
		[b addTarget:self action:@selector(tapFan:) forControlEvents:UIControlEventTouchUpInside];
		[self.fanCard addSubview:b];
		[fans addObject:b];
	}
	self.fanButtons = fans;

	self.speedCard = [[PDCard alloc] initWithFrame:CGRectZero];
	self.speedCard.titleLabel.text = @"PRINT SPEED";
	self.speedControl = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"Silent", @"Balanced", @"Sport", @"Ludicrous", nil]];
	self.speedControl.segmentedControlStyle = UISegmentedControlStyleBar;
	self.speedControl.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
	[self.speedControl addTarget:self action:@selector(speedChanged) forControlEvents:UIControlEventValueChanged];
	[self.speedCard addSubview:self.speedControl];

	self.lightButton = PDButton(@"Light", PD_AMBER);
	[self.lightButton addTarget:self action:@selector(toggleLight) forControlEvents:UIControlEventTouchUpInside];
	self.moveButton = PDButton(@"Move / Home", PD_ACCENT);
	[self.moveButton addTarget:self action:@selector(showMove:) forControlEvents:UIControlEventTouchUpInside];

	self.offline = [[UIView alloc] initWithFrame:CGRectZero];
	self.offline.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
	self.offlineTitle = PDLabel(PDLightFont(34), [UIColor whiteColor]);
	self.offlineTitle.textAlignment = NSTextAlignmentCenter;
	self.offlineDetail = PDLabel([UIFont systemFontOfSize:17], PD_DIM);
	self.offlineDetail.textAlignment = NSTextAlignmentCenter;
	self.offlineDetail.numberOfLines = 3;
	UIButton *search = PDButton(@"Search again", PD_ACCENT);
	search.tag = 1;
	[search addTarget:self action:@selector(startSearch) forControlEvents:UIControlEventTouchUpInside];
	UIButton *addr = PDButton(@"Enter address", PD_DIM);
	addr.tag = 2;
	[addr addTarget:self action:@selector(promptAddress) forControlEvents:UIControlEventTouchUpInside];
	for (UIView *s in [NSArray arrayWithObjects:self.offlineTitle, self.offlineDetail, search, addr, nil]) [self.offline addSubview:s];

	for (UIView *s in [NSArray arrayWithObjects:self.nameLabel, self.stateLabel, self.clockLabel, self.hostLabel, self.dot, self.menuButton,
			self.cameraOff, self.camera, self.fpsLabel, self.jobCard, self.pauseButton, self.stopButton, self.filesButton,
			self.nozzleCard, self.bedCard, self.chamberCard, self.fanCard, self.speedCard, self.lightButton, self.moveButton,
			self.offline, nil]) [v addSubview:s];

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	PDPrinter *p = [PDPrinter shared];
	[nc addObserver:self selector:@selector(refresh) name:PDPrinterDidUpdateNotification object:p];
	[nc addObserver:self selector:@selector(connectionChanged) name:PDPrinterConnectionNotification object:p];
	[nc addObserver:self selector:@selector(printerEvent:) name:PDPrinterEventNotification object:p];
	self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
	[self loadSounds];
	self.offlineSince = CFAbsoluteTimeGetCurrent();
	[self tick];
	[self refresh];
}

- (void)loadSounds {
	NSURL *u = [[NSBundle mainBundle] URLForResource:@"chime" withExtension:@"wav"];
	if (u) AudioServicesCreateSystemSoundID((__bridge CFURLRef)u, &_chime);
	u = [[NSBundle mainBundle] URLForResource:@"alarm" withExtension:@"wav"];
	if (u) AudioServicesCreateSystemSoundID((__bridge CFURLRef)u, &_alarm);
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return UIInterfaceOrientationIsLandscape(o); }

- (void)viewWillLayoutSubviews {
	[super viewWillLayoutSubviews];
	CGRect b = self.view.bounds;
	CGFloat W = b.size.width, H = b.size.height, g = 16, top = 70;
	// header
	self.nameLabel.frame = CGRectMake(g, 16, 300, 34);
	CGSize ns = [self.nameLabel.text sizeWithFont:self.nameLabel.font];
	CGFloat sx = g + MIN(300, ns.width) + 14;
	self.stateLabel.frame = CGRectMake(sx, 20, MAX(110, [self.stateLabel.text sizeWithFont:self.stateLabel.font].width + 30), 27);
	self.menuButton.frame = CGRectMake(W - 56, 12, 48, 44);
	self.clockLabel.frame = CGRectMake(W - 56 - 150, 10, 140, 34);
	self.hostLabel.frame = CGRectMake(W - 56 - 300, 44, 290, 16);
	CGSize hs = [self.hostLabel.text sizeWithFont:self.hostLabel.font];
	self.dot.center = CGPointMake(W - 56 - 10 - MIN(290, hs.width) - 10, 52);

	// left column: camera (16:9) + job card + buttons
	CGFloat lw = 600;
	CGRect cam = CGRectMake(g, top, lw, round(lw * 9 / 16));
	self.camera.frame = cam;
	self.cameraOff.frame = cam;
	self.fpsLabel.frame = CGRectMake(CGRectGetMaxX(cam) - 110, CGRectGetMaxY(cam) - 22, 100, 16);
	CGFloat btnH = 60, by = H - g - btnH;
	CGFloat jy = CGRectGetMaxY(cam) + 12;
	self.jobCard.frame = CGRectMake(g, jy, lw, by - 12 - jy);
	CGFloat bw = (lw - 2 * 12) / 3;
	self.pauseButton.frame = CGRectMake(g, by, bw, btnH);
	self.stopButton.frame = CGRectMake(g + bw + 12, by, bw, btnH);
	self.filesButton.frame = CGRectMake(g + 2 * (bw + 12), by, bw, btnH);
	[self layoutJobCard];

	// right column
	CGFloat rx = g + lw + g, rw = W - rx - g, y = top, gap = 10;
	CGFloat th = floor((by - gap - top - 110 - 84 - 4 * gap) / 3); // temperature cards share what's left
	self.nozzleCard.frame = CGRectMake(rx, y, rw, th); y += th + gap;
	self.bedCard.frame = CGRectMake(rx, y, rw, th); y += th + gap;
	self.chamberCard.frame = CGRectMake(rx, y, rw, th); y += th + gap;
	self.fanCard.frame = CGRectMake(rx, y, rw, 110); y += 110 + gap;
	CGRect fc = [self.fanCard contentBounds];
	CGFloat fw = (fc.size.width - 2 * 10) / 3;
	for (NSUInteger i = 0; i < 3; i++)
		[[self.fanButtons objectAtIndex:i] setFrame:CGRectMake(fc.origin.x + i * (fw + 10), fc.origin.y + 24, fw, fc.size.height - 24)];
	self.speedCard.frame = CGRectMake(rx, y, rw, 84);
	CGRect sc = [self.speedCard contentBounds];
	self.speedControl.frame = CGRectMake(sc.origin.x, sc.origin.y + 24, sc.size.width, 34);
	CGFloat half = (rw - 12) / 2;
	self.lightButton.frame = CGRectMake(rx, by, half, btnH);
	self.moveButton.frame = CGRectMake(rx + half + 12, by, half, btnH);

	self.offline.frame = CGRectMake(0, top - 6, W, H - top + 6);
	CGFloat cy = self.offline.bounds.size.height / 2 - 80;
	self.offlineTitle.frame = CGRectMake(40, cy, W - 80, 44);
	self.offlineDetail.frame = CGRectMake(100, cy + 50, W - 200, 66);
	[[self.offline viewWithTag:1] setFrame:CGRectMake(W / 2 - 210, cy + 130, 200, 54)];
	[[self.offline viewWithTag:2] setFrame:CGRectMake(W / 2 + 10, cy + 130, 200, 54)];
}

- (void)layoutJobCard {
	CGRect c = [self.jobCard contentBounds];
	CGFloat x = c.origin.x, y = c.origin.y + 24, ts = MIN(c.size.height - 24, 210);
	self.thumb.frame = CGRectMake(x, y, ts, ts);
	CGFloat tx = x + ts + 18, tw = CGRectGetMaxX(c) - tx, bottom = y + ts;
	self.jobName.frame = CGRectMake(tx, y - 4, tw - 120, 30);
	self.percentLabel.frame = CGRectMake(CGRectGetMaxX(c) - 120, y - 16, 120, 60);
	self.jobHint.frame = CGRectMake(tx, y + 28, tw - 120, 20);
	self.bar.frame = CGRectMake(tx, y + 60, tw, 16);
	self.remainLabel.frame = CGRectMake(tx, y + 92, tw, 44);
	self.doneAtLabel.frame = CGRectMake(tx, y + 138, tw, 22);
	self.doneAtLabel.textAlignment = NSTextAlignmentLeft;
	self.layerLabel.frame = CGRectMake(tx, bottom - 22, tw * 0.5, 22);
	self.elapsedLabel.frame = CGRectMake(tx + tw * 0.5, bottom - 22, tw * 0.5, 22);
	self.elapsedLabel.textAlignment = NSTextAlignmentRight;
}

#pragma mark - Updating

- (void)tick {
	NSDateFormatter *df = [[NSDateFormatter alloc] init];
	[df setDateFormat:@"h:mm"];
	self.clockLabel.text = [df stringFromDate:[NSDate date]];
	PDPrinter *p = [PDPrinter shared];
	if (self.camera.hasFrame && self.cameraEnabled && self.camera.fps >= 0.5) self.fpsLabel.text = [NSString stringWithFormat:@"%.0f fps", self.camera.fps];
	else self.fpsLabel.text = @"";
	// Keep the offline screen away for brief reconnects (Wi-Fi blips).
	BOOL showOffline = !p.connected && (CFAbsoluteTimeGetCurrent() - self.offlineSince > 4 || !p.host);
	if (showOffline != !self.offline.hidden) {
		self.offline.hidden = !showOffline;
		[self updateOfflineText];
	}
}

- (void)connectionChanged {
	PDPrinter *p = [PDPrinter shared];
	if (p.connected) {
		[[NSUserDefaults standardUserDefaults] setObject:p.host forKey:@"PDHost"];
		[[NSUserDefaults standardUserDefaults] setInteger:p.port forKey:@"PDPort"];
		[[NSUserDefaults standardUserDefaults] setInteger:p.videoPort forKey:@"PDVideoPort"];
		[[NSUserDefaults standardUserDefaults] synchronize];
	} else {
		self.offlineSince = CFAbsoluteTimeGetCurrent();
	}
	[self updateCamera];
	[self updateOfflineText];
	[self tick];
	[self refresh];
}

- (void)updateOfflineText {
	PDPrinter *p = [PDPrinter shared];
	if (self.searching) {
		self.offlineTitle.text = @"Looking for your printer…";
		self.offlineDetail.text = @"Searching the Wi-Fi for Elegoo printers.";
	} else if (!p.host) {
		self.offlineTitle.text = @"No printer found";
		self.offlineDetail.text = @"Make sure the printer is on and on the same Wi-Fi as this iPad, then search again — or enter its IP address (shown in the printer's network settings).";
	} else {
		self.offlineTitle.text = @"Printer offline";
		self.offlineDetail.text = [NSString stringWithFormat:@"Can't reach %@:%d (%@). Retrying every few seconds.", p.host, p.port, p.lastError ?: @"no answer"];
	}
}

- (void)setCameraEnabled:(BOOL)on {
	_cameraEnabled = on;
	[[NSUserDefaults standardUserDefaults] setBool:!on forKey:@"PDCameraOff"];
	[self updateCamera];
}

- (void)updateCamera {
	PDPrinter *p = [PDPrinter shared];
	BOOL run = self.cameraEnabled && p.connected && p.videoURL && [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
	self.camera.hidden = !self.cameraEnabled;
	self.cameraOff.hidden = self.cameraEnabled;
	self.camera.url = run ? [NSURL URLWithString:p.videoURL] : nil;
}

- (void)appDidResignActive { self.camera.url = nil; }
- (void)appDidBecomeActive { [self updateCamera]; [[PDPrinter shared] reconnectNow]; }

- (void)refresh {
	PDPrinter *p = [PDPrinter shared];
	NSDictionary *st = p.status, *pi = PDDict(st, @"PrintInfo");
	self.nameLabel.text = p.attributes ? p.printerName : @"PrintDeck";
	NSString *state = p.jobStateText;
	self.stateLabel.text = state;
	UIColor *sc = PD_DIM;
	switch (p.jobState) {
		case PDJobPrinting: sc = PD_ACCENT; break;
		case PDJobPreparing: case PDJobChecking: case PDJobRecovery: sc = PD_HOT; break;
		case PDJobPaused: case PDJobPausing: case PDJobStopping: sc = PD_AMBER; break;
		case PDJobComplete: sc = PD_GREEN; break;
		case PDJobStopped: sc = PD_RED; break;
		case PDJobIdle: sc = PD_GREEN; break;
		default: break;
	}
	if (!p.connected) sc = PD_RED;
	self.stateLabel.textColor = sc;
	self.stateLabel.layer.borderColor = [sc colorWithAlphaComponent:0.6].CGColor;
	self.stateLabel.backgroundColor = [sc colorWithAlphaComponent:0.12];
	self.dot.backgroundColor = p.connected ? PD_GREEN : PD_RED;
	self.hostLabel.text = p.host ? [NSString stringWithFormat:@"%@%@", p.host, p.port != 3030 ? [NSString stringWithFormat:@":%d", p.port] : @""] : @"not connected";

	// temperatures
	[self.nozzleCard setCurrent:PDNum(st, @"TempOfNozzle") target:PDNum(st, @"TempTargetNozzle") history:p.nozzleHistory];
	[self.bedCard setCurrent:PDNum(st, @"TempOfHotbed") target:PDNum(st, @"TempTargetHotbed") history:p.bedHistory];
	[self.chamberCard setCurrent:PDNum(st, @"TempOfBox") target:PDNum(st, @"TempTargetBox") history:p.chamberHistory];
	if ([PDNum(st, @"TempTargetBox") doubleValue] <= 0) self.chamberCard.targetLabel.text = @"no heater";

	// fans
	NSDictionary *fans = PDDict(st, @"CurrentFanSpeed");
	for (int i = 0; i < 3; i++) {
		UIButton *b = [self.fanButtons objectAtIndex:(NSUInteger)i];
		NSNumber *v = PDNum(fans, PDFanKeys[i]);
		[b setTitle:[NSString stringWithFormat:@"%@\n%@", PDFanNames[i], v ? [NSString stringWithFormat:@"%d%%", [v intValue]] : @"–"] forState:UIControlStateNormal];
		UIColor *c = [v intValue] > 0 ? PD_ACCENT : [UIColor whiteColor];
		[b setTitleColor:c forState:UIControlStateNormal];
		b.backgroundColor = [c colorWithAlphaComponent:[v intValue] > 0 ? 0.16 : 0.07];
	}

	// speed
	int pct = [PDNum(pi, @"PrintSpeedPct") intValue];
	NSInteger seg = UISegmentedControlNoSegment;
	for (int i = 0; i < 4; i++) if (PDSpeeds[i] == pct) seg = i;
	if (self.speedControl.selectedSegmentIndex != seg) self.speedControl.selectedSegmentIndex = seg;
	BOOL printing = p.jobState == PDJobPrinting || p.jobState == PDJobPaused || p.jobState == PDJobPreparing;
	self.speedControl.enabled = p.connected && printing;
	self.speedCard.alpha = self.speedControl.enabled ? 1 : 0.5;

	// light
	BOOL lightOn = [PDNum(PDDict(st, @"LightStatus"), @"SecondLight") intValue] != 0;
	[self.lightButton setTitle:lightOn ? @"Light on" : @"Light off" forState:UIControlStateNormal];
	UIColor *lc = lightOn ? PD_AMBER : PD_DIM;
	[self.lightButton setTitleColor:lc forState:UIControlStateNormal];
	self.lightButton.backgroundColor = [lc colorWithAlphaComponent:lightOn ? 0.2 : 0.1];

	// buttons
	BOOL busy = p.isBusy;
	BOOL paused = p.jobState == PDJobPaused;
	[self.pauseButton setTitle:paused ? @"Resume" : @"Pause" forState:UIControlStateNormal];
	[self.pauseButton setTitleColor:paused ? PD_GREEN : PD_AMBER forState:UIControlStateNormal];
	self.pauseButton.backgroundColor = [(paused ? PD_GREEN : PD_AMBER) colorWithAlphaComponent:0.14];
	self.pauseButton.enabled = p.connected && (p.jobState == PDJobPrinting || paused);
	self.stopButton.enabled = p.connected && busy && p.jobState != PDJobStopping;
	self.filesButton.enabled = p.connected;
	self.moveButton.enabled = p.connected && !busy;
	self.lightButton.enabled = p.connected;
	self.nozzleCard.enabled = self.bedCard.enabled = p.connected;
	for (UIButton *b in self.fanButtons) b.enabled = p.connected;
	for (UIButton *b in [NSArray arrayWithObjects:self.pauseButton, self.stopButton, self.filesButton, self.moveButton, self.lightButton, nil])
		b.alpha = b.enabled ? 1 : 0.45;

	// A "paused" alert is stale once the job is resumed or stopped (or this is a different printer).
	if (p.jobState != PDJobPaused && p.jobState != PDJobPausing) [PDEventOverlay dismissInView:self.view kind:@"paused"];
	[self refreshJob];
	[self.view setNeedsLayout];
}

- (void)refreshJob {
	PDPrinter *p = [PDPrinter shared];
	NSDictionary *pi = PDDict(p.status, @"PrintInfo");
	NSDictionary *task = p.lastTask;
	PDJobState js = p.jobState;
	BOOL active = p.isBusy || js == PDJobComplete || js == PDJobStopped;
	NSString *file = PDStr(pi, @"Filename");
	if (![file length]) file = PDStr(task, @"TaskName");
	BOOL taskMatches = task && (![PDStr(pi, @"TaskId") length] || [PDStr(pi, @"TaskId") isEqualToString:PDStr(task, @"TaskId")]);

	self.jobCard.titleLabel.text = active ? @"CURRENT JOB" : @"LAST JOB";
	self.jobName.text = [file length] ? PDPrettyFileName(file) : (p.connected ? @"No jobs yet" : @"–");
	double prog = active ? p.progress : (task ? 1 : 0);
	int cl = [PDNum(pi, @"CurrentLayer") intValue], tl = [PDNum(pi, @"TotalLayer") intValue];
	if (active) {
		self.percentLabel.text = [NSString stringWithFormat:@"%.0f%%", prog * 100];
		self.bar.progress = prog;
		self.bar.color = js == PDJobPaused ? PD_AMBER : js == PDJobComplete ? PD_GREEN : js == PDJobStopped ? PD_RED : PD_ACCENT;
		self.layerLabel.text = tl ? [NSString stringWithFormat:@"Layer %d of %d", cl, tl] : @"";
		self.elapsedLabel.text = [NSString stringWithFormat:@"Elapsed %@", PDDuration(p.elapsed)];
		if (js == PDJobComplete || js == PDJobStopped) {
			self.remainLabel.text = js == PDJobComplete ? @"Done" : @"Stopped";
			self.doneAtLabel.text = @"";
		} else {
			double rem = p.remaining;
			self.remainLabel.text = [NSString stringWithFormat:@"%@ left", PDDuration(rem)];
			NSDateFormatter *df = [[NSDateFormatter alloc] init];
			[df setDateFormat:@"h:mm a"];
			self.doneAtLabel.text = rem > 0 ? [NSString stringWithFormat:@"done ≈ %@", [df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:rem]]] : @"";
		}
		self.jobHint.text = js == PDJobPaused ? @"Paused" : (js == PDJobPrinting ? @"" : p.jobStateText);
		self.bar.hidden = NO;
	} else {
		self.percentLabel.text = @"";
		self.bar.progress = 0;
		self.bar.hidden = YES;
		self.remainLabel.text = @"";
		self.doneAtLabel.text = @"";
		if (task) {
			double b = [PDNum(task, @"BeginTime") doubleValue], e = [PDNum(task, @"EndTime") doubleValue];
			NSDateFormatter *df = [[NSDateFormatter alloc] init];
			[df setDateFormat:@"EEE MMM d, h:mm a"];
			int reason = [PDNum(task, @"ErrorStatusReason") intValue];
			self.jobHint.text = [NSString stringWithFormat:@"%@ %@", reason ? @"Stopped" : @"Finished", e > 0 ? [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:e]] : @""];
			int layers = [PDNum(task, @"AlreadyPrintLayer") intValue];
			self.layerLabel.text = layers ? [NSString stringWithFormat:@"%d layers", layers] : @"";
			self.elapsedLabel.text = (b > 0 && e > b) ? [NSString stringWithFormat:@"Took %@", PDDuration(e - b)] : @"";
		} else {
			self.jobHint.text = p.connected ? @"Tap Files to start a print." : @"";
			self.layerLabel.text = @"";
			self.elapsedLabel.text = @"";
		}
	}
	[self loadThumb:taskMatches ? PDStr(task, @"Thumbnail") : nil];
}

- (void)loadThumb:(NSString *)url {
	if ([url isEqualToString:self.thumbURL]) return;
	self.thumbURL = url;
	if (!url) { self.thumb.image = nil; return; }
	UIImage *cached = [self.thumbCache objectForKey:url];
	if (cached) { self.thumb.image = cached; return; }
	self.thumb.image = nil;
	NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:10];
	[NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
		UIImage *img = d ? [UIImage imageWithData:d] : nil;
		if (!img) return;
		[self.thumbCache setObject:img forKey:url];
		if ([url isEqualToString:self.thumbURL]) self.thumb.image = img;
	}];
}

#pragma mark - Events

- (void)printerEvent:(NSNotification *)n {
	NSString *kind = [n.userInfo objectForKey:@"kind"];
	[PDEventOverlay showInView:self.view kind:kind title:[n.userInfo objectForKey:@"title"] detail:[n.userInfo objectForKey:@"detail"]];
	SystemSoundID s = [kind isEqualToString:@"finished"] ? self.chime : self.alarm;
	if (s) {
		AudioServicesPlaySystemSound(s);
		// Repeat twice more so it is heard from another room.
		for (int i = 1; i <= 2; i++)
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ AudioServicesPlaySystemSound(s); });
	}
}

- (void)showTestEvent:(NSString *)kind {
	NSDictionary *t = [NSDictionary dictionaryWithObjectsAndKeys:
		@"Print finished", @"finished", @"Print paused", @"paused", @"Print stopped", @"failed", nil];
	NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:
		@"Kendama Mount, took 55m 11s", @"finished", @"The printer paused by itself. Check the filament.", @"paused",
		@"Kendama Mount: filament ran out", @"failed", nil];
	if (![t objectForKey:kind]) kind = @"finished";
	[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterEventNotification object:[PDPrinter shared]
		userInfo:[NSDictionary dictionaryWithObjectsAndKeys:kind, @"kind", [t objectForKey:kind], @"title", [d objectForKey:kind], @"detail", nil]];
}

#pragma mark - Discovery

- (void)startSearch {
	if (self.searching) return;
	self.searching = YES;
	[self updateOfflineText];
	if (!self.discovery) self.discovery = [[PDDiscovery alloc] init];
	__block BOOL found = NO;
	[self.discovery searchForSeconds:5 found:^(NSDictionary *info) {
		if (found) return;
		NSString *ip = PDStr(info, @"MainboardIP");
		if (![ip length]) return;
		found = YES;
		self.searching = NO;
		[self.discovery stop];
		[[PDPrinter shared] connectToHost:ip port:3030 videoPort:3031];
		[self updateCamera];
		[self updateOfflineText];
	} done:^{
		self.searching = NO;
		[self updateOfflineText];
	}];
}

- (void)promptAddress {
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Printer address" message:@"IP address, optionally with :port (default 3030)."
		delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Connect", nil];
	a.alertViewStyle = UIAlertViewStylePlainTextInput;
	a.tag = PDAlertAddress;
	UITextField *f = [a textFieldAtIndex:0];
	f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
	f.text = [PDPrinter shared].host;
	[a show];
}

#pragma mark - Actions

- (void)pauseResume {
	PDPrinter *p = [PDPrinter shared];
	if (p.jobState == PDJobPaused) [p resume]; else [p pause];
}

- (void)confirmStop {
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Stop this print?" message:@"The job can't be resumed after stopping."
		delegate:self cancelButtonTitle:@"Keep printing" otherButtonTitles:@"Stop print", nil];
	a.tag = PDAlertStop;
	[a show];
}

- (void)presentPopover:(UIViewController *)vc from:(UIView *)v {
	[self.popover dismissPopoverAnimated:NO];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
	nav.navigationBar.barStyle = UIBarStyleBlack;
	self.popover = [[UIPopoverController alloc] initWithContentViewController:nav];
	self.popover.delegate = self;
	[self.popover presentPopoverFromRect:v.bounds inView:v permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)pc { self.popover = nil; }

- (void)showFiles:(UIView *)sender {
	PDFilesViewController *f = [[PDFilesViewController alloc] initWithStyle:UITableViewStylePlain];
	__weak PDMainViewController *weakSelf = self;
	f.onDone = ^{ [weakSelf.popover dismissPopoverAnimated:YES]; weakSelf.popover = nil; };
	[self presentPopover:f from:sender];
}

- (void)showMove:(UIView *)sender {
	PDMoveViewController *m = [[PDMoveViewController alloc] init];
	m.title = @"Move / Home";
	[self presentPopover:m from:sender];
}

- (void)tapNozzle:(UIView *)v {
	UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:@"Nozzle temperature" delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
		otherButtonTitles:@"Off", @"200° (PLA)", @"220° (PLA+)", @"240° (PETG)", @"260° (ABS / ASA)", @"Custom…", nil];
	s.tag = PDSheetNozzle;
	[s showFromRect:v.bounds inView:v animated:YES];
}

- (void)tapBed:(UIView *)v {
	UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:@"Bed temperature" delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
		otherButtonTitles:@"Off", @"55° (PLA)", @"60° (PLA)", @"70° (PETG)", @"90° (ABS / ASA)", @"Custom…", nil];
	s.tag = PDSheetBed;
	[s showFromRect:v.bounds inView:v animated:YES];
}

- (void)tapFan:(UIButton *)b {
	self.sheetFan = (int)b.tag;
	UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%@ fan", PDFanNames[b.tag]] delegate:self
		cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:@"Off", @"30%", @"50%", @"70%", @"100%", nil];
	s.tag = PDSheetFan;
	[s showFromRect:b.bounds inView:b animated:YES];
}

- (void)speedChanged {
	NSInteger i = self.speedControl.selectedSegmentIndex;
	if (i >= 0 && i < 4) [[PDPrinter shared] setSpeedPercent:PDSpeeds[i]];
}

- (void)toggleLight {
	PDPrinter *p = [PDPrinter shared];
	BOOL on = [PDNum(PDDict(p.status, @"LightStatus"), @"SecondLight") intValue] != 0;
	[p setLight:!on];
}

- (void)showMenu {
	UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
		otherButtonTitles:self.cameraEnabled ? @"Turn camera off" : @"Turn camera on", @"Find printer on Wi-Fi", @"Enter printer address…", @"Reconnect", nil];
	s.tag = PDSheetMenu;
	[s showFromRect:self.menuButton.bounds inView:self.menuButton animated:YES];
}

- (void)actionSheet:(UIActionSheet *)s clickedButtonAtIndex:(NSInteger)i {
	if (i < 0) return;
	PDPrinter *p = [PDPrinter shared];
	switch (s.tag) {
		case PDSheetNozzle: {
			static const int t[] = {0, 200, 220, 240, 260};
			if (i < 5) [p setNozzleTarget:t[i]]; else [self promptCustomTemp:PDSheetNozzle];
			break;
		}
		case PDSheetBed: {
			static const int t[] = {0, 55, 60, 70, 90};
			if (i < 5) [p setBedTarget:t[i]]; else [self promptCustomTemp:PDSheetBed];
			break;
		}
		case PDSheetFan: {
			static const int f[] = {0, 30, 50, 70, 100};
			if (i < 5) [p setFan:PDFanKeys[self.sheetFan] percent:f[i]];
			break;
		}
		case PDSheetMenu:
			if (i == 0) self.cameraEnabled = !self.cameraEnabled;
			else if (i == 1) { self.offline.hidden = NO; [self startSearch]; }
			else if (i == 2) [self promptAddress];
			else if (i == 3) [p reconnectNow];
			break;
	}
}

- (void)promptCustomTemp:(int)which {
	self.customTempFor = which;
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:which == PDSheetNozzle ? @"Nozzle target (°C)" : @"Bed target (°C)"
		message:which == PDSheetNozzle ? @"0 – 300" : @"0 – 110" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Set", nil];
	a.alertViewStyle = UIAlertViewStylePlainTextInput;
	[a textFieldAtIndex:0].keyboardType = UIKeyboardTypeNumberPad;
	a.tag = PDAlertCustomTemp;
	[a show];
}

- (void)alertView:(UIAlertView *)a clickedButtonAtIndex:(NSInteger)i {
	if (i == a.cancelButtonIndex) return;
	PDPrinter *p = [PDPrinter shared];
	if (a.tag == PDAlertStop) {
		[p stop];
	} else if (a.tag == PDAlertCustomTemp) {
		int v = [[a textFieldAtIndex:0].text intValue];
		if (self.customTempFor == PDSheetNozzle) [p setNozzleTarget:MAX(0, MIN(300, v))];
		else [p setBedTarget:MAX(0, MIN(110, v))];
	} else if (a.tag == PDAlertAddress) {
		NSString *t = [[a textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSArray *hp = [t componentsSeparatedByString:@":"];
		if (![[hp objectAtIndex:0] length]) return;
		int port = [hp count] > 1 ? [[hp objectAtIndex:1] intValue] : 3030;
		[p connectToHost:[hp objectAtIndex:0] port:port videoPort:port == 3030 ? 3031 : port + 1];
		[self updateCamera];
	}
}

@end
