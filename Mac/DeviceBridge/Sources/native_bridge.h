#include <stdint.h>
#include <stddef.h>
// Callback data is borrowed for the duration of the call. 0 = closed,
// 9 = geometry JSON, 10 = borrowed CVPixelBuffer pointer (count=0),
// 254 = status UTF-8, 255 = error UTF-8. Retain pixels before returning if needed.
typedef void (*LLNativeCallback)(void *,uint8_t,const void *,size_t);
void *LLNativeCreate(const char *argumentsJSON,LLNativeCallback callback,void *context);
void LLNativeInput(void *session,const char *messageJSON);
void LLNativeClose(void *session);
