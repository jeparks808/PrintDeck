#import "PDAppDelegate.h"
#import "PDCardPage.h"
#import <GLKit/GLKit.h>
#import "PDToolpathView.h"
#import "PDMainViewController.h"
#import "PDPrinter.h"
#import "PDMesh.h"
#import "PDSlicer.h"
#import "PDDesignView.h"
#import <QuartzCore/QuartzCore.h>

@interface PDAppDelegate ()
@property (nonatomic, strong) PDMainViewController *main;
@end

static UIView *PDFindView(UIView *v, Class c) {
	if ([v isKindOfClass:c]) return v;
	for (UIView *sub in v.subviews) { UIView *f = PDFindView(sub, c); if (f) return f; }
	return nil;
}

static void PDCollectButtons(UIView *v, NSString *title, NSMutableArray *out) {
	if (v.hidden || v.alpha < 0.01) return;
	if ([v isKindOfClass:[UIButton class]] && [[(UIButton *)v currentTitle] isEqualToString:title] && [(UIButton *)v isEnabled]) [out addObject:v];
	if ([v isKindOfClass:[UITableViewCell class]] && [[(UITableViewCell *)v textLabel].text isEqualToString:title]) [out addObject:v];
	if ([v isKindOfClass:[UISegmentedControl class]]) {   // a segment: recorded as {control, index}
		UISegmentedControl *sc = (UISegmentedControl *)v;
		for (NSUInteger i = 0; i < sc.numberOfSegments; i++)
			if ([[sc titleForSegmentAtIndex:i] isEqualToString:title] && [sc isEnabledForSegmentAtIndex:i]) [out addObject:[NSArray arrayWithObjects:sc, [NSNumber numberWithUnsignedInteger:i], nil]];
	}
	if ([v isKindOfClass:[UISlider class]] && [title hasPrefix:@"slider:"]) [out addObject:v];   // press?title=slider:<0..1>
	if ([v isKindOfClass:[UISwitch class]] && [[v accessibilityLabel] isEqualToString:title] && [(UISwitch *)v isEnabled]) [out addObject:v];   // flips it
	for (UIView *sub in v.subviews) PDCollectButtons(sub, title, out);
}

// Paint every GLKView's own snapshot over the rendered layers (the 3D toolpath viewer).
static void PDDrawGLViews(UIView *root, UIView *v) {
	for (UIView *sub in v.subviews) {
		if (sub.hidden || sub.alpha < 0.01) continue;
		if ([sub isKindOfClass:[GLKView class]]) {
			UIImage *gl = [(GLKView *)sub snapshot];
			CGRect r = [sub.superview convertRect:sub.frame toView:root];
			[gl drawInRect:r];
			// then whatever sits above it again (labels over the 3D view)
			CGContextRef ctx = UIGraphicsGetCurrentContext();
			for (UIView *cur = sub; cur && cur != root; cur = cur.superview) {
				NSArray *sibs = cur.superview.subviews;
				for (NSUInteger k = [sibs indexOfObject:cur] + 1; k < [sibs count]; k++) {
					UIView *o = [sibs objectAtIndex:k];
					CGRect orr = [o.superview convertRect:o.frame toView:root];
					if (o.hidden || o.alpha < 0.01 || !CGRectIntersectsRect(orr, r)) continue;
					CGContextSaveGState(ctx);
					CGPoint c = [o.superview convertPoint:o.center toView:root];   // honour a rotated view (the layer slider)
					CGContextTranslateCTM(ctx, c.x, c.y);
					CGContextConcatCTM(ctx, o.transform);
					CGContextTranslateCTM(ctx, -o.bounds.size.width / 2, -o.bounds.size.height / 2);
					[o.layer renderInContext:ctx];
					CGContextRestoreGState(ctx);
				}
			}
		} else PDDrawGLViews(root, sub);
	}
}

@implementation PDAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	[application setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];
	application.idleTimerDisabled = YES; // a printer panel should stay on
	[PDMeshSource shared];   // from the start, so it can fetch a new bed mesh when the printer finishes levelling
	self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	self.window.backgroundColor = [UIColor blackColor];
	self.main = [[PDMainViewController alloc] init];
	self.window.rootViewController = self.main;
	[self.window makeKeyAndVisible];

	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	self.main.cameraEnabled = ![d boolForKey:@"PDCameraOff"];
	NSString *host = [d stringForKey:@"PDHost"];
	if ([host length]) [[PDPrinter shared] connectToHost:host port:(int)[d integerForKey:@"PDPort"] videoPort:(int)[d integerForKey:@"PDVideoPort"]];
	else [self.main startSearch];
	return YES;
}

// printdeck://                                        bring to front
// printdeck://connect?host=192.168.0.184[&port=3030&video=3031]   connect to a printer (or the simulator)
// printdeck://search                                  look for printers on the Wi-Fi
// printdeck://camera?on=0|1                           camera off / on
// printdeck://event?kind=finished|paused|failed       show the alert screen (to try it out)
// printdeck://card?name=nozzle|bed|chamber            open a temperature detail page
// printdeck://page?name=camera|job|file|fans|speed|machine   open a card detail page
// printdeck://mesh[?helper=<url-encoded http json endpoint>]   open the 3D bed-mesh page
// printdeck://slice[?model=builtin:Calibration%20cube|<path>][&set=support:1,infill:30][&go=1][&section=Speed]   open the Slice page
//                                                     (optionally with a model / changed settings / slicing right away)
// file://…/Inbox/x.stl (an STL sent with "Open in PrintDeck")   moved into Documents/PrintDeck, opened on the Slice page
// printdeck://snapshot                                save the screen to /tmp/printdeck-snapshot.png (developer aid)
// printdeck://zoom?z=<n>                            zoom the visible 3D views (developer aid)
// printdeck://press?title=<button title>[&n=0]       tap the n-th visible enabled button, table row or segment with that title;
//                                                     title=slider:<0..1> moves the n-th slider (developer aid)
// printdeck://type?label=<accessibility label>&text=<text>[&keep=1]   type into a visible text field, then leave it (developer aid)
// printdeck://drag?x0=&y0=&x1=&y1=[&hold=1]        drag on the Design canvas (screen points; hold: don't lift; drag?release=1 lifts)
// printdeck://bench                                   spin the job page's 3D view for 4 s, append fps to /tmp/printdeck-toolpath.log
// An STL handed over with "Open in PrintDeck" lands in Documents/Inbox: move it into the Slice page's model
// folder (/var/mobile/Documents/PrintDeck) under a free name, and open it for slicing.
static UIView *PDFindLabelled(UIView *v, NSString *label) {
	if (v.hidden || v.alpha < 0.01f) return nil;
	if ([v isKindOfClass:[UITextField class]] && [v.accessibilityLabel isEqualToString:label]) return v;
	for (UIView *s in v.subviews) { UIView *f = PDFindLabelled(s, label); if (f) return f; }
	return nil;
}

- (void)importModel:(NSURL *)url {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *src = [url path];
	NSString *docs = [PDSlicer libraryDirectory];
	NSString *dest = src;
	if (![[src stringByDeletingLastPathComponent] isEqualToString:docs]) {
		NSString *base = [[src lastPathComponent] stringByDeletingPathExtension], *ext = [src pathExtension];
		dest = [docs stringByAppendingPathComponent:[src lastPathComponent]];
		for (int n = 2; [fm fileExistsAtPath:dest]; n++) dest = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d.%@", base, n, ext]];
		if (![fm moveItemAtPath:src toPath:dest error:NULL] && ![fm copyItemAtPath:src toPath:dest error:NULL]) dest = src;
	}
	[self.main openSlice:dest];
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)source annotation:(id)annotation {
	if ([url isFileURL]) { [self importModel:url]; return YES; }
	NSString *cmd = [url host];
	NSMutableDictionary *q = [NSMutableDictionary dictionary];
	for (NSString *pair in [[url query] componentsSeparatedByString:@"&"]) {
		NSArray *kv = [pair componentsSeparatedByString:@"="];
		if ([kv count] == 2)
			[q setObject:[[kv objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] forKey:[kv objectAtIndex:0]];
	}
	if ([cmd isEqualToString:@"connect"] && [q objectForKey:@"host"]) {
		int port = [q objectForKey:@"port"] ? [[q objectForKey:@"port"] intValue] : 3030;
		int video = [q objectForKey:@"video"] ? [[q objectForKey:@"video"] intValue] : (port == 3030 ? 3031 : port + 1);
		[[PDPrinter shared] connectToHost:[q objectForKey:@"host"] port:port videoPort:video];
		[self.main appDidBecomeActive];
	} else if ([cmd isEqualToString:@"search"]) {
		[self.main startSearch];
	} else if ([cmd isEqualToString:@"camera"]) {
		self.main.cameraEnabled = [[q objectForKey:@"on"] intValue] != 0;
	} else if ([cmd isEqualToString:@"event"]) {
		[self.main showTestEvent:[q objectForKey:@"kind"]];
	} else if ([cmd isEqualToString:@"card"]) {
		[self.main openDetailKind:[q objectForKey:@"name"]];
	} else if ([cmd isEqualToString:@"page"]) {
		[self.main openCardPageKind:[q objectForKey:@"name"]];
	} else if ([cmd isEqualToString:@"design"]) {
		[self.main openDesign:[q objectForKey:@"name"]];
	} else if ([cmd isEqualToString:@"slice"]) {
		[self.main openSlice:[q objectForKey:@"model"]];
		if ([q objectForKey:@"section"]) [self.main scrollSliceSettingsTo:[q objectForKey:@"section"]];
		for (NSString *kv in [[q objectForKey:@"set"] componentsSeparatedByString:@","]) {   // developer aid: key:value settings
			NSArray *p = [kv componentsSeparatedByString:@":"];
			if ([p count] != 2) continue;
			NSString *v = [p objectAtIndex:1];
			NSScanner *sc = [NSScanner scannerWithString:v];
			double d;
			id val = ([sc scanDouble:&d] && [sc isAtEnd]) ? (id)[NSNumber numberWithDouble:d] : (id)v;
			[PDSliceSettings setValue:val forKey:[p objectAtIndex:0]];
		}
		if ([[q objectForKey:@"go"] intValue]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [[PDSlicer shared] slice]; });
	} else if ([cmd isEqualToString:@"mesh"]) {
		NSString *h = [q objectForKey:@"helper"];
		if ([h length]) { [PDMeshSource shared].helperURL = h; [[PDMeshSource shared] fetch]; }
		[self.main openMesh];
	} else if ([cmd isEqualToString:@"press"]) {   // developer aid: tap the n-th visible button titled `title`
		NSMutableArray *found = [NSMutableArray array];
		// every window: alerts (UIAlertView) live in a window of their own
		for (UIWindow *w in [UIApplication sharedApplication].windows) PDCollectButtons(w, [q objectForKey:@"title"] ?: @"", found);
		NSUInteger n = (NSUInteger)[[q objectForKey:@"n"] intValue];
		if (n < [found count]) {
			id hit = [found objectAtIndex:n];
			if ([hit isKindOfClass:[UIButton class]]) [(UIButton *)hit sendActionsForControlEvents:UIControlEventTouchUpInside];
			else if ([hit isKindOfClass:[NSArray class]]) {
				UISegmentedControl *sc = [hit objectAtIndex:0];
				sc.selectedSegmentIndex = [[hit objectAtIndex:1] integerValue];
				[sc sendActionsForControlEvents:UIControlEventValueChanged];
			} else if ([hit isKindOfClass:[UISwitch class]]) {
				UISwitch *sw = hit;
				sw.on = !sw.on;
				[sw sendActionsForControlEvents:UIControlEventValueChanged];
			} else if ([hit isKindOfClass:[UISlider class]]) {
				UISlider *sl = hit;
				sl.value = sl.minimumValue + (sl.maximumValue - sl.minimumValue) * [[[q objectForKey:@"title"] substringFromIndex:7] floatValue];
				[sl sendActionsForControlEvents:UIControlEventValueChanged];
				[sl sendActionsForControlEvents:UIControlEventTouchUpInside];
			}
			else {   // a table row: select it the way a tap would
				UITableViewCell *cell = hit;
				UIView *tv = cell.superview;
				while (tv && ![tv isKindOfClass:[UITableView class]]) tv = tv.superview;
				UITableView *table = (UITableView *)tv;
				NSIndexPath *ip = [table indexPathForCell:cell];
				if (ip) {
					[table selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
					[table.delegate tableView:table didSelectRowAtIndexPath:ip];
				}
			}
		}
	} else if ([cmd isEqualToString:@"type"]) {   // developer aid: type text into the visible text field with that accessibility label
		UITextField *tf = nil;
		for (UIWindow *w in [UIApplication sharedApplication].windows) if (!tf) tf = (UITextField *)PDFindLabelled(w, [q objectForKey:@"label"] ?: @"");
		if ([tf isKindOfClass:[UITextField class]]) {
			[tf becomeFirstResponder];
			tf.text = [q objectForKey:@"text"] ?: @"";
			if (![[q objectForKey:@"keep"] boolValue]) [tf resignFirstResponder];
		}
	} else if ([cmd isEqualToString:@"lane"]) {   // developer aid: on the CANVAS page, open slot n's (1-based) material/colour picker
		PDCardPage *pg = (PDCardPage *)PDFindView(self.window, [PDCardPage class]);
		if ([pg.kind isEqualToString:@"canvas"]) [pg editLane:[[q objectForKey:@"slot"] intValue] - 1];
	} else if ([cmd isEqualToString:@"drag"]) {   // developer aid: drag on the Design canvas, screen points x0,y0 -> x1,y1
		PDDesignView *dv = (PDDesignView *)PDFindView(self.window, [PDDesignView class]);
		UIView *root = self.window.rootViewController.view;
		CGPoint a = [dv convertPoint:CGPointMake([[q objectForKey:@"x0"] floatValue], [[q objectForKey:@"y0"] floatValue]) fromView:root];
		CGPoint b = [dv convertPoint:CGPointMake([[q objectForKey:@"x1"] floatValue], [[q objectForKey:@"y1"] floatValue]) fromView:root];
		[dv devDragFrom:a to:b hold:[[q objectForKey:@"hold"] intValue] != 0 release:[[q objectForKey:@"release"] intValue] != 0];
	} else if ([cmd isEqualToString:@"zoom"]) {   // developer aid: zoom every visible 3D view (1 = fit the part)
		NSMutableArray *todo = [NSMutableArray arrayWithObject:self.window];
		while ([todo count]) {
			UIView *v = [todo lastObject]; [todo removeLastObject];
			if (v.hidden) continue;
			if ([v respondsToSelector:@selector(resetView)] && [v respondsToSelector:@selector(redraw)]) {
				[v setValue:[NSNumber numberWithFloat:[[q objectForKey:@"z"] floatValue] ?: 1] forKey:@"zoom"];
				[v performSelector:@selector(redraw)];
			}
			[todo addObjectsFromArray:v.subviews];
		}
	} else if ([cmd isEqualToString:@"bench"]) {   // developer aid: spin the job page's 3D view, log fps
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			PDToolpathView *tv = (PDToolpathView *)PDFindView(self.window, [PDToolpathView class]);
			[tv benchmark:4 done:^(double fps) {
				NSString *line = [NSString stringWithFormat:@"bench: %.1f fps\n", fps];
				NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/printdeck-toolpath.log"];
				[fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
			}];
		});
	} else if ([cmd isEqualToString:@"snapshot"]) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			UIView *v = self.window.rootViewController.view;
			UIGraphicsBeginImageContextWithOptions(v.bounds.size, YES, 1.0);
			[v.layer renderInContext:UIGraphicsGetCurrentContext()];
			PDDrawGLViews(v, v);  // renderInContext can't see OpenGL content
			// Popovers and alerts sit beside the root view in the window (rotated like it): draw them on top.
			for (UIView *w in [[UIApplication sharedApplication] windows])
				for (UIView *o in w.subviews) {
					if (o == v || o.hidden || o.alpha < 0.01) continue;
					CGRect r = [v convertRect:o.bounds fromView:o];
					CGContextRef ctx = UIGraphicsGetCurrentContext();
					CGContextSaveGState(ctx);
					CGContextTranslateCTM(ctx, r.origin.x, r.origin.y);
					[o.layer renderInContext:ctx];
					CGContextRestoreGState(ctx);
				}
			UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
			UIGraphicsEndImageContext();
			[UIImagePNGRepresentation(img) writeToFile:@"/tmp/printdeck-snapshot.png" atomically:YES];
		});
	}
	return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application { [self.main appDidResignActive]; }

- (void)applicationDidBecomeActive:(UIApplication *)application {
	application.idleTimerDisabled = YES;
	[self.main appDidBecomeActive];
}

@end
