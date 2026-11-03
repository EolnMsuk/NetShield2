#import "NSAppStorage.h"
dispatch_queue_t NSAppStorageQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.eolnmsuk.netshield.app.storage", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}
