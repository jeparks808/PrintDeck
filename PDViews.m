#import "PDViews.h"
#import "PDUtil.h"
#import <QuartzCore/QuartzCore.h>

@implementation PDCard

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = PD_TILE;
		self.layer.cornerRadius = 12;
		_titleLabel = PDLabel([UIFont boldSystemFontOfSize:13], PD_DIM);
		[self addSubview:_titleLabel];
	}
	return self;
}

- (CGRect)contentBounds { return CGRectInset(self.bounds, 16, 12); }

- (void)layoutSubviews {
	[super layoutSubviews];
	CGRect c = [self contentBounds];
	self.titleLabel.frame = CGRectMake(c.origin.x, c.origin.y, c.size.width, 16);
}

- (void)setHighlighted:(BOOL)h {
	[super setHighlighted:h];
	if (self.tappable) self.backgroundColor = h ? PD_TILE_HI : PD_TILE;
}

- (BOOL)beginTrackingWithTouch:(UITouch *)t withEvent:(UIEvent *)e { return self.tappable && self.enabled; }

- (void)setEnabled:(BOOL)enabled {
	[super setEnabled:enabled];
	self.alpha = enabled ? 1.0 : 0.45;
}

@end

@implementation PDTempCard

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_valueLabel = PDLabel(PDLightFont(44), [UIColor whiteColor]);
		_targetLabel = PDLabel([UIFont systemFontOfSize:17], PD_DIM);
		_graph = [[PDSparklineView alloc] initWithFrame:CGRectZero];
		_graph.color = PD_HOT;
		for (UIView *v in [NSArray arrayWithObjects:_valueLabel, _targetLabel, _graph, nil]) [self addSubview:v];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGRect c = [self contentBounds];
	CGFloat left = 150;
	self.valueLabel.frame = CGRectMake(c.origin.x, c.origin.y + 18, left, 50);
	self.targetLabel.frame = CGRectMake(c.origin.x, CGRectGetMaxY(c) - 20, left, 20);
	self.graph.frame = CGRectMake(c.origin.x + left, c.origin.y + 4, c.size.width - left, c.size.height - 4);
}

- (void)setCurrent:(NSNumber *)cur target:(NSNumber *)target history:(NSArray *)hist {
	self.valueLabel.text = cur ? [NSString stringWithFormat:@"%.0f°", [cur doubleValue]] : @"–";
	double t = [target doubleValue];
	BOOL heating = t > 0;
	self.targetLabel.text = heating ? [NSString stringWithFormat:@"target %.0f°", t] : @"off";
	BOOL near = heating && fabs([cur doubleValue] - t) < 3;
	self.valueLabel.textColor = !heating ? [UIColor whiteColor] : (near ? PD_GREEN : PD_HOT);
	self.graph.color = heating ? PD_HOT : PD_ACCENT;
	self.graph.values = hist;
}

@end

@implementation PDProgressBar

- (id)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = [UIColor clearColor];
		self.contentMode = UIViewContentModeRedraw;
		_color = PD_ACCENT;
	}
	return self;
}

- (void)setProgress:(double)p { _progress = MAX(0, MIN(1, p)); [self setNeedsDisplay]; }
- (void)setColor:(UIColor *)c { _color = c; [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)rect {
	CGFloat r = self.bounds.size.height / 2;
	[[UIColor colorWithWhite:1 alpha:0.10] setFill];
	[[UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:r] fill];
	if (self.progress <= 0) return;
	CGRect f = self.bounds;
	f.size.width = MAX(f.size.height, f.size.width * self.progress);
	[self.color setFill];
	[[UIBezierPath bezierPathWithRoundedRect:f cornerRadius:r] fill];
}

@end

UIButton *PDButton(NSString *title, UIColor *color) {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
	[b setTitleColor:color forState:UIControlStateNormal];
	[b setTitleColor:[color colorWithAlphaComponent:0.4] forState:UIControlStateHighlighted];
	[b setTitleColor:[UIColor colorWithWhite:1 alpha:0.25] forState:UIControlStateDisabled];
	b.backgroundColor = [color colorWithAlphaComponent:0.14];
	b.layer.cornerRadius = 10;
	return b;
}

@interface PDEventOverlay ()
@property (nonatomic, copy) NSString *kind;
@end

@implementation PDEventOverlay

+ (void)dismissInView:(UIView *)view kind:(NSString *)kind {
	for (UIView *v in [view.subviews copy])
		if ([v isKindOfClass:[PDEventOverlay class]] && (!kind || [((PDEventOverlay *)v).kind isEqualToString:kind])) [(PDEventOverlay *)v dismiss];
}

+ (void)showInView:(UIView *)view kind:(NSString *)kind title:(NSString *)title detail:(NSString *)detail {
	for (UIView *v in [view.subviews copy]) if ([v isKindOfClass:[PDEventOverlay class]]) [v removeFromSuperview];
	UIColor *c = [kind isEqualToString:@"finished"] ? PD_GREEN : ([kind isEqualToString:@"paused"] || [kind isEqualToString:@"stopped"]) ? PD_AMBER : PD_RED;
	PDEventOverlay *o = [[PDEventOverlay alloc] initWithFrame:view.bounds];
	o.kind = kind;
	o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	o.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];

	UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 640, 300)];
	panel.center = CGPointMake(view.bounds.size.width / 2, view.bounds.size.height / 2);
	panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
	panel.backgroundColor = [c colorWithAlphaComponent:0.20];
	panel.layer.cornerRadius = 24;
	panel.layer.borderColor = c.CGColor;
	panel.layer.borderWidth = 3;
	[o addSubview:panel];

	UILabel *t = PDLabel(PDBoldFont(56), c);
	t.text = title;
	t.textAlignment = NSTextAlignmentCenter;
	t.frame = CGRectMake(20, 50, 600, 70);
	UILabel *d = PDLabel([UIFont systemFontOfSize:24], [UIColor whiteColor]);
	d.text = detail;
	d.numberOfLines = 2;
	d.textAlignment = NSTextAlignmentCenter;
	d.frame = CGRectMake(30, 130, 580, 70);
	UILabel *h = PDLabel([UIFont systemFontOfSize:15], PD_DIM);
	h.text = @"Tap to dismiss";
	h.textAlignment = NSTextAlignmentCenter;
	h.frame = CGRectMake(20, 240, 600, 24);
	for (UIView *v in [NSArray arrayWithObjects:t, d, h, nil]) [panel addSubview:v];

	[o addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:o action:@selector(dismiss)]];
	o.alpha = 0;
	[view addSubview:o];
	[UIView animateWithDuration:0.25 animations:^{ o.alpha = 1; }];
	// Pulse the border so it catches the eye from across the room.
	CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"borderWidth"];
	pulse.fromValue = [NSNumber numberWithFloat:3];
	pulse.toValue = [NSNumber numberWithFloat:14];
	pulse.duration = 0.8;
	pulse.autoreverses = YES;
	pulse.repeatCount = HUGE_VALF;
	[panel.layer addAnimation:pulse forKey:@"pulse"];
}

- (void)dismiss {
	[UIView animateWithDuration:0.2 animations:^{ self.alpha = 0; } completion:^(BOOL f) { [self removeFromSuperview]; }];
}

@end
