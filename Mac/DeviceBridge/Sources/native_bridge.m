#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include <xpc/xpc.h>
#include <uuid/uuid.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <string.h>
#include <errno.h>
#include <dlfcn.h>
#include <sqlite3.h>
#include <pthread.h>
#include <signal.h>
#include <math.h>
#include <unistd.h>
#include "native_bridge.h"
#include <stdatomic.h>
#include "bounded_sender.h"
#include "display_geometry.h"
#include "device_control.h"
#include "keyboard_input.h"


#define LOGE(...) do{ fprintf(stderr, "ipb-mirror: " __VA_ARGS__); fprintf(stderr,"\n"); }while(0)
#define DIE(code, ...) do{ fail((code), [NSString stringWithFormat:@"" __VA_ARGS__]); return (code); }while(0)

extern void _coredevice_xpc_add_bundle(NSBundle*);
extern void _coredevice_xpc_init_services(void);
typedef void *xrc_t;
extern xrc_t xpc_remote_connection_create_with_connected_fd(int,dispatch_queue_t,uint64_t,uint64_t);
extern void xpc_remote_connection_set_event_handler(xrc_t,xpc_handler_t);
extern void xpc_remote_connection_activate(xrc_t);
extern xpc_object_t xpc_remote_connection_send_message_with_reply_sync(xrc_t,xpc_object_t);

@interface AVCMediaStreamNegotiator : NSObject
- (instancetype)initWithMode:(long)mode options:(NSDictionary*)o error:(NSError**)e;
- (BOOL)createOffer; - (NSData*)offer;
- (BOOL)setAnswer:(NSData*)a withError:(NSError**)e;
- (id)generateMediaStreamConfigurationWithError:(NSError**)e;
- (id)generateMediaStreamInitOptionsWithError:(NSError**)e;
@end
@interface AVCVideoStream : NSObject
- (instancetype)initWithNetworkSockets:(id)socks options:(id)opts error:(NSError**)e;
- (BOOL)configure:(id)cfg error:(NSError**)e;
- (void)setDelegate:(id)d;
- (void)start;
- (void)stop;
- (void)requestLastDecodedFrame;
@end
@interface VCImageQueue : NSObject
- (long long)streamToken;
- (id)streamOutput;
- (void)setStreamOutput:(id)o;
@end
@interface VCStreamOutput : NSObject
- (instancetype)initWithStreamToken:(long long)t clientProcessID:(int)pid delegate:(id)d delegateQueue:(dispatch_queue_t)q;
@end

extern int uhid_make_digitizer_hid_report(double,double,int,int,void*);
extern int uhid_make_edge_touch_hid_report(double,double,int,int,int,void*);
extern int uhid_make_scroll_hid_report(int64_t,int64_t,uint32_t,uint32_t,uint32_t,double,double,void*);
extern int uhid_make_scroll_wire_hid_report(int32_t,int32_t,uint32_t,uint32_t,double,double,void*);
extern int uhid_make_absolute_pointer_hid_report(double,double,uint32_t,void*);
extern int uhid_make_keyboard_hid_report(uint32_t,int,void*);
extern int uhid_make_keyboard_state_hid_report(const uint32_t*,int32_t,void*);
extern int coredevice_print_connected_descriptors_async_raw(xrc_t);
extern int coredevice_send_universalhid_hid_report(xrc_t,const void*,uint64_t);
extern int coredevice_send_universalhid_barrier(xrc_t);
extern void xpc_remote_connection_cancel(xrc_t);
extern int coredevice_send_hid_button_custom(xrc_t,uint64_t,uint64_t,uint8_t);
extern int coredevice_send_hid_button_barrier(xrc_t);
extern int coredevice_send_hid_digitizer_cgpoint(xrc_t,double,double,double,double,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t);

static xpc_object_t action_env(const char*action,const char*dev,xpc_object_t input){
    uuid_t u; uuid_generate(u); char us[37]; uuid_unparse_upper(u,us);
    xpc_object_t m=xpc_dictionary_create_empty();
    xpc_dictionary_set_string(m,"CoreDevice.actionIdentifier",action);
    xpc_dictionary_set_string(m,"CoreDevice.deviceIdentifier",dev);
    xpc_dictionary_set_string(m,"CoreDevice.invocationIdentifier",us);
    xpc_object_t ver=xpc_dictionary_create_empty(); xpc_object_t comps=xpc_array_create_empty();
    xpc_array_append_value(comps,xpc_uint64_create(642)); xpc_array_append_value(comps,xpc_uint64_create(15));
    xpc_dictionary_set_value(ver,"components",comps); xpc_dictionary_set_int64(ver,"originalComponentsCount",2);
    xpc_dictionary_set_string(ver,"stringValue","642.15");
    xpc_dictionary_set_value(m,"CoreDevice.coreDeviceVersion",ver);
    xpc_dictionary_set_int64(m,"CoreDevice.CoreDeviceDDIProtocolVersion",1);
    xpc_dictionary_set_value(m,"CoreDevice.input",input);
    return m;
}


extern int layerlens_native_service_ids(xrc_t,uint64_t *,uint64_t *);

@interface LLNativeSession : NSObject {
@public
    _Atomic bool stopped;
    _Atomic bool rotating;
    _Atomic bool resumePending;
    xrc_t media, input, buttons, digitizer;
    int mediaFD, rtpFD, inputFD, buttonFD, digitizerFD;
    uint64_t touchService, keyboardService;
    BOOL touching, edge;
    double x,y;
    IPBDisplayInfo display;
    CMSampleBufferRef latest;
    BOOL writing;
    double lastImageTime;
    ipb_bounded_sender sender;
    LLNativeCallback callback;
    void *context;
}
@property(nonatomic,copy) NSArray<NSString *> *arguments;
@property(nonatomic,strong) AVCVideoStream *stream;
@property(nonatomic,strong) xpc_connection_t controlService;
@property(nonatomic,strong) id imageQueue;
@property(nonatomic,strong) id frameOutput;
@property(nonatomic,strong) dispatch_queue_t imageWork;
@property(nonatomic,strong) dispatch_queue_t inputWork;
@property(nonatomic,strong) dispatch_queue_t delegateWork;
@property(nonatomic,strong) NSMutableArray *connections;
@property(atomic,strong) NSTask *lease;
@property(atomic,strong) NSFileHandle *leaseLifetime;
@property(nonatomic,strong) dispatch_source_t geometryTimer;
@property(nonatomic,strong) NSData *lastGeometry;
@property(nonatomic,strong) NSString *failure;
- (void)begin;
- (void)close;
- (void)finish;
- (void)emit:(uint8_t)kind data:(NSData *)data;
- (void)emitVideoState:(NSString *)state active:(BOOL)active;
- (void)receive:(CMSampleBufferRef)sample;
- (void)handle:(NSDictionary *)message;
- (BOOL)wakeDisplayIfNeeded:(NSString **)error;
@end

static dispatch_queue_t nativeWork(void){
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("com.layerlens.native.session",DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static LLNativeSession *activeSession;
static IMP originalQueueStart;
static void nativeQueueStart(id queue,SEL command){
    LLNativeSession *session;
    @synchronized(LLNativeSession.class){ session=activeSession; }
    if(session && !atomic_load(&session->stopped) && ![(VCImageQueue*)queue streamOutput]){
        id output=[[objc_getClass("VCStreamOutput") alloc] initWithStreamToken:[(VCImageQueue*)queue streamToken]
            clientProcessID:getpid() delegate:session delegateQueue:session.delegateWork];
        if(output){ [(VCImageQueue*)queue setStreamOutput:output]; session.imageQueue=queue; session.frameOutput=output; }
    }
    ((void(*)(id,SEL))originalQueueStart)(queue,command);
}
static void installNativeSink(void){
    static dispatch_once_t once;
    dispatch_once(&once,^{
        Method method=class_getInstanceMethod(objc_getClass("VCImageQueue"),sel_registerName("start"));
        if(method){ originalQueueStart=method_getImplementation(method); method_setImplementation(method,(IMP)nativeQueueStart); }
    });
}

@implementation LLNativeSession
- (instancetype)init {
    if((self=[super init])){
        mediaFD=rtpFD=inputFD=buttonFD=digitizerFD=-1;
        ipb_bounded_sender_init(&sender);
        _connections=[NSMutableArray array];
        _imageWork=dispatch_queue_create("com.layerlens.native.images",DISPATCH_QUEUE_SERIAL);
        _inputWork=dispatch_queue_create("com.layerlens.native.input",DISPATCH_QUEUE_SERIAL);
        _delegateWork=dispatch_queue_create("com.layerlens.native.frames",DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)emit:(uint8_t)kind data:(NSData *)data {
    @synchronized(self){ if(callback) callback(context,kind,data.bytes,data.length); }
}
- (void)fail:(NSString *)reason {
    if(!_failure){ _failure=reason; [self emit:255 data:[reason dataUsingEncoding:NSUTF8StringEncoding]]; }
    [self close];
}
- (void)emitVideoState:(NSString *)state active:(BOOL)active {
    if(atomic_load(&stopped)) return;
    NSDictionary *result=@{@"type":@"video-state",@"state":state,@"active":@(active)};
    [self emit:8 data:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]];
}
- (void)hold:(xrc_t)remote {
    if(remote) [_connections addObject:(__bridge_transfer id)remote];
}
- (xrc_t)openFeature:(const char *)feature fd:(int *)fd {
    xpc_connection_t service=xpc_connection_create("com.apple.CoreDevice.CoreDeviceService",_delegateWork);
    xpc_connection_set_event_handler(service,^(xpc_object_t event){});xpc_connection_resume(service);
    xpc_object_t params=xpc_dictionary_create_empty();xpc_dictionary_set_string(params,"featureIdentifier",feature);
    xpc_object_t reply=xpc_connection_send_message_with_reply_sync(service,action_env("com.apple.coredevice.action.createservicesocket",_arguments[0].UTF8String,params));
    xpc_object_t output=reply&&xpc_get_type(reply)==XPC_TYPE_DICTIONARY?xpc_dictionary_get_dictionary(reply,"CoreDevice.output"):NULL;
    if(!output){ xpc_connection_cancel(service); [self fail:[NSString stringWithFormat:@"Device feature unavailable: %s",feature]];return NULL; }
    *fd=xpc_dictionary_dup_fd(output,"fileDescriptor");
    uint64_t flags=xpc_dictionary_get_uint64(output,"remoteXPCVersionFlags");xpc_connection_cancel(service);
    if(*fd<0){ [self fail:@"Device feature returned no socket"];return NULL; }
    xrc_t remote=xpc_remote_connection_create_with_connected_fd(*fd,_delegateWork,flags,0);
    // RemoteXPC/Network takes ownership. Never close this numeric descriptor
    // after cancellation: it may already have been reused by the host app.
    *fd=-1;
    if(!remote){ [self fail:@"Device RemoteXPC creation failed"];return NULL; }
    [self hold:remote];
    __weak LLNativeSession *weak=self;
    xpc_remote_connection_set_event_handler(remote,^(xpc_object_t event){
        if(event&&xpc_get_type(event)==XPC_TYPE_ERROR){
            LLNativeSession *strong=weak;
            if(strong&&!atomic_load(&strong->stopped)) [strong fail:@"Device connection closed"];
        }
    });
    xpc_remote_connection_activate(remote);return remote;
}
- (void)startLease {
    if(atomic_load(&stopped)) return;
    NSTask *task=[NSTask new];
    task.executableURL=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"DeviceBridge/bin/lease-guardian"];
    task.arguments=@[[NSString stringWithFormat:@"%d",getpid()],@"/Library/Developer/PrivateFrameworks/CoreDevice.framework/Resources/bin/devicectl",@"device",@"notification",@"observe",@"--device",_arguments[0],@"--name",@"com.apple.layerlens.tunnel.keepalive",@"--session-timeout",@"15",@"--timeout",@"15"];
    NSPipe *lifetime=[NSPipe pipe];
    fcntl(lifetime.fileHandleForWriting.fileDescriptor,F_SETFD,FD_CLOEXEC);
    fcntl(lifetime.fileHandleForReading.fileDescriptor,F_SETFD,FD_CLOEXEC);
    task.standardInput=lifetime;task.standardOutput=NSFileHandle.fileHandleWithNullDevice;task.standardError=NSFileHandle.fileHandleWithNullDevice;
    __weak LLNativeSession *weak=self;
    task.terminationHandler=^(NSTask *ended){ dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/4),nativeWork(),^{
        LLNativeSession *strong=weak;if(strong && !atomic_load(&strong->stopped)) [strong startLease];
    }); };
    NSError *error=nil;
    if(![task launchAndReturnError:&error]){ [lifetime.fileHandleForWriting closeFile];[self fail:error.localizedDescription];return; }
    self.leaseLifetime=lifetime.fileHandleForWriting;
    self.lease=task;
    if(atomic_load(&stopped)) [self.leaseLifetime closeFile];
}

#undef DIE
#define DIE(code,...) do { [self fail:[NSString stringWithFormat:@"" __VA_ARGS__]]; return; } while(0)
- (void)begin {
    if(atomic_load(&stopped)) return;
    if(_arguments.count<5){ [self fail:@"Invalid device connection arguments"];return; }
    LLNativeSession *previous;
    @synchronized(LLNativeSession.class){ previous=activeSession; }
    if(previous && previous!=self){ [previous close];[previous finish]; }
    @synchronized(LLNativeSession.class){ activeSession=self; }
    setenv("HIDCTL_QUIET","1",1);
    uint32_t count=0;CGGetActiveDisplayList(0,NULL,&count);
    [self emit:254 data:[[NSString stringWithFormat:@"native capture pid=%d, active displays=%u",getpid(),count] dataUsingEncoding:NSUTF8StringEncoding]];
    [self startLease];
    NSString *displayError=nil;
    NSDictionary *info=ipbDeviceControl(_arguments[0],@[@"device",@"info",@"displays"],&displayError);
    if(!info || !ipbParseDisplayInfo(info,&display)){ [self fail:displayError?:@"Invalid display metadata"];return; }
    dlopen("/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice",RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AVConference.framework/AVConference",RTLD_NOW);
    _coredevice_xpc_add_bundle([NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"]);
    _coredevice_xpc_init_services();
    buttons=[self openFeature:"com.apple.coredevice.feature.remote.hid.button" fd:&buttonFD];
    if(!buttons) return;
    NSString *wakeError=nil;
    if(![self wakeDisplayIfNeeded:&wakeError]){
        if(!atomic_load(&stopped)) [self fail:wakeError?:@"Device display wake failed"];
        return;
    }
    const char *dev=_arguments[0].UTF8String,*utun=_arguments[1].UTF8String,*rxip=_arguments[2].UTF8String,*txip=_arguments[3].UTF8String;
    __weak LLNativeSession *weakSelf=self;
    NSString *sessID = [[NSUUID UUID] UUIDString];
    Class N = objc_getClass("AVCMediaStreamNegotiator"); if(!N) DIE(2,"no AVCMediaStreamNegotiator");
    NSError *e=nil;
    id neg=[[N alloc] initWithMode:5 options:@{} error:&e];   // 5 = CoreDeviceScreenSharing
    if(!neg) DIE(2,"negotiator init: %s",e.description.UTF8String);
    if(![neg createOffer]) DIE(2,"createOffer failed");
    NSData *offer=[neg offer]; if(!offer.length) DIE(2,"empty offer");

    dispatch_queue_t q=dispatch_queue_create("ipb.video.cds",0);
    xpc_connection_t c=xpc_connection_create("com.apple.CoreDevice.CoreDeviceService",q);
    xpc_connection_set_event_handler(c,^(xpc_object_t x){});
    xpc_connection_resume(c);
    xpc_object_t in0=xpc_dictionary_create_empty();
    xpc_dictionary_set_string(in0,"featureIdentifier","com.apple.coredevice.feature.startmediastream");
    xpc_object_t rep=xpc_connection_send_message_with_reply_sync(c,action_env("com.apple.coredevice.action.createservicesocket",dev,in0));
    xpc_object_t out=rep && xpc_get_type(rep)==XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(rep,"CoreDevice.output") : NULL;
    if(!out) DIE(3,"createservicesocket: no output (device/service unavailable)");
    int sfd=xpc_dictionary_dup_fd(out,"fileDescriptor");
    uint64_t flags=xpc_dictionary_get_uint64(out,"remoteXPCVersionFlags");
    if(sfd<0) DIE(3,"no service fd");
    xrc_t rc=xpc_remote_connection_create_with_connected_fd(sfd,dispatch_queue_create("ipb.video.rc",0),flags,0);
    self.controlService=c; media=rc; mediaFD=-1; // RemoteXPC owns sfd
    if(!rc) DIE(3,"media RemoteXPC create failed");
    [self hold:rc];
    xpc_remote_connection_set_event_handler(rc,^(xpc_object_t ev){
        if(ev && xpc_get_type(ev)==XPC_TYPE_ERROR){
            const char *desc=xpc_dictionary_get_string(ev,XPC_ERROR_KEY_DESCRIPTION);
            [weakSelf fail:[NSString stringWithFormat:@"media RemoteXPC: %s",desc?desc:"unknown"]];
        }
    });
    xpc_remote_connection_activate(rc);

    int rtp=socket(AF_INET6,SOCK_DGRAM,0); rtpFD=rtp; if(rtp<0) DIE(3,"socket: %s",strerror(errno));
    int one=1; setsockopt(rtp,SOL_SOCKET,SO_REUSEADDR,&one,sizeof one); setsockopt(rtp,SOL_SOCKET,SO_REUSEPORT,&one,sizeof one);
    struct sockaddr_in6 la; memset(&la,0,sizeof la); la.sin6_len=sizeof la; la.sin6_family=AF_INET6;
    if(inet_pton(AF_INET6,rxip,&la.sin6_addr)!=1) DIE(2,"bad host IP %s",rxip);
    la.sin6_scope_id=if_nametoindex(utun); if(!la.sin6_scope_id) DIE(4,"no tunnel interface %s (is the device connected?)",utun);
    if(bind(rtp,(struct sockaddr*)&la,sizeof la)!=0) DIE(4,"bind [%s%%%s]: %s",rxip,utun,strerror(errno));
    socklen_t sl=sizeof la; if(getsockname(rtp,(struct sockaddr*)&la,&sl)!=0) DIE(3,"getsockname: %s",strerror(errno));
    uint16_t rxport=ntohs(la.sin6_port); if(!rxport) DIE(3,"no bound port");

    xpc_object_t in=xpc_dictionary_create_empty();
    xpc_dictionary_set_string(in,"receiverIP",rxip); xpc_dictionary_set_uint64(in,"receiverPort",rxport);
    xpc_dictionary_set_string(in,"senderIP",txip); xpc_dictionary_set_uint64(in,"senderPort",51000);
    xpc_dictionary_set_uint64(in,"timeout",30);
    xpc_dictionary_set_string(in,"type","video"); xpc_dictionary_set_string(in,"direction","output");
    xpc_dictionary_set_data(in,"negotiatorOffer",offer.bytes,offer.length);
    xpc_dictionary_set_uint64(in,"clientSupportedFeatures",972);
    xpc_object_t opts=xpc_dictionary_create_empty();
    uuid_t sessUU; uuid_parse(sessID.UTF8String, sessUU);
    xpc_object_t cvUUID=xpc_dictionary_create_empty(); xpc_dictionary_set_uuid(cvUUID,"uuid",sessUU);
    xpc_dictionary_set_value(opts,"avcMediaStreamOptionClientSessionID",cvUUID);
    xpc_dictionary_set_value(in,"options",opts);

    xpc_object_t srep=xpc_remote_connection_send_message_with_reply_sync(rc,action_env("com.apple.coredevice.action.mediastreamstart",dev,in));
    if(!srep || xpc_get_type(srep)!=XPC_TYPE_DICTIONARY) DIE(5,"mediastreamstart: null/error reply");
    xpc_object_t serr=xpc_dictionary_get_dictionary(srep,"CoreDevice.error");
    if(serr){ int64_t code=xpc_dictionary_get_int64(serr,"code"); const char*dom=xpc_dictionary_get_string(serr,"domain");
              DIE(5,"device rejected mediastreamstart: %s %lld",dom?dom:"?",(long long)code); }
    xpc_object_t so=xpc_dictionary_get_dictionary(srep,"CoreDevice.output");
    if(!so) DIE(5,"mediastreamstart: no output");
    size_t alen=0; const void*ans=xpc_dictionary_get_data(so,"negotiatorAnswer",&alen);
    if(!ans) ans=xpc_dictionary_get_data(so,"answer",&alen);
    if(!ans) DIE(5,"no negotiator answer from device");
    NSError *ae=nil;
    if(![neg setAnswer:[NSData dataWithBytes:ans length:alen] withError:&ae]) DIE(5,"setAnswer: %s",ae?ae.description.UTF8String:"?");
    id cfg=[neg generateMediaStreamConfigurationWithError:&ae]; if(!cfg) DIE(5,"generateConfiguration: %s",ae?ae.description.UTF8String:"?");
    id initOpts=[neg generateMediaStreamInitOptionsWithError:&ae]; if(!initOpts) DIE(5,"generateInitOptions: %s",ae?ae.description.UTF8String:"?");

    // learn the device's RTP source (MSG_PEEK, do not consume) and connect the socket to it
    struct timeval ptv={8,0}; setsockopt(rtp,SOL_SOCKET,SO_RCVTIMEO,&ptv,sizeof ptv);
    uint8_t pk[4]; struct sockaddr_in6 peer; socklen_t pl=sizeof peer;
    ssize_t pn=recvfrom(rtp,pk,sizeof pk,MSG_PEEK,(struct sockaddr*)&peer,&pl);
    if(pn<=0) DIE(6,"no RTP from device within 8s (peek: %s)",strerror(errno));
    if(connect(rtp,(struct sockaddr*)&peer,sizeof peer)!=0) DIE(6,"connect to RTP peer: %s",strerror(errno));

    NSMutableDictionary *o2=[NSMutableDictionary dictionary];
    if([initOpts isKindOfClass:[NSDictionary class]]) [o2 addEntriesFromDictionary:initOpts];
    o2[@"avcMediaStreamOptionRunInProcess"]=@(YES);   // default: decode in-process (no entitlement)
    o2[@"avcMediaStreamOptionClientName"]=@"CoreDeviceScreenSharing";
    o2[@"avcMediaStreamOptionClientSessionID"]=[[NSUUID alloc] initWithUUIDString:sessID];

    xpc_object_t socks=xpc_dictionary_create_empty();
    xpc_dictionary_set_fd(socks,"avcKeySharedSocket",rtp);
    self.delegateWork=dispatch_queue_create("ipb.mirror.media.delegate",DISPATCH_QUEUE_SERIAL);
    installNativeSink();
    if(!originalQueueStart) DIE(6,"Native image receiver unavailable");
    Class VS=objc_getClass("AVCVideoStream"); if(!VS) DIE(6,"no AVCVideoStream class");
    NSError *se=nil;
    AVCVideoStream *vs=[[VS alloc] initWithNetworkSockets:(id)socks options:o2 error:&se];
    if(!vs) DIE(6,"AVCVideoStream init: %s",se?se.description.UTF8String:"?");
    [vs setDelegate:self];
    NSError *ce=nil; if(![vs configure:cfg error:&ce]) DIE(6,"configure: %s",ce?ce.description.UTF8String:"?");
    self.stream=vs;
    if(atomic_load(&stopped)) return;
    [vs start];


    if(atomic_load(&stopped)) return;
    input=[self openFeature:"com.apple.coredevice.feature.remote.universalhidservice" fd:&inputFD];
    digitizer=[self openFeature:"com.apple.coredevice.feature.remote.hid.digitizer" fd:&digitizerFD];
    if(!input || !buttons || !digitizer) return;
    if(layerlens_native_service_ids(input,&touchService,&keyboardService)!=0 || !touchService){ [self fail:@"Touchscreen descriptor unavailable"];return; }
    [self emit:254 data:[[NSString stringWithFormat:@"native media and input ready, touch=0x%llx keyboard=0x%llx",(unsigned long long)touchService,(unsigned long long)keyboardService] dataUsingEncoding:NSUTF8StringEncoding]];
    self.geometryTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,nativeWork());
    dispatch_source_set_timer(self.geometryTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,NSEC_PER_SEC/10);
    dispatch_source_set_event_handler(self.geometryTimer,^{
        LLNativeSession *session=weakSelf;if(!session || atomic_load(&session->stopped)) return;
        NSString *error=nil;IPBDisplayInfo next={0};
        NSDictionary *info=ipbDeviceControl(session.arguments[0],@[@"device",@"info",@"displays"],&error);
        if(info && ipbParseDisplayInfo(info,&next)) @synchronized(session){ session->display=next; }
    });
    dispatch_resume(self.geometryTimer);
}
- (void)stream:(id)stream didStart:(BOOL)ok error:(NSError *)error { if(!ok) [self fail:error.description?:@"Video stream failed to start"]; }
- (void)streamDidStop:(id)stream { if(!atomic_load(&stopped)) [self fail:@"Video stream stopped"]; }
- (void)vcMediaStreamDidStop:(id)stream { [self streamDidStop:stream]; }
- (void)streamDidServerDie:(id)stream { [self streamDidStop:stream]; }
- (void)vcMediaStreamDidRTPTimeOut:(id)stream {
    if(!atomic_load(&stopped)) [self fail:@"Device video stream timed out"];
}
- (void)vcMediaStreamDidRTCPTimeOut:(id)stream {
    [self emit:254 data:[@"device media RTCP timed out" dataUsingEncoding:NSUTF8StringEncoding]];
}
- (void)didStall:(BOOL)stalled {
    [self emit:254 data:[[NSString stringWithFormat:@"device video output stalled=%@",stalled?@"YES":@"NO"] dataUsingEncoding:NSUTF8StringEncoding]];
    [self emitVideoState:@"stalled" active:!stalled];
}
- (void)didPause:(BOOL)paused {
    [self emit:254 data:[[NSString stringWithFormat:@"device video output paused=%@",paused?@"YES":@"NO"] dataUsingEncoding:NSUTF8StringEncoding]];
    [self emitVideoState:@"paused" active:!paused];
}
- (void)didSuspend:(BOOL)suspended {
    [self emit:254 data:[[NSString stringWithFormat:@"device video output suspended=%@",suspended?@"YES":@"NO"] dataUsingEncoding:NSUTF8StringEncoding]];
    [self emitVideoState:@"suspended" active:!suspended];
}
- (void)didInvalidate {
    if(!atomic_load(&stopped)) [self fail:@"Device video output invalidated"];
}
- (void)didReceiveSampleBuffer:(CMSampleBufferRef)sample { [self receive:sample]; }
- (void)streamOutput:(id)output didReceiveSampleBuffer:(CMSampleBufferRef)sample { [self receive:sample]; }
- (void)receive:(CMSampleBufferRef)sample {
    if(!sample || !CMSampleBufferGetImageBuffer(sample) || atomic_load(&stopped)) return;
    @synchronized(self){
        if(atomic_load(&stopped)) return;
        if(latest) CFRelease(latest);
        CFRetain(sample);latest=sample;
        if(writing) return;
        writing=YES;
    }
    dispatch_async(_imageWork,^{ @autoreleasepool {
        for(;;){ @autoreleasepool {
            CMSampleBufferRef current;IPBDisplayInfo frameDisplay;
            @synchronized(self){ current=self->latest;self->latest=NULL;frameDisplay=self->display;if(!current) self->writing=NO; }
            if(!current) return;
            if(atomic_load(&self->stopped)){ CFRelease(current);continue; }
            struct timespec tick;clock_gettime(CLOCK_MONOTONIC,&tick);
            double now=tick.tv_sec+tick.tv_nsec/1e9;
            if(now-self->lastImageTime<1.0/30){ CFRelease(current);continue; }
            self->lastImageTime=now;
            CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(current);
            CGFloat width=MIN(frameDisplay.nativeSize.width,CVPixelBufferGetWidth(pixels));
            CGFloat height=MIN(frameDisplay.nativeSize.height,CVPixelBufferGetHeight(pixels));
            NSDictionary *geometry=@{@"width":@(width),@"height":@(height),@"pointScale":@(frameDisplay.pointScale),
                @"orientation":@[@1,@3,@2,@4][frameDisplay.deviceQuarter&3],@"transport":@"h264"};
            NSData *metadata=[NSJSONSerialization dataWithJSONObject:geometry options:NSJSONWritingSortedKeys error:nil];
            if(![metadata isEqual:self.lastGeometry]){ [self emit:9 data:metadata];self.lastGeometry=metadata; }
            // Borrowed pixel buffer: Swift retains it before returning. No JPEG or pixel copy.
            @synchronized(self){
                if(self->callback && !atomic_load(&self->stopped))
                    self->callback(self->context,10,(const void *)pixels,0);
            }
            CFRelease(current);
        }}
    }});
}
- (int)send:(int (^)(void))work {
    bool started=false;
    int result=ipb_bounded_call(&sender,ipb_bounded_now_ns()+2*NSEC_PER_SEC,work,&started);
    if(result) [self fail:[NSString stringWithFormat:@"Device input failed (%d)",result]];
    return result;
}
- (void)touch:(BOOL)down {
    uint64_t words[2]={0};
    if(uhid_make_edge_touch_hid_report(x,y,down,down,edge?display.contentQuarter:-1,words)!=sizeof words){ [self fail:@"Touch report construction failed"];return; }
    NSData *data=[NSData dataWithBytes:words length:sizeof words];
    [self send:^{ return coredevice_send_universalhid_hid_report(self->input,data.bytes,self->touchService); }];
    if(!down) [self send:^{ return coredevice_send_universalhid_barrier(self->input); }];
}
- (void)keyboard:(IPBKeyboardState)state {
    uint64_t words[2]={0};
    uint32_t usages[232]={0};unsigned count=ipbKeyboardUsages(state,usages);
    if(uhid_make_keyboard_state_hid_report(usages,(int32_t)count,words)!=sizeof words){ [self fail:@"Keyboard report construction failed"];return; }
    NSData *data=[NSData dataWithBytes:words length:sizeof words];
    [self send:^{ return coredevice_send_universalhid_hid_report(self->input,data.bytes,self->keyboardService); }];
}
// nativeWork owns display queries and wake transitions, for startup and reuse.
- (BOOL)wakeDisplayIfNeeded:(NSString **)error {
    if(atomic_load(&stopped) || !buttons) return NO;
    NSDictionary *info=ipbDeviceControl(_arguments[0],@[@"device",@"info",@"displays"],error);
    if(atomic_load(&stopped)) return NO;
    if(!info) return NO;
    NSString *backlight=info[@"backlightState"];
    [self emit:254 data:[[NSString stringWithFormat:@"device wake check: backlight=%@",backlight?:@"unknown"] dataUsingEncoding:NSUTF8StringEncoding]];
    // Sleep/wake is a toggle. Never toggle an on or unknown display.
    if(![backlight isEqual:@"off"]) return YES;
    [self emit:254 data:[@"device display asleep; sending sleep/wake" dataUsingEncoding:NSUTF8StringEncoding]];
    if([self send:^{ return coredevice_send_hid_button_custom(self->buttons,0x0c,0x30,0); }]) return NO;
    usleep(80000);
    if([self send:^{ return coredevice_send_hid_button_custom(self->buttons,0x0c,0x30,1); }]) return NO;
    if([self send:^{ return coredevice_send_hid_button_barrier(self->buttons); }]) return NO;
    uint64_t deadline=ipb_bounded_now_ns()+3*NSEC_PER_SEC;
    do {
        if(atomic_load(&stopped)) return NO;
        usleep(100000);
        info=ipbDeviceControl(_arguments[0],@[@"device",@"info",@"displays"],error);
    } while([info[@"backlightState"] isEqual:@"off"] && ipb_bounded_now_ns()<deadline);
    if(atomic_load(&stopped)) return NO;
    if(!info || [info[@"backlightState"] isEqual:@"off"]){
        if(!*error) *error=@"Device display did not wake; retry the connection.";
        return NO;
    }
    [self emit:254 data:[@"device display awake; media may resume" dataUsingEncoding:NSUTF8StringEncoding]];
    return YES;
}
- (void)handle:(NSDictionary *)message {
    if(atomic_load(&stopped)) return;
    if([message[@"type"] isEqual:@"resume"]){
        if(atomic_exchange(&resumePending,true)) return;
        dispatch_async(nativeWork(),^{ @autoreleasepool {
            @try {
                if(atomic_load(&self->stopped)) return;
                NSString *error=nil;
                if(![self wakeDisplayIfNeeded:&error] && !atomic_load(&self->stopped)){
                    NSDictionary *result=@{@"type":@"input-error",@"detail":@"wake-unavailable",@"message":error?:@"Device display wake failed"};
                    [self emit:8 data:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]];
                }
            } @finally { atomic_store(&self->resumePending,false); }
        }});
        return;
    }
    if([message[@"type"] isEqual:@"rotate"]){
        NSString *direction=message[@"direction"], *requestID=message[@"requestId"];
        if(![@[@"left",@"right"] containsObject:direction] || ![requestID isKindOfClass:NSString.class] || requestID.length>128) return;
        if(atomic_exchange(&rotating,true)){
            NSDictionary *result=@{@"type":@"rotation-result",@"requestId":requestID,@"ok":@NO,@"detail":@"Rotation is already in progress"};
            [self emit:8 data:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]];
            return;
        }
        // 方向控制走独立 CoreDevice 命令, 不阻塞触摸/键盘队列。
        dispatch_async(nativeWork(),^{ @autoreleasepool {
            if(atomic_load(&self->stopped)){ atomic_store(&self->rotating,false);return; }
            NSString *error=nil;
            NSDictionary *reply=ipbDeviceControl(self.arguments[0],@[@"device",@"orientation",@"rotate",direction],&error);
            NSMutableDictionary *result=[@{@"type":@"rotation-result",@"requestId":requestID,@"ok":@(reply!=nil),@"detail":error?:@""} mutableCopy];
            int q=ipbDeviceQuarter(reply[@"deviceOrientation"]);
            if(q<0) q=ipbDeviceQuarter(reply[@"deviceOrientationNonFlat"]);
            if(reply && q>=0){
                @synchronized(self){ self->display.deviceQuarter=q; }
                result[@"orientation"]=@[@1,@3,@2,@4][q];
            }
            atomic_store(&self->rotating,false);
            if(!atomic_load(&self->stopped)) [self emit:8 data:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]];
        }});
        return;
    }
    dispatch_async(_inputWork,^{ @autoreleasepool {
        if(atomic_load(&self->stopped) || !self->input) return;
        NSString *type=message[@"type"];
        BOOL needsWake=NO;
        @synchronized(self){ needsWake=ipbDisplayNeedsWake(self->display); }
        BOOL explicitSleepWake=[type isEqual:@"button"] && [message[@"button"] isEqual:@"sleep-wake"];
        BOOL userInput=[type isEqual:@"touch1-down"] || [type isEqual:@"key"] || [type isEqual:@"paste"] ||
            ([type isEqual:@"button"] && !explicitSleepWake);
        if(needsWake && userInput){
            // Device control stays on nativeWork. The serial input queue waits for
            // that transition so touch-down/up ordering is preserved.
            __block BOOL awake=NO;
            __block NSString *wakeError=nil;
            dispatch_semaphore_t done=dispatch_semaphore_create(0);
            dispatch_async(nativeWork(),^{ @autoreleasepool {
                awake=[self wakeDisplayIfNeeded:&wakeError];
                if(awake) @synchronized(self){ self->display.backlightKnown=YES;self->display.backlightOn=YES; }
                dispatch_semaphore_signal(done);
            }});
            dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC));
            if(!awake || atomic_load(&self->stopped)){
                if(!atomic_load(&self->stopped) && wakeError){
                    NSDictionary *result=@{@"type":@"input-error",@"detail":@"wake-unavailable",@"message":wakeError};
                    [self emit:8 data:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]];
                }
                return;
            }
        }
        if([type hasPrefix:@"touch1-"]){
            double width=[message[@"width"] doubleValue],height=[message[@"height"] doubleValue];
            if(width<=0 || height<=0) return;
            self->x=fmax(0,fmin(1,[message[@"x"] doubleValue]/width));
            self->y=fmax(0,fmin(1,[message[@"y"] doubleValue]/height));
            if([type isEqual:@"touch1-down"]){ self->touching=YES;self->edge=self->y>=.98; }
            if(!self->touching) return;
            BOOL up=[type isEqual:@"touch1-up"];
            [self touch:!up];if(up) self->touching=NO;
        }else if([type isEqual:@"release"]){
            if(self->touching){ [self touch:NO];self->touching=NO; }
            IPBKeyboardState empty={0};if(self->keyboardService) [self keyboard:empty];
        }else if([type isEqual:@"button"]){
            uint64_t page=[message[@"button"] isEqual:@"app-switcher"]?0xff01:0x0c;
            uint64_t usage=page==0xff01?0x10:([message[@"button"] isEqual:@"sleep-wake"]?0x30:0x40);
            [self send:^{ return coredevice_send_hid_button_custom(self->buttons,page,usage,0); }];
            usleep(80000);
            [self send:^{ return coredevice_send_hid_button_custom(self->buttons,page,usage,1); }];
            [self send:^{ return coredevice_send_hid_button_barrier(self->buttons); }];
        }else if([type isEqual:@"key"] || [type isEqual:@"paste"]){
            NSString *code=message[@"code"];uint32_t usage=0;
            IPBKeyboardState state={0};
            if([type isEqual:@"paste"]){
                NSData *text=[message[@"text"] dataUsingEncoding:NSUTF8StringEncoding];NSString *error=nil;
                if(text.length>IPBDevicePayloadLimit) return;
                (void)ipbDeviceCommand(self.arguments[0],@[@"device",@"pasteboard",@"copy"],text,NO,&error);
                if(error){ [self fail:error];return; }
                usage=25;ipbKeyboardSet(&state,227,true);
            }else{
                if([code hasPrefix:@"Key"] && code.length==4) usage=[code characterAtIndex:3]-'A'+4;
                else if([code hasPrefix:@"Digit"] && code.length==6){ int n=[code characterAtIndex:5]-'0';usage=n?n+29:39; }
                else usage=[@{@"Enter":@40,@"Escape":@41,@"Backspace":@42,@"Tab":@43,@"Space":@44,@"Minus":@45,@"Equal":@46,@"BracketLeft":@47,@"BracketRight":@48,@"Backslash":@49,@"Semicolon":@51,@"Quote":@52,@"Backquote":@53,@"Comma":@54,@"Period":@55,@"Slash":@56,@"ArrowRight":@79,@"ArrowLeft":@80,@"ArrowDown":@81,@"ArrowUp":@82} [code] unsignedIntValue];
                for(NSString *modifier in message[@"modifiers"]){ uint32_t u=[@{@"control":@224,@"shift":@225,@"alt":@226,@"option":@226,@"command":@227}[modifier] unsignedIntValue];if(u) ipbKeyboardSet(&state,u,true); }
            }
            if(!usage || !self->keyboardService) return;
            ipbKeyboardSet(&state,usage,true);[self keyboard:state];usleep(40000);
            IPBKeyboardState empty={0};[self keyboard:empty];
            [self send:^{ return coredevice_send_universalhid_barrier(self->input); }];
        }
    }});
}
- (void)close {
    if(atomic_exchange(&stopped,true)) return;
    [self.leaseLifetime closeFile];
    dispatch_async(nativeWork(),^{ [self finish]; });
}
- (void)finish {
    if(!callback) return;
    atomic_store(&stopped,true);
    if(_geometryTimer){ dispatch_source_cancel(_geometryTimer);_geometryTimer=nil; }
    NSTask *lease=self.lease;
    [self.leaseLifetime closeFile];self.leaseLifetime=nil;
    lease.terminationHandler=nil;self.lease=nil;
    dispatch_sync(_inputWork,^{
        if(self->touching && self->input){ [self touch:NO];self->touching=NO; }
    });
    BOOL drained=ipb_bounded_sender_close(&sender,ipb_bounded_now_ns()+3*NSEC_PER_SEC);
    [_stream stop];
    if(_imageQueue) [(VCImageQueue*)_imageQueue setStreamOutput:nil];
    _imageQueue=nil;_frameOutput=nil;_stream=nil;
    dispatch_sync(_imageWork,^{});
    if(media) xpc_remote_connection_cancel(media);
    if(drained){
        if(input) xpc_remote_connection_cancel(input);
        if(buttons) xpc_remote_connection_cancel(buttons);
        if(digitizer) xpc_remote_connection_cancel(digitizer);
    }
    if(_controlService) xpc_connection_cancel(_controlService);_controlService=nil;
    @synchronized(LLNativeSession.class){ if(activeSession==self) activeSession=nil; }
    [self emit:0 data:NSData.data];
    @synchronized(self){ callback=NULL;context=NULL; }
}
- (void)dealloc {
    if(latest) CFRelease(latest);
    for(NSNumber *fd in @[@(mediaFD),@(rtpFD),@(inputFD),@(buttonFD),@(digitizerFD)]) if(fd.intValue>=0) close(fd.intValue);
    pthread_mutex_destroy(&sender.lock);pthread_cond_destroy(&sender.idle);
}
@end

void *LLNativeCreate(const char *json,LLNativeCallback callback,void *context){ @autoreleasepool {
    NSData *data=json?[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding]:nil;
    NSArray *args=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![args isKindOfClass:NSArray.class] || args.count<5) return NULL;
    LLNativeSession *session=[LLNativeSession new];session.arguments=args;session->callback=callback;session->context=context;
    dispatch_async(nativeWork(),^{ @autoreleasepool { @try { [session begin]; } @catch(NSException *error){ [session fail:error.reason?:@"Native capture exception"]; } if(atomic_load(&session->stopped)) [session finish]; } });
    return (__bridge_retained void*)session;
}}
void LLNativeInput(void *token,const char *json){ @autoreleasepool {
    if(!token || !json) return;
    NSData *data=[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
    id message=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if([message isKindOfClass:NSDictionary.class]) [(__bridge LLNativeSession*)token handle:message];
}}
void LLNativeClose(void *token){
    if(!token) return;
    LLNativeSession *session=CFBridgingRelease(token);[session close];
}
