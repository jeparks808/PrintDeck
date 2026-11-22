#import "PDPrinter.h"
#import "PDWebSocket.h"
#import "PDUtil.h"
#import <QuartzCore/QuartzCore.h>

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
@end

@implementation PDPrinter

+ (PDPrinter *)shared {
	static PDPrinter *p;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ p = [[PDPrinter alloc] init]; });
	return p;
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
		self.attributes = nil;
		self.files = nil;
		self.lastTask = nil;
		self.mainboardID = nil;
		self.haveStatus = NO;
		self.prevPrintStatus = -1;
		[self.nozzleH removeAllObjects];
		[self.bedH removeAllObjects];
		[self.chamberH removeAllObjects];
		[self.nozzleG removeAllObjects];
		[self.bedG removeAllObjects];
		[self.chamberG removeAllObjects];
	}
	self.videoURL = [NSString stringWithFormat:@"http://%@:%d/video", self.host, self.videoPort];
	[self reconnectNow];
}

- (void)reconnectNow {
	[self.retryTimer invalidate];
	self.retryTimer = nil;
	[self.ws close];
	self.ws = nil;
	if (!self.host) return;
	self.ws = [[PDWebSocket alloc] initWithHost:self.host port:self.port path:@"/websocket"];
	self.ws.delegate = self;
	[self.ws open];
}

- (void)disconnect {
	[self.pollTimer invalidate];
	self.pollTimer = nil;
	[self.retryTimer invalidate];
	self.retryTimer = nil;
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
	[self send:0 data:nil];
	[self send:1 data:nil];
	[self send:320 data:nil]; // history -> last job card
	[self refreshFiles];
	[self.pollTimer invalidate];
	self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)webSocket:(PDWebSocket *)ws didCloseWithReason:(NSString *)reason {
	if (ws != self.ws) return;
	self.ws = nil;
	[self.pollTimer invalidate];
	self.pollTimer = nil;
	[self setConnectedState:NO error:reason];
	[self scheduleRetry];
}

- (void)scheduleRetry {
	[self.retryTimer invalidate];
	self.retryTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(reconnectNow) userInfo:nil repeats:NO];
}

- (void)poll {
	if (CFAbsoluteTimeGetCurrent() - self.lastMessage > 8) {
		[self.ws close];
		[self webSocket:self.ws didCloseWithReason:@"printer stopped answering"];
		return;
	}
	[self send:0 data:nil];
}

- (void)send:(int)cmd data:(NSDictionary *)data {
	if (!self.ws.isOpen) return;
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
		NSString *why = reason ? [PDPrinter reasonText:reason] : @"stopped on the printer";
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
	int c = [PDNum([self printInfo], @"Status") intValue];
	switch (c) {
		case 1: return @"Homing";
		case 16: return @"Heating";
		case 20: return @"Leveling bed";
	}
	switch (self.jobState) {
		case PDJobIdle: {
			NSArray *cs = PDArr(self.status, @"CurrentStatus");
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

- (void)startFile:(NSString *)path {
	[self send:128 data:[NSDictionary dictionaryWithObjectsAndKeys:path, @"Filename", [NSNumber numberWithInt:0], @"StartLayer", nil]];
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

- (void)home:(NSString *)axes { [self send:402 data:[NSDictionary dictionaryWithObject:axes forKey:@"Axis"]]; }

- (void)jog:(NSString *)axis by:(double)mm {
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

@end
