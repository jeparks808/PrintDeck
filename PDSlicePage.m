#import "PDSlicePage.h"
#import "PDSlicer.h"
#import "PDModelView.h"
#import "PDToolpath.h"
#import "PDToolpathView.h"
#import "PDPrinter.h"
#import "PDViews.h"
#import "PDUtil.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const PDSliceModelKey = @"PDSliceModelSource";
static NSString *const PDSliceTransformKey = @"PDSliceModelTransform";

static UILabel *PDSL(UIFont *f, UIColor *c, NSTextAlignment a) {
	UILabel *l = PDLabel(f, c);
	l.textAlignment = a;
	return l;
}

static UIButton *PDSmallButton(NSString *title, UIColor *color) {
	UIButton *b = PDButton(title, color);
	b.titleLabel.font = PDBoldFont(15);
	return b;
}

#pragma mark - Model picker

// The popover list: built-in test shapes, then the STL files in Documents (swipe to delete those).
@interface PDModelPicker : UITableViewController
@property (nonatomic, copy) void (^picked)(NSString *source);
@property (nonatomic, strong) NSArray *files;
@end

@implementation PDModelPicker

- (id)init {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
		self.contentSizeForViewInPopover = CGSizeMake(380, 520);
		[self reloadFiles];
	}
	return self;
}

- (void)reloadFiles {
	NSString *dir = [PDSlicer libraryDirectory];
	NSMutableArray *a = [NSMutableArray array];
	for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL])
		if ([[[f pathExtension] lowercaseString] isEqualToString:@"stl"]) [a addObject:[dir stringByAppendingPathComponent:f]];
	[a sortUsingComparator:^NSComparisonResult(NSString *x, NSString *y) {   // newest first
		NSDate *dx = [[[NSFileManager defaultManager] attributesOfItemAtPath:x error:NULL] fileModificationDate];
		NSDate *dy = [[[NSFileManager defaultManager] attributesOfItemAtPath:y error:NULL] fileModificationDate];
		return [dy compare:dx];
	}];
	self.files = a;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
	return s == 0 ? (NSInteger)[[PDModel builtinNames] count] : MAX(1, (NSInteger)[self.files count]);
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return s == 0 ? @"Test shapes" : @"Your STL files"; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
	return s == 1 ? [NSString stringWithFormat:@"Tap “Open in…” → PrintDeck on an STL in Safari or Mail, or copy STL files into %@ (over SSH or with a file manager).", [PDSlicer libraryDirectory]] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"m"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"m"];
	c.selectionStyle = UITableViewCellSelectionStyleBlue;
	c.textLabel.textColor = [UIColor blackColor];
	if (ip.section == 0) {
		NSString *n = [[PDModel builtinNames] objectAtIndex:(NSUInteger)ip.row];
		c.textLabel.text = n;
		NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:@"20 mm cube", @"Calibration cube", @"Ø20 × 20 mm", @"Cylinder", @"Ø30 mm, flat base", @"Sphere",
			@"A “T” with 20 mm overhangs, to try supports", @"Support test", nil];
		c.detailTextLabel.text = [d objectForKey:n];
	} else if (![self.files count]) {
		c.textLabel.text = @"No STL files yet";
		c.textLabel.textColor = [UIColor grayColor];
		c.detailTextLabel.text = @"";
		c.selectionStyle = UITableViewCellSelectionStyleNone;
	} else {
		NSString *f = [self.files objectAtIndex:(NSUInteger)ip.row];
		c.textLabel.text = [[f lastPathComponent] stringByDeletingPathExtension];
		long long bytes = [[[[NSFileManager defaultManager] attributesOfItemAtPath:f error:NULL] objectForKey:NSFileSize] longLongValue];
		c.detailTextLabel.text = bytes > 1048576 ? [NSString stringWithFormat:@"%.1f MB", bytes / 1048576.0] : [NSString stringWithFormat:@"%lld KB", MAX(1LL, bytes / 1024)];
	}
	return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[t deselectRowAtIndexPath:ip animated:YES];
	NSString *src = nil;
	if (ip.section == 0) src = [@"builtin:" stringByAppendingString:[[PDModel builtinNames] objectAtIndex:(NSUInteger)ip.row]];
	else if ([self.files count]) src = [self.files objectAtIndex:(NSUInteger)ip.row];
	if (src && self.picked) self.picked(src);
}

- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1 && [self.files count] > 0; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
	if (style != UITableViewCellEditingStyleDelete || ip.section != 1 || (NSUInteger)ip.row >= [self.files count]) return;
	[[NSFileManager defaultManager] removeItemAtPath:[self.files objectAtIndex:(NSUInteger)ip.row] error:NULL];
	[self reloadFiles];
	[t reloadData];
}

@end

#pragma mark - Helpers

static UIColor *PDColorFromHex(NSString *hex) {
	unsigned v = 0x3C8CE6;
	if ([hex hasPrefix:@"#"] && [hex length] >= 7) [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(1, 6)]] scanHexInt:&v];
	return [UIColor colorWithRed:((v >> 16) & 255) / 255.0f green:((v >> 8) & 255) / 255.0f blue:(v & 255) / 255.0f alpha:1];
}

// A small downward triangle drawn in a layer (the ▾ glyph is missing from iOS 5's fonts).
static CAShapeLayer *PDChevron(UIColor *c) {
	CAShapeLayer *l = [CAShapeLayer layer];
	CGMutablePathRef p = CGPathCreateMutable();
	CGPathMoveToPoint(p, NULL, 0, 0); CGPathAddLineToPoint(p, NULL, 10, 0); CGPathAddLineToPoint(p, NULL, 5, 6); CGPathCloseSubpath(p);
	l.path = p; CGPathRelease(p);
	l.fillColor = c.CGColor;
	l.bounds = CGRectMake(0, 0, 10, 6);
	return l;
}

// Orca-style combo box: left-aligned title, a chevron at the right edge.
@interface PDComboButton : UIButton
@property (nonatomic, strong) CAShapeLayer *chevron;
@end
@implementation PDComboButton
+ (PDComboButton *)combo {
	PDComboButton *b = [PDComboButton buttonWithType:UIButtonTypeCustom];
	b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
	b.layer.cornerRadius = 8;
	b.layer.borderWidth = 1;
	b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
	b.titleLabel.font = PDBoldFont(15);
	b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
	b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
	b.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 28);
	[b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	[b setTitleColor:PD_DIM forState:UIControlStateHighlighted];
	[b setTitleColor:PD_FAINT forState:UIControlStateDisabled];
	b.chevron = PDChevron(PD_DIM);
	[b.layer addSublayer:b.chevron];
	return b;
}
- (void)layoutSubviews {
	[super layoutSubviews];
	[CATransaction begin]; [CATransaction setDisableActions:YES];
	self.chevron.position = CGPointMake(self.bounds.size.width - 15, self.bounds.size.height / 2);
	[CATransaction commit];
}
@end

#pragma mark - List picker

// The popover list behind every combo and drop-down: sections of items ({title, subtitle, value, checked,
// deletable, color}); tapping one calls `picked`, swiping a deletable one calls `deleted`.
@interface PDListPicker : UITableViewController
@property (nonatomic, strong) NSArray *sections;   // [{title, footer, items}]
@property (nonatomic, copy) void (^picked)(id value);
@property (nonatomic, copy) void (^deleted)(id value);
@end

@implementation PDListPicker
- (id)initWithSections:(NSArray *)sections width:(CGFloat)w {
	if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
		self.sections = sections;
		NSUInteger rows = 0;
		for (NSDictionary *s in sections) rows += [[s objectForKey:@"items"] count];
		BOOL subs = NO;
		for (NSDictionary *s in sections) for (NSDictionary *i in [s objectForKey:@"items"]) if ([i objectForKey:@"subtitle"]) subs = YES;
		self.contentSizeForViewInPopover = CGSizeMake(w, MIN(640, 30 + rows * (subs ? 52 : 44) + [sections count] * 46));
	}
	return self;
}
- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	for (NSUInteger s = 0; s < [self.sections count]; s++) {   // show the checked one
		NSArray *items = [[self.sections objectAtIndex:s] objectForKey:@"items"];
		for (NSUInteger i = 0; i < [items count]; i++)
			if ([[[items objectAtIndex:i] objectForKey:@"checked"] boolValue]) {
				[self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)i inSection:(NSInteger)s] atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
				return;
			}
	}
}
- (NSDictionary *)item:(NSIndexPath *)ip { return [[[self.sections objectAtIndex:(NSUInteger)ip.section] objectForKey:@"items"] objectAtIndex:(NSUInteger)ip.row]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return (NSInteger)[self.sections count]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return (NSInteger)[[[self.sections objectAtIndex:(NSUInteger)s] objectForKey:@"items"] count]; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return [[self.sections objectAtIndex:(NSUInteger)s] objectForKey:@"title"]; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s { return [[self.sections objectAtIndex:(NSUInteger)s] objectForKey:@"footer"]; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"i"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"i"];
	NSDictionary *it = [self item:ip];
	c.textLabel.text = [it objectForKey:@"title"];
	c.textLabel.font = [UIFont boldSystemFontOfSize:16];
	c.detailTextLabel.text = [it objectForKey:@"subtitle"];
	c.accessoryType = [[it objectForKey:@"checked"] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	UIColor *col = [it objectForKey:@"color"];
	if (col) {
		UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
		sw.backgroundColor = col; sw.layer.cornerRadius = 4; sw.layer.borderWidth = 1; sw.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.25].CGColor;
		UIGraphicsBeginImageContextWithOptions(CGSizeMake(22, 22), NO, 0);
		[sw.layer renderInContext:UIGraphicsGetCurrentContext()];
		c.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
		UIGraphicsEndImageContext();
	} else c.imageView.image = nil;
	return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[t deselectRowAtIndexPath:ip animated:YES];
	if (self.picked) self.picked([[self item:ip] objectForKey:@"value"]);
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip { return [[[self item:ip] objectForKey:@"deletable"] boolValue]; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
	if (style != UITableViewCellEditingStyleDelete) return;
	id v = [[self item:ip] objectForKey:@"value"];
	NSMutableArray *secs = [self.sections mutableCopy];
	NSMutableDictionary *sec = [[secs objectAtIndex:(NSUInteger)ip.section] mutableCopy];
	NSMutableArray *items = [[sec objectForKey:@"items"] mutableCopy];
	[items removeObjectAtIndex:(NSUInteger)ip.row];
	[sec setObject:items forKey:@"items"];
	[secs replaceObjectAtIndex:(NSUInteger)ip.section withObject:sec];
	self.sections = secs;
	[t deleteRowsAtIndexPaths:[NSArray arrayWithObject:ip] withRowAnimation:UITableViewRowAnimationAutomatic];
	if (self.deleted) self.deleted(v);
}
@end

#pragma mark - Colour picker

// Filament colour swatches (Elegoo's common spool colours), like the colour box beside Orca's filament combo.
@interface PDColorPicker : UIViewController
@property (nonatomic, copy) void (^picked)(NSString *hex);
@end

@implementation PDColorPicker
+ (NSArray *)palette {
	return [NSArray arrayWithObjects:@"#FFFFFF", @"#F2EFE6", @"#D3D3D3", @"#8A8D91", @"#4A4D52", @"#161616",
		@"#E52521", @"#B5121B", @"#FF7A1A", @"#FFC20E", @"#F5E663", @"#C7D530",
		@"#3BB54A", @"#0B7A3E", @"#14B8A6", @"#29A9E1", @"#3C8CE6", @"#1B3D8F",
		@"#7B4FBE", @"#C04BAF", @"#FF8FB8", @"#8B5A2B", @"#C9A26B", @"#D4AF37", nil];
}
- (id)init {
	if ((self = [super init])) self.contentSizeForViewInPopover = CGSizeMake(6 * 52 + 20, 4 * 52 + 20);
	return self;
}
- (void)loadView {
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 6 * 52 + 20, 4 * 52 + 20)];
	v.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
	NSArray *pal = [PDColorPicker palette];
	for (NSUInteger i = 0; i < [pal count]; i++) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
		b.frame = CGRectMake(10 + (i % 6) * 52 + 4, 10 + (i / 6) * 52 + 4, 44, 44);
		b.backgroundColor = PDColorFromHex([pal objectAtIndex:i]);
		b.layer.cornerRadius = 8; b.layer.borderWidth = 1; b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
		b.tag = (NSInteger)i;
		[b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
		[v addSubview:b];
	}
	self.view = v;
}
- (void)tap:(UIButton *)b { if (self.picked) self.picked([[PDColorPicker palette] objectAtIndex:(NSUInteger)b.tag]); }
@end

#pragma mark - Settings cell

// One settings row, Orca style: the label on the left, its value control on the right: −/+ around the value
// (numbers), a slider (percentages), a switch, segments (two options) or a drop-down (three or more).
@interface PDSettingCell : UITableViewCell
@property (nonatomic, strong) NSDictionary *row;
@property (nonatomic, strong) UILabel *title, *hint, *value;
@property (nonatomic, strong) UISegmentedControl *segments;
@property (nonatomic, strong) PDComboButton *menu;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UIButton *minus, *plus;
@property (nonatomic, copy) void (^openMenu)(PDSettingCell *cell);
- (void)refresh;
@end

@implementation PDSettingCell

- (id)initWithRow:(NSDictionary *)row {
	if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil])) {
		self.row = row;
		self.backgroundColor = [UIColor clearColor];
		self.selectionStyle = UITableViewCellSelectionStyleNone;
		self.title = PDLabel([UIFont boldSystemFontOfSize:14], [UIColor whiteColor]);
		self.title.text = [row objectForKey:@"title"];
		self.title.adjustsFontSizeToFitWidth = YES;
		self.title.minimumFontSize = 11;
		self.hint = PDLabel([UIFont systemFontOfSize:11], PD_DIM);
		self.hint.text = [row objectForKey:@"hint"];
		self.hint.numberOfLines = 2;
		self.hint.adjustsFontSizeToFitWidth = NO;
		[self.contentView addSubview:self.title];
		[self.contentView addSubview:self.hint];
		NSString *kind = [row objectForKey:@"kind"];
		if ([kind isEqualToString:@"choice"] && [[row objectForKey:@"options"] count] > 2) {
			self.menu = [PDComboButton combo];
			self.menu.titleLabel.font = PDBoldFont(14);
			[self.menu addTarget:self action:@selector(menuTap) forControlEvents:UIControlEventTouchUpInside];
			[self.contentView addSubview:self.menu];
		} else if ([kind isEqualToString:@"choice"]) {
			self.segments = [[UISegmentedControl alloc] initWithItems:[row objectForKey:@"options"]];
			self.segments.segmentedControlStyle = UISegmentedControlStyleBar;
			self.segments.tintColor = [UIColor colorWithWhite:0.28 alpha:1];
			[self.segments setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[UIFont boldSystemFontOfSize:12], UITextAttributeFont, nil] forState:UIControlStateNormal];
			[self.segments addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
			[self.contentView addSubview:self.segments];
		} else if ([kind isEqualToString:@"switch"]) {
			self.toggle = [[UISwitch alloc] init];
			self.toggle.onTintColor = PD_ACCENT;
			[self.toggle addTarget:self action:@selector(switchChanged) forControlEvents:UIControlEventValueChanged];
			[self.contentView addSubview:self.toggle];
		} else {
			self.value = PDLabel(PDBoldFont(15), [UIColor whiteColor]);
			self.value.textAlignment = NSTextAlignmentCenter;
			self.value.adjustsFontSizeToFitWidth = YES;
			[self.contentView addSubview:self.value];
			if ([kind isEqualToString:@"slider"]) {
				self.slider = [[UISlider alloc] init];
				self.slider.minimumValue = [[row objectForKey:@"min"] floatValue];
				self.slider.maximumValue = [[row objectForKey:@"max"] floatValue];
				self.slider.minimumTrackTintColor = PD_ACCENT;
				[self.slider addTarget:self action:@selector(sliderMoved) forControlEvents:UIControlEventValueChanged];
				[self.slider addTarget:self action:@selector(sliderDone) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
				[self.contentView addSubview:self.slider];
			} else {
				self.minus = PDSmallButton(@"−", PD_ACCENT);
				self.plus = PDSmallButton(@"+", PD_ACCENT);
				self.minus.titleLabel.font = PDBoldFont(20);
				self.plus.titleLabel.font = PDBoldFont(20);
				[self.minus addTarget:self action:@selector(stepDown) forControlEvents:UIControlEventTouchUpInside];
				[self.plus addTarget:self action:@selector(stepUp) forControlEvents:UIControlEventTouchUpInside];
				[self.contentView addSubview:self.minus];
				[self.contentView addSubview:self.plus];
			}
		}
		[self refresh];
	}
	return self;
}

- (NSString *)key { return [self.row objectForKey:@"key"]; }

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat W = self.contentView.bounds.size.width, H = self.contentView.bounds.size.height;
	CGFloat cw = self.toggle ? 70 : self.segments ? 130 : 176;   // control column
	if (self.menu) cw = 186;
	CGFloat tw = W - cw - 22;
	BOOL hasHint = [self.hint.text length] > 0;
	self.title.frame = CGRectMake(12, hasHint ? 5 : (H - 20) / 2, tw, 20);
	self.hint.frame = CGRectMake(12, 25, tw, H - 28);
	CGFloat x = W - cw - 8;
	if (self.menu) self.menu.frame = CGRectMake(x, (H - 34) / 2, cw, 34);
	if (self.segments) self.segments.frame = CGRectMake(x, (H - 30) / 2, cw, 30);
	if (self.toggle) self.toggle.frame = CGRectMake(W - self.toggle.bounds.size.width - 10, (H - self.toggle.bounds.size.height) / 2, self.toggle.bounds.size.width, self.toggle.bounds.size.height);
	if (self.slider) { self.slider.frame = CGRectMake(x, (H - 24) / 2, cw - 58, 24); self.value.frame = CGRectMake(x + cw - 56, (H - 24) / 2, 56, 24); }
	if (self.minus) {
		self.minus.frame = CGRectMake(x, (H - 34) / 2, 42, 34);
		self.plus.frame = CGRectMake(x + cw - 42, (H - 34) / 2, 42, 34);
		self.value.frame = CGRectMake(x + 44, (H - 24) / 2, cw - 88, 24);
	}
}

// Rows whose `when` condition doesn't hold are dimmed and disabled (they don't affect the slice).
- (BOOL)applies {
	NSString *when = [self.row objectForKey:@"when"];
	if (!when) return YES;
	id cur = [PDSliceSettings valueForKey:when], want = [self.row objectForKey:@"whenValue"];
	if (want) return [cur doubleValue] == [want doubleValue];
	return [cur doubleValue] != 0;
}

- (NSInteger)selectedIndex {
	id v = [PDSliceSettings valueForKey:[self key]];
	NSArray *vals = [self.row objectForKey:@"values"];
	for (NSUInteger i = 0; i < [vals count]; i++) {
		id x = [vals objectAtIndex:i];
		if ([x isEqual:v] || ([x isKindOfClass:[NSNumber class]] && [v isKindOfClass:[NSNumber class]] && fabs([x doubleValue] - [v doubleValue]) < 1e-6)) return (NSInteger)i;
	}
	return -1;
}

- (void)refresh {
	id v = [PDSliceSettings valueForKey:[self key]];
	if (self.segments) self.segments.selectedSegmentIndex = [self selectedIndex] >= 0 ? [self selectedIndex] : UISegmentedControlNoSegment;
	if (self.menu) [self.menu setTitle:[PDSliceSettings displayValueForRow:self.row] forState:UIControlStateNormal];
	if (self.toggle) self.toggle.on = [v boolValue];
	if (self.slider && !self.slider.tracking) self.slider.value = [v floatValue];
	if (self.value) self.value.text = [PDSliceSettings displayValueForRow:self.row];
	if (self.minus) {
		double d = [v doubleValue];
		self.minus.enabled = d > [[self.row objectForKey:@"min"] doubleValue] + 1e-9;
		self.plus.enabled = d < [[self.row objectForKey:@"max"] doubleValue] - 1e-9;
	}
	BOOL on = [self applies];
	self.contentView.alpha = on ? 1 : 0.35;
	self.userInteractionEnabled = on;
}

- (void)menuTap { if (self.openMenu) self.openMenu(self); }
- (void)pickIndex:(NSInteger)i {
	NSArray *vals = [self.row objectForKey:@"values"];
	if (i >= 0 && (NSUInteger)i < [vals count]) [PDSliceSettings setValue:[vals objectAtIndex:(NSUInteger)i] forKey:[self key]];
}
- (void)segmentChanged { [self pickIndex:self.segments.selectedSegmentIndex]; }
- (void)switchChanged { [PDSliceSettings setValue:[NSNumber numberWithInt:self.toggle.on ? 1 : 0] forKey:[self key]]; }

- (double)snapped:(double)v {
	double step = [[self.row objectForKey:@"step"] doubleValue], lo = [[self.row objectForKey:@"min"] doubleValue], hi = [[self.row objectForKey:@"max"] doubleValue];
	if (step > 0) v = lo + round((v - lo) / step) * step;
	v = MAX(lo, MIN(hi, v));
	return round(v * 1000) / 1000;   // no 0.30000000004
}
- (void)sliderMoved { self.value.text = [NSString stringWithFormat:@"%.0f %@", [self snapped:self.slider.value], [self.row objectForKey:@"unit"]]; }
- (void)sliderDone { [PDSliceSettings setValue:[NSNumber numberWithDouble:[self snapped:self.slider.value]] forKey:[self key]]; }
- (void)step:(int)dir {
	double v = [PDSliceSettings numberForKey:[self key]] + dir * [[self.row objectForKey:@"step"] doubleValue];
	[PDSliceSettings setValue:[NSNumber numberWithDouble:[self snapped:v]] forKey:[self key]];
}
- (void)stepDown { [self step:-1]; }
- (void)stepUp { [self step:1]; }

@end

#pragma mark - Page

static NSString *const PDSliceEditorKey = @"PDSliceEditor";       // remembered tab per editor
static NSString *const PDSliceAdvancedKey = @"PDSliceAdvanced";
static NSString *const PDSliceSchemeKey = @"PDSliceColorScheme";

@interface PDSlicePage () <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate, UIAlertViewDelegate, UIActionSheetDelegate, UIPopoverControllerDelegate>
// top bar
@property (nonatomic, strong) UIButton *backButton, *sliceButton, *printButton;
@property (nonatomic, strong) UISegmentedControl *modeTabs;          // Prepare | Preview
// sidebar
@property (nonatomic, strong) UIView *printerPanel, *filamentPanel, *processPanel;
@property (nonatomic, strong) UILabel *printerCaption, *filamentCaption, *processCaption, *editorTitle;
@property (nonatomic, strong) PDComboButton *printerCombo, *filamentCombo, *processCombo;
@property (nonatomic, strong) UIButton *printerEdit, *filamentEdit, *swatch, *saveButton, *doneButton;
@property (nonatomic, strong) UISwitch *advancedSwitch;
@property (nonatomic, strong) UILabel *advancedLabel;
@property (nonatomic, strong) UISegmentedControl *tabs;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableDictionary *cells;
@property (nonatomic, copy) NSString *editor;                        // "process" | "filament" | "printer"
@property (nonatomic, strong) NSArray *shownSections;
// canvas
@property (nonatomic, strong) PDModelView *modelView;
@property (nonatomic, strong) PDToolpathView *previewView;
@property (nonatomic, strong) UILabel *nameLabel, *sizeLabel, *emptyLabel, *layerLabel, *statusLabel;
@property (nonatomic, strong) UIButton *modelButton, *rotLeft, *rotRight, *layButton, *tipButton, *resetButton, *scaleDown, *scaleUp;
@property (nonatomic, strong) UILabel *scaleLabel;
@property (nonatomic, strong) UISlider *layerSlider;
@property (nonatomic, strong) UIButton *layerUp, *layerDown;      // one layer up / down, above and below the slider
@property (nonatomic, strong) UIView *sliderHolder;          // rotated -90° so the layer slider runs bottom to top
@property (nonatomic, strong) UIView *legend, *statusBox;
@property (nonatomic, strong) UISegmentedControl *schemeTabs;
@property (nonatomic, strong) PDProgressBar *bar;
@property (nonatomic, copy) NSString *notice;                        // one-off message in the status box
// misc
@property (nonatomic, strong) UIPopoverController *popover;
@property (nonatomic, strong) UISwipeGestureRecognizer *swipe;
@property (nonatomic, copy) NSString *loadError;
@property (nonatomic) BOOL loading;
@property (nonatomic) NSUInteger loadTicket;   // the latest model load; older ones finishing late are dropped
@end

@implementation PDSlicePage

static UILabel *PDCaption(NSString *t) {
	UILabel *l = PDSL([UIFont boldSystemFontOfSize:11], PD_FAINT, NSTextAlignmentLeft);
	l.text = t;
	return l;
}

static UIView *PDPanel(void) {
	UIView *v = [[UIView alloc] init];
	v.backgroundColor = PD_TILE;
	v.layer.cornerRadius = 10;
	return v;
}

static UIView *PDOverlayBox(void) {
	UIView *v = [[UIView alloc] init];
	v.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:0.82];
	v.layer.cornerRadius = 10;
	v.layer.borderWidth = 1;
	v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
	return v;
}

- (id)init {
	if ((self = [super initWithFrame:[[UIScreen mainScreen] bounds]])) {
		self.backgroundColor = PD_BG;
		self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

		// Top bar: ‹ PrintDeck · Prepare | Preview · Slice plate · Print plate
		self.backButton = [UIButton buttonWithType:UIButtonTypeCustom];
		[self.backButton setTitle:@"‹  PrintDeck" forState:UIControlStateNormal];
		[self.backButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
		[self.backButton setTitleColor:PD_DIM forState:UIControlStateHighlighted];
		self.backButton.titleLabel.font = [UIFont systemFontOfSize:19];
		self.backButton.backgroundColor = PD_TILE;
		self.backButton.layer.cornerRadius = 10;
		[self.backButton addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];
		self.modeTabs = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"Prepare", @"Preview", nil]];
		self.modeTabs.segmentedControlStyle = UISegmentedControlStyleBar;
		self.modeTabs.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
		[self.modeTabs setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:PDBoldFont(15), UITextAttributeFont, nil] forState:UIControlStateNormal];
		self.modeTabs.selectedSegmentIndex = 0;
		[self.modeTabs addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
		self.sliceButton = PDButton(@"Slice plate", PD_GREEN);
		self.sliceButton.titleLabel.font = PDBoldFont(17);
		[self.sliceButton addTarget:self action:@selector(sliceTap) forControlEvents:UIControlEventTouchUpInside];
		self.printButton = PDButton(@"Print plate", PD_ACCENT);
		self.printButton.titleLabel.font = PDBoldFont(17);
		[self.printButton addTarget:self action:@selector(printTap:) forControlEvents:UIControlEventTouchUpInside];

		// Sidebar: Printer, Filament, Process combos, then the active editor's tabs and settings.
		self.printerPanel = PDPanel(); self.filamentPanel = PDPanel(); self.processPanel = PDPanel();
		self.printerCaption = PDCaption(@"PRINTER");
		self.filamentCaption = PDCaption(@"FILAMENT");
		self.processCaption = PDCaption(@"PROCESS");
		self.printerCombo = [PDComboButton combo];
		[self.printerCombo addTarget:self action:@selector(pickPrinter:) forControlEvents:UIControlEventTouchUpInside];
		self.filamentCombo = [PDComboButton combo];
		[self.filamentCombo addTarget:self action:@selector(pickFilament:) forControlEvents:UIControlEventTouchUpInside];
		self.processCombo = [PDComboButton combo];
		[self.processCombo addTarget:self action:@selector(pickProcess:) forControlEvents:UIControlEventTouchUpInside];
		self.printerEdit = PDSmallButton(@"Edit", PD_ACCENT);
		[self.printerEdit addTarget:self action:@selector(editPrinter) forControlEvents:UIControlEventTouchUpInside];
		self.filamentEdit = PDSmallButton(@"Edit", PD_ACCENT);
		[self.filamentEdit addTarget:self action:@selector(editFilament) forControlEvents:UIControlEventTouchUpInside];
		self.swatch = [UIButton buttonWithType:UIButtonTypeCustom];
		self.swatch.layer.cornerRadius = 8; self.swatch.layer.borderWidth = 2; self.swatch.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
		[self.swatch addTarget:self action:@selector(pickColor:) forControlEvents:UIControlEventTouchUpInside];
		self.editorTitle = PDSL(PDBoldFont(15), [UIColor whiteColor], NSTextAlignmentLeft);
		self.saveButton = PDSmallButton(@"Save as…", PD_ACCENT);
		self.saveButton.titleLabel.font = PDBoldFont(13);
		[self.saveButton addTarget:self action:@selector(saveTap) forControlEvents:UIControlEventTouchUpInside];
		self.doneButton = PDSmallButton(@"Done", PD_GREEN);
		self.doneButton.titleLabel.font = PDBoldFont(13);
		[self.doneButton addTarget:self action:@selector(editProcess) forControlEvents:UIControlEventTouchUpInside];
		self.advancedLabel = PDSL([UIFont boldSystemFontOfSize:12], PD_DIM, NSTextAlignmentRight);
		self.advancedLabel.text = @"Advanced";
		self.advancedSwitch = [[UISwitch alloc] init];
		self.advancedSwitch.onTintColor = PD_ACCENT;
		self.advancedSwitch.on = [ud boolForKey:PDSliceAdvancedKey];
		[self.advancedSwitch addTarget:self action:@selector(advancedChanged) forControlEvents:UIControlEventValueChanged];
		self.tabs = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObject:@"-"]];
		self.tabs.segmentedControlStyle = UISegmentedControlStyleBar;
		self.tabs.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
		[self.tabs setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[UIFont boldSystemFontOfSize:13], UITextAttributeFont, nil] forState:UIControlStateNormal];
		[self.tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
		self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
		self.table.backgroundColor = PD_TILE;
		self.table.layer.cornerRadius = 10;
		self.table.separatorColor = [UIColor colorWithWhite:1 alpha:0.07];
		self.table.dataSource = self; self.table.delegate = self;
		self.cells = [NSMutableDictionary dictionary];

		// Canvas
		self.modelView = [[PDModelView alloc] initWithFrame:CGRectMake(0, 0, 580, 580)];
		self.previewView = [[PDToolpathView alloc] initWithFrame:CGRectMake(0, 0, 580, 680)];
		self.previewView.currentLayer = -1;
		self.previewView.colorScheme = (PDToolpathColorScheme)[ud integerForKey:PDSliceSchemeKey];
		for (UIView *v in [NSArray arrayWithObjects:self.modelView, self.previewView, nil]) { v.layer.cornerRadius = 10; v.clipsToBounds = YES; }
		self.nameLabel = PDSL(PDBoldFont(16), [UIColor whiteColor], NSTextAlignmentLeft);
		self.nameLabel.shadowColor = [UIColor blackColor]; self.nameLabel.shadowOffset = CGSizeMake(0, 1);
		self.sizeLabel = PDSL([UIFont systemFontOfSize:13], PD_DIM, NSTextAlignmentLeft);
		self.sizeLabel.shadowColor = [UIColor blackColor]; self.sizeLabel.shadowOffset = CGSizeMake(0, 1);
		self.emptyLabel = PDSL([UIFont systemFontOfSize:17], PD_DIM, NSTextAlignmentCenter);
		self.emptyLabel.numberOfLines = 0;
		self.modelButton = PDSmallButton(@"Model…", PD_ACCENT);
		[self.modelButton addTarget:self action:@selector(pickModel:) forControlEvents:UIControlEventTouchUpInside];
		self.rotLeft = PDSmallButton(@"Turn left", PD_DIM);
		[self.rotLeft addTarget:self action:@selector(rotateLeft) forControlEvents:UIControlEventTouchUpInside];
		self.rotRight = PDSmallButton(@"Turn right", PD_DIM);
		[self.rotRight addTarget:self action:@selector(rotateRight) forControlEvents:UIControlEventTouchUpInside];
		self.layButton = PDSmallButton(@"Tip forward", PD_DIM);
		[self.layButton addTarget:self action:@selector(tipX) forControlEvents:UIControlEventTouchUpInside];
		self.tipButton = PDSmallButton(@"Tip sideways", PD_DIM);
		[self.tipButton addTarget:self action:@selector(tipY) forControlEvents:UIControlEventTouchUpInside];
		self.resetButton = PDSmallButton(@"Reset", PD_DIM);
		[self.resetButton addTarget:self action:@selector(resetPlacement) forControlEvents:UIControlEventTouchUpInside];
		self.scaleDown = PDSmallButton(@"−", PD_ACCENT);
		self.scaleDown.titleLabel.font = PDBoldFont(22);
		[self.scaleDown addTarget:self action:@selector(scaleDownTap) forControlEvents:UIControlEventTouchUpInside];
		self.scaleUp = PDSmallButton(@"+", PD_ACCENT);
		self.scaleUp.titleLabel.font = PDBoldFont(22);
		[self.scaleUp addTarget:self action:@selector(scaleUpTap) forControlEvents:UIControlEventTouchUpInside];
		self.scaleLabel = PDSL(PDBoldFont(15), [UIColor whiteColor], NSTextAlignmentCenter);

		// Preview: a vertical layer slider on the right edge (as in Orca) and a legend at the top left.
		self.layerSlider = [[UISlider alloc] init];
		self.layerSlider.minimumTrackTintColor = PD_ACCENT;
		self.sliderHolder = [[UIView alloc] init];
		self.sliderHolder.transform = CGAffineTransformMakeRotation((CGFloat)-M_PI_2);
		[self.sliderHolder addSubview:self.layerSlider];
		[self.layerSlider addTarget:self action:@selector(layerMoved) forControlEvents:UIControlEventValueChanged];
		self.layerUp = PDSmallButton(@"\u25B2", PD_ACCENT);
		[self.layerUp addTarget:self action:@selector(layerUpTap) forControlEvents:UIControlEventTouchUpInside];
		self.layerDown = PDSmallButton(@"\u25BC", PD_ACCENT);
		[self.layerDown addTarget:self action:@selector(layerDownTap) forControlEvents:UIControlEventTouchUpInside];
		self.layerLabel = PDSL(PDBoldFont(13), [UIColor whiteColor], NSTextAlignmentCenter);
		self.layerLabel.numberOfLines = 2;
		self.layerLabel.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:0.82];
		self.layerLabel.layer.cornerRadius = 6;
		self.legend = PDOverlayBox();
		self.schemeTabs = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"Filament", @"Line type", @"Height", nil]];
		self.schemeTabs.segmentedControlStyle = UISegmentedControlStyleBar;
		self.schemeTabs.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
		[self.schemeTabs setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[UIFont boldSystemFontOfSize:11], UITextAttributeFont, nil] forState:UIControlStateNormal];
		self.schemeTabs.selectedSegmentIndex = (NSInteger)self.previewView.colorScheme;
		[self.schemeTabs addTarget:self action:@selector(schemeChanged) forControlEvents:UIControlEventValueChanged];
		[self.legend addSubview:self.schemeTabs];

		// Status box (bottom of the canvas): progress, results, errors.
		self.statusBox = PDOverlayBox();
		self.bar = [[PDProgressBar alloc] initWithFrame:CGRectZero];
		self.bar.color = PD_ACCENT;
		self.statusLabel = PDSL([UIFont systemFontOfSize:14], [UIColor whiteColor], NSTextAlignmentLeft);
		self.statusLabel.numberOfLines = 2;
		self.statusLabel.adjustsFontSizeToFitWidth = NO;
		[self.statusBox addSubview:self.statusLabel];
		[self.statusBox addSubview:self.bar];

		for (UIView *v in [NSArray arrayWithObjects:self.backButton, self.modeTabs, self.sliceButton, self.printButton,
			self.printerPanel, self.filamentPanel, self.processPanel, self.editorTitle, self.saveButton, self.doneButton, self.advancedLabel, self.advancedSwitch,
			self.tabs, self.table, self.modelView, self.previewView, self.emptyLabel, self.nameLabel, self.sizeLabel,
			self.modelButton, self.rotLeft, self.rotRight, self.layButton, self.tipButton, self.resetButton, self.scaleDown, self.scaleUp, self.scaleLabel,
			self.sliderHolder, self.layerUp, self.layerDown, self.layerLabel, self.legend, self.statusBox, nil]) [self addSubview:v];
		for (UIView *v in [NSArray arrayWithObjects:self.printerCaption, self.printerCombo, self.printerEdit, nil]) [self.printerPanel addSubview:v];
		for (UIView *v in [NSArray arrayWithObjects:self.filamentCaption, self.swatch, self.filamentCombo, self.filamentEdit, nil]) [self.filamentPanel addSubview:v];
		for (UIView *v in [NSArray arrayWithObjects:self.processCaption, self.processCombo, nil]) [self.processPanel addSubview:v];

		self.swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(back)];
		self.swipe.direction = UISwipeGestureRecognizerDirectionRight;
		self.swipe.delegate = self;
		[self addGestureRecognizer:self.swipe];

		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserver:self selector:@selector(update) name:PDSlicerNotification object:nil];
		[nc addObserver:self selector:@selector(settingsChanged) name:PDSliceSettingsChangedNotification object:nil];
		[nc addObserver:self selector:@selector(update) name:PDPrinterDidUpdateNotification object:nil];
		[nc addObserver:self selector:@selector(update) name:PDPrinterConnectionNotification object:nil];

		// First run with stock profiles: start from the stock 0.6 mm / 0.24mm Optimal / Elegoo PLA.
		if (![ud objectForKey:@"PDSliceProfile"] && [[PDSliceProfiles printers] count]) {
			double nozzle = [PDSliceSettings numberForKey:@"nozzle"];
			NSDictionary *pr = nil;
			for (NSDictionary *q in [PDSliceProfiles printers]) if (fabs([[q objectForKey:@"nozzle"] doubleValue] - nozzle) < 1e-6) pr = q;
			if (pr) [PDSliceProfiles applyPrinter:pr];
		}

		[self showEditor:@"process"];
		PDSlicer *s = [PDSlicer shared];
		if (s.model) [self showModel:s.model];
		else {
			NSString *src = [ud stringForKey:PDSliceModelKey] ?: @"builtin:Calibration cube";
			[self openModelSource:src restoringPlacement:YES];
		}
		[self settingsChanged];
	}
	return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)back { [self.popover dismissPopoverAnimated:NO]; if (self.backHandler) self.backHandler(); }

// Swipe-back only from outside the 3D views, the sliders and the settings list.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
	if (g != self.swipe) return YES;
	for (UIView *v = t.view; v; v = v.superview)
		if (v == self.modelView || v == self.previewView || v == self.table || [v isKindOfClass:[UISlider class]]) return NO;
	return YES;
}

#pragma mark Layout

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, pad = 12;
	CGFloat sw = 400, cx = pad + sw + 12, cw = W - cx - pad;   // sidebar | canvas

	// top bar
	self.backButton.frame = CGRectMake(pad, 12, 150, 44);
	self.modeTabs.frame = CGRectMake(cx, 16, 230, 36);
	self.printButton.frame = CGRectMake(W - pad - 140, 12, 140, 44);
	self.sliceButton.frame = CGRectMake(W - pad - 140 - 10 - 140, 12, 140, 44);

	// sidebar panels
	CGFloat y = 68, ph = 64;
	self.printerPanel.frame = CGRectMake(pad, y, sw, ph);
	self.filamentPanel.frame = CGRectMake(pad, y + ph + 6, sw, ph);
	self.processPanel.frame = CGRectMake(pad, y + 2 * (ph + 6), sw, ph);
	for (UILabel *l in [NSArray arrayWithObjects:self.printerCaption, self.filamentCaption, self.processCaption, nil]) l.frame = CGRectMake(12, 4, 200, 16);
	self.printerCombo.frame = CGRectMake(10, 21, sw - 20 - 70, 36);
	self.printerEdit.frame = CGRectMake(sw - 74, 21, 64, 36);
	self.swatch.frame = CGRectMake(10, 21, 36, 36);
	self.filamentCombo.frame = CGRectMake(52, 21, sw - 62 - 70, 36);
	self.filamentEdit.frame = CGRectMake(sw - 74, 21, 64, 36);
	self.processCombo.frame = CGRectMake(10, 21, sw - 20, 36);

	CGFloat ey = y + 3 * (ph + 6) + 2;
	BOOL process = [self.editor isEqualToString:@"process"];
	CGSize ss = self.advancedSwitch.bounds.size;
	CGFloat rx = pad + sw - ss.width;
	self.advancedSwitch.frame = CGRectMake(rx, ey + (32 - ss.height) / 2, ss.width, ss.height);
	self.advancedLabel.frame = CGRectMake(rx - 72, ey, 66, 32);
	rx -= 72 + 8 + 80;
	self.saveButton.frame = CGRectMake(rx, ey + 2, 80, 28);
	self.doneButton.hidden = process;
	if (!process) { rx -= 6 + 56; self.doneButton.frame = CGRectMake(rx, ey + 2, 56, 28); }
	self.editorTitle.frame = CGRectMake(pad + 4, ey, rx - pad - 10, 32);
	self.editorTitle.adjustsFontSizeToFitWidth = YES;
	self.tabs.frame = CGRectMake(pad, ey + 38, sw, 32);
	CGFloat ty = ey + 76;
	self.table.frame = CGRectMake(pad, ty, sw, H - ty - pad);

	// canvas
	CGFloat vy = 68, toolH = 96;
	CGRect prep = CGRectMake(cx, vy, cw, H - vy - pad - toolH);
	CGRect full = CGRectMake(cx, vy, cw, H - vy - pad);
	self.modelView.frame = prep;
	self.previewView.frame = full;
	self.emptyLabel.frame = CGRectInset(prep, 30, 0);
	self.nameLabel.frame = CGRectMake(cx + 14, vy + 10, cw - 28, 22);
	self.sizeLabel.frame = CGRectMake(cx + 14, vy + 32, cw - 28, 18);
	CGFloat by = prep.origin.y + prep.size.height + 8, bw = (cw - 3 * 8) / 4;
	NSArray *row1 = [NSArray arrayWithObjects:self.modelButton, self.rotLeft, self.rotRight, self.layButton, nil];
	for (NSUInteger i = 0; i < [row1 count]; i++) [(UIView *)[row1 objectAtIndex:i] setFrame:CGRectMake(cx + i * (bw + 8), by, bw, 40)];
	CGFloat by2 = by + 48;
	self.tipButton.frame = CGRectMake(cx, by2, bw, 40);
	self.scaleDown.frame = CGRectMake(cx + bw + 8, by2, 48, 40);
	self.scaleLabel.frame = CGRectMake(cx + bw + 60, by2, 2 * bw + 8 - 112, 40);
	self.scaleUp.frame = CGRectMake(cx + 3 * bw + 16 - 48, by2, 48, 40);
	self.resetButton.frame = CGRectMake(cx + 3 * (bw + 8), by2, bw, 40);

	// preview overlays
	// ▲ under the layer label, the slider, then ▼ (clear of the status box, which stops short of this column).
	CGFloat sliderTop = vy + 100, sliderLen = full.size.height - 158;
	self.layerUp.frame = CGRectMake(cx + cw - 48, vy + 56, 44, 38);
	self.sliderHolder.bounds = CGRectMake(0, 0, sliderLen, 34);
	self.sliderHolder.center = CGPointMake(cx + cw - 26, sliderTop + sliderLen / 2);
	self.layerDown.frame = CGRectMake(cx + cw - 48, sliderTop + sliderLen + 6, 44, 38);
	self.layerSlider.frame = self.sliderHolder.bounds;
	self.layerLabel.frame = CGRectMake(cx + cw - 110, vy + 10, 100, 40);
	[self layoutLegend];
	CGFloat sbW = cw - 24 - 60;
	self.statusBox.frame = CGRectMake(cx + 12, (self.modeTabs.selectedSegmentIndex == 1 ? full : prep).origin.y + (self.modeTabs.selectedSegmentIndex == 1 ? full : prep).size.height - 66, sbW, 54);
	self.statusLabel.frame = CGRectMake(12, 6, sbW - 24, 38);
	self.bar.frame = CGRectMake(12, 44, sbW - 24, 5);
}

#pragma mark Editors (sidebar)

- (void)showEditor:(NSString *)editor {
	self.editor = editor;
	NSArray *tabs = [PDSliceSettings tabsForEditor:editor];
	[self.tabs removeAllSegments];
	for (NSUInteger i = 0; i < [tabs count]; i++) [self.tabs insertSegmentWithTitle:[tabs objectAtIndex:i] atIndex:i animated:NO];
	NSDictionary *remembered = [[NSUserDefaults standardUserDefaults] dictionaryForKey:PDSliceEditorKey];
	NSUInteger t = [tabs indexOfObject:[remembered objectForKey:editor]];
	self.tabs.selectedSegmentIndex = t == NSNotFound ? 0 : (NSInteger)t;
	[self reloadSettings];
	[self setNeedsLayout];
}
- (void)editPrinter { [self showEditor:[self.editor isEqualToString:@"printer"] ? @"process" : @"printer"]; }
- (void)editFilament { [self showEditor:[self.editor isEqualToString:@"filament"] ? @"process" : @"filament"]; }
- (void)editProcess { [self showEditor:@"process"]; }

- (NSString *)currentTab {
	NSInteger i = self.tabs.selectedSegmentIndex;
	return i >= 0 ? [self.tabs titleForSegmentAtIndex:(NSUInteger)i] : nil;
}

- (void)tabChanged {
	NSMutableDictionary *r = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:PDSliceEditorKey] mutableCopy] ?: [NSMutableDictionary dictionary];
	if ([self currentTab]) [r setObject:[self currentTab] forKey:self.editor];
	[[NSUserDefaults standardUserDefaults] setObject:r forKey:PDSliceEditorKey];
	[self reloadSettings];
}

- (void)advancedChanged {
	[[NSUserDefaults standardUserDefaults] setBool:self.advancedSwitch.on forKey:PDSliceAdvancedKey];
	[self reloadSettings];
}

- (void)reloadSettings {
	self.shownSections = [PDSliceSettings sectionsForEditor:self.editor tab:[self currentTab] ?: @"" advanced:self.advancedSwitch.on];
	[self.table reloadData];
	[self.table setContentOffset:CGPointZero animated:NO];
	[self updateEditorHeader];
}

- (void)updateEditorHeader {
	NSString *name = [PDSliceProfiles selectedTitleForEditor:self.editor];
	NSString *what = [self.editor isEqualToString:@"printer"] ? @"Printer settings" : [self.editor isEqualToString:@"filament"] ? @"Filament settings" : @"Process settings";
	self.editorTitle.text = what;
	(void)name;
	[self.printerEdit setTitle:[self.editor isEqualToString:@"printer"] ? @"Done" : @"Edit" forState:UIControlStateNormal];
	[self.filamentEdit setTitle:[self.editor isEqualToString:@"filament"] ? @"Done" : @"Edit" forState:UIControlStateNormal];
	self.printerPanel.layer.borderWidth = self.filamentPanel.layer.borderWidth = self.processPanel.layer.borderWidth = 0;
	UIView *active = [self.editor isEqualToString:@"printer"] ? self.printerPanel : [self.editor isEqualToString:@"filament"] ? self.filamentPanel : self.processPanel;
	active.layer.borderWidth = 1.5;
	active.layer.borderColor = [PD_ACCENT colorWithAlphaComponent:0.6].CGColor;
}

// The combos show the selected preset, with " (modified)" once edited by hand, as in Orca.
- (void)updateCombos {
	NSString *(^T)(NSString *, NSString *) = ^NSString *(NSString *editor, NSString *fallback) {
		NSString *t = [PDSliceProfiles selectedTitleForEditor:editor] ?: fallback;
		if ([PDSliceProfiles isUser:editor]) t = [@"★ " stringByAppendingString:t];
		return [PDSliceProfiles isEdited:editor] ? [t stringByAppendingString:@" (modified)"] : t;
	};
	[self.printerCombo setTitle:T(@"printer", [NSString stringWithFormat:@"Centauri Carbon %g nozzle", [PDSliceSettings numberForKey:@"nozzle"]]) forState:UIControlStateNormal];
	NSString *fname = [PDSliceSettings valueForKey:@"filamentName"];
	[self.filamentCombo setTitle:T(@"filament", [fname length] ? fname : [NSString stringWithFormat:@"Generic %@", [PDSliceSettings valueForKey:@"material"]]) forState:UIControlStateNormal];
	[self.processCombo setTitle:T(@"process", [NSString stringWithFormat:@"%.2fmm Custom", [PDSliceSettings numberForKey:@"layerHeight"]]) forState:UIControlStateNormal];
	self.swatch.backgroundColor = PDColorFromHex([PDSliceSettings valueForKey:@"filamentColor"]);
}

- (void)present:(UIViewController *)vc from:(UIView *)v {
	[self.popover dismissPopoverAnimated:NO];
	self.popover = [[UIPopoverController alloc] initWithContentViewController:vc];
	self.popover.delegate = self;
	[self.popover presentPopoverFromRect:v.bounds inView:v permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
}
- (void)dismissPopover { [self.popover dismissPopoverAnimated:YES]; self.popover = nil; }
- (void)popoverControllerDidDismissPopover:(UIPopoverController *)p { self.popover = nil; }

- (NSDictionary *)userSectionForEditor:(NSString *)editor {
	NSMutableArray *items = [NSMutableArray array];
	NSDictionary *st = [PDSliceProfiles state];
	BOOL user = [PDSliceProfiles isUser:editor];
	for (NSDictionary *p in [PDSliceProfiles userPresetsForEditor:editor]) {
		NSDateFormatter *f = [[NSDateFormatter alloc] init];
		f.dateStyle = NSDateFormatterMediumStyle; f.timeStyle = NSDateFormatterNoStyle;
		[items addObject:[NSDictionary dictionaryWithObjectsAndKeys:[p objectForKey:@"name"], @"title",
			[NSString stringWithFormat:@"%@%@", [[p objectForKey:@"from"] length] ? [NSString stringWithFormat:@"From %@", [p objectForKey:@"from"]]
					: [NSString stringWithFormat:@"Saved %@", [f stringFromDate:[p objectForKey:@"date"]]],
				[editor isEqualToString:@"printer"] ? @"" : [editor isEqualToString:@"filament"] ?
					[NSString stringWithFormat:@" · %@ · %@ °C / %@ °C", [[p objectForKey:@"settings"] objectForKey:@"material"] ?: @"",
						[[p objectForKey:@"settings"] objectForKey:@"nozzleTemp"] ?: @"?", [[p objectForKey:@"settings"] objectForKey:@"bedTemp"] ?: @"?"]
					: [NSString stringWithFormat:@" · %@", [[[p objectForKey:@"printer"] componentsSeparatedByString:@"Elegoo "] lastObject]]], @"subtitle",
			p, @"value", [NSNumber numberWithBool:YES], @"deletable",
			[NSNumber numberWithBool:user && [[st objectForKey:editor] isEqualToString:[p objectForKey:@"name"]]], @"checked",
			// last: nil (no colour) ends the list
			[[p objectForKey:@"settings"] objectForKey:@"filamentColor"] ? PDColorFromHex([[p objectForKey:@"settings"] objectForKey:@"filamentColor"]) : nil, @"color", nil]];
	}
	return [NSDictionary dictionaryWithObjectsAndKeys:@"User presets", @"title", items, @"items",
		[items count] ? @"Swipe left on one to delete it." : @"None yet: change settings, then “Save as…”.", @"footer", nil];
}

- (NSString *)stockFooter {
	NSDictionary *st = [PDSliceProfiles stock];
	return [NSString stringWithFormat:@"From ElegooSlicer (%@, %@), bundled by tools/make-profiles.py.", [st objectForKey:@"commit"] ?: @"?", [st objectForKey:@"date"] ?: @"?"];
}

- (void)showPicker:(NSArray *)sections from:(UIView *)v width:(CGFloat)w picked:(void (^)(id value))picked {
	PDListPicker *lp = [[PDListPicker alloc] initWithSections:sections width:w];
	__weak PDSlicePage *weakSelf = self;
	lp.picked = ^(id value) { [weakSelf dismissPopover]; picked(value); };
	lp.deleted = ^(id value) { if ([value isKindOfClass:[NSDictionary class]]) [PDSliceProfiles deleteUserPreset:value]; };
	[self present:lp from:v];
}

- (void)pickPrinter:(UIView *)sender {
	NSString *cur = [[PDSliceProfiles state] objectForKey:@"printer"];
	BOOL user = [PDSliceProfiles isUser:@"printer"];
	NSMutableArray *items = [NSMutableArray array];
	for (NSDictionary *p in [PDSliceProfiles printers])
		[items addObject:[NSDictionary dictionaryWithObjectsAndKeys:[p objectForKey:@"name"], @"title",
			[NSString stringWithFormat:@"%g mm nozzle · 256 × 256 × 256 mm · default %@", [[p objectForKey:@"nozzle"] doubleValue], [[[p objectForKey:@"defaultProcess"] componentsSeparatedByString:@" @"] objectAtIndex:0]], @"subtitle",
			p, @"value", [NSNumber numberWithBool:!user && [cur isEqualToString:[p objectForKey:@"name"]]], @"checked", nil]];
	NSArray *secs = [NSArray arrayWithObjects:
		[NSDictionary dictionaryWithObjectsAndKeys:@"System presets", @"title", items, @"items", [self stockFooter], @"footer", nil],
		[self userSectionForEditor:@"printer"],
		[NSDictionary dictionaryWithObjectsAndKeys:@"", @"title", [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"Reset everything to the defaults", @"title",
			@"Centauri Carbon 0.6 nozzle · 0.24mm Optimal · Elegoo PLA", @"subtitle", @"reset", @"value", nil]], @"items", nil], nil];
	__weak PDSlicePage *weakSelf = self;
	[self showPicker:secs from:sender width:440 picked:^(id value) {
		if ([value isEqual:@"reset"]) [weakSelf confirmResetSettings];
		else if ([[value objectForKey:@"editor"] length]) [PDSliceProfiles applyUserPreset:value];
		else [PDSliceProfiles applyPrinter:value];
	}];
}

- (void)pickFilament:(UIView *)sender {
	NSString *printer = [[PDSliceProfiles currentPrinter] objectForKey:@"name"];
	NSString *cur = [[PDSliceProfiles state] objectForKey:@"filament"];
	BOOL user = [PDSliceProfiles isUser:@"filament"];
	NSMutableDictionary *byVendor = [NSMutableDictionary dictionary];
	NSMutableArray *vendors = [NSMutableArray array];
	for (NSDictionary *f in [PDSliceProfiles filamentsForPrinter:printer]) {
		NSString *v = [[f objectForKey:@"vendor"] length] ? [f objectForKey:@"vendor"] : @"Other";
		if (![byVendor objectForKey:v]) { [byVendor setObject:[NSMutableArray array] forKey:v]; [vendors addObject:v]; }
		NSDictionary *fs = [f objectForKey:@"settings"];
		[[byVendor objectForKey:v] addObject:[NSDictionary dictionaryWithObjectsAndKeys:[f objectForKey:@"title"], @"title",
			[NSString stringWithFormat:@"%@ · nozzle %@ °C · bed %@ °C · fan %@ %%", [f objectForKey:@"type"], [fs objectForKey:@"nozzleTemp"], [fs objectForKey:@"bedTemp"], [fs objectForKey:@"fan"]], @"subtitle",
			f, @"value", [NSNumber numberWithBool:!user && [cur isEqualToString:[f objectForKey:@"name"]]], @"checked", nil]];
	}
	NSMutableArray *secs = [NSMutableArray array];
	for (NSString *v in vendors)
		[secs addObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"System presets · %@", v], @"title", [byVendor objectForKey:v], @"items",
			v == [vendors lastObject] ? [self stockFooter] : nil, @"footer", nil]];
	[secs insertObject:[self userSectionForEditor:@"filament"] atIndex:0];
	[self showPicker:secs from:sender width:440 picked:^(id value) {
		if ([[value objectForKey:@"editor"] length]) [PDSliceProfiles applyUserPreset:value]; else [PDSliceProfiles applyFilament:value];
	}];
}

- (void)pickProcess:(UIView *)sender {
	NSString *printer = [[PDSliceProfiles currentPrinter] objectForKey:@"name"];
	NSString *cur = [[PDSliceProfiles state] objectForKey:@"process"];
	BOOL user = [PDSliceProfiles isUser:@"process"];
	NSMutableArray *items = [NSMutableArray array];
	for (NSDictionary *p in [PDSliceProfiles processesForPrinter:printer]) {
		NSDictionary *ps = [p objectForKey:@"settings"];
		NSArray *patterns = [NSArray arrayWithObjects:@"auto", @"grid", @"lines", @"concentric", @"gyroid", nil];
		NSUInteger pat = [[ps objectForKey:@"infillPattern"] unsignedIntegerValue];
		[items addObject:[NSDictionary dictionaryWithObjectsAndKeys:[p objectForKey:@"title"], @"title",
			[NSString stringWithFormat:@"%@ walls · %@ %% %@ infill · %@/%@ top/bottom · outer wall %@ mm/s", [ps objectForKey:@"walls"], [ps objectForKey:@"infill"],
				pat < [patterns count] ? [patterns objectAtIndex:pat] : @"", [ps objectForKey:@"topLayers"], [ps objectForKey:@"bottomLayers"], [ps objectForKey:@"outerWallSpeed"]], @"subtitle",
			p, @"value", [NSNumber numberWithBool:!user && [cur isEqualToString:[p objectForKey:@"name"]]], @"checked", nil]];
	}
	NSArray *secs = [NSArray arrayWithObjects:
		[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"System presets · %@", [[printer componentsSeparatedByString:@"Elegoo "] lastObject] ?: @""], @"title",
			items, @"items", [self stockFooter], @"footer", nil],
		[self userSectionForEditor:@"process"], nil];
	[self showPicker:secs from:sender width:460 picked:^(id value) {
		if ([[value objectForKey:@"editor"] length]) [PDSliceProfiles applyUserPreset:value]; else [PDSliceProfiles applyProcess:value];
	}];
}

- (void)pickColor:(UIView *)sender {
	PDColorPicker *cp = [[PDColorPicker alloc] init];
	__weak PDSlicePage *weakSelf = self;
	cp.picked = ^(NSString *hex) { [weakSelf dismissPopover]; [PDSliceSettings setValue:hex forKey:@"filamentColor"]; };
	[self present:cp from:sender];
}

- (void)openMenuForCell:(PDSettingCell *)cell {
	NSDictionary *row = cell.row;
	NSArray *opts = [row objectForKey:@"options"];
	NSInteger sel = [cell selectedIndex];
	NSMutableArray *items = [NSMutableArray array];
	for (NSUInteger i = 0; i < [opts count]; i++)
		[items addObject:[NSDictionary dictionaryWithObjectsAndKeys:[opts objectAtIndex:i], @"title", [NSNumber numberWithUnsignedInteger:i], @"value",
			[NSNumber numberWithBool:(NSInteger)i == sel], @"checked", nil]];
	[self showPicker:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:[row objectForKey:@"title"], @"title", items, @"items",
		[row objectForKey:@"hint"], @"footer", nil]] from:cell.menu width:300 picked:^(id value) { [cell pickIndex:[value integerValue]]; }];
}

- (void)saveTap {
	NSString *what = [self.editor isEqualToString:@"printer"] ? @"printer" : [self.editor isEqualToString:@"filament"] ? @"filament" : @"process";
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"Save %@ preset", what]
		message:[self.editor isEqualToString:@"printer"] ? @"Saves the printer settings (nozzle, retraction)." :
			[NSString stringWithFormat:@"Saves the %@ settings for the %@.", what, [[PDSliceProfiles currentPrinter] objectForKey:@"name"] ?: @"printer"]
		delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Save", nil];
	a.alertViewStyle = UIAlertViewStylePlainTextInput;
	NSString *cur = [PDSliceProfiles selectedTitleForEditor:self.editor];
	[a textFieldAtIndex:0].text = [PDSliceProfiles isUser:self.editor] ? cur : (cur ? [NSString stringWithFormat:@"%@ - my", cur] : @"");
	[a textFieldAtIndex:0].clearButtonMode = UITextFieldViewModeWhileEditing;
	a.tag = 3;
	[a show];
}

#pragma mark Model

- (void)openModelSource:(NSString *)source { [self openModelSource:source restoringPlacement:NO]; }

- (void)openModelSource:(NSString *)source restoringPlacement:(BOOL)restore {
	if (![source length]) return;
	NSUInteger ticket = ++self.loadTicket;
	self.loadError = nil;
	self.notice = nil;
	if ([source hasPrefix:@"builtin:"]) {
		PDModel *m = [PDModel builtin:[source substringFromIndex:8]];
		if (m) { if (restore) [self restorePlacement:m]; [self setModel:m]; }
		return;
	}
	self.loading = YES;
	[self update];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSString *err = nil;
		PDModel *m = [PDModel loadFile:source error:&err];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (ticket != self.loadTicket) return;   // another model was asked for meanwhile
			self.loading = NO;
			if (!m) { self.loadError = [NSString stringWithFormat:@"%@: %@", [source lastPathComponent], err]; [self update]; return; }
			if (restore) [self restorePlacement:m];
			[self setModel:m];
		});
	});
}

- (void)setModel:(PDModel *)m {
	[PDSlicer shared].model = m;
	[[NSUserDefaults standardUserDefaults] setObject:m.source forKey:PDSliceModelKey];
	[self savePlacement];
	[self showModel:m];
}

- (void)showModel:(PDModel *)m {
	self.modelView.model = m;
	self.modeTabs.selectedSegmentIndex = 0;
	[self modeChanged];
}

- (void)savePlacement {
	PDModel *m = [PDSlicer shared].model;
	if (!m) return;
	[[NSUserDefaults standardUserDefaults] setObject:[NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithInt:m.quarterX], @"qx", [NSNumber numberWithInt:m.quarterY], @"qy",
		[NSNumber numberWithFloat:m.rotZ], @"rz", [NSNumber numberWithFloat:m.scale], @"s", m.source, @"source", nil] forKey:PDSliceTransformKey];
}

- (void)restorePlacement:(PDModel *)m {
	NSDictionary *t = [[NSUserDefaults standardUserDefaults] dictionaryForKey:PDSliceTransformKey];
	if (![PDStr(t, @"source") isEqualToString:m.source]) return;
	m.quarterX = [PDNum(t, @"qx") intValue]; m.quarterY = [PDNum(t, @"qy") intValue];
	m.rotZ = [PDNum(t, @"rz") floatValue]; m.scale = PDNum(t, @"s") ? [PDNum(t, @"s") floatValue] : 1;
}

- (void)placementChanged {
	[self savePlacement];
	[self.modelView modelTransformChanged];
	if (self.modeTabs.selectedSegmentIndex != 0) { self.modeTabs.selectedSegmentIndex = 0; [self modeChanged]; }
	[self update];
}

- (void)rotateLeft { PDModel *m = [PDSlicer shared].model; m.rotZ += 15; [self placementChanged]; }
- (void)rotateRight { PDModel *m = [PDSlicer shared].model; m.rotZ -= 15; [self placementChanged]; }
- (void)tipX { PDModel *m = [PDSlicer shared].model; m.quarterX += 1; [self placementChanged]; }
- (void)tipY { PDModel *m = [PDSlicer shared].model; m.quarterY += 1; [self placementChanged]; }
- (void)resetPlacement { PDModel *m = [PDSlicer shared].model; m.quarterX = 0; m.quarterY = 0; m.rotZ = 0; m.scale = 1; [self.modelView resetView]; [self placementChanged]; }
// Scale in 5 % steps (1 % below 20 %, 25 % above 200 %).
- (void)scaleBy:(int)dir {
	PDModel *m = [PDSlicer shared].model;
	float pct = roundf(m.scale * 100);
	float step = pct < 20 || (pct == 20 && dir < 0) ? 1 : pct > 200 || (pct == 200 && dir > 0) ? 25 : 5;
	m.scale = MAX(1, MIN(1000, pct + dir * step)) / 100.0f;
	[self placementChanged];
}
- (void)scaleDownTap { [self scaleBy:-1]; }
- (void)scaleUpTap { [self scaleBy:1]; }

- (void)pickModel:(UIButton *)sender {
	PDModelPicker *p = [[PDModelPicker alloc] init];
	__weak PDSlicePage *weakSelf = self;
	p.picked = ^(NSString *src) { [weakSelf dismissPopover]; [weakSelf openModelSource:src restoringPlacement:NO]; };
	[self present:p from:sender];
}

// Room the adhesion needs around the part (skirt/brim/raft), mm per side.
- (float)adhesionMargin {
	int a = (int)[PDSliceSettings numberForKey:@"adhesion"];
	float lw = (float)[PDSliceSettings numberForKey:@"lineWidth"];
	if (a == 1) return (float)[PDSliceSettings numberForKey:@"skirtDistance"] + (float)[PDSliceSettings numberForKey:@"skirtLines"] * lw;
	if (a == 2) return (float)[PDSliceSettings numberForKey:@"brimLines"] * lw;
	if (a == 3) return (float)[PDSliceSettings numberForKey:@"raftMargin"] + 1;
	return 0;
}

- (BOOL)fits {
	PDModel *m = [PDSlicer shared].model;
	if (!m) return NO;
	GLKVector3 s = [m size];
	float edge = 2 * [self adhesionMargin] + 2;
	return s.x + edge <= PD_BED_MM && s.y + edge <= PD_BED_MM && s.z <= PD_BED_MM && s.x > 0.1f && s.y > 0.1f && s.z > 0.05f;
}

#pragma mark Preview

// What Preview shows: the last slice.
- (PDToolpath *)previewToolpath {
	return [PDSlicer shared].resultToolpath;
}

- (void)modeChanged {
	BOOL preview = self.modeTabs.selectedSegmentIndex == 1;
	self.modelView.hidden = preview;
	self.previewView.hidden = !preview;
	PDToolpath *tp = [self previewToolpath];
	if (preview && tp != self.previewView.toolpath) {
		self.previewView.toolpath = tp;
		self.layerSlider.minimumValue = 1;
		self.layerSlider.maximumValue = MAX(1, (float)tp.layerCount);
		self.layerSlider.value = self.layerSlider.maximumValue;
	}
	// The slice result uses the chosen filament colour.
	self.previewView.filamentColor = PDColorFromHex([PDSliceSettings valueForKey:@"filamentColor"]);
	[self layerMoved];
	[self setNeedsLayout];
	[self update];
}

- (void)stepLayer:(NSInteger)d {
	float v = roundf(self.layerSlider.value) + (float)d;
	self.layerSlider.value = MAX(self.layerSlider.minimumValue, MIN(self.layerSlider.maximumValue, v));
	[self layerMoved];
}
- (void)layerUpTap { [self stepLayer:1]; }
- (void)layerDownTap { [self stepLayer:-1]; }

- (void)layerMoved {
	PDToolpath *tp = self.previewView.toolpath;
	NSInteger n = (NSInteger)lroundf(self.layerSlider.value);
	NSInteger total = tp ? (NSInteger)tp.layerCount : 0;
	n = MAX(0, MIN(total, n));
	self.previewView.doneLayers = n;
	self.previewView.currentLayer = n < total ? n - 1 : -1;
	float z = (tp && n > 0) ? tp.layerZ[n - 1] : 0;
	self.layerUp.enabled = tp && n < total;
	self.layerDown.enabled = tp && n > 1;
	self.layerUp.alpha = self.layerUp.enabled ? 1 : 0.4;
	self.layerDown.alpha = self.layerDown.enabled ? 1 : 0.4;
	self.layerLabel.text = tp ? [NSString stringWithFormat:@"%ld / %ld\n%.2f mm", (long)n, (long)total, z] : @"";
}

- (void)schemeChanged {
	self.previewView.colorScheme = (PDToolpathColorScheme)self.schemeTabs.selectedSegmentIndex;
	[[NSUserDefaults standardUserDefaults] setInteger:self.schemeTabs.selectedSegmentIndex forKey:PDSliceSchemeKey];
	[self layoutLegend];
}

// Legend (top left of Preview): colour scheme, its key, and the totals, like Orca's.
- (void)layoutLegend {
	for (UIView *v in [self.legend.subviews copy]) if (v != self.schemeTabs) [v removeFromSuperview];
	CGFloat w = 250;
	__block CGFloat y = 44;
	self.schemeTabs.frame = CGRectMake(10, 10, w - 20, 28);
	UIView *(^Row)(UIColor *, NSString *) = ^UIView *(UIColor *c, NSString *t) {
		UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(12, y + 3, 14, 14)];
		sw.backgroundColor = c; sw.layer.cornerRadius = 3;
		[self.legend addSubview:sw];
		UILabel *l = PDSL([UIFont systemFontOfSize:12], [UIColor whiteColor], NSTextAlignmentLeft);
		l.text = t; l.frame = CGRectMake(34, y, w - 44, 20);
		[self.legend addSubview:l];
		return l;
	};
	PDToolpath *tp = self.previewView.toolpath;
	PDToolpathColorScheme sch = self.previewView.colorScheme;
	if (sch == PDToolpathColorLineType) {
		for (int i = 1; i < PDLineTypeCount; i++) {
			if (i == PDLineGapFill || i == PDLineSupportInterface) continue;   // CuraEngine doesn't make these
			Row([PDToolpathView colorForLineType:(PDLineType)i], [PDToolpathView nameForLineType:(PDLineType)i]); y += 20;
		}
	} else if (sch == PDToolpathColorFilament) {
		UIColor *c = self.previewView.filamentColor;
		NSString *name = [PDSliceSettings valueForKey:@"filamentName"];
		if (c) { Row(c, [name length] ? name : [PDSliceSettings valueForKey:@"material"]); y += 20; }
		else if (tp.filamentColorCount) {   // a printer file: its own colours, one per filament (T0, T1, …)
			for (NSUInteger k = 0; k < tp.filamentColorCount; k++) {
				uint32_t v = tp.filamentColors[k];
				Row([UIColor colorWithRed:((v >> 16) & 255) / 255.0f green:((v >> 8) & 255) / 255.0f blue:(v & 255) / 255.0f alpha:1],
					[NSString stringWithFormat:@"Filament %lu · #%06X%@", (unsigned long)k + 1, v, tp.filamentColorCount == 1 ? @" (from the file)" : @""]);
				y += 20;
			}
		} else { Row([UIColor grayColor], @"No colour in the file: by height"); y += 20; }
		Row([UIColor clearColor], @"Darker toward the bed"); y += 20;
	} else {
		Row([UIColor colorWithRed:1.0 green:0.55 blue:0.32 alpha:1], tp ? [NSString stringWithFormat:@"Top · %.2f mm", tp.maxZ] : @"Top"); y += 20;
		Row([UIColor colorWithRed:0.22 green:0.55 blue:1.0 alpha:1], @"Bed · 0 mm"); y += 20;
	}
	PDSlicer *s = [PDSlicer shared];
	if (s.state == PDSliceDone && tp == s.resultToolpath) {
		y += 6;
		UILabel *l = PDSL([UIFont boldSystemFontOfSize:12], PD_DIM, NSTextAlignmentLeft);
		l.numberOfLines = 3;
		l.text = [NSString stringWithFormat:@"Estimated time  %@\nFilament  %.2f m · %.1f g\nLayers  %d", PDDuration(s.resultSeconds), s.resultFilamentMM / 1000.0, s.resultGrams, s.resultLayers];
		l.frame = CGRectMake(12, y, w - 24, 48);
		[self.legend addSubview:l];
		y += 50;
	}
	CGRect pv = self.previewView.frame;
	self.legend.frame = CGRectMake(pv.origin.x + 10, pv.origin.y + 10, w, y + 8);
}

#pragma mark Actions

- (void)sliceTap {
	PDSlicer *s = [PDSlicer shared];
	if (s.state == PDSliceRunning) { [s cancel]; return; }
	if (![self fits]) return;
	self.notice = nil;
	[s slice];
}

- (void)printTap:(UIButton *)sender {
	UIActionSheet *a = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:@"Upload and print…", @"Upload only", nil];
	a.tag = 1;
	[a showFromRect:sender.bounds inView:sender animated:YES];
}

- (void)actionSheet:(UIActionSheet *)a clickedButtonAtIndex:(NSInteger)i {
	if (i < 0 || i == a.cancelButtonIndex) return;
	if (i == 1) { [[PDSlicer shared] uploadAndPrint:NO]; return; }
	PDSlicer *s = [PDSlicer shared];
	UIAlertView *al = [[UIAlertView alloc] initWithTitle:@"Upload and print?"
		message:[NSString stringWithFormat:@"%@\n%@ · %.1f g %@. Make sure the bed is clear.", PDPrettyFileName(s.resultName), PDDuration(s.resultSeconds), s.resultGrams,
			[PDSliceSettings valueForKey:@"material"]]
		delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Print", nil];
	al.tag = 1;
	[al show];
}

- (void)confirmResetSettings {
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Reset all slicing settings?"
		message:@"Printer, filament and process go back to the stock Centauri Carbon 0.6 nozzle, 0.24mm Optimal and Elegoo PLA. Your saved presets stay."
		delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Reset", nil];
	a.tag = 2;
	[a show];
}

- (void)alertView:(UIAlertView *)a clickedButtonAtIndex:(NSInteger)i {
	if (i == a.cancelButtonIndex) return;
	if (a.tag == 1) [[PDSlicer shared] uploadAndPrint:YES];
	else if (a.tag == 2) [PDSliceProfiles resetToDefaults];
	else if (a.tag == 3) [PDSliceProfiles saveUserPreset:[a textFieldAtIndex:0].text editor:self.editor];
}

#pragma mark State

- (void)settingsChanged {
	for (PDSettingCell *c in [self.cells allValues]) [c refresh];
	[self updateCombos];
	[self updateEditorHeader];
	self.previewView.filamentColor = PDColorFromHex([PDSliceSettings valueForKey:@"filamentColor"]);
	[self layoutLegend];
	[self update];
}

- (void)update {
	PDSlicer *s = [PDSlicer shared];
	PDModel *m = s.model;
	PDPrinter *p = [PDPrinter shared];
	BOOL fits = [self fits];
	BOOL running = s.state == PDSliceRunning;
	BOOL fresh = s.state == PDSliceDone && [s.resultSignature isEqualToString:[s currentSignature]];
	BOOL uploading = s.uploadState == PDUploadRunning;
	BOOL preview = self.modeTabs.selectedSegmentIndex == 1;

	self.nameLabel.text = m ? m.name : @"";
	if (m) {
		GLKVector3 sz = [m size];
		self.sizeLabel.text = [NSString stringWithFormat:@"%.1f × %.1f × %.1f mm · %lu triangles%@", sz.x, sz.y, sz.z, (unsigned long)m.triangleCount,
			fits ? @"" : @" · doesn't fit the bed"];
		self.sizeLabel.textColor = fits ? PD_DIM : PD_RED;
		self.scaleLabel.text = [NSString stringWithFormat:@"Scale %.0f %%", m.scale * 100];
	} else { self.sizeLabel.text = @""; self.scaleLabel.text = @""; }
	self.modelView.warn = m && !fits;
	self.emptyLabel.text = self.loading ? @"Loading model…" : self.loadError ?: (m ? @"" : @"Pick a model to slice.");
	self.emptyLabel.textColor = self.loadError ? PD_RED : PD_DIM;
	self.emptyLabel.hidden = preview || ![self.emptyLabel.text length];

	BOOL hasPreview = s.resultToolpath != nil;
	[self.modeTabs setEnabled:hasPreview forSegmentAtIndex:1];
	for (UIView *v in [NSArray arrayWithObjects:self.modelButton, self.rotLeft, self.rotRight, self.layButton, self.tipButton, self.resetButton, self.scaleDown, self.scaleUp,
		self.scaleLabel, self.nameLabel, self.sizeLabel, nil]) v.hidden = preview;
	self.sliderHolder.hidden = self.layerUp.hidden = self.layerDown.hidden = self.layerLabel.hidden = self.legend.hidden = !preview || !self.previewView.toolpath;
	for (UIButton *b in [NSArray arrayWithObjects:self.rotLeft, self.rotRight, self.layButton, self.tipButton, self.resetButton, self.scaleDown, self.scaleUp, nil]) {
		b.enabled = m != nil && !running;
		b.alpha = b.enabled ? 1 : 0.4;
	}
	self.modelButton.enabled = !running;

	[self.sliceButton setTitle:running ? @"Cancel" : @"Slice plate" forState:UIControlStateNormal];
	[self.sliceButton setTitleColor:running ? PD_RED : PD_GREEN forState:UIControlStateNormal];
	self.sliceButton.backgroundColor = [(running ? PD_RED : PD_GREEN) colorWithAlphaComponent:0.14];
	self.sliceButton.enabled = running || (m && fits && !uploading);
	self.sliceButton.alpha = self.sliceButton.enabled ? 1 : 0.4;
	self.printButton.enabled = fresh && p.connected && !uploading;
	self.printButton.alpha = self.printButton.enabled ? 1 : 0.4;

	// Status box
	self.bar.hidden = !(running || uploading);
	self.bar.progress = uploading ? s.uploadProgress : s.progress;
	NSString *text = nil;
	UIColor *color = [UIColor whiteColor];
	NSString *material = [PDSliceSettings valueForKey:@"material"];
	if (running) text = [NSString stringWithFormat:@"Slicing… %@ · %.0f %%", s.phase ?: @"", s.progress * 100];
	else if (uploading) text = [NSString stringWithFormat:@"Sending to the printer… %.0f %%", s.uploadProgress * 100];
	else if (self.notice) { text = self.notice; color = PD_GREEN; }
	else if (s.state == PDSliceFailed) { text = s.error; color = PD_RED; }
	else if (s.state == PDSliceDone) {
		NSString *result = [NSString stringWithFormat:@"%d layers · %@ · %.1f g %@ · sliced in %.1f s", s.resultLayers, PDDuration(s.resultSeconds), s.resultGrams, material, s.resultSliceTime];
		if (!fresh) { text = [NSString stringWithFormat:@"Changed since the last slice: slice the plate again to print it.\n%@", result]; color = PD_AMBER; }
		else if (s.uploadState == PDUploadFailed) { text = [NSString stringWithFormat:@"%@\n%@", result, s.uploadError]; color = PD_RED; }
		else if (s.uploadState == PDUploadDone) { text = [NSString stringWithFormat:@"%@\nOn the printer as “%@”.", result, PDPrettyFileName(s.uploadedName)]; color = PD_GREEN; }
		else if (!p.connected) text = [NSString stringWithFormat:@"%@\nConnect to the printer to print it.", result];
		else text = result;
	} else if (m) text = @"Pick presets on the left, then Slice plate. Slicing runs on the iPad; the camera pauses meanwhile.";
	self.statusLabel.text = text;
	self.statusLabel.textColor = color;
	self.statusBox.hidden = ![text length];

	PDToolpath *want = [self previewToolpath];
	if (preview && want != self.previewView.toolpath) [self modeChanged];
	// A finished slice: show it.
	static PDToolpath *shown;
	if (s.state == PDSliceDone && s.resultToolpath && shown != s.resultToolpath) {
		shown = s.resultToolpath;
		if (fresh) { self.modeTabs.selectedSegmentIndex = 1; [self modeChanged]; }
	}
}

#pragma mark Settings table

// Developer aid (printdeck://slice?section=…): an editor ("printer"/"filament"/"process"), a tab or a group title.
- (void)scrollToSettingsSection:(NSString *)title {
	for (NSString *e in [NSArray arrayWithObjects:@"process", @"filament", @"printer", nil]) {
		if ([e caseInsensitiveCompare:title] == NSOrderedSame) { [self showEditor:e]; return; }
		for (NSDictionary *s in [PDSliceSettings sections]) {
			if (![[s objectForKey:@"editor"] isEqualToString:e]) continue;
			BOOL tabMatch = [[s objectForKey:@"tab"] caseInsensitiveCompare:title] == NSOrderedSame;
			if (!tabMatch && [[s objectForKey:@"title"] caseInsensitiveCompare:title] != NSOrderedSame) continue;
			[self showEditor:e];
			NSUInteger t = [[PDSliceSettings tabsForEditor:e] indexOfObject:[s objectForKey:@"tab"]];
			self.tabs.selectedSegmentIndex = (NSInteger)t;
			[self tabChanged];
			for (NSUInteger i = 0; i < [self.shownSections count]; i++)
				if (!tabMatch && [[[self.shownSections objectAtIndex:i] objectForKey:@"title"] isEqualToString:[s objectForKey:@"title"]])
					[self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:(NSInteger)i] atScrollPosition:UITableViewScrollPositionTop animated:NO];
			return;
		}
	}
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return (NSInteger)[self.shownSections count]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return (NSInteger)[[[self.shownSections objectAtIndex:(NSUInteger)s] objectForKey:@"rows"] count]; }
- (NSDictionary *)rowAt:(NSIndexPath *)ip { return [[[self.shownSections objectAtIndex:(NSUInteger)ip.section] objectForKey:@"rows"] objectAtIndex:(NSUInteger)ip.row]; }

- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip { return [[[self rowAt:ip] objectForKey:@"hint"] length] ? 58 : 46; }
- (CGFloat)tableView:(UITableView *)t heightForHeaderInSection:(NSInteger)s { return 28; }

- (UIView *)tableView:(UITableView *)t viewForHeaderInSection:(NSInteger)s {
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, t.bounds.size.width, 28)];
	v.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.13 alpha:0.97];
	UIView *mark = [[UIView alloc] initWithFrame:CGRectMake(10, 8, 3, 13)];
	mark.backgroundColor = PD_GREEN;
	[v addSubview:mark];
	UILabel *l = PDSL([UIFont boldSystemFontOfSize:13], [UIColor whiteColor], NSTextAlignmentLeft);
	l.text = [[self.shownSections objectAtIndex:(NSUInteger)s] objectForKey:@"title"];
	l.frame = CGRectMake(20, 4, v.bounds.size.width - 30, 20);
	[v addSubview:l];
	return v;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	NSDictionary *row = [self rowAt:ip];
	NSString *key = [row objectForKey:@"key"];
	PDSettingCell *c = [self.cells objectForKey:key];
	if (!c) {
		c = [[PDSettingCell alloc] initWithRow:row];
		__weak PDSlicePage *weakSelf = self;
		c.openMenu = ^(PDSettingCell *cell) { [weakSelf openMenuForCell:cell]; };
		[self.cells setObject:c forKey:key];
	}
	[c refresh];
	return c;
}

@end
