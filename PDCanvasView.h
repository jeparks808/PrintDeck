#import <UIKit/UIKit.h>

// The CANVAS (Elegoo's 4-spool filament changer) as the printer reports it with SDCP Cmd 324:
// { active_canvas_id, active_tray_id (-1 none), auto_refill, canvas_list: [{ canvas_id, connected,
//   tray_list: [{ tray_id, brand, filament_type, filament_name, filament_color "#RRGGBB",
//   min_nozzle_temp, max_nozzle_temp, status (1 loaded, 0 empty) }] }] }.
//
// Draws the slots: compact rows (swatch, "1  PLA", brand) for the dashboard card, or big spool tiles with
// every detail for the CANVAS page. The slot feeding the nozzle is outlined in the accent colour.
@interface PDCanvasView : UIView
@property (nonatomic, strong) NSDictionary *info;   // the Cmd 324 data; nil = not heard yet
@property (nonatomic) BOOL large;                   // page tiles instead of card rows
@property (nonatomic, copy) NSString *emptyText;    // shown when there's nothing to draw
// The unit to show (the active one, else the first connected), its trays, and a one-line state such as
// "Slot 2 feeding" / "Idle" / "Not connected".
+ (NSDictionary *)unitIn:(NSDictionary *)info;
+ (NSString *)stateTextFor:(NSDictionary *)info;
@end

// "#F72221" -> a colour (grey for anything unreadable).
UIColor *PDColorFromHex(NSString *hex);
