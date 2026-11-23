#import "PDDesignPage.h"
#import "PDDesign.h"
#import "PDDesignView.h"
#import "PDSlicer.h"
#import "PDViews.h"
#import "PDUtil.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const PDDesignLastKey = @"PDDesignLast";
static NSString *const PDDesignSnapKey = @"PDDesignSnap";

static const uint32_t PDDesignColors[8] = {0x3B8FE0, 0xE0503B, 0xF0A030, 0xF0D040, 0x50C060, 0x9A60D0, 0xE8E8E8, 0x505860};
static NSString *const PDDesignColorNames[8] = {@"Blue", @"Red", @"Orange", @"Yellow", @"Green", @"Purple", @"White", @"Grey"};

static UIColor *PDColorFromRGB(uint32_t c) { return [UIColor colorWithRed:((c >> 16) & 255) / 255.0f green:((c >> 8) & 255) / 255.0f blue:(c & 255) / 255.0f alpha:1]; }

static UIButton *PDDButton(NSString *title, UIColor *color, CGFloat size) {
	UIButton *b = PDButton(title, color);
	b.titleLabel.font = PDBoldFont(size);
	return b;
}

#pragma mark - Icons

// Small flat pictures of the shapes for the palette (and the dashboard card).
static void PDDrawShapeIcon(CGContextRef g, NSString *kind, CGRect r, UIColor *fill, BOOL hole) {
	CGFloat x = r.origin.x, y = r.origin.y, w = r.size.width, h = r.size.height;
	CGFloat cr, cg, cb, ca;
	[fill getRed:&cr green:&cg blue:&cb alpha:&ca];
	UIColor *light = [UIColor colorWithRed:MIN(1, cr * 1.25 + 0.1) green:MIN(1, cg * 1.25 + 0.1) blue:MIN(1, cb * 1.25 + 0.1) alpha:1];
	UIColor *dark = [UIColor colorWithRed:cr * 0.62 green:cg * 0.62 blue:cb * 0.62 alpha:1];
	CGContextSaveGState(g);
	CGContextSetLineJoin(g, kCGLineJoinRound);
	CGContextSetLineWidth(g, 1);
	CGContextSetStrokeColorWithColor(g, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
	#define FILLPATH(col) do { CGContextSetFillColorWithColor(g, (col).CGColor); CGContextDrawPath(g, kCGPathFillStroke); } while (0)
	if ([kind isEqualToString:@"box"]) {
		CGFloat d = w * 0.28;
		CGContextMoveToPoint(g, x, y + d); CGContextAddLineToPoint(g, x + w - d, y + d); CGContextAddLineToPoint(g, x + w - d, y + h); CGContextAddLineToPoint(g, x, y + h); CGContextClosePath(g); FILLPATH(fill);
		CGContextMoveToPoint(g, x, y + d); CGContextAddLineToPoint(g, x + d, y); CGContextAddLineToPoint(g, x + w, y); CGContextAddLineToPoint(g, x + w - d, y + d); CGContextClosePath(g); FILLPATH(light);
		CGContextMoveToPoint(g, x + w - d, y + d); CGContextAddLineToPoint(g, x + w, y); CGContextAddLineToPoint(g, x + w, y + h - d); CGContextAddLineToPoint(g, x + w - d, y + h); CGContextClosePath(g); FILLPATH(dark);
	} else if ([kind isEqualToString:@"cylinder"] || [kind isEqualToString:@"tube"]) {
		CGFloat e = h * 0.28;
		CGContextMoveToPoint(g, x, y + e / 2); CGContextAddLineToPoint(g, x, y + h - e / 2);
		CGContextAddArc(g, x + w / 2, y + h - e / 2, w / 2, M_PI, 0, 1);
		CGContextAddLineToPoint(g, x + w, y + e / 2); CGContextClosePath(g); FILLPATH(fill);
		CGContextAddEllipseInRect(g, CGRectMake(x, y, w, e)); FILLPATH(light);
		if ([kind isEqualToString:@"tube"]) { CGContextAddEllipseInRect(g, CGRectMake(x + w * 0.25, y + e * 0.25, w * 0.5, e * 0.5)); FILLPATH([UIColor colorWithWhite:0.08 alpha:1]); }
	} else if ([kind isEqualToString:@"sphere"] || [kind isEqualToString:@"dome"]) {
		BOOL dome = [kind isEqualToString:@"dome"];
		if (dome) { CGContextMoveToPoint(g, x, y + h * 0.8); CGContextAddArc(g, x + w / 2, y + h * 0.8, w / 2, M_PI, 0, 0); CGContextClosePath(g); }
		else CGContextAddEllipseInRect(g, CGRectMake(x, y, w, h));
		FILLPATH(fill);
		CGContextSetFillColorWithColor(g, [light colorWithAlphaComponent:0.8].CGColor);
		CGContextFillEllipseInRect(g, CGRectMake(x + w * 0.22, y + (dome ? h * 0.38 : h * 0.18), w * 0.26, h * 0.2));
	} else if ([kind isEqualToString:@"cone"]) {
		CGFloat e = h * 0.26;
		CGContextMoveToPoint(g, x + w / 2, y); CGContextAddLineToPoint(g, x + w, y + h - e / 2);
		CGContextAddArc(g, x + w / 2, y + h - e / 2, w / 2, 0, M_PI, 0); CGContextClosePath(g); FILLPATH(fill);
		CGContextMoveToPoint(g, x + w / 2, y); CGContextAddLineToPoint(g, x + w, y + h - e / 2); CGContextAddArc(g, x + w / 2, y + h - e / 2, w / 2, 0, M_PI / 2, 0); CGContextClosePath(g); FILLPATH(dark);
	} else if ([kind isEqualToString:@"pyramid"]) {
		CGContextMoveToPoint(g, x + w * 0.55, y); CGContextAddLineToPoint(g, x, y + h * 0.82); CGContextAddLineToPoint(g, x + w * 0.62, y + h); CGContextClosePath(g); FILLPATH(fill);
		CGContextMoveToPoint(g, x + w * 0.55, y); CGContextAddLineToPoint(g, x + w * 0.62, y + h); CGContextAddLineToPoint(g, x + w, y + h * 0.75); CGContextClosePath(g); FILLPATH(dark);
	} else if ([kind isEqualToString:@"roof"]) {
		CGFloat d = w * 0.3;
		CGContextMoveToPoint(g, x, y + h); CGContextAddLineToPoint(g, x + (w - d) / 2, y + d); CGContextAddLineToPoint(g, x + w - d, y + h); CGContextClosePath(g); FILLPATH(fill);
		CGContextMoveToPoint(g, x + (w - d) / 2, y + d); CGContextAddLineToPoint(g, x + (w - d) / 2 + d, y); CGContextAddLineToPoint(g, x + w, y + h - d); CGContextAddLineToPoint(g, x + w - d, y + h); CGContextClosePath(g); FILLPATH(dark);
	} else if ([kind isEqualToString:@"wedge"]) {
		CGFloat d = w * 0.3;
		CGContextMoveToPoint(g, x, y + d); CGContextAddLineToPoint(g, x + w - d, y + h); CGContextAddLineToPoint(g, x, y + h); CGContextClosePath(g); FILLPATH(fill);
		CGContextMoveToPoint(g, x, y + d); CGContextAddLineToPoint(g, x + d, y); CGContextAddLineToPoint(g, x + w, y + h - d); CGContextAddLineToPoint(g, x + w - d, y + h); CGContextClosePath(g); FILLPATH(light);
	} else if ([kind isEqualToString:@"torus"]) {
		CGContextAddEllipseInRect(g, CGRectMake(x, y + h * 0.2, w, h * 0.6));
		CGContextAddEllipseInRect(g, CGRectMake(x + w * 0.3, y + h * 0.38, w * 0.4, h * 0.2));
		CGContextSetFillColorWithColor(g, fill.CGColor);
		CGContextDrawPath(g, kCGPathEOFillStroke);
	}
	#undef FILLPATH
	CGContextRestoreGState(g);
	(void)hole;
}

static UIImage *PDShapeIcon(NSString *kind, BOOL hole) {
	CGSize s = CGSizeMake(34, 30);
	UIGraphicsBeginImageContextWithOptions(s, NO, 0);
	CGContextRef g = UIGraphicsGetCurrentContext();
	UIColor *fill = hole ? [UIColor colorWithWhite:0.62 alpha:1] : PD_ACCENT;
	PDDrawShapeIcon(g, kind, CGRectMake(3, 2, 28, 26), fill, hole);
	if (hole) {   // a dashed outline marks holes
		CGContextSetStrokeColorWithColor(g, [UIColor colorWithWhite:1 alpha:0.8].CGColor);
		CGFloat dash[2] = {3, 2};
		CGContextSetLineDash(g, 0, dash, 2);
		CGContextSetLineWidth(g, 1.2);
		CGContextStrokeRect(g, CGRectMake(1.5, 1.5, s.width - 3, s.height - 3));
	}
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

#pragma mark - Library icons

static UIImage *PDPartIcon(NSString *type) {
	CGSize s = CGSizeMake(34, 30);
	UIGraphicsBeginImageContextWithOptions(s, NO, 0);
	CGContextRef g = UIGraphicsGetCurrentContext();
	BOOL hole = [PDShape partTypeIsHole:type];
	UIColor *fill = hole ? [UIColor colorWithWhite:0.62 alpha:1] : PD_ACCENT, *dark = [UIColor colorWithWhite:0.08 alpha:1];
	CGFloat fr, fg, fb, fa;
	[fill getRed:&fr green:&fg blue:&fb alpha:&fa];
	UIColor *shade = [UIColor colorWithRed:fr * 0.62 green:fg * 0.62 blue:fb * 0.62 alpha:1];
	CGContextSetLineJoin(g, kCGLineJoinRound);
	CGContextSetLineWidth(g, 1);
	CGContextSetStrokeColorWithColor(g, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
	CGContextSetFillColorWithColor(g, fill.CGColor);
	if ([type isEqualToString:@"bolt"]) {
		CGContextFillRect(g, CGRectMake(14, 3, 6, 19));
		CGContextSetStrokeColorWithColor(g, shade.CGColor);
		for (int y = 5; y < 21; y += 3) { CGContextMoveToPoint(g, 14, y + 1.5f); CGContextAddLineToPoint(g, 20, y - 0.5f); }
		CGContextStrokePath(g);
		CGContextSetFillColorWithColor(g, shade.CGColor);
		CGContextFillRect(g, CGRectMake(8, 21, 18, 7));
		CGContextSetFillColorWithColor(g, fill.CGColor);
		CGContextFillRect(g, CGRectMake(13, 21, 8, 7));
	} else if ([type isEqualToString:@"nut"]) {
		for (int i = 0; i < 6; i++) { double a = M_PI / 3 * i + M_PI / 6; if (i) CGContextAddLineToPoint(g, 17 + 13 * cos(a), 15 + 13 * sin(a)); else CGContextMoveToPoint(g, 17 + 13 * cos(a), 15 + 13 * sin(a)); }
		CGContextClosePath(g);
		CGContextDrawPath(g, kCGPathFillStroke);
		CGContextSetFillColorWithColor(g, dark.CGColor);
		CGContextFillEllipseInRect(g, CGRectMake(11, 9, 12, 12));
	} else if ([type isEqualToString:@"threadedHole"]) {
		CGContextFillRect(g, CGRectMake(11, 3, 12, 24));
		CGContextSetStrokeColorWithColor(g, dark.CGColor);
		for (int y = 5; y < 26; y += 3) { CGContextMoveToPoint(g, 11, y + 1.5f); CGContextAddLineToPoint(g, 23, y - 0.5f); }
		CGContextStrokePath(g);
	} else if ([type isEqualToString:@"screwHole"]) {
		CGContextMoveToPoint(g, 5, 3); CGContextAddLineToPoint(g, 29, 3); CGContextAddLineToPoint(g, 21, 11);
		CGContextAddLineToPoint(g, 21, 27); CGContextAddLineToPoint(g, 13, 27); CGContextAddLineToPoint(g, 13, 11); CGContextClosePath(g);
		CGContextDrawPath(g, kCGPathFillStroke);
	} else if ([type isEqualToString:@"edgeHole"]) {
		CGContextMoveToPoint(g, 5, 3); CGContextAddQuadCurveToPoint(g, 12, 3, 12, 11); CGContextAddLineToPoint(g, 12, 27);
		CGContextAddLineToPoint(g, 22, 27); CGContextAddLineToPoint(g, 22, 11); CGContextAddQuadCurveToPoint(g, 22, 3, 29, 3); CGContextClosePath(g);
		CGContextDrawPath(g, kCGPathFillStroke);
	} else if ([type isEqualToString:@"roundedBox"]) {
		UIBezierPath *b = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 7, 28, 19) cornerRadius:6];
		[fill setFill]; [b fill];
		[[UIColor colorWithWhite:1 alpha:0.35] setFill];
		[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(7, 9, 20, 4) cornerRadius:2] fill];
	} else if ([type isEqualToString:@"roundedCylinder"]) {
		UIBezierPath *b = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(8, 3, 18, 25) cornerRadius:6];
		[fill setFill]; [b fill];
		[[UIColor colorWithWhite:1 alpha:0.35] setFill];
		CGContextFillEllipseInRect(g, CGRectMake(11, 5, 12, 4));
	} else if ([type isEqualToString:@"gear"]) {
		int n = 40;
		for (int i = 0; i <= n; i++) {
			double a = 2 * M_PI * i / n, r = (i / 2) % 2 ? 10.5 : 13.5;
			if (i) CGContextAddLineToPoint(g, 17 + r * cos(a), 15 + r * sin(a)); else CGContextMoveToPoint(g, 17 + r * cos(a), 15 + r * sin(a));
		}
		CGContextClosePath(g);
		CGContextDrawPath(g, kCGPathFillStroke);
		CGContextSetFillColorWithColor(g, dark.CGColor);
		CGContextFillEllipseInRect(g, CGRectMake(13, 11, 8, 8));
	} else if ([type isEqualToString:@"models"]) {
		CGContextSetFillColorWithColor(g, shade.CGColor);
		CGContextFillRect(g, CGRectMake(5, 19, 24, 9));
		CGContextSetFillColorWithColor(g, fill.CGColor);
		CGContextMoveToPoint(g, 13, 2); CGContextAddLineToPoint(g, 21, 2); CGContextAddLineToPoint(g, 21, 11); CGContextAddLineToPoint(g, 26, 11);
		CGContextAddLineToPoint(g, 17, 20); CGContextAddLineToPoint(g, 8, 11); CGContextAddLineToPoint(g, 13, 11); CGContextClosePath(g);
		CGContextFillPath(g);
	}
	if (hole) {
		CGContextSetStrokeColorWithColor(g, [UIColor colorWithWhite:1 alpha:0.8].CGColor);
		CGFloat dash[2] = {3, 2};
		CGContextSetLineDash(g, 0, dash, 2);
		CGContextSetLineWidth(g, 1.2);
		CGContextStrokeRect(g, CGRectMake(1.5, 1.5, s.width - 3, s.height - 3));
	}
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

#pragma mark - Inspector row

// "W  [−] 20.0 mm [+]": a value with steppers; the value itself is tappable (type a number).
@interface PDValueRow : UIView
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIButton *minus, *value, *plus;
@property (nonatomic, copy) void (^step)(int dir);
@property (nonatomic, copy) void (^edit)(void);
@property (nonatomic) CGFloat nameWidth;
@end

@implementation PDValueRow
- (id)initWithName:(NSString *)name minus:(NSString *)m plus:(NSString *)p {
	if ((self = [super initWithFrame:CGRectMake(0, 0, 240, 36)])) {
		_nameWidth = 56;
		_nameLabel = PDLabel([UIFont boldSystemFontOfSize:14], PD_DIM);
		_nameLabel.text = name;
		_minus = PDDButton(m, PD_ACCENT, 15);
		_plus = PDDButton(p, PD_ACCENT, 15);
		_value = [UIButton buttonWithType:UIButtonTypeCustom];
		_value.titleLabel.font = [UIFont boldSystemFontOfSize:15];
		[_value setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
		[_value setTitleColor:PD_DIM forState:UIControlStateHighlighted];
		[_value setTitleColor:PD_FAINT forState:UIControlStateDisabled];
		_value.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
		_value.layer.cornerRadius = 8;
		[_minus addTarget:self action:@selector(down) forControlEvents:UIControlEventTouchUpInside];
		[_plus addTarget:self action:@selector(up) forControlEvents:UIControlEventTouchUpInside];
		[_value addTarget:self action:@selector(tapValue) forControlEvents:UIControlEventTouchUpInside];
		for (UIView *v in [NSArray arrayWithObjects:_nameLabel, _minus, _value, _plus, nil]) [self addSubview:v];
	}
	return self;
}
- (void)down { if (self.step) self.step(-1); }
- (void)up { if (self.step) self.step(1); }
- (void)tapValue { if (self.edit) self.edit(); }
- (void)layoutSubviews {
	CGFloat w = self.bounds.size.width, h = self.bounds.size.height, bw = 50;
	CGFloat nw = self.nameWidth;
	self.nameLabel.frame = CGRectMake(0, 0, nw, h);
	self.minus.frame = CGRectMake(nw + 2, 0, bw, h);
	self.plus.frame = CGRectMake(w - bw, 0, bw, h);
	self.value.frame = CGRectMake(nw + 2 + bw + 6, 0, w - nw - 2 - 2 * bw - 12, h);
}
- (void)setEnabled:(BOOL)on {
	self.minus.enabled = self.plus.enabled = self.value.enabled = on;
	self.alpha = on ? 1 : 0.45;
}
@end

// A percentage box for the Scale tool: "X  [−] [ 100 % ] [+]", the box typed into (Return or leaving it applies).
@interface PDPercentRow : UIView <UITextFieldDelegate>
@property (nonatomic, strong) UILabel *nameLabel, *unitLabel;
@property (nonatomic, strong) UIButton *minus, *plus;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, copy) void (^step)(int dir);
@property (nonatomic, copy) void (^commit)(float value);
@property (nonatomic, copy) void (^began)(void);
- (void)showValue:(float)v;
@end

@implementation PDPercentRow
- (id)initWithName:(NSString *)name {
	if ((self = [super initWithFrame:CGRectMake(0, 0, 240, 36)])) {
		_nameLabel = PDLabel([UIFont boldSystemFontOfSize:14], PD_DIM);
		_nameLabel.text = name;
		_unitLabel = PDLabel([UIFont boldSystemFontOfSize:14], PD_DIM);
		_unitLabel.text = @"%";
		_minus = PDDButton(@"−", PD_ACCENT, 15);
		_plus = PDDButton(@"+", PD_ACCENT, 15);
		_field = [[UITextField alloc] initWithFrame:CGRectZero];
		_field.font = [UIFont boldSystemFontOfSize:15];
		_field.textColor = [UIColor whiteColor];
		_field.textAlignment = NSTextAlignmentCenter;
		_field.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
		_field.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
		_field.layer.cornerRadius = 8;
		_field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
		_field.returnKeyType = UIReturnKeyDone;
		_field.clearsOnBeginEditing = NO;
		_field.accessibilityLabel = [NSString stringWithFormat:@"%@ percent", name];
		_field.delegate = self;
		[_minus addTarget:self action:@selector(down) forControlEvents:UIControlEventTouchUpInside];
		[_plus addTarget:self action:@selector(up) forControlEvents:UIControlEventTouchUpInside];
		for (UIView *v in [NSArray arrayWithObjects:_nameLabel, _minus, _field, _unitLabel, _plus, nil]) [self addSubview:v];
	}
	return self;
}
- (void)down { [self.field resignFirstResponder]; if (self.step) self.step(-1); }
- (void)up { [self.field resignFirstResponder]; if (self.step) self.step(1); }
- (void)layoutSubviews {
	CGFloat w = self.bounds.size.width, h = self.bounds.size.height, bw = 44, nw = 24, uw = 18;
	self.nameLabel.frame = CGRectMake(0, 0, nw, h);
	self.minus.frame = CGRectMake(nw, 0, bw, h);
	self.plus.frame = CGRectMake(w - bw, 0, bw, h);
	self.field.frame = CGRectMake(nw + bw + 6, 0, w - nw - 2 * bw - 12 - uw, h);
	self.unitLabel.frame = CGRectMake(CGRectGetMaxX(self.field.frame) + 3, 0, uw, h);
}
- (void)showValue:(float)v { if (!self.field.isEditing) self.field.text = [NSString stringWithFormat:@"%g", roundf(v * 10) / 10]; }
- (void)textFieldDidBeginEditing:(UITextField *)tf { if (self.began) self.began(); }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
- (void)textFieldDidEndEditing:(UITextField *)tf {
	NSScanner *sc = [NSScanner scannerWithString:[tf.text stringByReplacingOccurrencesOfString:@"," withString:@"."]];
	float v;
	if ([sc scanFloat:&v] && self.commit) self.commit(v);
	else if (self.commit) self.commit(NAN);   // not a number: just show the value again
}
- (void)setEnabled:(BOOL)on {
	self.minus.enabled = self.plus.enabled = self.field.enabled = on;
	self.alpha = on ? 1 : 0.45;
}
@end

#pragma mark - Design list

@interface PDDesignList : UITableViewController
@property (nonatomic, strong) NSMutableArray *names;
@property (nonatomic, copy) NSString *current;
@property (nonatomic, copy) void (^picked)(NSString *name);
@property (nonatomic, copy) void (^deleted)(NSString *name);
@end

@implementation PDDesignList
- (id)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.names = [[PDDesign savedNames] mutableCopy];
		self.contentSizeForViewInPopover = CGSizeMake(320, MIN(560, 44 * MAX(1, [self.names count])));
	}
	return self;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return MAX(1, (NSInteger)[self.names count]); }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"d"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"d"];
	if (![self.names count]) { c.textLabel.text = @"No saved designs"; c.selectionStyle = UITableViewCellSelectionStyleNone; c.accessoryType = UITableViewCellAccessoryNone; return c; }
	NSString *n = [self.names objectAtIndex:(NSUInteger)ip.row];
	c.textLabel.text = n;
	c.selectionStyle = UITableViewCellSelectionStyleBlue;
	c.accessoryType = [n isEqualToString:self.current] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	if (![self.names count]) return;
	if (self.picked) self.picked([self.names objectAtIndex:(NSUInteger)ip.row]);
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip { return [self.names count] > 0; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
	if (st != UITableViewCellEditingStyleDelete || (NSUInteger)ip.row >= [self.names count]) return;
	NSString *n = [self.names objectAtIndex:(NSUInteger)ip.row];
	[PDDesign deleteNamed:n];
	[self.names removeObjectAtIndex:(NSUInteger)ip.row];
	if ([self.names count]) [t deleteRowsAtIndexPaths:[NSArray arrayWithObject:ip] withRowAnimation:UITableViewRowAnimationFade];
	else [t reloadData];
	if (self.deleted) self.deleted(n);
}
@end

#pragma mark - Part editor

// The parameters of a Library part, in a popover: steppers for numbers (tap the value to type one), segments for
// short choices (‹ › for long ones such as the thread size), switches. "Add to plate" / "Update part".
@interface PDPartEditor : UIViewController <UIAlertViewDelegate>
@property (nonatomic, copy) NSString *type;
@property (nonatomic, strong) NSMutableDictionary *params;
@property (nonatomic, strong) NSArray *spec;
@property (nonatomic) BOOL updating;
@property (nonatomic, copy) void (^done)(NSDictionary *params);
@property (nonatomic, strong) NSMutableArray *controls;   // per spec row
@property (nonatomic, strong) UILabel *summary;
@property (nonatomic, copy) NSString *editingKey;
@end

@implementation PDPartEditor
- (id)initWithType:(NSString *)type parameters:(NSDictionary *)p updating:(BOOL)updating {
	if ((self = [super init])) {
		_type = [type copy];
		_params = [p mutableCopy] ?: [NSMutableDictionary dictionary];
		_spec = [PDShape parameterSpecForPartType:type];
		_updating = updating;
		self.contentSizeForViewInPopover = CGSizeMake(420, 140 + 48 * [_spec count]);
	}
	return self;
}
- (void)loadView {
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 420, 140 + 48 * [self.spec count])];
	v.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
	CGFloat x = 16, w = 420 - 32, y = 14;
	UILabel *title = PDLabel(PDBoldFont(19), [UIColor whiteColor]);
	title.text = [PDShape titleForPartType:self.type];
	title.frame = CGRectMake(x, y, w, 24); y += 26;
	[v addSubview:title];
	self.summary = PDLabel([UIFont systemFontOfSize:13], PD_DIM);
	self.summary.frame = CGRectMake(x, y, w, 18); y += 28;
	[v addSubview:self.summary];
	self.controls = [NSMutableArray array];
	__weak PDPartEditor *weakSelf = self;
	for (NSDictionary *row in self.spec) {
		NSString *kind = [row objectForKey:@"kind"], *key = [row objectForKey:@"key"];
		NSArray *choices = [row objectForKey:@"choices"];
		UIView *c = nil;
		if ([kind isEqualToString:@"number"] || ([kind isEqualToString:@"choice"] && [choices count] > 4)) {
			BOOL choice = [kind isEqualToString:@"choice"];
			PDValueRow *r = [[PDValueRow alloc] initWithName:[row objectForKey:@"title"] minus:choice ? @"‹" : @"−" plus:choice ? @"›" : @"+"];
			r.nameWidth = 104;
			r.step = ^(int dir) { [weakSelf step:key dir:dir]; };
			if (!choice) r.edit = ^{ [weakSelf typeValue:key]; };
			r.frame = CGRectMake(x, y, w, 38);
			c = r;
		} else {
			UILabel *l = PDLabel([UIFont boldSystemFontOfSize:14], PD_DIM);
			l.text = [row objectForKey:@"title"];
			l.frame = CGRectMake(x, y, 104, 38);
			[v addSubview:l];
			if ([kind isEqualToString:@"choice"]) {
				UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:choices];
				sc.segmentedControlStyle = UISegmentedControlStyleBar;
				sc.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
				sc.frame = CGRectMake(x + 106, y + 2, w - 106, 34);
				sc.tag = (NSInteger)[self.controls count];
				[sc addTarget:self action:@selector(choiceChanged:) forControlEvents:UIControlEventValueChanged];
				c = sc;
			} else {
				UISwitch *sw = [[UISwitch alloc] init];
				sw.frame = CGRectMake(x + 106, y + 5, sw.frame.size.width, sw.frame.size.height);
				sw.accessibilityLabel = [row objectForKey:@"title"];
				sw.tag = (NSInteger)[self.controls count];
				[sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
				c = sw;
			}
		}
		[v addSubview:c];
		[self.controls addObject:c];
		y += 48;
	}
	UIButton *go = PDDButton(self.updating ? ([self.type hasPrefix:@"shape."] ? @"Update shape" : @"Update part") : @"Add to plate", PD_GREEN, 17);
	go.frame = CGRectMake(x, y + 6, w, 46);
	[go addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
	[v addSubview:go];
	self.view = v;
	[self refresh];
}
- (NSDictionary *)rowFor:(NSString *)key { for (NSDictionary *r in self.spec) if ([[r objectForKey:@"key"] isEqualToString:key]) return r; return nil; }
- (void)setValue:(double)v forParam:(NSString *)key {
	NSDictionary *r = [self rowFor:key];
	if ([[r objectForKey:@"kind"] isEqualToString:@"number"]) {
		double lo = [[r objectForKey:@"min"] doubleValue], hi = [[r objectForKey:@"max"] doubleValue];
		v = MAX(lo, MIN(hi, v));
		v = round(v * 1000) / 1000;
	}
	[self.params setObject:[NSNumber numberWithDouble:v] forKey:key];
	[self refresh];
}
- (void)step:(NSString *)key dir:(int)dir {
	NSDictionary *r = [self rowFor:key];
	double cur = [[self.params objectForKey:key] doubleValue];
	if ([[r objectForKey:@"kind"] isEqualToString:@"choice"]) {
		NSInteger n = (NSInteger)[[r objectForKey:@"choices"] count], i = (NSInteger)lround(cur) + dir;
		[self setValue:(double)MAX(0, MIN(n - 1, i)) forParam:key];
		return;
	}
	double st = [[r objectForKey:@"step"] doubleValue];
	if (st <= 0) st = 1;
	double v = dir > 0 ? floor(cur / st + 1e-6) * st + st : ceil(cur / st - 1e-6) * st - st;
	[self setValue:v forParam:key];
}
- (void)typeValue:(NSString *)key {
	self.editingKey = key;
	NSDictionary *r = [self rowFor:key];
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:[r objectForKey:@"title"] message:[r objectForKey:@"unit"] delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Set", nil];
	a.alertViewStyle = UIAlertViewStylePlainTextInput;
	UITextField *tf = [a textFieldAtIndex:0];
	tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
	tf.text = [NSString stringWithFormat:@"%g", [[self.params objectForKey:key] doubleValue]];
	[a show];
}
- (void)alertView:(UIAlertView *)a clickedButtonAtIndex:(NSInteger)i {
	if (i == a.cancelButtonIndex || !self.editingKey) return;
	NSScanner *sc = [NSScanner scannerWithString:[[a textFieldAtIndex:0].text stringByReplacingOccurrencesOfString:@"," withString:@"."]];
	double v;
	if ([sc scanDouble:&v]) [self setValue:v forParam:self.editingKey];
}
- (void)choiceChanged:(UISegmentedControl *)sc {
	NSDictionary *r = [self.spec objectAtIndex:(NSUInteger)sc.tag];
	[self setValue:(double)sc.selectedSegmentIndex forParam:[r objectForKey:@"key"]];
}
- (void)switchChanged:(UISwitch *)sw {
	NSDictionary *r = [self.spec objectAtIndex:(NSUInteger)sw.tag];
	[self setValue:sw.on ? 1 : 0 forParam:[r objectForKey:@"key"]];
}
- (void)refresh {
	for (NSUInteger i = 0; i < [self.spec count] && i < [self.controls count]; i++) {
		NSDictionary *r = [self.spec objectAtIndex:i];
		id c = [self.controls objectAtIndex:i];
		double v = [[self.params objectForKey:[r objectForKey:@"key"]] doubleValue];
		if ([c isKindOfClass:[PDValueRow class]]) {
			NSArray *choices = [r objectForKey:@"choices"];
			NSString *t = choices ? [choices objectAtIndex:(NSUInteger)MAX(0, MIN((long)[choices count] - 1, lround(v)))]
				: [NSString stringWithFormat:@"%g %@", v, [r objectForKey:@"unit"]];
			[((PDValueRow *)c).value setTitle:t forState:UIControlStateNormal];
		} else if ([c isKindOfClass:[UISegmentedControl class]]) ((UISegmentedControl *)c).selectedSegmentIndex = lround(v);
		else if ([c isKindOfClass:[UISwitch class]]) ((UISwitch *)c).on = v != 0;
	}
	self.summary.text = [PDShape describePart:self.type parameters:self.params];
}
- (void)finish { if (self.done) self.done([self.params copy]); }
@end

#pragma mark - Model picker

// "Models…": saved Library parts and the STL/OBJ models on the iPad, to bring into the design; a link to download one.
@interface PDDesignModelPicker : UITableViewController
@property (nonatomic, strong) NSMutableArray *parts, *models;
@property (nonatomic, strong) NSArray *handy;            // bundled test models: {path, note}
@property (nonatomic, copy) void (^picked)(NSString *path);
@property (nonatomic, copy) void (^download)(void);
@end

@implementation PDDesignModelPicker
- (id)init {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.parts = [[PDLibrary savedParts] mutableCopy];
		self.models = [[PDLibrary models] mutableCopy];
		// Handy models: calibration and test prints, from ElegooSlicer's resources/handy_models (Draco meshes
		// exported to STL) plus a generated overhang test. Bundled in PrintDeck.app/HandyModels.
		NSString *dir = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"HandyModels"];
		NSArray *spec = [NSArray arrayWithObjects:
			@"Overhang test 20-70", @"Fins at 20° to 70° from vertical, 10° apart",
			@"All-in-one test (KSR FDM)", @"Overhangs, bridges, stringing, tolerances, text in one",
			@"Elegoo test cube", @"Elegoo's calibration piece",
			@"Orca test cube", @"OrcaSlicer's 30 mm calibration cube",
			@"Voron design cube", @"30 mm dimensional cube",
			@"Elegoo tolerance test", @"Peg fit from loose to tight",
			@"Orca tolerance test", @"Peg fit from loose to tight",
			@"Elegoo stringing test", @"Towers for retraction tuning",
			@"Orca stringing test", @"Towers for retraction tuning",
			@"Calicat", @"Calibration cat: dimensions and overhangs",
			@"Stanford bunny", @"Organic shape, 118 mm tall", nil];
		NSMutableArray *h = [NSMutableArray array];
		for (NSUInteger i = 0; i + 1 < [spec count]; i += 2) {
			NSString *path = [dir stringByAppendingPathComponent:[[spec objectAtIndex:i] stringByAppendingPathExtension:@"stl"]];
			if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [h addObject:[NSDictionary dictionaryWithObjectsAndKeys:path, @"path", [spec objectAtIndex:i + 1], @"note", nil]];
		}
		self.handy = h;
		UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 400, 96)];
		head.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
		UIButton *b = PDDButton(@"Download from a link…", PD_ACCENT, 15);
		b.frame = CGRectMake(12, 10, 376, 40);
		[b addTarget:self action:@selector(downloadTap) forControlEvents:UIControlEventTouchUpInside];
		[head addSubview:b];
		UILabel *l = PDLabel([UIFont systemFontOfSize:12], PD_DIM);
		l.numberOfLines = 2;
		l.text = @"STL or OBJ, in mm. Tap one to put it on the plate. Save to library (in the inspector) adds your own parts here.";
		l.frame = CGRectMake(12, 54, 376, 36);
		[head addSubview:l];
		self.tableView.tableHeaderView = head;
		self.tableView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
		self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.1];
		NSUInteger rows = MAX(1, [self.parts count]) + [self.handy count] + MAX(1, [self.models count]);
		self.contentSizeForViewInPopover = CGSizeMake(400, MIN(640, 96 + 3 * 30 + 50 * rows));
	}
	return self;
}
- (void)downloadTap { if (self.download) self.download(); }
// Sections: 0 saved parts, 1 handy models (bundled, can't be deleted), 2 models on the iPad.
- (NSMutableArray *)listFor:(NSInteger)sec { return sec == 0 ? self.parts : sec == 2 ? self.models : nil; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)sec { return sec == 0 ? @"Saved parts" : sec == 1 ? @"Handy models" : @"Models on the iPad"; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)sec { return sec == 1 ? (NSInteger)[self.handy count] : MAX(1, (NSInteger)[[self listFor:sec] count]); }
- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip { return 50; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"m"];
	if (!c) {
		c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"m"];
		c.textLabel.textColor = [UIColor whiteColor];
		c.detailTextLabel.textColor = PD_DIM;
		c.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
		UIView *sel = [[UIView alloc] init];
		sel.backgroundColor = [PD_ACCENT colorWithAlphaComponent:0.3];
		c.selectedBackgroundView = sel;
	}
	if (ip.section == 1) {
		NSDictionary *m = [self.handy objectAtIndex:(NSUInteger)ip.row];
		c.textLabel.textColor = [UIColor whiteColor];
		c.selectionStyle = UITableViewCellSelectionStyleBlue;
		c.textLabel.text = [[[m objectForKey:@"path"] lastPathComponent] stringByDeletingPathExtension];
		c.detailTextLabel.text = [m objectForKey:@"note"];
		return c;
	}
	NSArray *list = [self listFor:ip.section];
	if (![list count]) {
		c.textLabel.text = ip.section == 0 ? @"None yet" : @"No models";
		c.detailTextLabel.text = ip.section == 0 ? @"Select a shape and tap Save to library." : @"Copy STL files in, or download one.";
		c.textLabel.textColor = PD_DIM;
		c.selectionStyle = UITableViewCellSelectionStyleNone;
		return c;
	}
	NSString *path = [list objectAtIndex:(NSUInteger)ip.row];
	c.textLabel.textColor = [UIColor whiteColor];
	c.selectionStyle = UITableViewCellSelectionStyleBlue;
	c.textLabel.text = [[path lastPathComponent] stringByDeletingPathExtension];
	unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] fileSize];
	c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", [[path pathExtension] uppercaseString],
		size > 1048576 ? [NSString stringWithFormat:@"%.1f MB", size / 1048576.0] : [NSString stringWithFormat:@"%llu KB", size / 1024 + 1]];
	return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[t deselectRowAtIndexPath:ip animated:YES];
	if (ip.section == 1) { if ((NSUInteger)ip.row < [self.handy count] && self.picked) self.picked([[self.handy objectAtIndex:(NSUInteger)ip.row] objectForKey:@"path"]); return; }
	NSArray *list = [self listFor:ip.section];
	if ((NSUInteger)ip.row < [list count] && self.picked) self.picked([list objectAtIndex:(NSUInteger)ip.row]);
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip { return [[self listFor:ip.section] count] > 0; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
	NSMutableArray *list = [self listFor:ip.section];
	if (st != UITableViewCellEditingStyleDelete || (NSUInteger)ip.row >= [list count]) return;
	[[NSFileManager defaultManager] removeItemAtPath:[list objectAtIndex:(NSUInteger)ip.row] error:NULL];
	[list removeObjectAtIndex:(NSUInteger)ip.row];
	if ([list count]) [t deleteRowsAtIndexPaths:[NSArray arrayWithObject:ip] withRowAnimation:UITableViewRowAnimationFade];
	else [t reloadData];
}
@end

#pragma mark - Shape picker

// "Pick shapes…": every shape on the plate with a checkmark; tap rows to choose what to group (or align).
@interface PDShapePicker : UITableViewController
@property (nonatomic, strong) NSArray *shapes;
@property (nonatomic, strong) NSMutableIndexSet *picked;
@property (nonatomic, copy) void (^changed)(NSIndexSet *picked);
@property (nonatomic, copy) void (^groupTapped)(void);
@property (nonatomic, strong) UIButton *groupButton;
@end

static UIImage *PDSwatchImage(PDShape *s) {
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(22, 22), NO, 0);
	CGContextRef g = UIGraphicsGetCurrentContext();
	UIBezierPath *b = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 20, 20) cornerRadius:5];
	if (s.hole) {
		[[UIColor colorWithWhite:0.6 alpha:1] setFill]; [b fill];
		CGFloat dash[2] = {3, 2};
		CGContextSetLineDash(g, 0, dash, 2);
		[[UIColor whiteColor] setStroke]; b.lineWidth = 1.2; [b stroke];
	} else { [PDColorFromRGB(s.color) setFill]; [b fill]; }
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

@implementation PDShapePicker
- (id)initWithShapes:(NSArray *)shapes picked:(NSIndexSet *)picked {
	if ((self = [super initWithStyle:UITableViewStylePlain])) {
		self.shapes = shapes;
		self.picked = [picked mutableCopy] ?: [NSMutableIndexSet indexSet];
		UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 340, 56)];
		NSArray *titles = [NSArray arrayWithObjects:@"All", @"None", @"Group", nil];
		for (NSUInteger i = 0; i < 3; i++) {
			UIButton *b = PDDButton([titles objectAtIndex:i], i == 2 ? PD_GREEN : PD_ACCENT, 15);
			b.frame = i == 2 ? CGRectMake(170, 8, 160, 40) : CGRectMake(10 + i * 78, 8, 72, 40);
			b.tag = (NSInteger)i;
			[b addTarget:self action:@selector(headTap:) forControlEvents:UIControlEventTouchUpInside];
			[head addSubview:b];
			if (i == 2) self.groupButton = b;
		}
		head.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
		self.tableView.tableHeaderView = head;
		self.tableView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
		self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.1];
		self.contentSizeForViewInPopover = CGSizeMake(340, MIN(600, 56 + 50 * MAX(1, [shapes count])));
		[self refreshGroup];
	}
	return self;
}
- (void)refreshGroup {
	self.groupButton.enabled = [self.picked count] >= 2;
	self.groupButton.alpha = self.groupButton.enabled ? 1 : 0.4;
	[self.groupButton setTitle:[self.picked count] >= 2 ? [NSString stringWithFormat:@"Group %lu", (unsigned long)[self.picked count]] : @"Group" forState:UIControlStateNormal];
}
- (void)headTap:(UIButton *)b {
	if (b.tag == 2) { if (self.groupTapped) self.groupTapped(); return; }
	[self.picked removeAllIndexes];
	if (b.tag == 0) [self.picked addIndexesInRange:NSMakeRange(0, [self.shapes count])];
	[self.tableView reloadData];
	[self refreshGroup];
	if (self.changed) self.changed(self.picked);
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)sec { return (NSInteger)[self.shapes count]; }
- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip { return 50; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"s"];
	if (!c) {
		c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"s"];
		c.textLabel.textColor = [UIColor whiteColor];
		c.detailTextLabel.textColor = PD_DIM;
		c.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
		UIView *sel = [[UIView alloc] init];
		sel.backgroundColor = [PD_ACCENT colorWithAlphaComponent:0.3];
		c.selectedBackgroundView = sel;
	}
	PDShape *s = [self.shapes objectAtIndex:(NSUInteger)ip.row];
	c.textLabel.text = [NSString stringWithFormat:@"%lu. %@%@", (unsigned long)ip.row + 1, [s title], s.hole ? @" hole" : @""];
	GLKVector3 lo = [s worldMin], hi = [s worldMax];
	c.detailTextLabel.text = [NSString stringWithFormat:@"%.0f × %.0f × %.0f mm · at %.0f, %.0f", hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, (lo.x + hi.x) / 2, (lo.y + hi.y) / 2];
	c.imageView.image = PDSwatchImage(s);
	c.accessoryType = [self.picked containsIndex:(NSUInteger)ip.row] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[t deselectRowAtIndexPath:ip animated:YES];
	NSUInteger r = (NSUInteger)ip.row;
	if ([self.picked containsIndex:r]) [self.picked removeIndex:r]; else [self.picked addIndex:r];
	[t cellForRowAtIndexPath:ip].accessoryType = [self.picked containsIndex:r] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	[self refreshGroup];
	if (self.changed) self.changed(self.picked);
}
@end

#pragma mark - Page

@interface PDDesignPage () <UIAlertViewDelegate, UIActionSheetDelegate, UIPopoverControllerDelegate>
@property (nonatomic, strong) PDDesign *design;
@property (nonatomic, strong) NSArray *shapes;
@property (nonatomic, strong) NSIndexSet *selection;
@property (nonatomic, strong) NSMutableArray *undoStack, *redoStack;
@property (nonatomic) BOOL busy;
@property (nonatomic) float snap, turnStep;
@property (nonatomic) int nextColor;
// top bar
@property (nonatomic, strong) UIButton *backButton, *titleButton, *designsButton, *undoButton, *redoButton, *sliceButton, *multiButton;
// palette
@property (nonatomic, strong) UIScrollView *palette, *library;
@property (nonatomic, strong) NSMutableArray *tiles, *libTiles;   // libTiles: [button, type ("models" for Models…)]
@property (nonatomic, strong) UISegmentedControl *paletteTabs;
// canvas
@property (nonatomic, strong) PDDesignView *canvas;
@property (nonatomic, strong) UISegmentedControl *gizmoControl;   // Slide | Move | Rotate | Scale
@property (nonatomic, strong) UILabel *scaleCaption, *scaleHint;  // Scale mode: the % boxes, at the top of the inspector
@property (nonatomic, strong) UIButton *uniformButton;
@property (nonatomic, strong) NSArray *scaleRows;                 // PDPercentRow: X, Y, Z (the shape's W, D, H)
@property (nonatomic, weak) PDShape *scaleEditShape;              // the shape a box was being typed for
@property (nonatomic, strong) UIButton *resetTurnButton;          // Rotate mode: back onto the shape's own axes
// inspector
@property (nonatomic, strong) UIScrollView *inspector;
@property (nonatomic, strong) UILabel *insTitle, *insInfo, *sizeCaption, *posCaption, *turnCaption, *colorCaption, *helpLabel, *snapCaption;
@property (nonatomic, strong) UISegmentedControl *solidHole, *snapControl;
@property (nonatomic, strong) NSArray *swatches, *sizeRows, *posRows, *turnRows, *actions;
@property (nonatomic, strong) UIButton *selectAllButton, *fitButton, *selectMoreButton, *pickButton, *gridButton;
@property (nonatomic, strong) UILabel *alignCaption, *alignHint;
@property (nonatomic, strong) NSArray *alignLabels, *alignButtons, *spaceButtons;
@property (nonatomic, strong) UIPopoverController *popover;
@property (nonatomic) int editingField;   // 0-2 size, 3-5 position
@end

@implementation PDDesignPage

+ (NSArray *)savedDesignNames { return [PDDesign savedNames]; }

+ (UIImage *)iconImage {
	static UIImage *img;
	if (!img) {
		UIGraphicsBeginImageContextWithOptions(CGSizeMake(44, 44), NO, 0);
		CGContextRef g = UIGraphicsGetCurrentContext();
		PDDrawShapeIcon(g, @"box", CGRectMake(2, 12, 26, 26), PDColorFromRGB(0x3B8FE0), NO);
		PDDrawShapeIcon(g, @"cylinder", CGRectMake(20, 4, 20, 28), PDColorFromRGB(0xF0A030), NO);
		img = UIGraphicsGetImageFromCurrentImageContext();
		UIGraphicsEndImageContext();
	}
	return img;
}

- (id)init {
	if ((self = [super initWithFrame:CGRectMake(0, 0, 1024, 768)])) {
		self.backgroundColor = PD_BG;
		NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
		_snap = [ud floatForKey:PDDesignSnapKey] > 0 ? [ud floatForKey:PDDesignSnapKey] : 1;
		_turnStep = 15;
		_undoStack = [NSMutableArray array];
		_redoStack = [NSMutableArray array];
		_selection = [NSIndexSet indexSet];
		_shapes = [NSArray array];

		// Top bar
		_backButton = [UIButton buttonWithType:UIButtonTypeCustom];
		[_backButton setTitle:@"‹  PrintDeck" forState:UIControlStateNormal];
		[_backButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
		[_backButton setTitleColor:PD_DIM forState:UIControlStateHighlighted];
		_backButton.titleLabel.font = [UIFont systemFontOfSize:19];
		_backButton.backgroundColor = PD_TILE;
		_backButton.layer.cornerRadius = 10;
		[_backButton addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];
		_titleButton = [UIButton buttonWithType:UIButtonTypeCustom];
		_titleButton.titleLabel.font = PDBoldFont(20);
		_titleButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
		_titleButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
		[_titleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
		[_titleButton setTitleColor:PD_DIM forState:UIControlStateHighlighted];
		[_titleButton addTarget:self action:@selector(rename) forControlEvents:UIControlEventTouchUpInside];
		_designsButton = PDDButton(@"Designs", PD_ACCENT, 16);
		[_designsButton addTarget:self action:@selector(designsMenu:) forControlEvents:UIControlEventTouchUpInside];
		_undoButton = PDDButton(@"Undo", PD_ACCENT, 16);
		[_undoButton addTarget:self action:@selector(undo) forControlEvents:UIControlEventTouchUpInside];
		_redoButton = PDDButton(@"Redo", PD_ACCENT, 16);
		[_redoButton addTarget:self action:@selector(redo) forControlEvents:UIControlEventTouchUpInside];
		_sliceButton = PDDButton(@"Send to slicer", PD_GREEN, 17);
		[_sliceButton addTarget:self action:@selector(sendToSlicer) forControlEvents:UIControlEventTouchUpInside];

		// Palette: the shapes, then the two common holes.
		_palette = [[UIScrollView alloc] initWithFrame:CGRectZero];
		_palette.backgroundColor = PD_TILE;
		_palette.layer.cornerRadius = 12;
		_palette.showsVerticalScrollIndicator = NO;
		_tiles = [NSMutableArray array];
		NSMutableArray *entries = [NSMutableArray array];
		for (NSString *k in [PDShape kinds]) [entries addObject:[NSArray arrayWithObjects:k, [NSNumber numberWithBool:NO], nil]];
		[entries addObject:[NSArray arrayWithObjects:@"box", [NSNumber numberWithBool:YES], nil]];
		[entries addObject:[NSArray arrayWithObjects:@"cylinder", [NSNumber numberWithBool:YES], nil]];
		for (NSArray *e in entries) {
			NSString *kind = [e objectAtIndex:0];
			BOOL hole = [[e objectAtIndex:1] boolValue];
			UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
			[b setTitle:hole ? [NSString stringWithFormat:@"%@ hole", [PDShape titleForKind:kind]] : [PDShape titleForKind:kind] forState:UIControlStateNormal];
			b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
			[b setTitleColor:PD_DIM forState:UIControlStateNormal];
			[b setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
			b.contentVerticalAlignment = UIControlContentVerticalAlignmentBottom;
			b.titleEdgeInsets = UIEdgeInsetsMake(0, 0, 4, 0);
			b.layer.cornerRadius = 8;
			b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
			UIImageView *iv = [[UIImageView alloc] initWithImage:PDShapeIcon(kind, hole)];
			iv.tag = 1000;
			iv.userInteractionEnabled = NO;
			[b addSubview:iv];
			b.tag = (NSInteger)[_tiles count];
			[b addTarget:self action:@selector(tileTap:) forControlEvents:UIControlEventTouchUpInside];
			[_palette addSubview:b];
			[_tiles addObject:[NSArray arrayWithObjects:b, kind, [NSNumber numberWithBool:hole], nil]];
		}

		// Library: parts made from parameters, then models to bring in.
		_paletteTabs = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"Basic", @"Library", nil]];
		_paletteTabs.segmentedControlStyle = UISegmentedControlStyleBar;
		_paletteTabs.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
		_paletteTabs.selectedSegmentIndex = [ud integerForKey:@"PDDesignTab"] == 1 ? 1 : 0;
		[_paletteTabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
		_library = [[UIScrollView alloc] initWithFrame:CGRectZero];
		_library.backgroundColor = PD_TILE;
		_library.layer.cornerRadius = 12;
		_library.showsVerticalScrollIndicator = NO;
		_libTiles = [NSMutableArray array];
		NSMutableArray *libTypes = [[PDShape partTypes] mutableCopy];
		[libTypes addObject:@"models"];
		for (NSString *type in libTypes) {
			UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
			[b setTitle:[type isEqualToString:@"models"] ? @"Models…" : [type isEqualToString:@"roundedCylinder"] ? @"Round cylinder" : [PDShape titleForPartType:type] forState:UIControlStateNormal];
			b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
			[b setTitleColor:PD_DIM forState:UIControlStateNormal];
			[b setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
			b.contentVerticalAlignment = UIControlContentVerticalAlignmentBottom;
			b.titleEdgeInsets = UIEdgeInsetsMake(0, 0, 4, 0);
			b.layer.cornerRadius = 8;
			b.backgroundColor = [UIColor colorWithWhite:1 alpha:[type isEqualToString:@"models"] ? 0.1 : 0.04];
			UIImageView *iv = [[UIImageView alloc] initWithImage:PDPartIcon(type)];
			iv.tag = 1000;
			iv.userInteractionEnabled = NO;
			[b addSubview:iv];
			b.tag = (NSInteger)[_libTiles count];
			[b addTarget:self action:@selector(libTileTap:) forControlEvents:UIControlEventTouchUpInside];
			[_library addSubview:b];
			[_libTiles addObject:[NSArray arrayWithObjects:b, type, nil]];
		}

		// Canvas
		_canvas = [[PDDesignView alloc] initWithFrame:CGRectMake(0, 0, 600, 600)];
		_canvas.layer.cornerRadius = 12;
		_canvas.clipsToBounds = YES;
		_canvas.snap = _snap;
		__weak PDDesignPage *weakSelf = self;
		_canvas.selectionChanged = ^{ weakSelf.selection = weakSelf.canvas.selection; [weakSelf update]; };
		_canvas.willMove = ^{ [weakSelf remember]; };
		_canvas.moved = ^(BOOL done) { if (done) [weakSelf changed]; else [weakSelf updateInspectorValues]; };
		_gizmoControl = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"Slide", @"Move XYZ", @"Rotate", @"Scale", nil]];
		_gizmoControl.segmentedControlStyle = UISegmentedControlStyleBar;
		_gizmoControl.tintColor = [UIColor colorWithWhite:0.22 alpha:1];
		_gizmoControl.selectedSegmentIndex = MAX(0, MIN(3, [ud integerForKey:@"PDDesignGizmo"]));
		_canvas.gizmo = _gizmoControl.selectedSegmentIndex;
		_canvas.uniformScale = [ud boolForKey:@"PDDesignUniformScale"];
		[_gizmoControl addTarget:self action:@selector(gizmoChanged) forControlEvents:UIControlEventValueChanged];
		_resetTurnButton = PDDButton(@"Reset rotation", PD_ACCENT, 14);
		_resetTurnButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
		[_resetTurnButton addTarget:self action:@selector(resetRotation) forControlEvents:UIControlEventTouchUpInside];
		_multiButton = PDDButton(@"Select more", PD_DIM, 14);
		[_multiButton addTarget:self action:@selector(toggleMulti) forControlEvents:UIControlEventTouchUpInside];

		// Inspector
		_inspector = [[UIScrollView alloc] initWithFrame:CGRectZero];
		_inspector.backgroundColor = PD_TILE;
		_inspector.layer.cornerRadius = 12;
		_insTitle = PDLabel(PDBoldFont(20), [UIColor whiteColor]);
		_insInfo = PDLabel([UIFont systemFontOfSize:13], PD_DIM);
		_insInfo.numberOfLines = 2;
		_solidHole = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"Solid", @"Hole", nil]];
		_solidHole.segmentedControlStyle = UISegmentedControlStyleBar;
		_solidHole.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
		[_solidHole addTarget:self action:@selector(solidHoleChanged) forControlEvents:UIControlEventValueChanged];
		_colorCaption = [self caption:@"COLOUR"];
		NSMutableArray *sw = [NSMutableArray array];
		for (int i = 0; i < 8; i++) {
			UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
			b.backgroundColor = PDColorFromRGB(PDDesignColors[i]);
			b.layer.cornerRadius = 8;
			b.layer.borderColor = [UIColor whiteColor].CGColor;
			b.accessibilityLabel = PDDesignColorNames[i];
			b.tag = i;
			[b setTitle:PDDesignColorNames[i] forState:UIControlStateNormal];   // for printdeck://press (not shown)
			[b setTitleColor:[UIColor clearColor] forState:UIControlStateNormal];
			b.titleLabel.font = [UIFont systemFontOfSize:1];
			[b addTarget:self action:@selector(colorTap:) forControlEvents:UIControlEventTouchUpInside];
			[sw addObject:b];
		}
		_swatches = sw;
		_sizeCaption = [self caption:@"SIZE"];
		_posCaption = [self caption:@"POSITION"];
		_turnCaption = [self caption:@"TURN"];
		NSArray *sizeNames = [NSArray arrayWithObjects:@"Width", @"Depth", @"Height", nil];
		NSArray *posNames = [NSArray arrayWithObjects:@"X", @"Y", @"Lift", nil];
		NSArray *axes = [NSArray arrayWithObjects:@"Z", @"X", @"Y", nil];
		NSArray *axisLetters = [NSArray arrayWithObjects:@"X", @"Y", @"Z", nil];
		NSMutableArray *rows = [NSMutableArray array];
		for (int a = 0; a < 3; a++) {
			PDValueRow *r = [[PDValueRow alloc] initWithName:[sizeNames objectAtIndex:(NSUInteger)a] minus:@"−" plus:@"+"];
			r.step = ^(int dir) { [weakSelf stepSize:a dir:dir]; };
			r.edit = ^{ [weakSelf editField:a]; };
			[rows addObject:r];
		}
		_sizeRows = rows;
		rows = [NSMutableArray array];
		for (int a = 0; a < 3; a++) {
			PDValueRow *r = [[PDValueRow alloc] initWithName:[posNames objectAtIndex:(NSUInteger)a] minus:@"−" plus:@"+"];
			r.step = ^(int dir) { [weakSelf stepPosition:a dir:dir]; };
			r.edit = ^{ [weakSelf editField:3 + a]; };
			[rows addObject:r];
		}
		_posRows = rows;
		rows = [NSMutableArray array];
		for (int a = 0; a < 3; a++) {
			PDValueRow *r = [[PDValueRow alloc] initWithName:[axes objectAtIndex:(NSUInteger)a] minus:@"↺" plus:@"↻"];
			int axis = a == 0 ? 2 : a - 1;   // rows: about Z (spin on the plate), X, Y
			r.step = ^(int dir) { [weakSelf turnAxis:axis dir:dir]; };
			r.edit = ^{ [weakSelf cycleTurnStep]; };
			[rows addObject:r];
		}
		_turnRows = rows;
		_scaleCaption = [self caption:@"SCALE (% OF ITS SIZE WHEN PICKED)"];
		_scaleHint = PDLabel([UIFont systemFontOfSize:12], PD_FAINT);
		_scaleHint.text = @"Select one shape to scale it.";
		_uniformButton = PDDButton(@"☐  Uniform", PD_ACCENT, 15);
		_uniformButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
		_uniformButton.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 0);
		[_uniformButton addTarget:self action:@selector(toggleUniform) forControlEvents:UIControlEventTouchUpInside];
		rows = [NSMutableArray array];
		for (int a = 0; a < 3; a++) {
			PDPercentRow *r = [[PDPercentRow alloc] initWithName:[axisLetters objectAtIndex:(NSUInteger)a]];
			r.step = ^(int dir) { [weakSelf stepScale:a dir:dir]; };
			r.commit = ^(float v) { if ([[weakSelf selectedShapes] lastObject] == weakSelf.scaleEditShape) [weakSelf setScale:v axis:a]; else [weakSelf updateInspectorValues]; };
			r.began = ^{ weakSelf.scaleEditShape = [[weakSelf selectedShapes] lastObject]; };
			[rows addObject:r];
		}
		_scaleRows = rows;
		NSArray *actionTitles = [NSArray arrayWithObjects:@"Duplicate", @"Delete", @"Group", @"Ungroup", @"Mirror…", @"Drop to plate", @"Edit part…", @"Save part…", nil];
		NSMutableArray *acts = [NSMutableArray array];
		for (NSUInteger i = 0; i < [actionTitles count]; i++) {
			UIButton *b = PDDButton([actionTitles objectAtIndex:i], i == 1 ? PD_RED : PD_ACCENT, 15);
			b.tag = (NSInteger)i;
			[b addTarget:self action:@selector(actionTap:) forControlEvents:UIControlEventTouchUpInside];
			[acts addObject:b];
		}
		_actions = acts;
		_selectMoreButton = PDDButton(@"Select more", PD_ACCENT, 15);
		[_selectMoreButton addTarget:self action:@selector(toggleMulti) forControlEvents:UIControlEventTouchUpInside];
		_pickButton = PDDButton(@"Pick shapes…", PD_ACCENT, 15);
		[_pickButton addTarget:self action:@selector(pickShapes:) forControlEvents:UIControlEventTouchUpInside];
		_alignCaption = [self caption:@"ALIGN (TO THE SELECTION'S BOX)"];
		_alignHint = PDLabel([UIFont systemFontOfSize:12], PD_FAINT);
		_alignHint.text = @"Select two or more shapes to line them up.";
		NSArray *axisNames = [NSArray arrayWithObjects:@"X", @"Y", @"Z", nil];
		NSArray *modeNames = [NSArray arrayWithObjects:@"Left", @"Centre", @"Right", @"Front", @"Centre", @"Back", @"Bottom", @"Middle", @"Top", nil];
		NSMutableArray *labels = [NSMutableArray array], *abtns = [NSMutableArray array];
		for (int a = 0; a < 3; a++) {
			UILabel *l = PDLabel([UIFont boldSystemFontOfSize:14], PD_DIM);
			l.text = [axisNames objectAtIndex:(NSUInteger)a];
			[labels addObject:l];
			for (int m = 0; m < 3; m++) {
				UIButton *b = PDDButton([modeNames objectAtIndex:(NSUInteger)(a * 3 + m)], PD_ACCENT, 13);
				b.accessibilityLabel = [NSString stringWithFormat:@"Align %@ %@", [axisNames objectAtIndex:(NSUInteger)a], [modeNames objectAtIndex:(NSUInteger)(a * 3 + m)]];
				b.tag = a * 3 + m;
				[b addTarget:self action:@selector(alignTap:) forControlEvents:UIControlEventTouchUpInside];
				[abtns addObject:b];
			}
		}
		_alignLabels = labels;
		_alignButtons = abtns;
		NSMutableArray *sp = [NSMutableArray array];
		for (int a = 0; a < 2; a++) {
			UIButton *b = PDDButton(a == 0 ? @"Space evenly ↔" : @"Space evenly ↕", PD_ACCENT, 13);
			b.tag = a;
			[b addTarget:self action:@selector(spaceTap:) forControlEvents:UIControlEventTouchUpInside];
			[sp addObject:b];
		}
		_spaceButtons = sp;
		_gridButton = PDDButton(@"Arrange in a grid…", PD_ACCENT, 15);
		[_gridButton addTarget:self action:@selector(gridTap:) forControlEvents:UIControlEventTouchUpInside];
		_helpLabel = PDLabel([UIFont systemFontOfSize:14], PD_DIM);
		_helpLabel.numberOfLines = 0;
		_helpLabel.adjustsFontSizeToFitWidth = NO;
		_helpLabel.text = @"Tap a shape on the left to drop it on the plate.\n\nTap a shape to select it; drag it to slide it around. "
			@"Drag empty space to look around, two fingers to pan, pinch to zoom, double-tap to fit.\n\n"
			@"Move XYZ shows arrows on the selection: drag one to move along just that axis (up and down too). "
			@"Rotate shows rings: drag one to turn the selection about its centre (30° snaps inside its pie-slice disc; drag out beyond it for fine 1° steps); Reset rotation squares it back up. "
			@"Scale shows a handle on each of a shape's axes: drag one to stretch it that way, or type the X, Y and Z percentages (0.1–200 %); Uniform keeps its proportions.\n\n"
			@"Holes cut only when grouped: pick the hole and the shapes it should cut (Pick shapes…, or Select more and tap them), then Group. "
			@"Align lines selected shapes up; Arrange in a grid lays them out in rows.";
		_snapCaption = [self caption:@"SNAP GRID"];
		_snapControl = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"0.1", @"0.5", @"1", @"5 mm", nil]];
		_snapControl.segmentedControlStyle = UISegmentedControlStyleBar;
		_snapControl.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
		_snapControl.selectedSegmentIndex = _snap < 0.3f ? 0 : _snap < 0.8f ? 1 : _snap < 3 ? 2 : 3;
		[_snapControl addTarget:self action:@selector(snapChanged) forControlEvents:UIControlEventValueChanged];
		_selectAllButton = PDDButton(@"Select all", PD_ACCENT, 15);
		[_selectAllButton addTarget:self action:@selector(selectAll) forControlEvents:UIControlEventTouchUpInside];
		_fitButton = PDDButton(@"Fit view", PD_ACCENT, 15);
		[_fitButton addTarget:_canvas action:@selector(fitView) forControlEvents:UIControlEventTouchUpInside];
		NSMutableArray *ins = [NSMutableArray arrayWithObjects:_insTitle, _insInfo, _solidHole, _colorCaption, _sizeCaption, _posCaption, _turnCaption,
			_helpLabel, _snapCaption, _snapControl, _selectAllButton, _fitButton, nil];
		[ins addObjectsFromArray:_swatches]; [ins addObjectsFromArray:_sizeRows]; [ins addObjectsFromArray:_posRows];
		[ins addObjectsFromArray:_turnRows]; [ins addObjectsFromArray:_actions];
		[ins addObjectsFromArray:_scaleRows]; [ins addObjectsFromArray:[NSArray arrayWithObjects:_scaleCaption, _scaleHint, _uniformButton, nil]];
		[ins addObjectsFromArray:[NSArray arrayWithObjects:_selectMoreButton, _pickButton, _alignCaption, _alignHint, _gridButton, nil]];
		[ins addObjectsFromArray:_alignLabels]; [ins addObjectsFromArray:_alignButtons]; [ins addObjectsFromArray:_spaceButtons];
		for (UIView *v in ins) [_inspector addSubview:v];

		for (UIView *v in [NSArray arrayWithObjects:_backButton, _titleButton, _designsButton, _undoButton, _redoButton, _sliceButton,
				_palette, _library, _paletteTabs, _canvas, _multiButton, _gizmoControl, _resetTurnButton, _inspector, nil]) [self addSubview:v];
		[self tabChanged];

		UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(back)];
		swipe.direction = UISwipeGestureRecognizerDirectionRight;
		[_backButton addGestureRecognizer:swipe];

		// The last design, or a new one.
		NSString *last = [ud stringForKey:PDDesignLastKey];
		NSArray *saved = [PDDesign savedNames];
		if (![saved containsObject:last]) last = [saved count] ? [saved objectAtIndex:0] : nil;
		if (last) [self openDesignNamed:last];
		else [self newDesign];
	}
	return self;
}

- (UILabel *)caption:(NSString *)t {
	UILabel *l = PDLabel([UIFont boldSystemFontOfSize:11], PD_FAINT);
	l.text = t;
	return l;
}

- (void)back { [self.popover dismissPopoverAnimated:NO]; if (self.backHandler) self.backHandler(); }

#pragma mark Layout

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat W = self.bounds.size.width, H = self.bounds.size.height, g = 12, top = 68;
	self.backButton.frame = CGRectMake(g, 12, 130, 44);
	self.sliceButton.frame = CGRectMake(W - g - 170, 12, 170, 44);
	self.redoButton.frame = CGRectMake(CGRectGetMinX(self.sliceButton.frame) - 12 - 76, 12, 76, 44);
	self.undoButton.frame = CGRectMake(CGRectGetMinX(self.redoButton.frame) - 8 - 76, 12, 76, 44);
	self.designsButton.frame = CGRectMake(CGRectGetMinX(self.undoButton.frame) - 12 - 100, 12, 100, 44);
	self.titleButton.frame = CGRectMake(CGRectGetMaxX(self.backButton.frame) + 16, 12, CGRectGetMinX(self.designsButton.frame) - CGRectGetMaxX(self.backButton.frame) - 28, 44);

	CGFloat pw = 104, iw = 264;
	self.paletteTabs.frame = CGRectMake(g, top, pw, 30);
	CGRect pf = CGRectMake(g, top + 36, pw, H - top - g - 36);
	self.palette.frame = self.library.frame = pf;
	for (int which = 0; which < 2; which++) {
		NSArray *tiles = which ? self.libTiles : self.tiles;
		UIScrollView *sv = which ? self.library : self.palette;
		CGFloat ty = 6, th = MAX(50, MIN(64, floor((pf.size.height - 6) / [tiles count]) - 4));
		for (NSArray *t in tiles) {
			UIButton *b = [t objectAtIndex:0];
			b.frame = CGRectMake(6, ty, pw - 12, th);
			[[b viewWithTag:1000] setFrame:CGRectMake((pw - 12 - 34) / 2, MAX(3, (th - 16 - 30) / 2), 34, 30)];
			ty += th + 4;
		}
		sv.contentSize = CGSizeMake(pw, ty + 2);
	}

	self.canvas.frame = CGRectMake(g + pw + g, top, W - pw - iw - 4 * g, H - top - g);
	self.multiButton.frame = CGRectMake(CGRectGetMinX(self.canvas.frame) + 10, top + 10, 120, 34);
	self.gizmoControl.frame = CGRectMake(CGRectGetMaxX(self.canvas.frame) - 10 - 320, top + 10, 320, 34);
	self.resetTurnButton.frame = CGRectMake(CGRectGetMaxX(self.canvas.frame) - 10 - 140, top + 52, 140, 34);
	self.inspector.frame = CGRectMake(W - g - iw, top, iw, H - top - g);
	[self layoutInspector];
}

- (void)layoutInspector {
	NSUInteger n = [self.selection count];
	BOOL any = n > 0, several = n >= 2;
	CGFloat x = 14, w = self.inspector.bounds.size.width - 28, y = 14, bw = (w - 8) / 2;
	NSArray *selViews = [NSArray arrayWithObjects:self.insInfo, self.solidHole, self.colorCaption, self.sizeCaption, self.posCaption, self.turnCaption, self.alignCaption, nil];
	for (UIView *v in selViews) v.hidden = !any;
	for (NSArray *group in [NSArray arrayWithObjects:self.swatches, self.sizeRows, self.posRows, self.turnRows, self.actions, nil])
		for (UIView *v in group) v.hidden = !any;
	for (NSArray *group in [NSArray arrayWithObjects:self.alignLabels, self.alignButtons, self.spaceButtons, nil])
		for (UIView *v in group) v.hidden = !several;
	self.gridButton.hidden = !several;
	self.alignHint.hidden = !any || several;
	BOOL scaling = any && self.canvas.gizmo == 3, scaleOne = scaling && n == 1;
	self.scaleCaption.hidden = !scaling;
	self.scaleHint.hidden = !scaling || scaleOne;
	self.uniformButton.hidden = !scaleOne;
	for (UIView *v in self.scaleRows) v.hidden = !scaleOne;
	for (UIView *v in [NSArray arrayWithObjects:self.helpLabel, self.snapCaption, self.snapControl, self.selectAllButton, self.fitButton, nil]) v.hidden = any;
	self.insTitle.frame = CGRectMake(x, y, w, 26); y += 28;
	if (!any) {
		CGSize hs = [self.helpLabel.text sizeWithFont:self.helpLabel.font constrainedToSize:CGSizeMake(w, 1000)];
		self.helpLabel.frame = CGRectMake(x, y, w, hs.height); y += hs.height + 16;
		self.selectMoreButton.frame = CGRectMake(x, y, bw, 40);
		self.pickButton.frame = CGRectMake(x + bw + 8, y, bw, 40); y += 48;
		self.selectAllButton.frame = CGRectMake(x, y, bw, 40);
		self.fitButton.frame = CGRectMake(x + bw + 8, y, bw, 40); y += 56;
		self.snapCaption.frame = CGRectMake(x, y, w, 14); y += 18;
		self.snapControl.frame = CGRectMake(x, y, w, 34); y += 46;
	} else {
		self.insInfo.frame = CGRectMake(x, y, w, 34); y += 38;
		if (scaling) {   // Scale mode: its boxes first, where the keyboard doesn't cover them
			self.scaleCaption.frame = CGRectMake(x, y, w, 14); y += 18;
			if (!scaleOne) { self.scaleHint.frame = CGRectMake(x, y, w, 16); y += 26; }
			else {
				self.uniformButton.frame = CGRectMake(x, y, w, 36); y += 42;
				for (UIView *r in self.scaleRows) { r.frame = CGRectMake(x, y, w, 36); y += 42; }
				y += 6;
			}
		}
		// Choosing what to group comes first, then what to do with it.
		self.selectMoreButton.frame = CGRectMake(x, y, bw, 40);
		self.pickButton.frame = CGRectMake(x + bw + 8, y, bw, 40); y += 48;
		for (NSUInteger i = 0; i < [self.actions count]; i++) {
			[[self.actions objectAtIndex:i] setFrame:CGRectMake(x + (i % 2) * (bw + 8), y, bw, 40)];
			if (i % 2) y += 48;
		}
		y += 6;
		self.alignCaption.frame = CGRectMake(x, y, w, 14); y += 18;
		if (!several) { self.alignHint.frame = CGRectMake(x, y, w, 16); y += 26; }
		else {
			CGFloat lw = 22, ab = (w - lw - 2 * 6) / 3;
			for (NSUInteger a = 0; a < 3; a++) {
				[[self.alignLabels objectAtIndex:a] setFrame:CGRectMake(x, y, lw, 34)];
				for (NSUInteger m = 0; m < 3; m++) [[self.alignButtons objectAtIndex:a * 3 + m] setFrame:CGRectMake(x + lw + m * (ab + 6), y, ab, 34)];
				y += 40;
			}
			for (NSUInteger k = 0; k < 2; k++) [[self.spaceButtons objectAtIndex:k] setFrame:CGRectMake(x + k * (bw + 8), y, bw, 34)];
			y += 40;
			self.gridButton.frame = CGRectMake(x, y, w, 38); y += 50;
		}
		self.solidHole.frame = CGRectMake(x, y, w, 34); y += 44;
		self.colorCaption.frame = CGRectMake(x, y, w, 14); y += 18;
		CGFloat sw = (w - 7 * 6) / 8;
		for (NSUInteger i = 0; i < 8; i++) [[self.swatches objectAtIndex:i] setFrame:CGRectMake(x + i * (sw + 6), y, sw, sw)];
		y += sw + 12;
		self.sizeCaption.frame = CGRectMake(x, y, w, 14); y += 18;
		for (UIView *r in self.sizeRows) { r.frame = CGRectMake(x, y, w, 36); y += 42; }
		y += 4;
		self.posCaption.frame = CGRectMake(x, y, w, 14); y += 18;
		for (UIView *r in self.posRows) { r.frame = CGRectMake(x, y, w, 36); y += 42; }
		y += 4;
		self.turnCaption.frame = CGRectMake(x, y, w, 14); y += 18;
		for (UIView *r in self.turnRows) { r.frame = CGRectMake(x, y, w, 36); y += 42; }
	}
	self.inspector.contentSize = CGSizeMake(self.inspector.bounds.size.width, y + 8);
}

#pragma mark State

- (NSArray *)selectedShapes {
	NSMutableArray *a = [NSMutableArray array];
	for (NSUInteger k = [self.selection firstIndex]; k != NSNotFound; k = [self.selection indexGreaterThanIndex:k])
		if (k < [self.shapes count]) [a addObject:[self.shapes objectAtIndex:k]];
	return a;
}

- (void)selectionBoundsMin:(GLKVector3 *)lo max:(GLKVector3 *)hi {
	*lo = GLKVector3Make(1e30f, 1e30f, 1e30f); *hi = GLKVector3Make(-1e30f, -1e30f, -1e30f);
	for (PDShape *s in [self selectedShapes]) { *lo = GLKVector3Minimum(*lo, [s worldMin]); *hi = GLKVector3Maximum(*hi, [s worldMax]); }
}

// Before every change: keep the current shapes (copies) for Undo.
- (void)remember {
	[self.undoStack addObject:[[NSArray alloc] initWithArray:self.shapes copyItems:YES]];
	while ([self.undoStack count] > 40) [self.undoStack removeObjectAtIndex:0];
	[self.redoStack removeAllObjects];
}

// After every change: show it and save.
- (void)changed {
	self.canvas.shapes = self.shapes;
	self.canvas.selection = self.selection;
	self.design.shapes = self.shapes;
	if ([self.shapes count] || [[PDDesign savedNames] containsObject:self.design.name]) [self.design save];
	[self update];
}

- (void)setShapes:(NSArray *)shapes selecting:(NSIndexSet *)sel {
	self.shapes = shapes;
	self.selection = sel ?: [NSIndexSet indexSet];
	[self changed];
}

- (void)update {
	[self.titleButton setTitle:self.design.name forState:UIControlStateNormal];
	self.undoButton.enabled = [self.undoStack count] && !self.busy;
	self.redoButton.enabled = [self.redoStack count] && !self.busy;
	self.sliceButton.enabled = !self.busy && [self.shapes count];
	for (UIButton *b in [NSArray arrayWithObjects:self.undoButton, self.redoButton, self.sliceButton, nil]) b.alpha = b.enabled ? 1 : 0.4;
	BOOL multi = self.canvas.multiSelect;
	self.resetTurnButton.hidden = self.canvas.gizmo != 2;
	self.resetTurnButton.enabled = [self.selection count] > 0 && !self.busy;
	self.resetTurnButton.alpha = self.resetTurnButton.enabled ? 1 : 0.4;
	[self.multiButton setTitle:multi ? @"Selecting more ✓" : @"Select more" forState:UIControlStateNormal];
	[self.selectMoreButton setTitle:multi ? @"Selecting… ✓" : @"Select more" forState:UIControlStateNormal];
	[self.selectMoreButton setTitleColor:multi ? [UIColor whiteColor] : PD_ACCENT forState:UIControlStateNormal];
	self.selectMoreButton.backgroundColor = multi ? [PD_ACCENT colorWithAlphaComponent:0.55] : PD_TILE_HI;
	self.pickButton.enabled = [self.shapes count] > 0;
	self.pickButton.alpha = self.pickButton.enabled ? 1 : 0.4;
	[self.multiButton setTitleColor:self.canvas.multiSelect ? [UIColor whiteColor] : PD_DIM forState:UIControlStateNormal];
	self.multiButton.backgroundColor = self.canvas.multiSelect ? [PD_ACCENT colorWithAlphaComponent:0.55] : [UIColor colorWithWhite:0 alpha:0.45];
	self.userInteractionEnabled = YES;
	self.palette.userInteractionEnabled = !self.busy;
	self.inspector.userInteractionEnabled = !self.busy;
	self.palette.alpha = self.inspector.alpha = self.busy ? 0.6 : 1;

	NSArray *sel = [self selectedShapes];
	NSUInteger n = [sel count];
	if (!n) self.insTitle.text = [self.shapes count] ? [NSString stringWithFormat:@"%lu shape%@", (unsigned long)[self.shapes count], [self.shapes count] == 1 ? @"" : @"s"] : @"Empty plate";
	else if (n == 1) { PDShape *s = [sel objectAtIndex:0]; self.insTitle.text = s.hole ? [NSString stringWithFormat:@"%@ hole", [s title]] : [s title]; }
	else self.insTitle.text = [NSString stringWithFormat:@"%lu shapes", (unsigned long)n];
	if (n) {
		int holes = 0, groups = 0;
		for (PDShape *s in sel) { if (s.hole) holes++; if ([s.kind isEqualToString:@"group"]) groups++; }
		self.solidHole.selectedSegmentIndex = holes == (int)n ? 1 : holes == 0 ? 0 : UISegmentedControlNoSegment;
		uint32_t c = ((PDShape *)[sel objectAtIndex:0]).color;
		for (UIButton *b in self.swatches) b.layer.borderWidth = (holes == 0 && PDDesignColors[b.tag] == c) ? 3 : 0;
		for (PDValueRow *r in self.sizeRows) [r setEnabled:n == 1];
		UIButton *group = [self.actions objectAtIndex:2], *ungroup = [self.actions objectAtIndex:3];
		group.enabled = n >= 2; ungroup.enabled = groups > 0;
		group.alpha = group.enabled ? 1 : 0.4; ungroup.alpha = ungroup.enabled ? 1 : 0.4;
		UIButton *edit = [self.actions objectAtIndex:6], *save = [self.actions objectAtIndex:7];
		NSString *k1 = [[sel objectAtIndex:0] kind];
		BOOL basic = [PDShape kindHasOptions:k1];
		[edit setTitle:basic ? @"Options…" : @"Edit part…" forState:UIControlStateNormal];
		edit.enabled = n == 1 && ([k1 isEqualToString:@"part"] || basic);
		save.enabled = n == 1;
		edit.alpha = edit.enabled ? 1 : 0.4; save.alpha = save.enabled ? 1 : 0.4;
		for (PDValueRow *r in self.turnRows) [r.value setTitle:[NSString stringWithFormat:@"%g°", self.turnStep] forState:UIControlStateNormal];
		[self updateInspectorValues];
	}
	[self setNeedsLayout];
}

// Numbers only (during a drag).
- (void)updateInspectorValues {
	NSArray *sel = [self selectedShapes];
	if (![sel count]) return;
	GLKVector3 lo, hi;
	[self selectionBoundsMin:&lo max:&hi];
	GLKVector3 sz = [sel count] == 1 ? [(PDShape *)[sel objectAtIndex:0] axisLengths] : GLKVector3Subtract(hi, lo);
	for (int a = 0; a < 3; a++) [((PDValueRow *)[self.sizeRows objectAtIndex:(NSUInteger)a]).value setTitle:[NSString stringWithFormat:@"%.1f mm", sz.v[a]] forState:UIControlStateNormal];
	float pos[3] = {(lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z};
	for (int a = 0; a < 3; a++) [((PDValueRow *)[self.posRows objectAtIndex:(NSUInteger)a]).value setTitle:[NSString stringWithFormat:@"%.1f mm", pos[a]] forState:UIControlStateNormal];
	GLKVector3 bs = GLKVector3Subtract(hi, lo);
	BOOL off = lo.x < -0.01f || lo.y < -0.01f || hi.x > 256.01f || hi.y > 256.01f;
	self.insInfo.text = [NSString stringWithFormat:@"%.1f × %.1f × %.1f mm%@", bs.x, bs.y, bs.z, off ? @" · off the plate" : lo.z < -0.01f ? @" · below the plate" : @""];
	self.insInfo.textColor = off || lo.z < -0.01f ? PD_AMBER : PD_DIM;
	self.turnCaption.text = [NSString stringWithFormat:@"TURN  ·  %@", [PDShape rotationTextFor:sel]];
	GLKVector3 pct;
	if ([self.canvas scalePercent:&pct]) for (int a = 0; a < 3; a++) [(PDPercentRow *)[self.scaleRows objectAtIndex:(NSUInteger)a] showValue:pct.v[a]];
	BOOL u = self.canvas.uniformScale;
	[self.uniformButton setTitle:u ? @"☑  Uniform (keep proportions)" : @"☐  Uniform" forState:UIControlStateNormal];
	[self.uniformButton setTitleColor:u ? [UIColor whiteColor] : PD_ACCENT forState:UIControlStateNormal];
	self.uniformButton.backgroundColor = u ? [PD_ACCENT colorWithAlphaComponent:0.55] : PD_TILE_HI;
}

#pragma mark Designs

- (void)showDesign:(PDDesign *)d {
	self.design = d;
	[[NSUserDefaults standardUserDefaults] setObject:d.name forKey:PDDesignLastKey];
	[self.undoStack removeAllObjects];
	[self.redoStack removeAllObjects];
	self.shapes = d.shapes ?: [NSArray array];
	self.selection = [NSIndexSet indexSet];
	self.canvas.shapes = self.shapes;
	self.canvas.selection = self.selection;
	[self.canvas fitView];
	[self update];
}

- (void)newDesign {
	PDDesign *d = [[PDDesign alloc] init];
	d.name = [PDDesign unusedName:@"Design"];
	d.shapes = [NSArray array];
	[self showDesign:d];
}

- (void)openDesignNamed:(NSString *)name {
	if (self.busy || ![name length]) return;
	[self setBusy:YES message:@"Opening…"];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		PDDesign *d = [PDDesign loadNamed:name];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setBusy:NO message:nil];
			if (d) [self showDesign:d];
			else [[[UIAlertView alloc] initWithTitle:@"Couldn't open the design" message:name delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
		});
	});
}

- (void)setBusy:(BOOL)busy message:(NSString *)msg {
	self.busy = busy;
	self.canvas.message = msg;
	self.canvas.userInteractionEnabled = !busy;
	[self update];
}

- (void)designsMenu:(UIButton *)sender {
	UIActionSheet *a = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
		otherButtonTitles:@"New design", @"Open…", @"Duplicate this design", @"Rename…", @"Delete this design", nil];
	a.tag = 1;
	[a showFromRect:sender.bounds inView:sender animated:YES];
}

- (void)actionSheet:(UIActionSheet *)a clickedButtonAtIndex:(NSInteger)i {
	if (i < 0) return;
	if (a.tag == 1) {
		if (i == 0) [self newDesign];
		else if (i == 1) [self openList];
		else if (i == 2) {
			PDDesign *d = [[PDDesign alloc] init];
			d.name = [PDDesign unusedName:[NSString stringWithFormat:@"%@ copy", self.design.name]];
			d.shapes = [[NSArray alloc] initWithArray:self.shapes copyItems:YES];
			[d save];
			[self showDesign:d];
		} else if (i == 3) [self rename];
		else if (i == 4) {
			UIAlertView *al = [[UIAlertView alloc] initWithTitle:@"Delete design" message:[NSString stringWithFormat:@"Delete “%@”? This can't be undone.", self.design.name]
				delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Delete", nil];
			al.tag = 3;
			[al show];
		}
	} else if (a.tag == 5) {   // grid
		float gaps[4] = {0, 2, 5, 10};
		if (i <= 3) [self arrangeGridGap:gaps[i]];
	} else if (a.tag == 2) {   // mirror
		if (i <= 2) [self mirrorAxis:(int)i];
	}
}

- (void)openList {
	PDDesignList *l = [[PDDesignList alloc] init];
	l.current = self.design.name;
	__weak PDDesignPage *weakSelf = self;
	l.picked = ^(NSString *name) { [weakSelf.popover dismissPopoverAnimated:YES]; weakSelf.popover = nil; [weakSelf openDesignNamed:name]; };
	l.deleted = ^(NSString *name) { if ([name isEqualToString:weakSelf.design.name]) [weakSelf newDesign]; };
	self.popover = [[UIPopoverController alloc] initWithContentViewController:l];
	self.popover.delegate = self;
	[self.popover presentPopoverFromRect:self.designsButton.bounds inView:self.designsButton permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)p { self.popover = nil; }

- (void)rename {
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Design name" message:nil delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Rename", nil];
	a.alertViewStyle = UIAlertViewStylePlainTextInput;
	[a textFieldAtIndex:0].text = self.design.name;
	a.tag = 2;
	[a show];
}

#pragma mark Shapes

// At the middle of the view, snapped; nudged along if a shape already stands there.
- (void)freeSpotX:(float *)px y:(float *)py {
	GLKVector3 f = [self.canvas focusPoint];
	float s = MAX(1.0f, self.snap);
	float x = roundf(f.x / s) * s, y = roundf(f.y / s) * s;
	for (int tries = 0; tries < 20; tries++) {
		BOOL taken = NO;
		for (PDShape *o in self.shapes) {
			GLKVector3 lo = [o worldMin], hi = [o worldMax];
			if (fabsf((lo.x + hi.x) / 2 - x) < 1 && fabsf((lo.y + hi.y) / 2 - y) < 1) { taken = YES; break; }
		}
		if (!taken) break;
		x += 10; y += 10;
	}
	*px = x; *py = y;
}

// Adds a ready-made shape (a part or a model) at the middle of the view and selects it.
- (void)addShape:(PDShape *)sh {
	if (!sh) return;
	if (!sh.hole) sh.color = PDDesignColors[self.nextColor++ % 6];
	[self remember];
	NSMutableArray *a = [self.shapes mutableCopy];
	[a addObject:sh];
	[self setShapes:a selecting:[NSIndexSet indexSetWithIndex:[a count] - 1]];
}

#pragma mark Library

- (void)tabChanged {
	BOOL lib = self.paletteTabs.selectedSegmentIndex == 1;
	self.palette.hidden = lib;
	self.library.hidden = !lib;
	[[NSUserDefaults standardUserDefaults] setInteger:lib ? 1 : 0 forKey:@"PDDesignTab"];
}

- (void)libTileTap:(UIButton *)b {
	if (self.busy || b.tag < 0 || (NSUInteger)b.tag >= [self.libTiles count]) return;
	NSString *type = [[self.libTiles objectAtIndex:(NSUInteger)b.tag] objectAtIndex:1];
	if ([type isEqualToString:@"models"]) { [self showModels:b]; return; }
	PDPartEditor *ed = [[PDPartEditor alloc] initWithType:type parameters:[PDShape defaultParametersForPartType:type] updating:NO];
	__weak PDDesignPage *weakSelf = self;
	ed.done = ^(NSDictionary *params) {
		[weakSelf.popover dismissPopoverAnimated:YES];
		weakSelf.popover = nil;
		[PDShape rememberParameters:params forPartType:type];
		[weakSelf makePart:type parameters:params replacing:nil];
	};
	[self presentPopover:ed from:b];
}

- (void)presentPopover:(UIViewController *)vc from:(UIView *)v {
	[self.popover dismissPopoverAnimated:NO];
	self.popover = [[UIPopoverController alloc] initWithContentViewController:vc];
	self.popover.delegate = self;
	[self.popover presentPopoverFromRect:v.bounds inView:v permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
}

// Makes the part off the main thread (threads have thousands of triangles); adds it, or swaps it for `old`.
- (void)makePart:(NSString *)type parameters:(NSDictionary *)params replacing:(PDShape *)old {
	float x, y;
	[self freeSpotX:&x y:&y];
	[self setBusy:YES message:old ? @"Updating the part…" : @"Making the part…"];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		PDShape *sh = old ? [old withParameters:params] : [PDShape partOfType:type parameters:params x:x y:y];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setBusy:NO message:nil];
			if (!sh) {
				[[[UIAlertView alloc] initWithTitle:@"Couldn't make that part" message:@"Those settings don't make a shape. Try other values." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
				return;
			}
			if (!old) { [self addShape:sh]; return; }
			NSUInteger i = [self.shapes indexOfObjectIdenticalTo:old];
			if (i == NSNotFound) return;
			[self remember];
			NSMutableArray *a = [self.shapes mutableCopy];
			[a replaceObjectAtIndex:i withObject:sh];
			[self setShapes:a selecting:[NSIndexSet indexSetWithIndex:i]];
		});
	});
}

- (void)editPart:(UIButton *)b {
	NSArray *sel = [self selectedShapes];
	if ([sel count] != 1 || self.busy) return;
	PDShape *s = [sel objectAtIndex:0];
	if ([PDShape kindHasOptions:s.kind]) { [self editOptions:s from:b]; return; }
	if (![s.kind isEqualToString:@"part"]) return;
	PDPartEditor *ed = [[PDPartEditor alloc] initWithType:s.partType parameters:s.parameters updating:YES];
	__weak PDDesignPage *weakSelf = self;
	ed.done = ^(NSDictionary *params) {
		[weakSelf.popover dismissPopoverAnimated:YES];
		weakSelf.popover = nil;
		[PDShape rememberParameters:params forPartType:s.partType];
		[weakSelf makePart:s.partType parameters:params replacing:s];
	};
	[self presentPopover:ed from:b];
}

// A basic shape's options (fillet, chamfer, sides…): quick to make, so on the spot.
- (void)editOptions:(PDShape *)s from:(UIView *)b {
	NSString *type = [@"shape." stringByAppendingString:s.kind];
	PDPartEditor *ed = [[PDPartEditor alloc] initWithType:type parameters:[s editableOptions] updating:YES];
	__weak PDDesignPage *weakSelf = self;
	ed.done = ^(NSDictionary *params) {
		[weakSelf.popover dismissPopoverAnimated:YES];
		weakSelf.popover = nil;
		PDShape *sh = [s withOptions:params];
		NSUInteger i = [weakSelf.shapes indexOfObjectIdenticalTo:s];
		if (!sh) {
			[[[UIAlertView alloc] initWithTitle:@"Couldn't make that shape" message:@"Those options don't make a shape. Try other values." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			return;
		}
		if (i == NSNotFound) return;
		[weakSelf remember];
		NSMutableArray *a = [weakSelf.shapes mutableCopy];
		[a replaceObjectAtIndex:i withObject:sh];
		[weakSelf setShapes:a selecting:[NSIndexSet indexSetWithIndex:i]];
	};
	[self presentPopover:ed from:b];
}

- (void)showModels:(UIView *)from {
	PDDesignModelPicker *mp = [[PDDesignModelPicker alloc] init];
	__weak PDDesignPage *weakSelf = self;
	mp.picked = ^(NSString *path) {
		[weakSelf.popover dismissPopoverAnimated:YES];
		weakSelf.popover = nil;
		[weakSelf importModel:path];
	};
	mp.download = ^{
		[weakSelf.popover dismissPopoverAnimated:YES];
		weakSelf.popover = nil;
		[weakSelf askDownload];
	};
	[self presentPopover:mp from:from];
}

- (void)importModel:(NSString *)path {
	if (self.busy) return;
	float x, y;
	[self freeSpotX:&x y:&y];
	[self setBusy:YES message:@"Bringing in the model…"];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSString *err = nil;
		PDShape *sh = [PDShape shapeFromModelFile:path x:x y:y error:&err];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setBusy:NO message:nil];
			if (!sh) { [[[UIAlertView alloc] initWithTitle:@"Couldn't bring in the model" message:err delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show]; return; }
			[self addShape:sh];
			int n = 0;
			[sh unitTriangles:&n];
			GLKVector3 lo = [sh worldMin], hi = [sh worldMax];
			NSMutableArray *notes = [NSMutableArray array];
			if (hi.x - lo.x > 256 || hi.y - lo.y > 256 || hi.z - lo.z > 256) [notes addObject:[NSString stringWithFormat:@"It's %.0f × %.0f × %.0f mm, bigger than the plate; scale it down with Size.", hi.x - lo.x, hi.y - lo.y, hi.z - lo.z]];
			if (n > 60000) [notes addObject:[NSString stringWithFormat:@"It has %d triangles, so grouping it with other shapes can take a while.", n]];
			if ([notes count]) [[[UIAlertView alloc] initWithTitle:sh.meshName message:[notes componentsJoinedByString:@"\n\n"] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
		});
	});
}

- (void)askDownload {
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Download a model" message:@"A direct link to an STL or OBJ file" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Download", nil];
	a.alertViewStyle = UIAlertViewStylePlainTextInput;
	UITextField *tf = [a textFieldAtIndex:0];
	tf.keyboardType = UIKeyboardTypeURL;
	tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
	tf.autocorrectionType = UITextAutocorrectionTypeNo;
	NSString *clip = [UIPasteboard generalPasteboard].string;
	tf.text = [clip hasPrefix:@"http"] ? clip : @"http://";
	a.tag = 20;
	[a show];
}

- (void)download:(NSString *)link {
	NSURL *u = [NSURL URLWithString:[link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
	if (![u host]) { [[[UIAlertView alloc] initWithTitle:@"That isn't a link" message:link delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show]; return; }
	[self setBusy:YES message:@"Downloading…"];
	NSURLRequest *rq = [NSURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:90];
	[NSURLConnection sendAsynchronousRequest:rq queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
		[self setBusy:NO message:nil];
		NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)r statusCode] : 200;
		if (e || code != 200 || [d length] < 20) {
			NSString *why = e ? [e localizedDescription] : [NSString stringWithFormat:@"The server answered %ld.", (long)code];
			if ([[u scheme] isEqualToString:@"https"]) why = [why stringByAppendingString:@"\n\niOS 5 can't reach many modern HTTPS sites; a plain http:// link (for example from a computer on your network) works best."];
			[[[UIAlertView alloc] initWithTitle:@"Download failed" message:why delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			return;
		}
		NSString *name = [[[r suggestedFilename] ?: [u lastPathComponent] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] lastPathComponent];
		NSString *ext = [[name pathExtension] lowercaseString];
		if (![ext isEqualToString:@"stl"] && ![ext isEqualToString:@"obj"]) {   // sniff it
			const char *b = [d bytes];
			uint32_t n = 0;
			if ([d length] >= 84) [d getBytes:&n range:NSMakeRange(80, 4)];
			NSString *head = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN((NSUInteger)4096, [d length]))] encoding:NSISOLatin1StringEncoding];
			if ([d length] == 84 + (NSUInteger)n * 50 || ([d length] >= 5 && !memcmp(b, "solid", 5))) ext = @"stl";
			else if ([head rangeOfString:@"\nv "].location != NSNotFound) ext = @"obj";
			else { [[[UIAlertView alloc] initWithTitle:@"Not a model" message:@"That link isn't an STL or OBJ file." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show]; return; }
			name = [[([name length] ? [name stringByDeletingPathExtension] : @"Download") stringByAppendingPathExtension:ext] lastPathComponent];
		}
		name = [[name stringByReplacingOccurrencesOfString:@":" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
		NSString *dir = [PDSlicer libraryDirectory], *path = [dir stringByAppendingPathComponent:name];
		for (int i = 2; [[NSFileManager defaultManager] fileExistsAtPath:path]; i++)
			path = [dir stringByAppendingPathComponent:[[NSString stringWithFormat:@"%@ %d", [name stringByDeletingPathExtension], i] stringByAppendingPathExtension:ext]];
		if (![d writeToFile:path atomically:YES]) { [[[UIAlertView alloc] initWithTitle:@"Couldn't save the download" message:nil delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show]; return; }
		[self importModel:path];
	}];
}

- (void)saveToLibrary {
	NSArray *sel = [self selectedShapes];
	if ([sel count] != 1) return;
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Save to library" message:@"It will be in Library › Models… for any design." delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Save", nil];
	a.alertViewStyle = UIAlertViewStylePlainTextInput;
	PDShape *s = [sel objectAtIndex:0];
	[a textFieldAtIndex:0].text = [s.kind isEqualToString:@"part"] ? [PDShape describePart:s.partType parameters:s.parameters] : [s title];
	a.tag = 21;
	[a show];
}

- (void)tileTap:(UIButton *)b {
	if (self.busy || b.tag < 0 || (NSUInteger)b.tag >= [self.tiles count]) return;
	NSArray *t = [self.tiles objectAtIndex:(NSUInteger)b.tag];
	NSString *kind = [t objectAtIndex:1];
	BOOL hole = [[t objectAtIndex:2] boolValue];
	GLKVector3 size = GLKVector3Make(20, 20, 20);
	if ([kind isEqualToString:@"dome"]) size.z = 10;
	else if ([kind isEqualToString:@"torus"]) size = GLKVector3Make(30, 30, 8);
	float x, y;
	[self freeSpotX:&x y:&y];
	PDShape *sh = [PDShape shapeOfKind:kind size:size x:x y:y];
	if (!sh) return;
	sh.hole = hole;
	sh.color = PDDesignColors[self.nextColor % 6];
	if (!hole) self.nextColor++;
	[self remember];
	NSMutableArray *a = [self.shapes mutableCopy];
	[a addObject:sh];
	[self setShapes:a selecting:[NSIndexSet indexSetWithIndex:[a count] - 1]];
}

- (void)solidHoleChanged {
	NSInteger i = self.solidHole.selectedSegmentIndex;
	if (i < 0 || ![self.selection count]) return;
	[self remember];
	for (PDShape *s in [self selectedShapes]) s.hole = i == 1;
	[self changed];
}

- (void)colorTap:(UIButton *)b {
	if (![self.selection count]) return;
	[self remember];
	for (PDShape *s in [self selectedShapes]) { s.color = PDDesignColors[b.tag]; s.hole = NO; }
	[self changed];
}

// Keep the selection standing where it stood: same bottom height.
- (void)keepBottom:(float)z of:(NSArray *)shapes {
	float lo = 1e30f;
	for (PDShape *s in shapes) lo = MIN(lo, [s worldMin].z);
	if (lo > 1e29f) return;
	for (PDShape *s in shapes) { GLKMatrix4 m = s.matrix; m.m[14] += z - lo; s.matrix = m; }
}

- (void)setSize:(float)v axis:(int)a {
	NSArray *sel = [self selectedShapes];
	if ([sel count] != 1) return;
	PDShape *s = [sel objectAtIndex:0];
	float old = [s axisLengths].v[a];
	v = MAX(0.1f, MIN(1000, v));
	if (old <= 0 || fabsf(v - old) < 1e-4f) return;
	[self remember];
	float bottom = [s worldMin].z;
	GLKMatrix4 m = s.matrix;
	for (int k = 0; k < 3; k++) m.m[a * 4 + k] *= v / old;   // stretch along the shape's own axis, about its centre
	s.matrix = m;
	[s remakeOptionsMesh];   // fillets and walls stay their size in mm
	[self keepBottom:bottom of:sel];
	[self changed];
}

- (void)stepSize:(int)a dir:(int)dir {
	NSArray *sel = [self selectedShapes];
	if ([sel count] != 1) return;
	float s = self.snap, cur = [(PDShape *)[sel objectAtIndex:0] axisLengths].v[a];
	float v = dir > 0 ? floorf(cur / s + 1e-3f) * s + s : ceilf(cur / s - 1e-3f) * s - s;
	[self setSize:MAX(s, v) axis:a];
}

- (void)moveSelectionBy:(GLKVector3)d {
	if (![self.selection count]) return;
	[self remember];
	for (PDShape *s in [self selectedShapes]) { GLKMatrix4 m = s.matrix; m.m[12] += d.x; m.m[13] += d.y; m.m[14] += d.z; s.matrix = m; }
	[self changed];
}

- (float)positionValue:(int)a {
	GLKVector3 lo, hi;
	[self selectionBoundsMin:&lo max:&hi];
	return a == 2 ? lo.z : (lo.v[a] + hi.v[a]) / 2;
}

- (void)setPosition:(float)v axis:(int)a {
	GLKVector3 d = GLKVector3Make(0, 0, 0);
	d.v[a] = v - [self positionValue:a];
	if (fabsf(d.v[a]) > 1e-4f) [self moveSelectionBy:d];
}

- (void)stepPosition:(int)a dir:(int)dir {
	float s = self.snap, cur = [self positionValue:a];
	float v = dir > 0 ? floorf(cur / s + 1e-3f) * s + s : ceilf(cur / s - 1e-3f) * s - s;
	[self setPosition:v axis:a];
}

- (void)turnAxis:(int)axis dir:(int)dir {
	NSArray *sel = [self selectedShapes];
	if (![sel count]) return;
	[self remember];
	GLKVector3 lo, hi;
	[self selectionBoundsMin:&lo max:&hi];
	GLKVector3 c = GLKVector3MultiplyScalar(GLKVector3Add(lo, hi), 0.5f);
	float ang = GLKMathDegreesToRadians(self.turnStep) * dir;
	GLKMatrix4 r = axis == 0 ? GLKMatrix4MakeXRotation(ang) : axis == 1 ? GLKMatrix4MakeYRotation(ang) : GLKMatrix4MakeZRotation(ang);
	GLKMatrix4 t = GLKMatrix4Multiply(GLKMatrix4Multiply(GLKMatrix4MakeTranslation(c.x, c.y, c.z), r), GLKMatrix4MakeTranslation(-c.x, -c.y, -c.z));
	for (PDShape *s in sel) s.matrix = GLKMatrix4Multiply(t, s.matrix);
	[self keepBottom:lo.z of:sel];
	[self changed];
}

// Scale mode's boxes: v % of the shape's base size along axis a (clamped; all three with Uniform). NAN just
// shows the values again.
- (void)setScale:(float)v axis:(int)a {
	GLKVector3 cur;
	if (isnan(v) || self.busy || ![self.canvas scalePercent:&cur] || fabsf(MAX(0.1f, MIN(200, v)) - cur.v[a]) < 0.05f) { [self updateInspectorValues]; return; }
	[self remember];
	[self.canvas setScalePercent:v axis:a];
	[self changed];
}

- (void)stepScale:(int)a dir:(int)dir {
	GLKVector3 cur;
	if (![self.canvas scalePercent:&cur]) return;
	float s = cur.v[a] <= 10 && dir < 0 ? 1 : 5, v = dir > 0 ? floorf(cur.v[a] / s + 1e-3f) * s + s : ceilf(cur.v[a] / s - 1e-3f) * s - s;
	[self setScale:MAX(0.1f, v) axis:a];
}

- (void)toggleUniform {
	self.canvas.uniformScale = !self.canvas.uniformScale;
	[[NSUserDefaults standardUserDefaults] setBool:self.canvas.uniformScale forKey:@"PDDesignUniformScale"];
	[self updateInspectorValues];
	[self.canvas redraw];
}

- (void)cycleTurnStep {
	self.turnStep = self.turnStep == 15 ? 45 : self.turnStep == 45 ? 90 : self.turnStep == 90 ? 5 : 15;
	[self update];
}

- (void)mirrorAxis:(int)axis {
	NSArray *sel = [self selectedShapes];
	if (![sel count]) return;
	[self remember];
	GLKVector3 lo, hi;
	[self selectionBoundsMin:&lo max:&hi];
	GLKVector3 c = GLKVector3MultiplyScalar(GLKVector3Add(lo, hi), 0.5f);
	GLKMatrix4 f = GLKMatrix4MakeScale(axis == 0 ? -1 : 1, axis == 1 ? -1 : 1, axis == 2 ? -1 : 1);
	GLKMatrix4 t = GLKMatrix4Multiply(GLKMatrix4Multiply(GLKMatrix4MakeTranslation(c.x, c.y, c.z), f), GLKMatrix4MakeTranslation(-c.x, -c.y, -c.z));
	for (PDShape *s in sel) s.matrix = GLKMatrix4Multiply(t, s.matrix);
	[self changed];
}

- (void)editField:(int)field {
	if (![self.selection count] || (field < 3 && [self.selection count] != 1)) return;
	self.editingField = field;
	NSArray *names = [NSArray arrayWithObjects:@"Width", @"Depth", @"Height", @"X (centre)", @"Y (centre)", @"Lift (bottom)", nil];
	float cur = field < 3 ? [(PDShape *)[[self selectedShapes] objectAtIndex:0] axisLengths].v[field] : [self positionValue:field - 3];
	UIAlertView *a = [[UIAlertView alloc] initWithTitle:[names objectAtIndex:(NSUInteger)field] message:@"mm" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Set", nil];
	a.alertViewStyle = UIAlertViewStylePlainTextInput;
	UITextField *tf = [a textFieldAtIndex:0];
	tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
	tf.text = [NSString stringWithFormat:@"%g", roundf(cur * 100) / 100];
	a.tag = 10;
	[a show];
}

- (void)alertView:(UIAlertView *)a clickedButtonAtIndex:(NSInteger)i {
	if (i == a.cancelButtonIndex) return;
	if (a.tag == 10) {
		NSScanner *sc = [NSScanner scannerWithString:[[a textFieldAtIndex:0].text stringByReplacingOccurrencesOfString:@"," withString:@"."]];
		float v;
		if (![sc scanFloat:&v]) return;
		if (self.editingField < 3) [self setSize:v axis:self.editingField];
		else [self setPosition:v axis:self.editingField - 3];
	} else if (a.tag == 2) {
		NSString *n = [[a textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (![n length] || [n isEqualToString:self.design.name]) return;
		BOOL saved = [[PDDesign savedNames] containsObject:self.design.name];
		if ([[PDDesign savedNames] containsObject:n] || (saved && ![PDDesign renameDesign:self.design.name to:n])) {
			[[[UIAlertView alloc] initWithTitle:@"Name in use" message:[NSString stringWithFormat:@"There's already a design called “%@”.", n] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
			return;
		}
		self.design.name = n;
		[[NSUserDefaults standardUserDefaults] setObject:n forKey:PDDesignLastKey];
		[self update];
	} else if (a.tag == 3) {
		[PDDesign deleteNamed:self.design.name];
		NSArray *saved = [PDDesign savedNames];
		if ([saved count]) [self openDesignNamed:[saved objectAtIndex:0]]; else [self newDesign];
	} else if (a.tag == 4) {
		[self exportAndSend];
	} else if (a.tag == 20) {
		[self download:[a textFieldAtIndex:0].text];
	} else if (a.tag == 21) {
		NSString *n = [[a textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		NSArray *sel = [self selectedShapes];
		if (![n length] || [sel count] != 1) return;
		NSString *path = [PDLibrary unusedPathFor:n];
		if ([[sel objectAtIndex:0] writeSTL:path])
			[[[UIAlertView alloc] initWithTitle:@"Saved" message:[NSString stringWithFormat:@"“%@” is in Library › Models….", [[path lastPathComponent] stringByDeletingPathExtension]] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
		else [[[UIAlertView alloc] initWithTitle:@"Couldn't save" message:nil delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
	}
}

- (void)actionTap:(UIButton *)b {
	if (self.busy) return;
	switch (b.tag) {
		case 0: [self duplicate]; break;
		case 1: [self deleteSelection]; break;
		case 2: [self group]; break;
		case 3: [self ungroup]; break;
		case 4: {
			UIActionSheet *a = [[UIActionSheet alloc] initWithTitle:@"Mirror" delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
				otherButtonTitles:@"Left ↔ right", @"Front ↔ back", @"Upside down", nil];
			a.tag = 2;
			[a showFromRect:b.bounds inView:b animated:YES];
			break;
		}
		case 5: [self dropToPlate]; break;
		case 6: [self editPart:b]; break;
		case 7: [self saveToLibrary]; break;
	}
}

- (void)duplicate {
	NSArray *sel = [self selectedShapes];
	if (![sel count]) return;
	[self remember];
	NSMutableArray *a = [self.shapes mutableCopy];
	NSMutableIndexSet *ns = [NSMutableIndexSet indexSet];
	float off = MAX(5.0f, self.snap * 5);
	for (PDShape *s in sel) {
		PDShape *c = [s copy];
		GLKMatrix4 m = c.matrix; m.m[12] += off; m.m[13] += off; c.matrix = m;
		[a addObject:c];
		[ns addIndex:[a count] - 1];
	}
	[self setShapes:a selecting:ns];
}

- (void)deleteSelection {
	if (![self.selection count]) return;
	[self remember];
	NSMutableArray *a = [self.shapes mutableCopy];
	[a removeObjectsAtIndexes:self.selection];
	[self setShapes:a selecting:nil];
}

- (void)dropToPlate {   // each selected shape down onto the plate
	NSArray *sel = [self selectedShapes];
	if (![sel count]) return;
	[self remember];
	for (PDShape *s in sel) { GLKMatrix4 m = s.matrix; m.m[14] -= [s worldMin].z; s.matrix = m; }
	[self changed];
}

- (void)group {
	NSArray *sel = [self selectedShapes];
	if ([sel count] < 2) return;
	NSArray *members = [[NSArray alloc] initWithArray:sel copyItems:YES];
	NSIndexSet *was = self.selection;
	[self setBusy:YES message:@"Combining shapes…"];
	self.canvas.progress = 0;
	__weak PDDesignPage *weakSelf = self;
	void (^progress)(float, int, int) = ^(float f, int step, int steps) {   // CSG thread -> the bar
		dispatch_async(dispatch_get_main_queue(), ^{
			PDDesignPage *me = weakSelf;
			if (!me.busy) return;
			me.canvas.message = [NSString stringWithFormat:@"Combining shapes…  step %d of %d  ·  %.0f%%", MAX(1, MIN(step, steps)), steps, f * 100];
			me.canvas.progress = f;
		});
	};
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
		PDShape *g = [PDShape groupOf:members progress:progress];
		double took = CFAbsoluteTimeGetCurrent() - t0;
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setBusy:NO message:nil];
			NSLog(@"PrintDeck: grouped %lu shapes in %.2f s", (unsigned long)[members count], took);
			if (!g) {
				[[[UIAlertView alloc] initWithTitle:@"Nothing left" message:@"The holes cut those shapes away completely, so there's nothing to group." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
				return;
			}
			self.canvas.multiSelect = NO;   // the group is made: back to plain taps
			[self remember];
			NSMutableArray *a = [self.shapes mutableCopy];
			NSUInteger at = [was firstIndex];
			[a removeObjectsAtIndexes:was];
			at = MIN(at, [a count]);
			[a insertObject:g atIndex:at];
			[self setShapes:a selecting:[NSIndexSet indexSetWithIndex:at]];
		});
	});
}

- (void)ungroup {
	NSArray *sel = [self selectedShapes];
	if (![sel count]) return;
	[self remember];
	NSMutableArray *a = [NSMutableArray array];
	NSMutableIndexSet *ns = [NSMutableIndexSet indexSet];
	NSUInteger i = 0;
	for (PDShape *s in self.shapes) {
		BOOL picked = [self.selection containsIndex:i++];
		if (picked && [s.kind isEqualToString:@"group"]) for (PDShape *c in [s ungrouped]) { [a addObject:c]; [ns addIndex:[a count] - 1]; }
		else { [a addObject:s]; if (picked) [ns addIndex:[a count] - 1]; }
	}
	[self setShapes:a selecting:ns];
}

- (void)selectAll {
	self.selection = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [self.shapes count])];
	self.canvas.selection = self.selection;
	[self update];
}

#pragma mark Pick, align, arrange

- (void)pickShapes:(UIButton *)sender {
	if (self.busy || ![self.shapes count]) return;
	[self.popover dismissPopoverAnimated:NO];
	PDShapePicker *pk = [[PDShapePicker alloc] initWithShapes:self.shapes picked:self.selection];
	__weak PDDesignPage *weakSelf = self;
	pk.changed = ^(NSIndexSet *picked) {
		weakSelf.selection = [picked copy];
		weakSelf.canvas.selection = weakSelf.selection;
		[weakSelf update];
	};
	pk.groupTapped = ^{
		[weakSelf.popover dismissPopoverAnimated:YES];
		weakSelf.popover = nil;
		[weakSelf group];
	};
	self.popover = [[UIPopoverController alloc] initWithContentViewController:pk];
	self.popover.delegate = self;
	[self.popover presentPopoverFromRect:sender.bounds inView:sender permittedArrowDirections:UIPopoverArrowDirectionRight | UIPopoverArrowDirectionUp animated:YES];
}

static void PDMoveShape(PDShape *s, int axis, float d) {
	if (fabsf(d) < 1e-5f) return;
	GLKMatrix4 m = s.matrix;
	m.m[12 + axis] += d;
	s.matrix = m;
}

// Line the selected shapes up on one axis: mode 0 = their low sides, 1 = centres, 2 = high sides,
// all to the selection's own box (as Tinkercad's Align does).
- (void)alignTap:(UIButton *)b {
	NSArray *sel = [self selectedShapes];
	if ([sel count] < 2 || self.busy) return;
	int axis = (int)b.tag / 3, mode = (int)b.tag % 3;
	GLKVector3 lo, hi;
	[self selectionBoundsMin:&lo max:&hi];
	float target = mode == 0 ? lo.v[axis] : mode == 2 ? hi.v[axis] : (lo.v[axis] + hi.v[axis]) / 2;
	[self remember];
	for (PDShape *s in sel) {
		GLKVector3 a = [s worldMin], z = [s worldMax];
		float cur = mode == 0 ? a.v[axis] : mode == 2 ? z.v[axis] : (a.v[axis] + z.v[axis]) / 2;
		PDMoveShape(s, axis, target - cur);
	}
	[self changed];
}

static NSArray *PDSortedAlong(NSArray *shapes, int axis) {
	return [shapes sortedArrayUsingComparator:^NSComparisonResult(PDShape *p, PDShape *q) {
		float a = [p worldMin].v[axis] + [p worldMax].v[axis], b = [q worldMin].v[axis] + [q worldMax].v[axis];
		return a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : NSOrderedSame;
	}];
}

// Equal gaps between the selected shapes along X or Y, keeping the outermost two where they are.
- (void)spaceTap:(UIButton *)b {
	NSArray *sel = [self selectedShapes];
	if ([sel count] < 3 || self.busy) {
		if ([sel count] == 2) [[[UIAlertView alloc] initWithTitle:@"Space evenly" message:@"Select three or more shapes to space them evenly." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
		return;
	}
	int axis = (int)b.tag;
	NSArray *order = PDSortedAlong(sel, axis);
	GLKVector3 lo, hi;
	[self selectionBoundsMin:&lo max:&hi];
	float total = 0;
	for (PDShape *s in order) total += [s worldMax].v[axis] - [s worldMin].v[axis];
	float gap = (hi.v[axis] - lo.v[axis] - total) / ([order count] - 1);
	[self remember];
	float at = lo.v[axis];
	for (PDShape *s in order) {
		float a = [s worldMin].v[axis], size = [s worldMax].v[axis] - a;
		PDMoveShape(s, axis, at - a);
		at += size + gap;
	}
	[self changed];
}

- (void)gridTap:(UIButton *)b {
	if ([self.selection count] < 2 || self.busy) return;
	UIActionSheet *a = [[UIActionSheet alloc] initWithTitle:@"Arrange the selected shapes in rows, from the selection's front-left corner"
		delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:@"Touching (no gap)", @"2 mm gaps", @"5 mm gaps", @"10 mm gaps", nil];
	a.tag = 5;
	[a showFromRect:b.bounds inView:b animated:YES];
}

// A grid of about √n columns, in the shapes' current front-to-back, left-to-right order. Each column is as wide
// as its widest shape and each row as deep as its deepest, so different sizes line up without overlapping.
- (void)arrangeGridGap:(float)gap {
	NSArray *sel = [self selectedShapes];
	NSUInteger n = [sel count];
	if (n < 2) return;
	NSUInteger cols = (NSUInteger)ceil(sqrt((double)n)), rows = (n + cols - 1) / cols;
	NSArray *order = [sel sortedArrayUsingComparator:^NSComparisonResult(PDShape *p, PDShape *q) {
		float py = [p worldMin].y + [p worldMax].y, qy = [q worldMin].y + [q worldMax].y;
		if (fabsf(py - qy) > 10) return py < qy ? NSOrderedAscending : NSOrderedDescending;
		float px = [p worldMin].x + [p worldMax].x, qx = [q worldMin].x + [q worldMax].x;
		return px < qx ? NSOrderedAscending : px > qx ? NSOrderedDescending : NSOrderedSame;
	}];
	float colW[64] = {0}, rowD[64] = {0};
	if (cols > 64 || rows > 64) return;
	for (NSUInteger i = 0; i < n; i++) {
		PDShape *s = [order objectAtIndex:i];
		GLKVector3 a = [s worldMin], z = [s worldMax];
		colW[i % cols] = MAX(colW[i % cols], z.x - a.x);
		rowD[i / cols] = MAX(rowD[i / cols], z.y - a.y);
	}
	GLKVector3 lo, hi;
	[self selectionBoundsMin:&lo max:&hi];
	[self remember];
	for (NSUInteger i = 0; i < n; i++) {
		PDShape *s = [order objectAtIndex:i];
		NSUInteger c = i % cols, r = i / cols;
		float x0 = lo.x, y0 = lo.y;
		for (NSUInteger k = 0; k < c; k++) x0 += colW[k] + gap;
		for (NSUInteger k = 0; k < r; k++) y0 += rowD[k] + gap;
		GLKVector3 a = [s worldMin], z = [s worldMax];
		// centred in its cell
		PDMoveShape(s, 0, x0 + (colW[c] - (z.x - a.x)) / 2 - a.x);
		PDMoveShape(s, 1, y0 + (rowD[r] - (z.y - a.y)) / 2 - a.y);
	}
	[self changed];
}

- (void)gizmoChanged {
	[self endEditing:YES];
	self.canvas.gizmo = self.gizmoControl.selectedSegmentIndex;
	[self update];
	[[NSUserDefaults standardUserDefaults] setInteger:self.canvas.gizmo forKey:@"PDDesignGizmo"];
}

// Turns each selected shape back onto its own original axes (Tinkercad's "reset rotation"): same size and
// mirroring, about its own centre; a shape standing on the plate stays on it.
- (void)resetRotation {
	NSArray *sel = [self selectedShapes];
	if (![sel count] || self.busy) return;
	[self remember];
	for (PDShape *s in sel) {
		float bottom = [s worldMin].z;
		GLKMatrix4 m = s.matrix;
		GLKVector3 c[3];
		for (int i = 0; i < 3; i++) c[i] = GLKVector3Make(m.m[i * 4], m.m[i * 4 + 1], m.m[i * 4 + 2]);
		int flip = -1;   // a mirrored shape stays mirrored: along the axis that points most backwards
		if (GLKVector3DotProduct(c[0], GLKVector3CrossProduct(c[1], c[2])) < 0) {
			float worst = 2;
			for (int i = 0; i < 3; i++) { float l = GLKVector3Length(c[i]), k = l > 0 ? c[i].v[i] / l : 0; if (k < worst) { worst = k; flip = i; } }
		}
		for (int i = 0; i < 3; i++) {
			float l = GLKVector3Length(c[i]) * (i == flip ? -1 : 1);
			for (int k = 0; k < 3; k++) m.m[i * 4 + k] = k == i ? l : 0;
		}
		s.matrix = m;   // the translation (its centre) is untouched
		if (fabsf(bottom) < 0.05f) [self keepBottom:0 of:[NSArray arrayWithObject:s]];
	}
	[self changed];
}

- (void)toggleMulti { self.canvas.multiSelect = !self.canvas.multiSelect; [self update]; }

- (void)snapChanged {
	float v[4] = {0.1f, 0.5f, 1, 5};
	NSInteger i = self.snapControl.selectedSegmentIndex;
	if (i < 0 || i > 3) return;
	self.snap = v[i];
	self.canvas.snap = self.snap;
	[[NSUserDefaults standardUserDefaults] setFloat:self.snap forKey:PDDesignSnapKey];
}

- (void)undo {
	if (![self.undoStack count] || self.busy) return;
	[self.redoStack addObject:[[NSArray alloc] initWithArray:self.shapes copyItems:YES]];
	NSArray *prev = [self.undoStack lastObject];
	[self.undoStack removeLastObject];
	[self setShapes:prev selecting:nil];
}

- (void)redo {
	if (![self.redoStack count] || self.busy) return;
	[self.undoStack addObject:[[NSArray alloc] initWithArray:self.shapes copyItems:YES]];
	NSArray *next = [self.redoStack lastObject];
	[self.redoStack removeLastObject];
	[self setShapes:next selecting:nil];
}

#pragma mark Send to slicer

- (void)sendToSlicer {
	if (self.busy || ![self.shapes count]) return;
	int holes = 0, solids = 0;
	for (PDShape *s in self.shapes) { if (s.hole) holes++; else solids++; }
	if (!solids) {
		[[[UIAlertView alloc] initWithTitle:@"Nothing to print" message:@"The design only has holes. Make a shape solid, or group the holes with the shapes they should cut." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
		return;
	}
	if (holes) {
		UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Loose holes" message:[NSString stringWithFormat:@"%d hole%@ %@n't grouped with anything, so %@ won't cut. Select a hole and the shapes it should cut, then Group.",
			holes, holes == 1 ? @"" : @"s", holes == 1 ? @"is" : @"are", holes == 1 ? @"it" : @"they"] delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Send anyway", nil];
		a.tag = 4;
		[a show];
		return;
	}
	[self exportAndSend];
}

- (void)exportAndSend {
	PDDesign *d = [[PDDesign alloc] init];
	d.name = self.design.name;
	d.shapes = [[NSArray alloc] initWithArray:self.shapes copyItems:YES];
	[self setBusy:YES message:@"Preparing the model…"];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSString *err = nil;
		int loose = 0;
		NSString *path = [d exportSTL:&err looseHoles:&loose];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setBusy:NO message:nil];
			if (!path) { [[[UIAlertView alloc] initWithTitle:@"Couldn't export" message:err delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show]; return; }
			if (self.sliceHandler) self.sliceHandler(path);
		});
	});
}

@end
