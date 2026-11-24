#import "PDPrinter.h"
#import "PDWebSocket.h"
#import "PDUtil.h"
#import <QuartzCore/QuartzCore.h>
#import "PDMesh.h"

NSString *const PDPrinterDidUpdateNotification = @"PDPrinterDidUpdateNotification";
NSString *const PDPrinterConnectionNotification = @"PDPrinterConnectionNotification";
NSString *const PDPrinterFilesNotification = @"PDPrinterFilesNotification";
NSString *const PDPrinterEventNotification = @"PDPrinterEventNotification";
NSString *const PDPrinterGraphNotification = @"PDPrinterGraphNotification";

static const NSUInteger PDHistoryLen = 300;
static const NSUInteger PDGraphLen = (NSUInteger)PD_GWINDOW + 4;  // samples kept for the smooth graphs

@interface PDPrinter () <PDWebSocketDelegate>
@property (nonatomic, readwrite, copy) NSString *host, *lastError, *videoURL;
@property (nonatomic, readwrite) int port, videoPort;
@property (nonatomic, readwrite) BOOL connected;
@property (nonatomic, readwrite, strong) NSDictionary *status, *attributes, *lastTask;
@property (nonatomic, readwrite) double cosmosPrintTime;
@property (nonatomic, readwrite, strong) NSArray *files;
@property (nonatomic, strong) NSMutableArray *nozzleH, *bedH, *chamberH;
@property (nonatomic, strong) NSMutableArray *nozzleG, *bedG, *chamberG;  // per-second, for the smooth graphs
@property (nonatomic, readwrite) double graphTime;
@property (nonatomic, strong) NSTimer *graphTimer;
@property (nonatomic, strong) PDWebSocket *ws;
@property (nonatomic, copy) NSString *mainboardID;
@property (nonatomic, strong) NSTimer *pollTimer, *retryTimer;
@property (nonatomic, assign) CFAbsoluteTime lastMessage, lastSample;
@property (nonatomic, assign) int prevPrintStatus;
@property (nonatomic, assign) BOOL pauseRequestedHere, stopRequestedHere, haveStatus;
@property (nonatomic, assign) PDJobState awaitingOutcome; // PDJobComplete/PDJobStopped while waiting for the history entry
@property (nonatomic, assign) int outcomeTries;
@property (nonatomic, copy) NSString *taskBeforeOutcome, *requestedTask;
@property (nonatomic, strong) NSMutableArray *videoWaiters;
@property (nonatomic, readwrite, strong) NSDictionary *fileDetail;
@property (nonatomic, readwrite, copy) NSString *fileDetailPath;
@property (nonatomic, copy) NSString *pendingDetailPath;   // the 260 reply doesn't name the file
@property (nonatomic, assign) NSUInteger videoRequestGen;
@property (nonatomic, readwrite, strong) NSDictionary *canvas;
@property (nonatomic, assign) int pollCount, lastAms;
// COSMOS / Moonraker
@property (nonatomic, readwrite) BOOL cosmos;
@property (nonatomic, assign) BOOL modeKnown;
@property (nonatomic, assign) NSUInteger probeGen;
@property (nonatomic, readwrite) int moonrakerPort;
@property (nonatomic, readwrite, copy) NSString *klippyState, *klippyMessage;
@property (nonatomic, readwrite, copy) NSString *auxFanName, *chamberFanName, *caseLedName;
@property (nonatomic, copy) NSString *chamberSensor, *jobMetaFile;
@property (nonatomic, strong) NSArray *mrObjects, *lanes;
@property (nonatomic, strong) NSMutableDictionary *mr, *rpcWaiting;
@property (nonatomic, strong) NSDictionary *jobMeta;
@property (nonatomic, assign) int rpcSeq;
@property (nonatomic, assign) BOOL discovering;
@end

@implementation PDPrinter

+ (PDPrinter *)shared {
	static PDPrinter *p;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ p = [[PDPrinter alloc] init]; });
	return p;
}

// Kept on the iPad once read, so the figure still shows while the printer runs Elegoo's firmware again.
static NSString *const PDEarlierPrintTimeKey = @"PDStockPrintTime";

+ (double)earlierPrintTime { return MAX(0, [[NSUserDefaults standardUserDefaults] doubleForKey:PDEarlierPrintTimeKey]); }

// COSMOS keeps Elegoo's /board-resource/sysconf.cfg and serves that folder as Moonraker's "logs" root:
// read its "cumulative_time : <seconds>" line.
- (void)fetchStockPrintTime {
	if (!self.cosmos) return;
	NSURLRequest *req = [NSURLRequest requestWithURL:[self moonrakerURL:@"/server/files/logs/sysconf.cfg"]
		cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
	[NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
		NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)r statusCode] : 0;
		NSString *t = code == 200 && d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
		for (NSString *line in [t componentsSeparatedByString:@"\n"]) {
			if (![line hasPrefix:@"cumulative_time"]) continue;
			NSRange c = [line rangeOfString:@":"];
			if (c.location == NSNotFound) break;
			double secs = [[line substringFromIndex:c.location + 1] doubleValue];
			if (secs <= 0 || secs == [PDPrinter earlierPrintTime]) break;
			[[NSUserDefaults standardUserDefaults] setDouble:secs forKey:PDEarlierPrintTimeKey];
			[[NSUserDefaults standardUserDefaults] synchronize];
			[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self];
			break;
		}
	}];
}

- (double)lifetimePrintTime {
	double before = [PDPrinter earlierPrintTime], klipper = self.cosmos ? self.cosmosPrintTime : -1;
	if (klipper < 0) return before > 0 ? before : -1;
	return before + klipper;
}

- (id)init {
	if ((self = [super init])) {
		_nozzleH = [NSMutableArray array];
		_bedH = [NSMutableArray array];
		_chamberH = [NSMutableArray array];
		_nozzleG = [NSMutableArray array];
		_bedG = [NSMutableArray array];
		_chamberG = [NSMutableArray array];
		_prevPrintStatus = -1;
		_cosmosPrintTime = -1;
		_awaitingOutcome = PDJobUnknown;
		_videoWaiters = [NSMutableArray array];
		_graphTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(sampleGraph) userInfo:nil repeats:YES];
		[[NSRunLoop mainRunLoop] addTimer:_graphTimer forMode:NSRunLoopCommonModes];
	}
	return self;
}

- (NSArray *)nozzleHistory { return [self.nozzleH copy]; }
- (NSArray *)bedHistory { return [self.bedH copy]; }
- (NSArray *)chamberHistory { return [self.chamberH copy]; }
- (NSArray *)nozzleGraph { return [self.nozzleG copy]; }
- (NSArray *)bedGraph { return [self.bedG copy]; }
- (NSArray *)chamberGraph { return [self.chamberG copy]; }

// One per-second sample of the three temperatures for the smooth graphs. A gap (NSNull) while disconnected or
// before the first status, so the graph shows the break instead of a flat line.
- (void)sampleGraph {
	NSDictionary *st = self.status;
	BOOL live = self.connected && st != nil;
	id n = live && PDNum(st, @"TempOfNozzle") ? PDNum(st, @"TempOfNozzle") : [NSNull null];
	id b = live && PDNum(st, @"TempOfHotbed") ? PDNum(st, @"TempOfHotbed") : [NSNull null];
	id c = live && PDNum(st, @"TempOfBox") ? PDNum(st, @"TempOfBox") : [NSNull null];
	[self push:n onto:self.nozzleG cap:PDGraphLen];
	[self push:b onto:self.bedG cap:PDGraphLen];
	[self push:c onto:self.chamberG cap:PDGraphLen];
	self.graphTime = CACurrentMediaTime();
	[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterGraphNotification object:self];
}

- (void)push:(id)v onto:(NSMutableArray *)arr cap:(NSUInteger)cap {
	[arr addObject:v ?: [NSNull null]];
	while ([arr count] > cap) [arr removeObjectAtIndex:0];
}

#pragma mark - Connection

- (void)connectToHost:(NSString *)host port:(int)port videoPort:(int)videoPort {
	BOOL same = [host isEqualToString:self.host] && port == self.port;
	self.host = host;
	self.port = port > 0 ? port : 3030;
	self.videoPort = videoPort > 0 ? videoPort : 3031;
	if (!same) {
		self.status = nil;
		self.canvas = nil;
		self.lastAms = 0;
		self.attributes = nil;
		self.files = nil;
		self.lastTask = nil;
		self.cosmosPrintTime = -1;
		self.mainboardID = nil;
		self.haveStatus = NO;
		self.prevPrintStatus = -1;
		self.modeKnown = NO;
		self.cosmos = NO;
		self.mrObjects = nil;
		self.mr = nil;
		self.jobMeta = nil; self.jobMetaFile = nil;
		self.klippyState = nil; self.klippyMessage = nil;
		[self.nozzleH removeAllObjects];
		[self.bedH removeAllObjects];
		[self.chamberH removeAllObjects];
		[self.nozzleG removeAllObjects];
		[self.bedG removeAllObjects];
		[self.chamberG removeAllObjects];
	}
	self.videoURL = self.cosmos ? [[self moonrakerURL:@"/webcam/?action=stream"] absoluteString] : [NSString stringWithFormat:@"http://%@:%d/video", self.host, self.videoPort];
	[self reconnectNow];
}

- (void)reconnectNow {
	[self.retryTimer invalidate];
	self.retryTimer = nil;
	[self.ws close];
	self.ws = nil;
	if (!self.host) return;
	if (!self.modeKnown) { [self probeMode]; return; }
	[self openSocket];
}

- (void)openSocket {
	[self.rpcWaiting removeAllObjects];
	self.discovering = NO;
	self.ws = [[PDWebSocket alloc] initWithHost:self.host port:self.cosmos ? self.moonrakerPort : self.port path:@"/websocket"];
	self.ws.delegate = self;
	[self.ws open];
}

// Which firmware? Moonraker answers GET /server/info with JSON; the stock/OpenCentauri web server on port 80
// doesn't. No answer at all: try SDCP now and ask again on the next reconnect.
- (void)probeMode {
	NSUInteger gen = ++self.probeGen;
	int mp = self.port == 3030 ? 80 : self.port;
	NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%d/server/info", self.host, mp]];
	NSURLRequest *req = [NSURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];
	[NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
		if (gen != self.probeGen || self.ws) return;
		NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)r statusCode] : 0;
		id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
		NSDictionary *res = [j isKindOfClass:[NSDictionary class]] ? PDDict(j, @"result") : nil;
		BOOL moon = code == 200 && (PDStr(res, @"klippy_state") || PDArr(res, @"components"));
		if (code == 0 && self.host) { [self openSocket]; return; }   // no answer: keep the mode we had, ask again next time
		self.cosmos = moon;
		if (!moon) self.cosmosPrintTime = -1;
		self.modeKnown = moon || code > 0;
		if (moon) {
			self.moonrakerPort = mp;
			self.videoURL = [[self moonrakerURL:@"/webcam/?action=stream"] absoluteString];
			// The bed mesh comes straight from Klipper: no meshbridge on COSMOS. Keep the SDCP printer's helper URL
			// to put back when an SDCP printer is connected again.
			NSString *cur = [PDMeshSource shared].helperURL;
			if ([cur length] && [cur rangeOfString:@"/printer/objects/query"].location == NSNotFound)
				[[NSUserDefaults standardUserDefaults] setObject:cur forKey:@"PDMeshHelperURLSDCP"];
			[PDMeshSource shared].helperURL = [[self moonrakerURL:@"/printer/objects/query?bed_mesh"] absoluteString];
			NSLog(@"PrintDeck: %@ runs COSMOS (Moonraker on port %d)", self.host, mp);
			[self fetchStockPrintTime];
		} else {
			self.videoURL = [NSString stringWithFormat:@"http://%@:%d/video", self.host, self.videoPort];
			if (code > 0 && [[PDMeshSource shared].helperURL rangeOfString:@"/printer/objects/query"].location != NSNotFound)
				[PDMeshSource shared].helperURL = [[NSUserDefaults standardUserDefaults] stringForKey:@"PDMeshHelperURLSDCP"];
		}
		[self openSocket];
	}];
}

- (void)disconnect {
	[self.pollTimer invalidate];
	self.pollTimer = nil;
	[self.retryTimer invalidate];
	self.retryTimer = nil;
	self.probeGen++;
	[self.ws close];
	self.ws = nil;
	[self setConnectedState:NO error:nil];
}

- (void)setConnectedState:(BOOL)c error:(NSString *)err {
	BOOL changed = (c != self.connected) || (err && ![err isEqualToString:self.lastError]);
	self.connected = c;
	self.lastError = err;
	if (changed) [[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterConnectionNotification object:self];
}

- (void)webSocketDidOpen:(PDWebSocket *)ws {
	self.lastMessage = CFAbsoluteTimeGetCurrent();
	[self setConnectedState:YES error:nil];
	if (self.cosmos) self.mrObjects = nil;   // discover the object names again (the config may have changed)
	[self send:0 data:nil];
	[self send:1 data:nil];
	[self send:320 data:nil]; // history -> last job card
	[self refreshFiles];
	[self refreshCanvas];
	[self.pollTimer invalidate];
	self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)webSocket:(PDWebSocket *)ws didCloseWithReason:(NSString *)reason {
	if (ws != self.ws) return;
	self.ws = nil;
	[self.pollTimer invalidate];
	self.pollTimer = nil;
	[self setConnectedState:NO error:reason];
	self.modeKnown = NO;   // ask again before reconnecting: the printer may have been reflashed (SDCP <-> COSMOS)
	[self scheduleRetry];
}

- (void)scheduleRetry {
	[self.retryTimer invalidate];
	self.retryTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(reconnectNow) userInfo:nil repeats:NO];
}

- (void)poll {
	if (CFAbsoluteTimeGetCurrent() - self.lastMessage > (self.cosmos ? 10 : 8)) {
		[self.ws close];
		[self webSocket:self.ws didCloseWithReason:@"printer stopped answering"];
		return;
	}
	[self send:0 data:nil];
	self.pollCount++;
	if (self.pollCount % (self.isBusy ? 2 : 5) == 0) [self refreshCanvas];
}

- (void)refreshCanvas { [self send:324 data:nil]; }

- (void)send:(int)cmd data:(NSDictionary *)data {
	if (!self.ws.isOpen) return;
	if (self.cosmos) { [self cosmosCommand:cmd data:data]; return; }
	CFUUIDRef u = CFUUIDCreate(NULL);
	NSString *rid = [[(__bridge_transfer NSString *)CFUUIDCreateString(NULL, u) stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
	CFRelease(u);
	NSDictionary *inner = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithInt:cmd], @"Cmd",
		data ?: [NSDictionary dictionary], @"Data",
		rid, @"RequestID",
		self.mainboardID ?: @"", @"MainboardID",
		[NSNumber numberWithLongLong:(long long)([[NSDate date] timeIntervalSince1970] * 1000)], @"TimeStamp",
		[NSNumber numberWithInt:1], @"From", nil];
	NSMutableDictionary *msg = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"", @"Id", inner, @"Data", nil];
	if (self.mainboardID) [msg setObject:[NSString stringWithFormat:@"sdcp/request/%@", self.mainboardID] forKey:@"Topic"];
	NSData *json = [NSJSONSerialization dataWithJSONObject:msg options:0 error:NULL];
	if (json) [self.ws sendText:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
}

#pragma mark - Incoming

- (void)webSocket:(PDWebSocket *)ws didReceiveText:(NSString *)text {
	self.lastMessage = CFAbsoluteTimeGetCurrent();
	id m = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
	if (![m isKindOfClass:[NSDictionary class]]) return;
	if (self.cosmos) { [self cosmosReceive:m]; return; }
	NSString *topic = PDStr(m, @"Topic") ?: @"";
	NSString *mb = PDStr(m, @"MainboardID") ?: PDStr(PDDict(m, @"Data"), @"MainboardID");
	if ([mb length]) self.mainboardID = mb;

	NSDictionary *st = PDDict(m, @"Status");
	if (st) { [self handleStatus:st]; return; }
	NSDictionary *attr = PDDict(m, @"Attributes");
	if (attr) {
		self.attributes = attr;
		[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self];
		return;
	}
	if ([topic hasPrefix:@"sdcp/response/"] || PDNum(PDDict(m, @"Data"), @"Cmd")) {
		NSDictionary *d = PDDict(m, @"Data");
		[self handleResponse:[PDNum(d, @"Cmd") intValue] data:PDDict(d, @"Data")];
	}
}

- (void)handleResponse:(int)cmd data:(NSDictionary *)d {
	int ack = [PDNum(d, @"Ack") intValue];
	switch (cmd) {
		case 258: {
			NSArray *list = PDArr(d, @"FileList");
			if (!list) return;
			NSMutableArray *files = [NSMutableArray array];
			for (id f in list) if ([f isKindOfClass:[NSDictionary class]] && [PDNum(f, @"type") intValue] == 1) [files addObject:f];
			[files sortUsingComparator:^NSComparisonResult(id a, id b) {
				return [PDNum(b, @"CreateTime") ?: @0 compare:PDNum(a, @"CreateTime") ?: @0];
			}];
			self.files = files;
			[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterFilesNotification object:self];
			break;
		}
		case 320: {
			NSArray *ids = PDArr(d, @"HistoryData");
			if ([ids count]) [self send:321 data:[NSDictionary dictionaryWithObject:[NSArray arrayWithObject:[ids objectAtIndex:0]] forKey:@"Id"]];
			break;
		}
		case 321: {
			NSArray *list = PDArr(d, @"HistoryDetailList");
			if ([list count] && [[list objectAtIndex:0] isKindOfClass:[NSDictionary class]]) {
				NSDictionary *prev = self.lastTask;
				self.lastTask = [list objectAtIndex:0];
				[self maybeReportTaskOutcome:prev];
				[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self];
			}
			break;
		}
		case 260: {
			NSDictionary *info = PDDict(d, @"FileInfo");
			if (info && self.pendingDetailPath) {
				self.fileDetail = info;
				self.fileDetailPath = self.pendingDetailPath;
				[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self];
			}
			break;
		}
		case 324: {
			if (ack != 0 || !PDArr(d, @"canvas_list")) break;
			NSMutableDictionary *c = [d mutableCopy];
			[c removeObjectForKey:@"Ack"];
			if (![c isEqualToDictionary:self.canvas]) {
				self.canvas = c;
				[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self];
			}
			break;
		}
		case 386:
			if (ack != 0) NSLog(@"PrintDeck: video stream enable returned %d", ack);
			[self flushVideoWaiters];
			break;
		case 128: case 129: case 130: case 131: case 401: case 402: case 403:
			if (ack != 0) [self postEvent:@"error" title:@"Printer refused the command" detail:[self ackText:cmd ack:ack]];
			break;
		default: break;
	}
}

- (NSString *)ackText:(int)cmd ack:(int)ack {
	if (cmd == 128) {
		switch (ack) {
			case 1: return @"The printer is busy.";
			case 2: return @"File not found.";
			case 3: return @"File check failed.";
			case 4: return @"File read failed.";
		}
	}
	if (cmd == 401 || cmd == 402) return @"Home the axes first, or the move is out of range.";
	return [NSString stringWithFormat:@"Command %d returned code %d.", cmd, ack];
}

- (void)handleStatus:(NSDictionary *)st {
	self.status = st;
	int ams = PDNum(st, @"AmsConnectStatus") ? [PDNum(st, @"AmsConnectStatus") intValue] : -1;
	if (ams != self.lastAms) { self.lastAms = ams; [self refreshCanvas]; }   // plugged in or out: ask again now
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - self.lastSample >= 4 || ![self.nozzleH count]) {
		self.lastSample = now;
		[self push:PDNum(st, @"TempOfNozzle") onto:self.nozzleH];
		[self push:PDNum(st, @"TempOfHotbed") onto:self.bedH];
		[self push:PDNum(st, @"TempOfBox") onto:self.chamberH];
	}
	// A job we have no details for yet (started on the printer's screen, say): fetch them for the thumbnail.
	NSString *tid = PDStr(PDDict(st, @"PrintInfo"), @"TaskId");
	if ([tid length] && ![tid isEqualToString:PDStr(self.lastTask, @"TaskId")] && ![tid isEqualToString:self.requestedTask]) {
		self.requestedTask = tid;
		[self send:321 data:[NSDictionary dictionaryWithObject:[NSArray arrayWithObject:tid] forKey:@"Id"]];
	}
	int ps = [PDNum(PDDict(st, @"PrintInfo"), @"Status") intValue];
	if (self.haveStatus && ps != self.prevPrintStatus) [self printStatusChangedFrom:self.prevPrintStatus to:ps];
	self.prevPrintStatus = ps;
	self.haveStatus = YES;
	[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self];
}

- (void)push:(NSNumber *)v onto:(NSMutableArray *)a {
	if (!v) return;
	[a addObject:v];
	if ([a count] > PDHistoryLen) [a removeObjectAtIndex:0];
}

#pragma mark - Events (finished / paused / stopped)

+ (PDJobState)stateForCode:(int)c {
	switch (c) {
		case 0: return PDJobIdle;
		case 1: case 15: case 16: case 18: case 19: case 20: case 21: return PDJobPreparing;
		case 13: case 2: case 3: case 4: return PDJobPrinting;
		case 5: return PDJobPausing;
		case 6: return PDJobPaused;
		case 7: return PDJobStopping;
		case 8: case 14: return PDJobStopped;
		case 9: return PDJobComplete;
		case 10: return PDJobChecking;
		case 12: return PDJobRecovery;
	}
	return PDJobUnknown;
}

- (void)printStatusChangedFrom:(int)from to:(int)to {
	PDJobState a = [PDPrinter stateForCode:from], b = [PDPrinter stateForCode:to];
	if ((b == PDJobComplete || b == PDJobStopped) && a != b) {
		// The history entry has the outcome (and the reason, if it failed). The printer writes it a moment
		// after the status flips, so ask a little later, and again if it isn't there yet.
		self.awaitingOutcome = b;
		self.outcomeTries = 0;
		self.taskBeforeOutcome = PDStr(self.lastTask, @"TaskId");
		[self performSelector:@selector(requestOutcome) withObject:nil afterDelay:2.0];
		[self refreshFiles];
	}
	if (b == PDJobPaused && a != PDJobPaused) {
		if (!self.pauseRequestedHere)
			[self postEvent:@"paused" title:@"Print paused" detail:@"The printer paused by itself. Check the filament."];
		self.pauseRequestedHere = NO;
	}
}

- (void)requestOutcome { if (self.awaitingOutcome != PDJobUnknown) [self send:320 data:nil]; }

- (void)maybeReportTaskOutcome:(NSDictionary *)prev {
	PDJobState how = self.awaitingOutcome;
	if (how != PDJobComplete && how != PDJobStopped) return;
	NSDictionary *t = self.lastTask;
	double end = [PDNum(t, @"EndTime") doubleValue];
	BOOL fresh = end > 0 && ![PDStr(t, @"TaskId") isEqualToString:self.taskBeforeOutcome ?: @""];
	if (!fresh && [PDStr(t, @"TaskId") isEqualToString:PDStr(prev, @"TaskId")] && [PDNum(prev, @"EndTime") doubleValue] != end) fresh = end > 0;
	if (!fresh && ++self.outcomeTries < 4) {
		[self performSelector:@selector(requestOutcome) withObject:nil afterDelay:3.0];
		return;
	}
	self.awaitingOutcome = PDJobUnknown;
	NSString *name = PDPrettyFileName(PDStr(t, @"TaskName") ?: PDStr([self printInfo], @"Filename"));
	double begin = [PDNum(t, @"BeginTime") doubleValue];
	int reason = [PDNum(t, @"ErrorStatusReason") intValue];
	if (how == PDJobComplete && reason == 0) {
		NSString *took = (fresh && begin > 0) ? PDDuration(end - begin) : PDDuration(self.elapsed);
		[self postEvent:@"finished" title:@"Print finished" detail:[NSString stringWithFormat:@"%@, took %@", name, took]];
	} else if (self.stopRequestedHere && reason == 0) {
		[self postEvent:@"stopped" title:@"Print stopped" detail:name];
	} else {
		NSString *why = PDStr(t, @"PDReasonText") ?: (reason ? [PDPrinter reasonText:reason] : @"stopped on the printer");
		[self postEvent:@"failed" title:@"Print stopped" detail:[NSString stringWithFormat:@"%@: %@", name, why]];
	}
	self.stopRequestedHere = NO;
}

+ (NSString *)reasonText:(int)r {
	switch (r) {
		case 0: return @"stopped";
		case 1: return @"temperature error";
		case 3: return @"filament ran out";
		case 6: return @"filament jam";
		case 13: case 14: case 23: return @"homing failed";
		case 25: return @"camera error";
		case 33: case 34: return @"temperature sensor offline";
	}
	return [NSString stringWithFormat:@"error %d", r];
}

- (void)postEvent:(NSString *)kind title:(NSString *)title detail:(NSString *)detail {
	[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterEventNotification object:self
		userInfo:[NSDictionary dictionaryWithObjectsAndKeys:kind, @"kind", title, @"title", detail ?: @"", @"detail", nil]];
}

#pragma mark - Readings

- (NSDictionary *)printInfo { return PDDict(self.status, @"PrintInfo"); }

- (PDJobState)jobState {
	if (!self.status) return PDJobUnknown;
	return [PDPrinter stateForCode:[PDNum([self printInfo], @"Status") intValue]];
}

- (NSString *)jobStateText {
	if (!self.connected) return @"Offline";
	if (!self.status) return @"Connecting…";
	if (self.cosmos && [self.klippyState length] && ![self.klippyState isEqualToString:@"ready"])
		return [self.klippyState isEqualToString:@"startup"] ? @"Klipper starting" : [NSString stringWithFormat:@"Klipper %@", self.klippyState];
	int c = [PDNum([self printInfo], @"Status") intValue];
	switch (c) {
		case 1: return @"Homing";
		case 16: return @"Heating";
		case 20: return @"Leveling bed";
	}
	switch (self.jobState) {
		case PDJobIdle: {
			NSArray *cs = PDArr(self.status, @"CurrentStatus");
			if ([cs containsObject:[NSNumber numberWithInt:5]]) return @"Leveling bed";
			if ([cs containsObject:[NSNumber numberWithInt:3]]) return @"Calibrating";
			if ([cs containsObject:[NSNumber numberWithInt:2]]) return @"Receiving file";
			return @"Ready";
		}
		case PDJobPreparing: return @"Preparing";
		case PDJobPrinting: return @"Printing";
		case PDJobPausing: return @"Pausing…";
		case PDJobPaused: return @"Paused";
		case PDJobStopping: return @"Stopping…";
		case PDJobStopped: return @"Stopped";
		case PDJobComplete: return @"Finished";
		case PDJobChecking: return @"Checking file";
		case PDJobRecovery: return @"Recovering";
		default: return [NSString stringWithFormat:@"Status %d", c];
	}
}

- (BOOL)machineBusy {
	if (self.cosmos || self.isBusy) return NO;
	for (id c in PDArr(self.status, @"CurrentStatus"))   // 0 idle, 1 printing (covered by isBusy), 2 receiving a file
		if ([c isKindOfClass:[NSNumber class]] && [c intValue] > 2) return YES;
	return NO;
}

// Refuses (with an alert) while the machine is busy outside a job.
- (BOOL)refuseWhileMachineBusy {
	if (!self.machineBusy) return NO;
	[self postEvent:@"error" title:@"Printer is busy" detail:[NSString stringWithFormat:@"%@ — wait until it's done.", self.jobStateText]];
	return YES;
}

- (BOOL)isBusy {
	PDJobState s = self.jobState;
	return s == PDJobPreparing || s == PDJobPrinting || s == PDJobPausing || s == PDJobPaused ||
		s == PDJobStopping || s == PDJobChecking || s == PDJobRecovery;
}

- (double)progress {
	if (self.jobState == PDJobComplete) return 1;
	double p = [PDNum([self printInfo], @"Progress") doubleValue] / 100.0;
	if (p <= 0) {
		double cl = [PDNum([self printInfo], @"CurrentLayer") doubleValue], tl = [PDNum([self printInfo], @"TotalLayer") doubleValue];
		if (tl > 0 && self.isBusy) p = cl / tl;
	}
	return MAX(0, MIN(1, p));
}

- (double)elapsed { return [PDNum([self printInfo], @"CurrentTicks") doubleValue]; }

// The slicer's estimate (TotalTicks) can be far off (a 2h18m slice took 3h41m on this printer), so blend it
// with a progress-based extrapolation that takes over as the print goes on.
- (double)remaining {
	double cur = self.elapsed, total = [PDNum([self printInfo], @"TotalTicks") doubleValue], p = self.progress;
	double slicer = MAX(0, total - cur);
	if (p < 0.02 || cur < 60) return slicer;
	double extrap = cur * (1 - p) / p;
	double w = MIN(1.0, p / 0.25);
	return (1 - w) * slicer + w * extrap;
}

- (NSString *)printerName {
	return PDStr(self.attributes, @"Name") ?: PDStr(self.attributes, @"MachineName") ?: @"Printer";
}

#pragma mark - Commands

- (void)pause { self.pauseRequestedHere = YES; [self send:129 data:nil]; [self send:0 data:nil]; }
- (void)resume { [self send:131 data:nil]; [self send:0 data:nil]; }
- (void)stop { self.stopRequestedHere = YES; [self send:130 data:nil]; [self send:0 data:nil]; }

- (void)startFile:(NSString *)path { [self startFile:path plate:0 timelapse:NO level:NO]; }

- (void)startFile:(NSString *)path plate:(int)plate timelapse:(BOOL)timelapse level:(BOOL)level {
	if ([self refuseWhileMachineBusy]) return;
	// The full start command, as OrcaSlicer's ElegooLink sends it. A partial one ({Filename, StartLayer} only)
	// crashed a CC1 with a CANVAS attached (firmware hung, all four CANVAS lights blinking red, no job logged).
	// Calibration_switch 1 = level the bed before the print, PrintPlatformType 0 = PTE (textured) plate,
	// 1 = smooth plate, Tlp_Switch 1 = time-lapse. Filename is the "/local/<name>" path the file list gives.
	NSNumber *zero = [NSNumber numberWithInt:0];
	[self send:128 data:[NSDictionary dictionaryWithObjectsAndKeys:path, @"Filename", zero, @"StartLayer",
		[NSNumber numberWithInt:level ? 1 : 0], @"Calibration_switch", [NSNumber numberWithInt:plate == 1 ? 1 : 0], @"PrintPlatformType",
		[NSNumber numberWithInt:timelapse ? 1 : 0], @"Tlp_Switch", nil]];
	[self send:0 data:nil];
}

- (void)edit:(NSDictionary *)d { [self send:403 data:d]; [self send:0 data:nil]; }
- (void)setNozzleTarget:(int)c { [self edit:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:c] forKey:@"TempTargetNozzle"]]; }
- (void)setBedTarget:(int)c { [self edit:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:c] forKey:@"TempTargetHotbed"]]; }
- (void)setSpeedPercent:(int)pct { [self edit:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:pct] forKey:@"PrintSpeedPct"]]; }

- (void)setFan:(NSString *)fan percent:(int)pct {
	// The web UI sends all three fans together; do the same so the others stay where they are.
	NSMutableDictionary *fans = [NSMutableDictionary dictionary];
	NSDictionary *cur = PDDict(self.status, @"CurrentFanSpeed");
	for (NSString *k in [NSArray arrayWithObjects:@"ModelFan", @"AuxiliaryFan", @"BoxFan", nil])
		[fans setObject:PDNum(cur, k) ?: [NSNumber numberWithInt:0] forKey:k];
	[fans setObject:[NSNumber numberWithInt:pct] forKey:fan];
	[self edit:[NSDictionary dictionaryWithObject:fans forKey:@"TargetFanSpeed"]];
}

- (void)setLight:(BOOL)on {
	NSMutableDictionary *ls = [NSMutableDictionary dictionaryWithDictionary:PDDict(self.status, @"LightStatus") ?: [NSDictionary dictionary]];
	[ls setObject:[NSNumber numberWithInt:on ? 1 : 0] forKey:@"SecondLight"];
	if (![ls objectForKey:@"RgbLight"]) [ls setObject:[NSArray arrayWithObjects:@0, @0, @0, nil] forKey:@"RgbLight"];
	[self edit:[NSDictionary dictionaryWithObject:ls forKey:@"LightStatus"]];
}

- (void)home:(NSString *)axes { if ([self refuseWhileMachineBusy]) return; [self send:402 data:[NSDictionary dictionaryWithObject:axes forKey:@"Axis"]]; }

- (void)jog:(NSString *)axis by:(double)mm {
	if ([self refuseWhileMachineBusy]) return;
	[self send:401 data:[NSDictionary dictionaryWithObjectsAndKeys:axis, @"Axis", [NSNumber numberWithDouble:mm], @"Step", nil]];
}

- (void)enableVideoStream:(void (^)(void))then {
	if (then) [self.videoWaiters addObject:[then copy]];
	if (!self.ws.isOpen) { [self flushVideoWaiters]; return; } // try the camera anyway
	[self send:386 data:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:1] forKey:@"Enable"]];
	NSUInteger gen = ++self.videoRequestGen;
	__weak PDPrinter *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (weakSelf.videoRequestGen == gen) [weakSelf flushVideoWaiters];
	});
}

- (void)flushVideoWaiters {
	self.videoRequestGen++;
	NSArray *w = [self.videoWaiters copy];
	[self.videoWaiters removeAllObjects];
	for (void (^b)(void) in w) b();
}

- (void)refreshAttributes { [self send:1 data:nil]; }

- (void)requestFileDetail:(NSString *)path {
	if (![path length] || [path isEqualToString:self.fileDetailPath]) return;
	self.pendingDetailPath = path;
	[self send:260 data:[NSDictionary dictionaryWithObject:path forKey:@"Url"]];
}

- (NSString *)jobFilePath {
	NSString *f = PDStr([self printInfo], @"Filename");
	if (![f length]) f = PDStr(self.lastTask, @"TaskName");
	if (![f length]) return nil;
	return [f hasPrefix:@"/"] ? f : [@"/local/" stringByAppendingString:f];
}

- (NSURL *)urlForFile:(NSString *)path {
	if (![path length] || !self.host) return nil;
	if (self.cosmos) {
		NSString *rel = [path hasPrefix:@"/local/"] ? [path substringFromIndex:7] : [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
		NSString *enc = (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)rel, NULL,
			CFSTR("?#[]@!$&'()*+,;=% "), kCFStringEncodingUTF8);
		return [self moonrakerURL:[@"/server/files/gcodes/" stringByAppendingString:enc]];
	}
	NSString *origin = [NSString stringWithFormat:@"http://%@", self.host];
	NSURL *thumb = [NSURL URLWithString:PDStr(self.lastTask, @"Thumbnail") ?: @""];
	if ([thumb host]) origin = [thumb port] ? [NSString stringWithFormat:@"%@://%@:%@", [thumb scheme], [thumb host], [thumb port]]
		: [NSString stringWithFormat:@"%@://%@", [thumb scheme], [thumb host]];
	NSString *enc = (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)path, NULL,
		CFSTR("?#[]@!$&'()*+,;=% "), kCFStringEncodingUTF8);
	return [NSURL URLWithString:[origin stringByAppendingString:enc]];
}

- (long long)sizeOfFile:(NSString *)path {
	for (NSDictionary *f in self.files) if ([PDStr(f, @"name") isEqualToString:path]) return [PDNum(f, @"FileSize") longLongValue];
	return 0;
}

- (BOOL)getPosition:(double *)xyz {
	NSString *c = PDStr(self.status, @"CurrenCoord");
	if (![c length]) return NO;
	NSScanner *sc = [NSScanner scannerWithString:c];
	NSCharacterSet *skip = [[NSCharacterSet characterSetWithCharactersInString:@"-.0123456789"] invertedSet];
	for (int i = 0; i < 3; i++) {
		[sc scanCharactersFromSet:skip intoString:NULL];
		if (![sc scanDouble:&xyz[i]]) return NO;
	}
	return YES;
}

- (void)refreshFiles { [self send:258 data:[NSDictionary dictionaryWithObject:@"/local" forKey:@"Url"]]; }

#pragma mark - COSMOS (Klipper + Moonraker)

- (NSURL *)moonrakerURL:(NSString *)pathAndQuery {
	if (!self.host) return nil;
	int port = self.moonrakerPort ?: 80;
	return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@%@%@", self.host,
		port == 80 ? @"" : [NSString stringWithFormat:@":%d", port], pathAndQuery]];
}

static NSString *PDRel(NSString *path) {   // "/local/a.gcode" -> "a.gcode"
	if ([path hasPrefix:@"/local/"]) return [path substringFromIndex:7];
	return [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
}

static NSNumber *PDN(double v) { return [NSNumber numberWithDouble:v]; }
static NSNumber *PDI(long v) { return [NSNumber numberWithLong:v]; }

- (void)rpc:(NSString *)method params:(NSDictionary *)params then:(void (^)(id result, NSString *err))then {
	if (!self.ws.isOpen) return;
	if (!self.rpcWaiting) self.rpcWaiting = [NSMutableDictionary dictionary];
	int i = ++self.rpcSeq;
	if (then) [self.rpcWaiting setObject:[then copy] forKey:[NSNumber numberWithInt:i]];
	NSMutableDictionary *m = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"2.0", @"jsonrpc", method, @"method", [NSNumber numberWithInt:i], @"id", nil];
	if (params) [m setObject:params forKey:@"params"];
	NSData *json = [NSJSONSerialization dataWithJSONObject:m options:0 error:NULL];
	if (json) [self.ws sendText:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
}

- (void)cosmosReceive:(NSDictionary *)m {
	id rid = [m objectForKey:@"id"];
	if ([rid isKindOfClass:[NSNumber class]]) {
		void (^then)(id, NSString *) = [self.rpcWaiting objectForKey:rid];
		if (!then) return;
		[self.rpcWaiting removeObjectForKey:rid];
		NSDictionary *err = PDDict(m, @"error");
		then([m objectForKey:@"result"], err ? (PDStr(err, @"message") ?: @"error") : nil);
		return;
	}
	NSString *method = PDStr(m, @"method");
	if ([method isEqualToString:@"notify_filelist_changed"]) {   // a file added, deleted or moved (here, in Mainsail, on the screen)
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshFiles) object:nil];
		[self performSelector:@selector(refreshFiles) withObject:nil afterDelay:1.0];   // one refresh for a burst of changes
		return;
	}
	if ([method hasPrefix:@"notify_klippy_"]) {   // ready / shutdown / disconnected: look again now
		if (![method isEqualToString:@"notify_klippy_shutdown"]) self.mrObjects = nil;
		[self cosmosCommand:0 data:nil];
	}
}

// Klipper's object names differ between configs, so pick them from printer.objects.list by shape.
- (void)cosmosDiscover {
	if (self.discovering) return;
	self.discovering = YES;
	[self rpc:@"printer.objects.list" params:nil then:^(id res, NSString *err) {
		self.discovering = NO;
		NSArray *objs = PDArr(res, @"objects");
		if (err || ![objs count]) { [self cosmosQueryWebhooks]; return; }   // Klipper not ready: still show why
		NSMutableArray *gen = [NSMutableArray array], *leds = [NSMutableArray array], *lanes = [NSMutableArray array], *temps = [NSMutableArray array];
		for (NSString *o in objs) {
			if (![o isKindOfClass:[NSString class]]) continue;
			if ([o hasPrefix:@"fan_generic "]) [gen addObject:[o substringFromIndex:12]];
			else if ([o hasPrefix:@"led "]) [leds addObject:[o substringFromIndex:4]];
			else if ([o hasPrefix:@"AFC_lane "]) [lanes addObject:[o substringFromIndex:9]];
			else if ([o hasPrefix:@"temperature_sensor "]) [temps addObject:o];
		}
		[lanes sortUsingSelector:@selector(compare:)];
		NSString *(^pick)(NSArray *, NSArray *, NSString *) = ^NSString *(NSArray *names, NSArray *words, NSString *notThis) {
			for (NSString *w in words) for (NSString *n in names)
				if ([[n lowercaseString] rangeOfString:w].location != NSNotFound && ![n isEqualToString:notThis]) return n;
			for (NSString *n in names) if (![n isEqualToString:notThis]) return n;
			return nil;
		};
		self.auxFanName = pick(gen, @[@"aux", @"side"], nil);
		self.chamberFanName = pick(gen, @[@"chamber", @"box", @"case", @"exhaust"], self.auxFanName);
		self.caseLedName = pick(leds, @[@"case", @"chamber", @"light"], nil);
		self.chamberSensor = pick(temps, @[@"chamber", @"box"], nil);
		self.lanes = lanes;
		self.mrObjects = objs;
		[self cosmosQuery];
		[self cosmosCanvas];
	}];
}

- (NSMutableDictionary *)cosmosWant {
	NSMutableDictionary *w = [NSMutableDictionary dictionary];
	for (NSString *o in @[@"webhooks", @"print_stats", @"virtual_sdcard", @"extruder", @"heater_bed", @"fan", @"gcode_move", @"toolhead", @"stepper_enable"])
		if ([self.mrObjects containsObject:o]) [w setObject:[NSNull null] forKey:o];
	if (self.chamberSensor) [w setObject:[NSNull null] forKey:self.chamberSensor];
	if (self.auxFanName) [w setObject:[NSNull null] forKey:[@"fan_generic " stringByAppendingString:self.auxFanName]];
	if (self.chamberFanName) [w setObject:[NSNull null] forKey:[@"fan_generic " stringByAppendingString:self.chamberFanName]];
	if (self.caseLedName) [w setObject:[NSNull null] forKey:[@"led " stringByAppendingString:self.caseLedName]];
	return w;
}

- (void)mergeStatus:(NSDictionary *)st {
	if (!self.mr) self.mr = [NSMutableDictionary dictionary];
	for (NSString *k in st) {
		NSDictionary *v = [st objectForKey:k];
		if (![v isKindOfClass:[NSDictionary class]]) continue;
		NSMutableDictionary *cur = [[self.mr objectForKey:k] mutableCopy] ?: [NSMutableDictionary dictionary];
		[cur addEntriesFromDictionary:v];
		[self.mr setObject:cur forKey:k];
	}
}

- (void)cosmosQueryWebhooks {
	[self rpc:@"printer.objects.query" params:@{@"objects": @{@"webhooks": [NSNull null]}} then:^(id res, NSString *err) {
		if (err) { [self.mr removeObjectForKey:@"webhooks"]; [self noteKlippy:@"disconnected" message:err]; [self buildCosmosStatus]; return; }
		[self mergeStatus:PDDict(res, @"status")];
		[self buildCosmosStatus];
	}];
}

- (void)cosmosQuery {
	if (!self.mrObjects) { [self cosmosDiscover]; return; }
	[self rpc:@"printer.objects.query" params:@{@"objects": [self cosmosWant]} then:^(id res, NSString *err) {
		if (err) { self.mrObjects = nil; [self.mr removeObjectForKey:@"webhooks"]; [self noteKlippy:@"disconnected" message:err]; [self buildCosmosStatus]; return; }
		[self mergeStatus:PDDict(res, @"status")];
		[self buildCosmosStatus];
	}];
}

- (void)noteKlippy:(NSString *)state message:(NSString *)msg {
	NSString *was = self.klippyState;
	self.klippyState = state;
	self.klippyMessage = msg;
	if ([was isEqualToString:@"ready"] && ([state isEqualToString:@"shutdown"] || [state isEqualToString:@"error"]))
		[self postEvent:@"failed" title:@"Klipper shut down" detail:[msg length] ? msg : @"The printer stopped. Fix the cause, then Restart firmware on the Move / Home page."];
}

// Moonraker's objects -> the SDCP "Status" the pages read.
- (void)buildCosmosStatus {
	NSDictionary *wh = [self.mr objectForKey:@"webhooks"];
	if (PDStr(wh, @"state")) [self noteKlippy:PDStr(wh, @"state") message:PDStr(wh, @"state_message")];
	NSDictionary *ext = [self.mr objectForKey:@"extruder"], *bed = [self.mr objectForKey:@"heater_bed"];
	NSDictionary *ps = [self.mr objectForKey:@"print_stats"], *vs = [self.mr objectForKey:@"virtual_sdcard"];
	NSDictionary *gm = [self.mr objectForKey:@"gcode_move"], *th = [self.mr objectForKey:@"toolhead"];
	NSMutableDictionary *st = [NSMutableDictionary dictionary];
	if (PDNum(ext, @"temperature")) { [st setObject:PDNum(ext, @"temperature") forKey:@"TempOfNozzle"]; [st setObject:PDNum(ext, @"target") ?: @0 forKey:@"TempTargetNozzle"]; }
	if (PDNum(bed, @"temperature")) { [st setObject:PDNum(bed, @"temperature") forKey:@"TempOfHotbed"]; [st setObject:PDNum(bed, @"target") ?: @0 forKey:@"TempTargetHotbed"]; }
	NSNumber *box = PDNum([self.mr objectForKey:self.chamberSensor ?: @""], @"temperature");
	if (box) { [st setObject:box forKey:@"TempOfBox"]; [st setObject:@0 forKey:@"TempTargetBox"]; }
	double (^fan)(NSString *) = ^double(NSString *obj) { return round([PDNum([self.mr objectForKey:obj], @"speed") doubleValue] * 100); };
	[st setObject:@{@"ModelFan": PDN(fan(@"fan")),
		@"AuxiliaryFan": PDN(self.auxFanName ? fan([@"fan_generic " stringByAppendingString:self.auxFanName]) : 0),
		@"BoxFan": PDN(self.chamberFanName ? fan([@"fan_generic " stringByAppendingString:self.chamberFanName]) : 0)} forKey:@"CurrentFanSpeed"];
	NSArray *cd = PDArr([self.mr objectForKey:self.caseLedName ? [@"led " stringByAppendingString:self.caseLedName] : @""], @"color_data");
	BOOL lit = NO;
	for (id ch in ([cd count] && [[cd objectAtIndex:0] isKindOfClass:[NSArray class]]) ? [cd objectAtIndex:0] : nil) if ([ch doubleValue] > 0) lit = YES;
	[st setObject:@{@"SecondLight": PDI(lit), @"RgbLight": @[@0, @0, @0]} forKey:@"LightStatus"];
	NSArray *pos = PDArr(th, @"position");
	if ([pos count] >= 3) [st setObject:[NSString stringWithFormat:@"%.2f,%.2f,%.2f", [[pos objectAtIndex:0] doubleValue], [[pos objectAtIndex:1] doubleValue], [[pos objectAtIndex:2] doubleValue]] forKey:@"CurrenCoord"];
	NSArray *ho = PDArr(gm, @"homing_origin");
	if ([ho count] >= 3) [st setObject:[ho objectAtIndex:2] forKey:@"ZOffset"];
	NSDictionary *se = PDDict([self.mr objectForKey:@"stepper_enable"], @"steppers");
	if (se) { BOOL on = NO; for (NSString *k in se) if ([[se objectForKey:k] boolValue]) on = YES; [st setObject:on ? @"on" : @"off" forKey:@"CosmosMotors"]; }
	[st setObject:PDI([self.lanes count] ? 1 : 0) forKey:@"AmsConnectStatus"];
	[st setObject:@[@0] forKey:@"CurrentStatus"];

	// the job
	NSString *state = PDStr(ps, @"state") ?: @"standby", *file = PDStr(ps, @"filename") ?: @"";
	BOOL ready = [self.klippyState isEqualToString:@"ready"];
	int code = 0;
	if ([state isEqualToString:@"printing"]) code = ready ? 13 : 14;
	else if ([state isEqualToString:@"paused"]) code = 6;
	else if ([state isEqualToString:@"complete"]) code = 9;
	else if ([state isEqualToString:@"cancelled"]) code = 8;
	else if ([state isEqualToString:@"error"]) code = 14;
	if ([file length] && ![file isEqualToString:self.jobMetaFile]) {
		self.jobMetaFile = file; self.jobMeta = nil;
		[self rpc:@"server.files.metadata" params:@{@"filename": file} then:^(id res, NSString *err) {
			if ([res isKindOfClass:[NSDictionary class]] && [file isEqualToString:self.jobMetaFile]) { self.jobMeta = res; [self buildCosmosStatus]; }
		}];
	}
	NSDictionary *info = PDDict(ps, @"info");
	NSNumber *tl = PDNum(info, @"total_layer") ?: PDNum(self.jobMeta, @"layer_count") ?: @0;
	NSNumber *cl = PDNum(info, @"current_layer") ?: @0;
	double prog = [PDNum(vs, @"progress") doubleValue];
	NSString *tid = @"";
	if ([file length] && code) {
		BOOL same = [PDStr(self.lastTask, @"TaskName") isEqualToString:file];
		tid = same ? (PDStr(self.lastTask, @"TaskId") ?: @"") : [@"cosmos:" stringByAppendingString:file];
	}
	[st setObject:@{@"Status": PDI(code), @"Filename": file, @"TaskId": tid, @"CurrentLayer": cl, @"TotalLayer": tl,
		@"CurrentTicks": PDNum(ps, @"print_duration") ?: @0, @"TotalTicks": PDNum(self.jobMeta, @"estimated_time") ?: @0,
		@"Progress": PDN(round(prog * 1000) / 10.0), @"PrintSpeedPct": PDN(round([PDNum(gm, @"speed_factor") ?: @1 doubleValue] * 100))} forKey:@"PrintInfo"];
	[self handleStatus:st];
}

- (void)cosmosCanvas {
	if (![self.lanes count]) {
		if (self.mrObjects && self.canvas) { self.canvas = nil; [[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self]; }
		return;
	}
	NSMutableDictionary *w = [NSMutableDictionary dictionary];
	for (NSString *l in self.lanes) [w setObject:[NSNull null] forKey:[@"AFC_lane " stringByAppendingString:l]];
	[self rpc:@"printer.objects.query" params:@{@"objects": w} then:^(id res, NSString *err) {
		if (err) return;
		NSDictionary *st = PDDict(res, @"status");
		NSMutableArray *trays = [NSMutableArray array];
		int active = -1;
		for (NSUInteger i = 0; i < [self.lanes count]; i++) {
			NSDictionary *l = PDDict(st, [@"AFC_lane " stringByAppendingString:[self.lanes objectAtIndex:i]]);
			NSString *col = PDStr(l, @"color") ?: @"";
			if ([col length] && ![col hasPrefix:@"#"]) col = [@"#" stringByAppendingString:col];
			BOOL loaded = [PDNum(l, @"prep") boolValue] || [PDNum(l, @"load") boolValue];
			if ([PDNum(l, @"tool_loaded") boolValue]) active = (int)i;
			// AFC sends "map" as a list (["T0"]); "current_map" is the tool this lane answers to now.
			NSString *map = PDStr(l, @"current_map") ?: ([[PDArr(l, @"map") lastObject] isKindOfClass:[NSString class]] ? [PDArr(l, @"map") lastObject] : @"");
			[trays addObject:@{@"tray_id": PDI((long)i), @"brand": PDStr(l, @"spool_vendor") ?: @"", @"filament_type": PDStr(l, @"material") ?: @"",
				@"filament_name": PDStr(l, @"filament_name") ?: @"", @"filament_color": col, @"status": PDI(loaded),
				@"lane": [self.lanes objectAtIndex:i], @"map": map}];
		}
		NSDictionary *c = @{@"active_canvas_id": @0, @"active_tray_id": PDI(active), @"auto_refill": @0,
			@"canvas_list": @[@{@"canvas_id": @0, @"connected": @1, @"tray_list": trays}]};
		if (![c isEqualToDictionary:self.canvas]) {
			self.canvas = c;
			[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self];
		}
	}];
}

// Moonraker history job -> an SDCP history entry (Cmd 321's HistoryDetailList[0]).
- (NSDictionary *)taskFromJob:(NSDictionary *)j {
	NSString *status = PDStr(j, @"status") ?: @"";
	NSDictionary *meta = PDDict(j, @"metadata");
	NSMutableDictionary *t = [NSMutableDictionary dictionary];
	[t setObject:PDStr(j, @"job_id") ?: @"" forKey:@"TaskId"];
	[t setObject:PDStr(j, @"filename") ?: @"" forKey:@"TaskName"];
	[t setObject:PDNum(j, @"start_time") ?: @0 forKey:@"BeginTime"];
	[t setObject:[status isEqualToString:@"in_progress"] ? @0 : (PDNum(j, @"end_time") ?: @0) forKey:@"EndTime"];
	BOOL ok = [status isEqualToString:@"completed"] || [status isEqualToString:@"cancelled"] || [status isEqualToString:@"in_progress"];
	[t setObject:PDI(ok ? 0 : 1000) forKey:@"ErrorStatusReason"];
	if (!ok) [t setObject:[status isEqualToString:@"klippy_shutdown"] ? @"Klipper shut down" : [status isEqualToString:@"klippy_disconnect"] ? @"Klipper disconnected"
		: [NSString stringWithFormat:@"ended with %@", status] forKey:@"PDReasonText"];
	NSNumber *layers = PDNum(meta, @"layer_count");
	if (layers) {
		[t setObject:@{@"total_layer_numbers": layers} forKey:@"SliceInformation"];
		if ([status isEqualToString:@"completed"]) [t setObject:layers forKey:@"AlreadyPrintLayer"];
	}
	NSDictionary *best = nil;
	for (NSDictionary *th in PDArr(meta, @"thumbnails")) if (!best || [PDNum(th, @"width") intValue] > [PDNum(best, @"width") intValue]) best = th;
	NSString *rel = PDStr(best, @"relative_path");
	if ([rel length]) {
		NSString *dir = [PDStr(j, @"filename") stringByDeletingLastPathComponent];
		NSString *full = [dir length] ? [dir stringByAppendingPathComponent:rel] : rel;
		NSString *u = [[self urlForFile:[@"/local/" stringByAppendingString:full]] absoluteString];
		if (u) [t setObject:u forKey:@"Thumbnail"];
	}
	return t;
}

- (void)gcode:(NSString *)script {
	[self rpc:@"printer.gcode.script" params:@{@"script": script} then:^(id res, NSString *err) {
		if (err) [self postEvent:@"error" title:@"Printer refused the command" detail:[err stringByReplacingOccurrencesOfString:@"!! " withString:@""]];
		[self cosmosQuery];
	}];
}

- (void)cosmosCall:(NSString *)method params:(NSDictionary *)params {
	[self rpc:method params:params then:^(id res, NSString *err) {
		if (err) [self postEvent:@"error" title:@"Printer refused the command" detail:err];
		[self cosmosQuery];
	}];
}

// SDCP command -> Moonraker. Replies come back shaped like the SDCP ones, through the same handlers.
- (void)cosmosCommand:(int)cmd data:(NSDictionary *)d {
	switch (cmd) {
		case 0: [self cosmosQuery]; break;
		case 1: {
			[self rpc:@"printer.info" params:nil then:^(id res, NSString *err) {
				if (![res isKindOfClass:[NSDictionary class]]) return;
				self.attributes = @{@"Name": @"Centauri Carbon", @"MachineName": @"Centauri Carbon (COSMOS)",
					@"FirmwareVersion": PDStr(res, @"software_version") ?: @"", @"Hostname": PDStr(res, @"hostname") ?: @"", @"MainboardIP": self.host ?: @""};
				[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self];
			}];
			break;
		}
		case 128: [self cosmosCall:@"printer.print.start" params:@{@"filename": PDRel(PDStr(d, @"Filename") ?: @"")}]; break;
		case 129: [self cosmosCall:@"printer.print.pause" params:nil]; break;
		case 130: [self cosmosCall:@"printer.print.cancel" params:nil]; break;
		case 131: [self cosmosCall:@"printer.print.resume" params:nil]; break;
		case 258: {
			[self rpc:@"server.files.get_directory" params:@{@"path": @"gcodes", @"extended": @YES} then:^(id res, NSString *err) {
				NSArray *list = PDArr(res, @"files");
				if (!list) return;
				NSMutableArray *fl = [NSMutableArray array];
				for (NSDictionary *f in list) {
					if (![f isKindOfClass:[NSDictionary class]] || ![PDStr(f, @"filename") length]) continue;
					NSMutableDictionary *e = [NSMutableDictionary dictionaryWithObjectsAndKeys:[@"/local/" stringByAppendingString:PDStr(f, @"filename")], @"name",
						@1, @"type", PDNum(f, @"size") ?: @0, @"FileSize", PDNum(f, @"modified") ?: @0, @"CreateTime", nil];
					if (PDNum(f, @"layer_count")) [e setObject:PDNum(f, @"layer_count") forKey:@"TotalLayers"];
					[fl addObject:e];
				}
				[self handleResponse:258 data:@{@"FileList": fl}];
			}];
			break;
		}
		case 259: {
			for (NSString *f in PDArr(d, @"FileList"))
				[self rpc:@"server.files.delete_file" params:@{@"path": [@"gcodes/" stringByAppendingString:PDRel(f)]} then:^(id res, NSString *err) {
					if (err) [self postEvent:@"error" title:@"Couldn't delete the file" detail:err];
					[self refreshFiles];
				}];
			break;
		}
		case 260: {
			NSString *path = self.pendingDetailPath;
			[self rpc:@"server.files.metadata" params:@{@"filename": PDRel(PDStr(d, @"Url") ?: @"")} then:^(id res, NSString *err) {
				if (![res isKindOfClass:[NSDictionary class]] || ![path isEqualToString:self.pendingDetailPath]) return;
				NSMutableDictionary *fi = [NSMutableDictionary dictionary];
				if (PDNum(res, @"estimated_time")) [fi setObject:PDNum(res, @"estimated_time") forKey:@"EstTime"];
				if (PDNum(res, @"filament_weight_total")) [fi setObject:PDNum(res, @"filament_weight_total") forKey:@"EstWeight"];
				NSArray *cols = PDArr(res, @"filament_colors");
				if ([cols count] > 1) [fi setObject:cols forKey:@"ColorMapping"];
				NSDictionary *task = [self taskFromJob:@{@"filename": PDRel(path), @"metadata": res}];
				if (PDStr(task, @"Thumbnail")) [fi setObject:PDStr(task, @"Thumbnail") forKey:@"Thumbnail"];
				[self handleResponse:260 data:@{@"FileInfo": fi}];
			}];
			break;
		}
		case 320: case 321: {
			[self rpc:@"server.history.list" params:@{@"limit": @1, @"order": @"desc"} then:^(id res, NSString *err) {
				NSArray *jobs = PDArr(res, @"jobs");
				if (![jobs count] || ![[jobs objectAtIndex:0] isKindOfClass:[NSDictionary class]]) return;
				[self handleResponse:321 data:@{@"HistoryDetailList": @[[self taskFromJob:[jobs objectAtIndex:0]]]}];
			}];
			// Klipper's print-time total, for the lifetime figure. Asked with the history, so it is fresh after each job.
			[self rpc:@"server.history.totals" params:nil then:^(id res, NSString *err) {
				NSNumber *t = PDNum(PDDict(res, @"job_totals"), @"total_print_time");
				if (!t || !self.cosmos) return;
				self.cosmosPrintTime = [t doubleValue];
				[[NSNotificationCenter defaultCenter] postNotificationName:PDPrinterDidUpdateNotification object:self];
			}];
			break;
		}
		case 324: [self cosmosCanvas]; break;
		case 386: [self flushVideoWaiters]; break;   // mjpg-streamer needs no enabling
		case 401: {
			NSString *ax = PDStr(d, @"Axis") ?: @"X";
			[self gcode:[NSString stringWithFormat:@"G91\nG1 %@%.3f F%d\nG90", ax, [PDNum(d, @"Step") doubleValue], [ax isEqualToString:@"Z"] ? 600 : 6000]];
			break;
		}
		case 402: {
			NSString *ax = PDStr(d, @"Axis") ?: @"XYZ";
			[self gcode:[ax isEqualToString:@"XYZ"] ? @"G28" : [@"G28 " stringByAppendingString:ax]];
			break;
		}
		case 403: {
			NSMutableArray *g = [NSMutableArray array];
			if (PDNum(d, @"TempTargetNozzle")) [g addObject:[NSString stringWithFormat:@"M104 S%d", [PDNum(d, @"TempTargetNozzle") intValue]]];
			if (PDNum(d, @"TempTargetHotbed")) [g addObject:[NSString stringWithFormat:@"M140 S%d", [PDNum(d, @"TempTargetHotbed") intValue]]];
			if (PDNum(d, @"PrintSpeedPct")) [g addObject:[NSString stringWithFormat:@"M220 S%d", [PDNum(d, @"PrintSpeedPct") intValue]]];
			NSDictionary *fans = PDDict(d, @"TargetFanSpeed"), *cur = PDDict(self.status, @"CurrentFanSpeed");
			for (NSString *k in fans) {
				int v = [PDNum(fans, k) intValue];
				if (PDNum(cur, k) && [PDNum(cur, k) intValue] == v) continue;   // only the one that changed
				if ([k isEqualToString:@"ModelFan"]) [g addObject:[NSString stringWithFormat:@"M106 S%ld", lround(v * 2.55)]];
				NSString *name = [k isEqualToString:@"AuxiliaryFan"] ? self.auxFanName : [k isEqualToString:@"BoxFan"] ? self.chamberFanName : nil;
				if (name) [g addObject:[NSString stringWithFormat:@"SET_FAN_SPEED FAN=%@ SPEED=%.2f", name, v / 100.0]];
			}
			NSDictionary *ls = PDDict(d, @"LightStatus");
			if (ls && self.caseLedName) [g addObject:[NSString stringWithFormat:@"SET_LED LED=%@ WHITE=%d", self.caseLedName, [PDNum(ls, @"SecondLight") intValue] ? 1 : 0]];
			if ([g count]) [self gcode:[g componentsJoinedByString:@"\n"]];
			break;
		}
		default: break;
	}
}

- (void)runGcode:(NSString *)script { if (self.cosmos && [script length]) [self gcode:script]; }

- (void)setLane:(int)slot color:(NSString *)hex material:(NSString *)material {
	if (!self.cosmos || slot < 0 || slot >= (int)[self.lanes count]) return;
	NSString *lane = [self.lanes objectAtIndex:(NSUInteger)slot];
	NSMutableArray *g = [NSMutableArray array];
	if ([hex length]) [g addObject:[NSString stringWithFormat:@"SET_COLOR LANE=%@ COLOR=%@", lane, [hex stringByReplacingOccurrencesOfString:@"#" withString:@""]]];
	if ([material length]) [g addObject:[NSString stringWithFormat:@"SET_MATERIAL LANE=%@ MATERIAL=%@", lane, material]];
	if (![g count]) return;
	[self rpc:@"printer.gcode.script" params:@{@"script": [g componentsJoinedByString:@"\n"]} then:^(id res, NSString *err) {
		if (err) [self postEvent:@"error" title:@"Couldn't set the slot" detail:err];
		[self cosmosCanvas];
	}];
}

- (void)adjustZOffset:(double)mm {
	if (!self.cosmos) return;
	[self gcode:[NSString stringWithFormat:@"SET_GCODE_OFFSET Z_ADJUST=%.3f%@", mm, self.isBusy ? @" MOVE=1" : @""]];
}

- (void)motorsOff { if (self.cosmos) [self gcode:@"M84"]; }

- (void)firmwareRestart {
	if (!self.cosmos) return;
	[self rpc:@"printer.firmware_restart" params:nil then:^(id res, NSString *err) {
		if (err) [self postEvent:@"error" title:@"Restart failed" detail:err];
		self.mrObjects = nil;
		[self performSelector:@selector(reconnectNow) withObject:nil afterDelay:4];
	}];
}

@end
