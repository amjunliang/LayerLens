#import <VideoToolbox/VideoToolbox.h>
#include <stdbool.h>
// Interposition is confined to our own helper. Apple's processes are untouched.
static bool (*sink)(CMSampleBufferRef);
void LLSetCompressedSink(bool (*callback)(CMSampleBufferRef)) { sink=callback; }
static bool consume(CMSampleBufferRef b){ return sink && sink(b); }
static OSStatus decode(VTDecompressionSessionRef s,CMSampleBufferRef b,VTDecodeFrameFlags f,void*r,VTDecodeInfoFlags*i){
    if(consume(b)){ if(i)*i=0; return noErr; } return VTDecompressionSessionDecodeFrame(s,b,f,r,i);
}
static OSStatus options(VTDecompressionSessionRef s,CMSampleBufferRef b,VTDecodeFrameFlags f,CFDictionaryRef o,void*r,VTDecodeInfoFlags*i){
    if(consume(b)){ if(i)*i=0; return noErr; } return VTDecompressionSessionDecodeFrameWithOptions(s,b,f,o,r,i);
}
static OSStatus handler(VTDecompressionSessionRef s,CMSampleBufferRef b,VTDecodeFrameFlags f,VTDecodeInfoFlags*i,VTDecompressionOutputHandler h){
    if(consume(b)){ if(i)*i=0; return noErr; } return VTDecompressionSessionDecodeFrameWithOutputHandler(s,b,f,i,h);
}
static OSStatus optionsHandler(VTDecompressionSessionRef s,CMSampleBufferRef b,VTDecodeFrameFlags f,CFDictionaryRef o,VTDecodeInfoFlags*i,VTDecompressionOutputHandler h){
    if(consume(b)){ if(i)*i=0; return noErr; } return VTDecompressionSessionDecodeFrameWithOptionsAndOutputHandler(s,b,f,o,i,h);
}
static OSStatus multi(VTDecompressionSessionRef s,CMSampleBufferRef b,VTDecodeFrameFlags f,VTDecodeInfoFlags*i,VTDecompressionMultiImageCapableOutputHandler h){
    if(consume(b)){ if(i)*i=0; return noErr; } return VTDecompressionSessionDecodeFrameWithMultiImageCapableOutputHandler(s,b,f,i,h);
}
#define INTERPOSE(replacement,original) __attribute__((used)) static struct {const void *replacement;const void *original;} interpose_##original __attribute__((section("__DATA,__interpose")))={(const void*)&replacement,(const void*)&original};
INTERPOSE(decode,VTDecompressionSessionDecodeFrame)
INTERPOSE(options,VTDecompressionSessionDecodeFrameWithOptions)
INTERPOSE(handler,VTDecompressionSessionDecodeFrameWithOutputHandler)
INTERPOSE(optionsHandler,VTDecompressionSessionDecodeFrameWithOptionsAndOutputHandler)
INTERPOSE(multi,VTDecompressionSessionDecodeFrameWithMultiImageCapableOutputHandler)
extern OSStatus VCPDecompressionSessionDecodeFrame(void *,CMSampleBufferRef,VTDecodeFrameFlags,void*,VTDecodeInfoFlags*);
static OSStatus vcp(void*s,CMSampleBufferRef b,VTDecodeFrameFlags f,void*r,VTDecodeInfoFlags*i){
    if(consume(b)){ if(i)*i=0; return noErr; } return VCPDecompressionSessionDecodeFrame(s,b,f,r,i);
}
INTERPOSE(vcp,VCPDecompressionSessionDecodeFrame)
