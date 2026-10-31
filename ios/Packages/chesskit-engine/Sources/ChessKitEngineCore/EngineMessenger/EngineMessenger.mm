//
//  EngineMessenger.m
//  ChessKitEngine
//

#import "EngineMessenger.h"
#import "../Engines/AvailableEngines.h"

@implementation EngineMessenger : NSObject

dispatch_queue_t _queue;
Engine *_engine;
NSPipe *_readPipe;
NSPipe *_writePipe;
NSFileHandle *_pipeReadHandle;
NSFileHandle *_pipeWriteHandle;
NSLock *_lock;

/// Initializes a new `EngineMessenger` with default engine `Stockfish`.
- (id)init {
    return [self initWithEngineType:EngineTypeStockfish];
}

- (id)initWithEngineType: (EngineType_objc) type {
    self = [super init];

    if (self) {
        _lock = [[NSLock alloc] init];
        switch (type) {
            case EngineTypeStockfish:
                _engine = new StockfishEngine();
                break;
            case EngineTypeLc0:
                _engine = new Lc0Engine();
                break;
        }
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _engine->deinitialize();
}

- (void)start {
    [_lock lock];
    // set up read pipe
    _readPipe = [NSPipe pipe];
    _pipeReadHandle = [_readPipe fileHandleForReading];

    dup2([[_readPipe fileHandleForWriting] fileDescriptor], fileno(stdout));

    // Rookie Lab：在自己的背景執行緒一直讀引擎輸出（原本在主執行緒讀，分析時每秒幾百行會卡住畫面），
    // 並保留讀到一半的那一行，跟下一塊接起來（原本直接切開，一行被切成兩半就整行不見，bestmove 掉了就等不到結果）
    int readFd = [_pipeReadHandle fileDescriptor];
    dispatch_async(dispatch_queue_create("ck-read-queue", DISPATCH_QUEUE_SERIAL), ^{
        NSMutableData *pending = [NSMutableData data];
        char buf[8192];
        while (true) {
            ssize_t n = read(readFd, buf, sizeof(buf));
            if (n <= 0) break;
            [pending appendBytes:buf length:(NSUInteger)n];
            const char *bytes = (const char *)pending.bytes;
            NSUInteger len = pending.length, start = 0;
            for (NSUInteger i = 0; i < len; i++) {
                if (bytes[i] != '\n') continue;
                NSString *line = [[NSString alloc] initWithBytes:bytes + start length:i - start encoding:NSUTF8StringEncoding];
                start = i + 1;
                void (^handler)(NSString *) = self.responseHandler;
                if (line != nil && handler != nil) { handler(line); }
            }
            if (start > 0) { [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0]; }
        }
    });

    // set up write pipe
    _writePipe = [NSPipe pipe];
    _pipeWriteHandle = [_writePipe fileHandleForWriting];
    dup2([[_writePipe fileHandleForReading] fileDescriptor], fileno(stdin));

    // create command dispatch queue and start engine
    _queue = dispatch_queue_create("ck-message-queue", DISPATCH_QUEUE_CONCURRENT);

    dispatch_async(_queue, ^{
        _engine->initialize();
    });
    [_lock unlock];
}

- (void)stop {
    [_lock lock];
    [_pipeReadHandle closeFile];
    [_pipeWriteHandle closeFile];

    _readPipe = NULL;
    _pipeReadHandle = NULL;

    _writePipe = NULL;
    _pipeWriteHandle = NULL;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_lock unlock];
}

- (void)sendCommand: (NSString*) command {
    dispatch_sync(_queue, ^{
        const char *cmd = [[command stringByAppendingString:@"\n"] UTF8String];
        write([_pipeWriteHandle fileDescriptor], cmd, strlen(cmd));
    });
}

# pragma mark Private

@end
