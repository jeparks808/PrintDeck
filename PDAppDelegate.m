#import "PDAppDelegate.h"
#import "PDMainViewController.h"
#import "PDPrinter.h"
#import <QuartzCore/QuartzCore.h>

@interface PDAppDelegate ()
@property (nonatomic, strong) PDMainViewController *main;
@end

@implementation PDAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	[application setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];
	application.idleTimerDisabled = YES; // a printer panel should stay on
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
// printdeck://snapshot                                save the screen to /tmp/printdeck-snapshot.png (developer aid)
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)source annotation:(id)annotation {
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
	} else if ([cmd isEqualToString:@"snapshot"]) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			UIView *v = self.window.rootViewController.view;
			UIGraphicsBeginImageContextWithOptions(v.bounds.size, YES, 1.0);
			[v.layer renderInContext:UIGraphicsGetCurrentContext()];
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
