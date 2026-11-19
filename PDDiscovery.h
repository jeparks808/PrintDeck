#import <Foundation/Foundation.h>

// Finds Elegoo SDCP printers on the Wi-Fi: broadcasts "M99999" to UDP port 3000; each printer answers
// with a JSON description (Data.MainboardIP, Data.Name, ...). The callback runs on the main queue once per
// reply. Search lasts `seconds`, re-broadcasting every second (UDP replies can get lost).
@interface PDDiscovery : NSObject
- (void)searchForSeconds:(NSTimeInterval)seconds found:(void (^)(NSDictionary *info))found done:(void (^)(void))done;
- (void)stop;
@end
