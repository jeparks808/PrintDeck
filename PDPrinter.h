#import <Foundation/Foundation.h>

// One Elegoo SDCP printer (Centauri Carbon, stock or OpenCentauri firmware). Talks SDCP V3 JSON over
// ws://host:3030/websocket. The printer does not push status on its own while idle, so this polls
// Cmd 0 every 2 s; that poll doubles as the heartbeat (no reply for 8 s -> reconnect).
// All callbacks and notifications are on the main thread.

extern NSString *const PDPrinterDidUpdateNotification;      // status/attributes changed
extern NSString *const PDPrinterConnectionNotification;     // connected / disconnected
extern NSString *const PDPrinterFilesNotification;          // file list arrived
extern NSString *const PDPrinterEventNotification;          // userInfo: kind (NSString), title, detail

typedef enum {
	PDJobIdle, PDJobPreparing, PDJobPrinting, PDJobPausing, PDJobPaused, PDJobStopping,
	PDJobStopped, PDJobComplete, PDJobChecking, PDJobRecovery, PDJobUnknown
} PDJobState;

@interface PDPrinter : NSObject
+ (PDPrinter *)shared;

@property (nonatomic, readonly, copy) NSString *host;
@property (nonatomic, readonly) int port, videoPort;
@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly, copy) NSString *lastError;
@property (nonatomic, readonly, strong) NSDictionary *status;      // the "Status" object
@property (nonatomic, readonly, strong) NSDictionary *attributes;  // the "Attributes" object
@property (nonatomic, readonly, strong) NSArray *files;            // newest first; dicts with name/FileSize/TotalLayers/CreateTime
@property (nonatomic, readonly, strong) NSDictionary *lastTask;    // newest history entry (HistoryDetailList[0])
@property (nonatomic, readonly, copy) NSString *videoURL;
@property (nonatomic, readonly, strong) NSArray *nozzleHistory, *bedHistory, *chamberHistory; // NSNumbers, 1 per 4 s, ~20 min

// Convenience readings from the latest status
@property (nonatomic, readonly) PDJobState jobState;
@property (nonatomic, readonly) NSString *jobStateText;
@property (nonatomic, readonly) BOOL isBusy;           // a job is underway (printing/paused/preparing...)
@property (nonatomic, readonly) double progress;       // 0..1
@property (nonatomic, readonly) double elapsed;        // seconds
@property (nonatomic, readonly) double remaining;      // seconds, best estimate
@property (nonatomic, readonly) NSString *printerName;

- (void)connectToHost:(NSString *)host port:(int)port videoPort:(int)videoPort;
- (void)disconnect;
- (void)reconnectNow;

// Commands (SDCP Cmd numbers in brackets; taken from the printer's own web UI)
- (void)pause;                          // 129
- (void)resume;                         // 131
- (void)stop;                           // 130
- (void)startFile:(NSString *)path;     // 128
- (void)setNozzleTarget:(int)c;         // 403 TempTargetNozzle
- (void)setBedTarget:(int)c;            // 403 TempTargetHotbed
- (void)setSpeedPercent:(int)pct;       // 403 PrintSpeedPct (50 silent, 100 balanced, 130 sport, 160 ludicrous)
- (void)setFan:(NSString *)fan percent:(int)pct; // 403 TargetFanSpeed {ModelFan, AuxiliaryFan, BoxFan}
- (void)setLight:(BOOL)on;              // 403 LightStatus.SecondLight
- (void)home:(NSString *)axes;          // 402 "X" "Y" "Z" "XYZ"
- (void)jog:(NSString *)axis by:(double)mm; // 401
- (void)refreshFiles;                   // 258
@end
