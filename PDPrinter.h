#import <Foundation/Foundation.h>

// One Elegoo SDCP printer (Centauri Carbon, stock or OpenCentauri firmware). Talks SDCP V3 JSON over
// ws://host:3030/websocket. The printer does not push status on its own while idle, so this polls
// Cmd 0 every 2 s; that poll doubles as the heartbeat (no reply for 8 s -> reconnect).
// All callbacks and notifications are on the main thread.

extern NSString *const PDPrinterDidUpdateNotification;      // status/attributes changed
extern NSString *const PDPrinterConnectionNotification;     // connected / disconnected
extern NSString *const PDPrinterFilesNotification;          // file list arrived
extern NSString *const PDPrinterEventNotification;          // userInfo: kind (NSString), title, detail
extern NSString *const PDPrinterGraphNotification;          // a new per-second temperature sample was taken

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
// Per-second histories (NSNumber, NSNull = no data) for the smooth graphs, newest last, ~64 s, taken at graphTime
// (a monotonic clock in the same base as CACurrentMediaTime, which PDGraphClock expects).
@property (nonatomic, readonly, strong) NSArray *nozzleGraph, *bedGraph, *chamberGraph;
@property (nonatomic, readonly) double graphTime;

// Convenience readings from the latest status
@property (nonatomic, readonly) PDJobState jobState;
@property (nonatomic, readonly) NSString *jobStateText;
@property (nonatomic, readonly) BOOL isBusy;           // a job is underway (printing/paused/preparing...)
// The machine is doing something that isn't a job, e.g. auto bed levelling started from the touchscreen's settings
// (CurrentStatus 5) or calibrating (3). Prints, moves and homing aren't sent then.
@property (nonatomic, readonly) BOOL machineBusy;
- (BOOL)refuseWhileMachineBusy;        // YES (and an "error" alert) when machineBusy
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
- (void)startFile:(NSString *)path;     // 128 (textured plate, no time-lapse, no levelling)
// 128 with the print options the printer's own start screen offers: plate 0 = textured PEI (side A),
// 1 = smooth PEI (side B); time-lapse; auto bed levelling first. COSMOS (Moonraker) ignores the options.
- (void)startFile:(NSString *)path plate:(int)plate timelapse:(BOOL)timelapse level:(BOOL)level;
- (void)setNozzleTarget:(int)c;         // 403 TempTargetNozzle
- (void)setBedTarget:(int)c;            // 403 TempTargetHotbed
- (void)setSpeedPercent:(int)pct;       // 403 PrintSpeedPct (50 silent, 100 balanced, 130 sport, 160 ludicrous)
- (void)setFan:(NSString *)fan percent:(int)pct; // 403 TargetFanSpeed {ModelFan, AuxiliaryFan, BoxFan}
- (void)setLight:(BOOL)on;              // 403 LightStatus.SecondLight
- (void)home:(NSString *)axes;          // 402 "X" "Y" "Z" "XYZ"
- (void)jog:(NSString *)axis by:(double)mm; // 401
- (void)refreshFiles;                   // 258
- (void)refreshAttributes;              // 1 (motor/camera status, video viewers)
// 324: the CANVAS filament changer — its slots' filament (type, colour, brand, nozzle range), which slot is
// feeding, auto-refill. Asked on connect and every 10 s (4 s while a job runs); the reply lands in `canvas`
// and posts PDPrinterDidUpdateNotification. Status.AmsConnectStatus says whether one is plugged in.
- (void)refreshCanvas;
@property (nonatomic, readonly, strong) NSDictionary *canvas;

// The G-code of the running job, or of the last one if nothing is running ("/local/…gcode"), or nil.
- (NSString *)jobFilePath;
// HTTP URL of a stored file. The printer's port-80 web server shares /local/; the origin comes from the
// history thumbnail URL when there is one (so the simulator works too), else http://host.
- (NSURL *)urlForFile:(NSString *)path;
- (long long)sizeOfFile:(NSString *)path;    // from the file list, 0 if unknown
// CurrenCoord ("x,y,z") parsed; NO if the printer hasn't reported one.
- (BOOL)getPosition:(double *)xyz;
// 260: the printer's details for a stored file (EstTime s, EstWeight g, Thumbnail URL, ColorMapping). The reply
// lands in fileDetail / fileDetailPath and posts PDPrinterDidUpdateNotification.
- (void)requestFileDetail:(NSString *)path;
@property (nonatomic, readonly, strong) NSDictionary *fileDetail;
@property (nonatomic, readonly, copy) NSString *fileDetailPath;
// 386 {Enable:1}. The camera port sends no frames until this is sent ("camera not ready" or an empty
// stream), and a video connection opened before the reply never starts, so open it from `then`.
// `then` runs on the main thread once the printer answers, or after 2 s if it doesn't.
- (void)enableVideoStream:(void (^)(void))then;

// COSMOS (OpenCentauri's Klipper + Moonraker firmware). On connect PrintDeck asks GET /server/info on port 80 (or on
// the given port when it isn't 3030); a Moonraker answer switches this printer to COSMOS mode. In that mode the
// same SDCP-shaped status / attributes / files / lastTask / canvas / fileDetail are filled from Moonraker
// (JSON-RPC over ws://host/websocket), and every command above becomes Moonraker calls or G-code, so the pages
// don't need to know which firmware is on the other end. Files keep their "/local/<name>" paths.
@property (nonatomic, readonly) BOOL cosmos;
@property (nonatomic, readonly, copy) NSString *klippyState;    // "ready", "startup", "shutdown", "error" (COSMOS)
@property (nonatomic, readonly, copy) NSString *klippyMessage;
@property (nonatomic, readonly) int moonrakerPort;
@property (nonatomic, readonly, copy) NSString *auxFanName, *chamberFanName, *caseLedName;  // discovered Klipper names
- (NSURL *)moonrakerURL:(NSString *)pathAndQuery;               // http://host:port<pathAndQuery>
- (void)runGcode:(NSString *)script;                            // printer.gcode.script; an error posts an "error" event
// COSMOS only (no SDCP equivalent):
- (void)setLane:(int)slot color:(NSString *)hex material:(NSString *)material;  // AFC SET_COLOR / SET_MATERIAL, slot 0..3
- (void)adjustZOffset:(double)mm;    // SET_GCODE_OFFSET Z_ADJUST= (MOVE=1 while printing)
- (void)motorsOff;                   // M84
- (void)firmwareRestart;             // FIRMWARE_RESTART, after a Klipper shutdown

// Lifetime print time. Elegoo's firmware (stock and OpenCentauri patched) counts every print's time in
// /board-resource/sysconf.cfg (`cumulative_time`, seconds; Settings > About shows it as "1007h27m"), and COSMOS
// starts its own count at zero. COSMOS leaves that file in place and Moonraker serves it, so on COSMOS it is read
// from the printer (earlierPrintTime, remembered on the iPad) and Klipper's own total (Moonraker's job totals) is
// added to it. Not editable: both numbers come from the printer.
@property (nonatomic, readonly) double cosmosPrintTime;   // seconds, total_print_time; -1 until known (or not COSMOS)
+ (double)earlierPrintTime;                                 // seconds, 0 until read from a COSMOS printer
- (double)lifetimePrintTime;                                // earlier + cosmosPrintTime; -1 when neither is known
@end
