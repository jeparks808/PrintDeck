#import "PDPanels.h"
#import "PDPrinter.h"
#import "PDUtil.h"
#import "PDViews.h"

@interface PDFilesViewController () <UIAlertViewDelegate>
@property (nonatomic, strong) NSDictionary *pending;
@end

@implementation PDFilesViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Files on the printer";
	self.tableView.rowHeight = 64;
	self.contentSizeForViewInPopover = CGSizeMake(460, 560);
	[[NSNotificationCenter defaultCenter] addObserver:self.tableView selector:@selector(reloadData) name:PDPrinterFilesNotification object:nil];
	[[PDPrinter shared] refreshFiles];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self.tableView]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX(1, (NSInteger)[[PDPrinter shared].files count]); }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"f"];
	if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
	NSArray *files = [PDPrinter shared].files;
	if (![files count]) {
		c.textLabel.text = files ? @"No files on the printer" : @"Loading…";
		c.detailTextLabel.text = nil;
		c.selectionStyle = UITableViewCellSelectionStyleNone;
		return c;
	}
	NSDictionary *f = [files objectAtIndex:(NSUInteger)ip.row];
	NSString *path = PDStr(f, @"name");
	c.textLabel.text = PDPrettyFileName(path);
	c.textLabel.font = [UIFont boldSystemFontOfSize:17];
	NSMutableArray *bits = [NSMutableArray array];
	// Slicer time is the last "_" part of Elegoo file names, e.g. ..._2h18m.gcode
	NSString *last = [[[[path lastPathComponent] stringByDeletingPathExtension] componentsSeparatedByString:@"_"] lastObject];
	if ([last rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == 0 && [last length] <= 9) [bits addObject:last];
	int layers = [PDNum(f, @"TotalLayers") intValue];
	if (layers) [bits addObject:[NSString stringWithFormat:@"%d layers", layers]];
	double size = [PDNum(f, @"FileSize") doubleValue];
	if (size) [bits addObject:[NSString stringWithFormat:@"%.1f MB", size / 1e6]];
	double t = [PDNum(f, @"CreateTime") doubleValue];
	if (t > 0) {
		NSDateFormatter *df = [[NSDateFormatter alloc] init];
		[df setDateFormat:@"MMM d, h:mm a"];
		[bits addObject:[df stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]]];
	}
	c.detailTextLabel.text = [bits componentsJoinedByString:@"  ·  "];
	c.selectionStyle = UITableViewCellSelectionStyleBlue;
	return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	NSArray *files = [PDPrinter shared].files;
	if ((NSUInteger)ip.row >= [files count]) return;
	if ([PDPrinter shared].isBusy) {
		[[[UIAlertView alloc] initWithTitle:@"Printer is busy" message:@"Wait for the current job to finish." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
		return;
	}
	self.pending = [files objectAtIndex:(NSUInteger)ip.row];
	NSString *msg = [NSString stringWithFormat:@"Start printing \"%@\"? Make sure the bed is clear.", PDPrettyFileName(PDStr(self.pending, @"name"))];
	[[[UIAlertView alloc] initWithTitle:@"Start print" message:msg delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Print", nil] show];
}

- (void)alertView:(UIAlertView *)a clickedButtonAtIndex:(NSInteger)i {
	if (i == a.cancelButtonIndex || !self.pending) return;
	[[PDPrinter shared] startFile:PDStr(self.pending, @"name")];
	self.pending = nil;
	if (self.onDone) self.onDone();
}

@end

@interface PDMoveViewController ()
@property (nonatomic, strong) UISegmentedControl *step;
@end

@implementation PDMoveViewController

static const double PDSteps[] = {0.1, 1, 10, 50};

- (void)loadView {
	UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 420, 360)];
	v.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1];
	self.view = v;
	self.contentSizeForViewInPopover = v.bounds.size;

	UILabel *t = PDLabel([UIFont boldSystemFontOfSize:17], [UIColor whiteColor]);
	t.text = @"Move (mm)";
	t.frame = CGRectMake(20, 14, 200, 24);
	[v addSubview:t];
	self.step = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"0.1", @"1", @"10", @"50", nil]];
	self.step.segmentedControlStyle = UISegmentedControlStyleBar;
	self.step.tintColor = [UIColor darkGrayColor];
	self.step.selectedSegmentIndex = 2;
	self.step.frame = CGRectMake(200, 12, 200, 30);
	[v addSubview:self.step];

	NSArray *rows = [NSArray arrayWithObjects:@"X", @"Y", @"Z", nil];
	for (NSUInteger i = 0; i < 3; i++) {
		NSString *axis = [rows objectAtIndex:i];
		CGFloat y = 60 + i * 66;
		UILabel *l = PDLabel(PDLightFont(30), [UIColor whiteColor]);
		l.text = axis;
		l.frame = CGRectMake(24, y + 8, 40, 40);
		[v addSubview:l];
		UIButton *minus = PDButton([NSString stringWithFormat:@"%@ −", axis], PD_ACCENT);
		minus.frame = CGRectMake(70, y, 105, 54);
		minus.tag = (NSInteger)i * 2;
		[minus addTarget:self action:@selector(jog:) forControlEvents:UIControlEventTouchUpInside];
		UIButton *plus = PDButton([NSString stringWithFormat:@"%@ +", axis], PD_ACCENT);
		plus.frame = CGRectMake(185, y, 105, 54);
		plus.tag = (NSInteger)i * 2 + 1;
		[plus addTarget:self action:@selector(jog:) forControlEvents:UIControlEventTouchUpInside];
		UIButton *home = PDButton([NSString stringWithFormat:@"Home %@", axis], PD_DIM);
		home.frame = CGRectMake(300, y, 100, 54);
		home.tag = (NSInteger)i;
		[home addTarget:self action:@selector(homeAxis:) forControlEvents:UIControlEventTouchUpInside];
		for (UIView *b in [NSArray arrayWithObjects:minus, plus, home, nil]) [v addSubview:b];
	}
	UIButton *all = PDButton(@"Home all axes", PD_GREEN);
	all.frame = CGRectMake(70, 268, 330, 54);
	[all addTarget:self action:@selector(homeAll) forControlEvents:UIControlEventTouchUpInside];
	[v addSubview:all];
	UILabel *note = PDLabel([UIFont systemFontOfSize:12], PD_DIM);
	note.text = @"Z + lowers the bed. Home first after power-on.";
	note.frame = CGRectMake(70, 328, 330, 20);
	[v addSubview:note];
}

- (BOOL)ok {
	if (![PDPrinter shared].isBusy) return YES;
	[[[UIAlertView alloc] initWithTitle:@"Printer is busy" message:@"Moving is disabled while a job is running." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
	return NO;
}

- (void)jog:(UIButton *)b {
	if (![self ok]) return;
	NSArray *axes = [NSArray arrayWithObjects:@"X", @"Y", @"Z", nil];
	double mm = PDSteps[MAX(0, MIN(3, self.step.selectedSegmentIndex))];
	[[PDPrinter shared] jog:[axes objectAtIndex:(NSUInteger)(b.tag / 2)] by:(b.tag % 2) ? mm : -mm];
}

- (void)homeAxis:(UIButton *)b {
	if (![self ok]) return;
	[[PDPrinter shared] home:[[NSArray arrayWithObjects:@"X", @"Y", @"Z", nil] objectAtIndex:(NSUInteger)b.tag]];
}

- (void)homeAll { if ([self ok]) [[PDPrinter shared] home:@"XYZ"]; }

@end
