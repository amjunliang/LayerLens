
//
//  LayerLens_MessageProtocol.h
//  Lookin
//
//  Created by Li Kai on 2018/8/6.
//  https://lookin.work
//

#import "TargetConditionals.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#elif TARGET_OS_MAC
#import <Appkit/Appkit.h>
#endif

#include <stdint.h>

#pragma mark - Version

/// current connection protocol version of LayerLens_Server
static const int LAYERLENS_SERVER_VERSION = 7;

/// current release version of LayerLens_Server
static NSString * const LAYERLENS_SERVER_READABLE_VERSION = @"1.2.8";

/// current connection protocol version of LayerLens_Client
static const int LAYERLENS_CLIENT_VERSION = 7;

/// the minimum connection protocol version supported by current LayerLens_Client
static const int LAYERLENS_SUPPORTED_SERVER_MIN = 7;
/// the maximum connection protocol version supported by current LayerLens_Client
static const int LAYERLENS_SUPPORTED_SERVER_MAX = 7;

#pragma mark - Connection

/// LayerLens_Server 在真机上会依次尝试监听 47175 ~ 47179 这几个端口
static const int LayerLens_USBDeviceIPv4PortNumberStart = 47175;
static const int LayerLens_USBDeviceIPv4PortNumberEnd = 47179;

/// LayerLens_Server 在模拟器中会依次尝试监听 47164 ~ 47169 这几个端口
static const int LayerLens_SimulatorIPv4PortNumberStart = 47164;
static const int LayerLens_SimulatorIPv4PortNumberEnd = 47169;

enum {
    /// 确认两端是否可以响应通讯
    LayerLens_RequestTypePing = 200,
    /// 请求 App 的截图、设备型号等信息
    LayerLens_RequestTypeApp = 201,
    /// 请求 Hierarchy 信息
    LayerLens_RequestTypeHierarchy = 202,
    /// 请求 screenshots 和 attrGroups 信息
    LayerLens_RequestTypeHierarchyDetails = 203,
    /// 请求修改某个内置的 Attribute 的值
    LayerLens_RequestTypeInbuiltAttrModification = 204,
    /// 修改某个 attr 后，请求一系列最新的 Screenshots、属性值等信息
    LayerLens_RequestTypeAttrModificationPatch = 205,
    /// 执行某个方法
    LayerLens_RequestTypeInvokeMethod = 206,
    /**
     @request: @{@"oid":}
     @response: LayerLens_Object *
     */
    LayerLens_RequestTypeFetchObject = 207,
    
    LayerLens_RequestTypeFetchImageViewImage = 208,
    
    LayerLens_RequestTypeModifyRecognizerEnable = 209,
    
    /// 请求 attribute group list
    LayerLens_RequestTypeAllAttrGroups = 210,
    
    /// 请求 iOS App 里某个 class 的所有 selector 名字列表（包括 superclass）
    LayerLens_RequestTypeAllSelectorNames = 213,
    
    /// 请求修改某个自定义 Attribute 的值
    LayerLens_RequestTypeCustomAttrModification = 214,
    
    /// 从 LayerLens_Server 1.2.7 & Lookin 1.0.7 开始，该属性被废弃、不再使用
    LayerLens_Push_BringForwardScreenshotTask = 303,
    
    // 用户在 Lookin 客户端取消了之前 HierarchyDetails 的拉取
    LayerLens_Push_CanceHierarchyDetails = 304,
};

static NSString * const LayerLens_Param_ViewLayerTag = @"tag";

static NSString * const LayerLens_Param_SelectorName = @"sn";
static NSString * const LayerLens_Param_MethodType = @"mt";
static NSString * const LayerLens_Param_SelectorClassName = @"scn";

static NSString * const LayerLens_StringFlag_VoidReturn = @"LAYERLENS_TAG_RETURN_VALUE_VOID";

#pragma mark - Error

static NSString * const LayerLens_ErrorDomain = @"LayerLens_Error";

enum {
    LayerLens_ErrCode_Default = -400,
    /// Lookin 内部业务逻辑错误
    LayerLens_ErrCode_Inner = -401,
    /// PeerTalk 内部错误
    LayerLens_ErrCode_PeerTalk = -402,
    /// 连接不存在或已断开
    LayerLens_ErrCode_NoConnect = -403,
    /// ping 失败了，原因是 ping 请求超时
    LayerLens_ErrCode_PingFailForTimeout = -404,
    /// 请求超时未返回
    LayerLens_ErrCode_Timeout = -405,
    /// 有相同 Type 的新请求被发出，因此旧请求被丢弃
    LayerLens_ErrCode_Discard = -406,
    /// ping 失败了，原因是 app 主动报告自身正处于后台模式
    LayerLens_ErrCode_PingFailForBackgroundState = -407,
    
    /// 没有找到对应的对象，可能已被释放
    LayerLens_ErrCode_ObjectNotFound = -500,
    /// 不支持修改当前类型的 LayerLens_CodingValueType
    LayerLens_ErrCode_ModifyValueTypeInvalid = -501,
    LayerLens_ErrCode_Exception = -502,
    
    // LayerLens_Server 版本过高，要升级 client
    LayerLens_ErrCode_ServerVersionTooHigh = -600,
    // LayerLens_Server 版本过低，要升级 server
    LayerLens_ErrCode_ServerVersionTooLow = -601,
    
    // 不支持的文件类型
    LayerLens_ErrCode_UnsupportedFileType = -700,
};

#define LayerLens_Err_ObjNotFound [NSError errorWithDomain:LayerLens_ErrorDomain code:LayerLens_ErrCode_ObjectNotFound userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"Failed to get target object in iOS app", nil), NSLocalizedRecoverySuggestionErrorKey:NSLocalizedString(@"Perhaps the related object was deallocated. You can reload Lookin to get newest data.", nil)}]

#define LayerLens_Err_NoConnect [NSError errorWithDomain:LayerLens_ErrorDomain code:LayerLens_ErrCode_NoConnect userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"The operation failed due to disconnection with the iOS app.", nil)}]

#define LayerLens_Err_Inner [NSError errorWithDomain:LayerLens_ErrorDomain code:LayerLens_ErrCode_Inner userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"The operation failed due to an inner error.", nil)}]

#define LayerLens_ErrorMake(errorTitle, errorDetail) [NSError errorWithDomain:LayerLens_ErrorDomain code:LayerLens_ErrCode_Default userInfo:@{NSLocalizedDescriptionKey:errorTitle, NSLocalizedRecoverySuggestionErrorKey:errorDetail}]

#define LayerLens_ErrorText_Timeout NSLocalizedString(@"Perhaps your iOS app is paused with breakpoint in Xcode, blocked by other tasks in main thread, or moved to background state.", nil)

#pragma mark - Colors

#if TARGET_OS_IPHONE
#define LayerLens_Color UIColor
#define LayerLens_Insets UIEdgeInsets
#define LayerLens_Image UIImage
#elif TARGET_OS_MAC
#define LayerLens_Color NSColor
#define LayerLens_Insets NSEdgeInsets
#define LayerLens_Image NSImage
#endif

#define LayerLens_ColorRGBAMake(r, g, b, a) [LayerLens_Color colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a]
#define LayerLens_ColorMake(r, g, b) [LayerLens_Color colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1]

#pragma mark - Preview

/// SCNNode 所允许的图片的最大的长和宽，单位是 px，这个值是 Scenekit 自身指定的
/// Max pixel size of a SCNNode object. It is designated by SceneKit.
static const double LayerLens_NodeImageMaxLengthInPx = 16384;

typedef NS_OPTIONS(NSUInteger, LayerLens_PreviewBitMask) {
    LayerLens_PreviewBitMask_None = 0,
    
    LayerLens_PreviewBitMask_Selectable = 1 << 1,
    LayerLens_PreviewBitMask_Unselectable = 1 << 2,
    
    LayerLens_PreviewBitMask_HasLight = 1 << 3,
    LayerLens_PreviewBitMask_NoLight = 1 << 4
};

