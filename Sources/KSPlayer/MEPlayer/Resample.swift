//
//  SWScale.swift
//  KSPlayer-iOS
//
//  Created by wangjinbian on 2020/1/27.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import ffmpeg
import VideoToolbox
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

protocol Swresample {
    func transfer(avframe: UnsafeMutablePointer<AVFrame>, timebase: Timebase) -> Frame
    func shutdown()
}

class VideoSwresample: Swresample {
    private let dstFormat: AVPixelFormat
    private var imgConvertCtx: OpaquePointer?
    private var format: AVPixelFormat = AV_PIX_FMT_NONE
    private var height: Int32 = 0
    private var width: Int32 = 0
    private var forceTransfer: Bool
    var dstFrame: UnsafeMutablePointer<AVFrame>?
    init(dstFormat: AVPixelFormat, forceTransfer: Bool = false) {
        self.dstFormat = dstFormat
        self.forceTransfer = forceTransfer
    }

    private func setup(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        setup(format: frame.pointee.format, width: frame.pointee.width, height: frame.pointee.height)
    }

    func setup(format: Int32, width: Int32, height: Int32) -> Bool {
        if self.format.rawValue == format, self.width == width, self.height == height {
            return true
        }
        shutdown()
        self.format = AVPixelFormat(rawValue: format)
        self.height = height
        self.width = width
        if !forceTransfer, PixelBuffer.isSupported(format: self.format) {
            return true
        }
        imgConvertCtx = sws_getCachedContext(imgConvertCtx, width, height, self.format, width, height, dstFormat, SWS_BICUBIC, nil, nil, nil)
        guard imgConvertCtx != nil else {
            return false
        }
        dstFrame = av_frame_alloc()
        guard let dstFrame = dstFrame else {
            sws_freeContext(imgConvertCtx)
            imgConvertCtx = nil
            return false
        }
        dstFrame.pointee.width = width
        dstFrame.pointee.height = height
        dstFrame.pointee.format = dstFormat.rawValue
        av_image_alloc(&dstFrame.pointee.data.0, &dstFrame.pointee.linesize.0, width, height, AVPixelFormat(rawValue: dstFrame.pointee.format), 64)
        return true
    }

    func transfer(avframe: UnsafeMutablePointer<AVFrame>, timebase: Timebase) -> Frame {
        let frame = VideoVTBFrame()
        frame.timebase = timebase
        if avframe.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            // swiftlint:disable force_cast
            frame.corePixelBuffer = avframe.pointee.data.3 as! CVPixelBuffer
            // swiftlint:enable force_cast
        } else {
            if setup(frame: avframe), let dstFrame = dstFrame, swsConvert(data: Array(tuple: avframe.pointee.data), linesize: Array(tuple: avframe.pointee.linesize)) {
                avframe.pointee.format = dstFrame.pointee.format
                avframe.pointee.data = dstFrame.pointee.data
                avframe.pointee.linesize = dstFrame.pointee.linesize
            }
            frame.corePixelBuffer = PixelBuffer(frame: avframe)
        }
        frame.duration = avframe.pointee.pkt_duration
        frame.size = Int64(avframe.pointee.pkt_size)
        return frame
    }

    func transfer(format: AVPixelFormat, width: Int32, height: Int32, data: [UnsafeMutablePointer<UInt8>?], linesize: [Int32]) -> UIImage? {
        if setup(format: format.rawValue, width: width, height: height), swsConvert(data: data, linesize: linesize), let frame = dstFrame?.pointee {
            return UIImage(rgbData: frame.data.0!, linesize: Int(frame.linesize.0), width: Int(width), height: Int(height), isAlpha: dstFormat == AV_PIX_FMT_RGBA)
        }
        return nil
    }

    private func swsConvert(data: [UnsafeMutablePointer<UInt8>?], linesize: [Int32]) -> Bool {
        guard let dstFrame = dstFrame else {
            return false
        }
        let result = sws_scale(imgConvertCtx, data.map { UnsafePointer($0) }, linesize, 0, height, &dstFrame.pointee.data.0, &dstFrame.pointee.linesize.0)
        return result > 0
    }

    func shutdown() {
        av_frame_free(&dstFrame)
        sws_freeContext(imgConvertCtx)
        imgConvertCtx = nil
    }

    static func == (lhs: VideoSwresample, rhs: AVFrame) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.format.rawValue == rhs.format
    }
}

class PixelBuffer: BufferProtocol {
    let format: OSType
    let width: Int
    let height: Int
    let planeCount: Int
    let isFullRangeVideo: Bool
    let colorAttachments: NSString
    let drawableSize: CGSize
    private let formats: [MTLPixelFormat]
    private let widths: [Int]
    private let heights: [Int]
    private let dataWrap: ByteDataWrap
    private let bytesPerRow: [Int32]
    init(frame: UnsafeMutablePointer<AVFrame>) {
        format = AVPixelFormat(rawValue: frame.pointee.format).format
        if frame.pointee.colorspace == AVCOL_SPC_BT709 {
            colorAttachments = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        } else {
            //        else if frame.colorspace == AVCOL_SPC_SMPTE170M || frame.colorspace == AVCOL_SPC_BT470BG {
            colorAttachments = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        }
        width = Int(frame.pointee.width)
        height = Int(frame.pointee.height)
        isFullRangeVideo = format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        bytesPerRow = Array(tuple: frame.pointee.linesize)
        let vertical = Int(frame.pointee.sample_aspect_ratio.den)
        let horizontal = Int(frame.pointee.sample_aspect_ratio.num)
        if vertical > 0, horizontal > 0, vertical != horizontal {
            drawableSize = CGSize(width: width, height: height * vertical / horizontal)
        } else {
            drawableSize = CGSize(width: width, height: height)
        }
        switch format {
        case kCVPixelFormatType_420YpCbCr8Planar:
            planeCount = 3
            formats = [.r8Unorm, .r8Unorm, .r8Unorm]
            widths = [width, width / 2, width / 2]
            heights = [height, height / 2, height / 2]
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            planeCount = 2
            formats = [.r8Unorm, .rg8Unorm]
            widths = [width, width / 2]
            heights = [height, height / 2]
        default:
            planeCount = 1
            formats = [.bgra8Unorm]
            widths = [width]
            heights = [height]
        }
        dataWrap = ObjectPool.share.object(class: ByteDataWrap.self, key: "VideoData") { ByteDataWrap() }
        let bytes = Array(tuple: frame.pointee.data)
        dataWrap.size = (0 ..< planeCount).map { Int(bytesPerRow[$0]) * heights[$0] }
        (0 ..< planeCount).forEach { i in
            dataWrap.data[i]?.assign(from: bytes[i]!, count: dataWrap.size[i])
        }
    }

    deinit {
        ObjectPool.share.comeback(item: dataWrap, key: "VideoData")
    }

    func textures(frome cache: MetalTextureCache) -> [MTLTexture] {
        cache.textures(formats: formats, widths: widths, heights: heights, bytes: dataWrap.data, bytesPerRows: bytesPerRow)
    }

    func widthOfPlane(at planeIndex: Int) -> Int {
        widths[planeIndex]
    }

    func heightOfPlane(at planeIndex: Int) -> Int {
        heights[planeIndex]
    }

    public static func isSupported(format: AVPixelFormat) -> Bool {
        [AV_PIX_FMT_NV12, AV_PIX_FMT_YUV420P, AV_PIX_FMT_BGRA].contains(format)
    }

    func image() -> UIImage? {
        var image: UIImage?
        if format.format == AV_PIX_FMT_RGB24 {
            image = UIImage(rgbData: dataWrap.data[0]!, linesize: Int(bytesPerRow[0]), width: width, height: height)
        }
        let scale = VideoSwresample(dstFormat: AV_PIX_FMT_RGB24, forceTransfer: true)
        image = scale.transfer(format: format.format, width: Int32(width), height: Int32(height), data: dataWrap.data, linesize: bytesPerRow)
        scale.shutdown()
        return image
    }
}

extension AVCodecParameters {
    var aspectRatio: NSDictionary? {
        let den = sample_aspect_ratio.den
        let num = sample_aspect_ratio.num
        if den > 0, num > 0, den != num {
            return [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: num,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: den] as NSDictionary
        } else {
            return nil
        }
    }
}

extension AVPixelFormat {
    var format: OSType {
        switch self {
        case AV_PIX_FMT_MONOBLACK: return kCVPixelFormatType_1Monochrome
        case AV_PIX_FMT_RGB555BE: return kCVPixelFormatType_16BE555
        case AV_PIX_FMT_RGB555LE: return kCVPixelFormatType_16LE555
        case AV_PIX_FMT_RGB565BE: return kCVPixelFormatType_16BE565
        case AV_PIX_FMT_RGB565LE: return kCVPixelFormatType_16LE565
        case AV_PIX_FMT_RGB24: return kCVPixelFormatType_24RGB
        case AV_PIX_FMT_BGR24: return kCVPixelFormatType_24BGR
        case AV_PIX_FMT_0RGB: return kCVPixelFormatType_32ARGB
        case AV_PIX_FMT_BGR0: return kCVPixelFormatType_32BGRA
        case AV_PIX_FMT_0BGR: return kCVPixelFormatType_32ABGR
        case AV_PIX_FMT_RGB0: return kCVPixelFormatType_32RGBA
        case AV_PIX_FMT_BGRA: return kCVPixelFormatType_32BGRA
        case AV_PIX_FMT_BGR48BE: return kCVPixelFormatType_48RGB
        case AV_PIX_FMT_UYVY422: return kCVPixelFormatType_422YpCbCr8
        case AV_PIX_FMT_YUVA444P: return kCVPixelFormatType_4444YpCbCrA8R
        case AV_PIX_FMT_YUVA444P16LE: return kCVPixelFormatType_4444AYpCbCr16
        case AV_PIX_FMT_YUV444P: return kCVPixelFormatType_444YpCbCr8
        //        case AV_PIX_FMT_YUV422P16: return kCVPixelFormatType_422YpCbCr16
        //        case AV_PIX_FMT_YUV422P10: return kCVPixelFormatType_422YpCbCr10
        //        case AV_PIX_FMT_YUV444P10: return kCVPixelFormatType_444YpCbCr10
        case AV_PIX_FMT_YUV420P: return kCVPixelFormatType_420YpCbCr8Planar
        case AV_PIX_FMT_YUV420P10LE: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case AV_PIX_FMT_NV12: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case AV_PIX_FMT_YUYV422: return kCVPixelFormatType_422YpCbCr8_yuvs
        case AV_PIX_FMT_GRAY8: return kCVPixelFormatType_OneComponent8
        default:
            return 0
        }
    }
}

extension OSType {
    var format: AVPixelFormat {
        switch self {
        case kCVPixelFormatType_32ARGB: return AV_PIX_FMT_ARGB
        case kCVPixelFormatType_32BGRA: return AV_PIX_FMT_BGRA
        case kCVPixelFormatType_24RGB: return AV_PIX_FMT_RGB24
        case kCVPixelFormatType_16BE555: return AV_PIX_FMT_RGB555BE
        case kCVPixelFormatType_16BE565: return AV_PIX_FMT_RGB565BE
        case kCVPixelFormatType_16LE555: return AV_PIX_FMT_RGB555LE
        case kCVPixelFormatType_16LE565: return AV_PIX_FMT_RGB565LE
        case kCVPixelFormatType_422YpCbCr8: return AV_PIX_FMT_UYVY422
        case kCVPixelFormatType_422YpCbCr8_yuvs: return AV_PIX_FMT_YUYV422
        case kCVPixelFormatType_444YpCbCr8: return AV_PIX_FMT_YUV444P
        case kCVPixelFormatType_4444YpCbCrA8: return AV_PIX_FMT_YUV444P16LE
        case kCVPixelFormatType_422YpCbCr16: return AV_PIX_FMT_YUV422P16LE
        case kCVPixelFormatType_422YpCbCr10: return AV_PIX_FMT_YUV422P10LE
        case kCVPixelFormatType_444YpCbCr10: return AV_PIX_FMT_YUV444P10LE
        case kCVPixelFormatType_420YpCbCr8Planar: return AV_PIX_FMT_YUV420P
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return AV_PIX_FMT_NV12
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return AV_PIX_FMT_NV12
        case kCVPixelFormatType_422YpCbCr8_yuvs: return AV_PIX_FMT_YUYV422
        default:
            return AV_PIX_FMT_NONE
        }
    }
}

extension CVPixelBufferPool {
    func getPixelBuffer(fromFrame frame: AVFrame) -> CVPixelBuffer? {
        var pbuf: CVPixelBuffer?
        let ret = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self, &pbuf)
        //        let dic = [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        //                       kCVPixelBufferBytesPerRowAlignmentKey: frame.linesize.0] as NSDictionary
        //        let ret = CVPixelBufferCreate(kCFAllocatorDefault, Int(frame.width), Int(frame.height), AVPixelFormat(rawValue: frame.format).format, dic, &pbuf)
        if let pbuf = pbuf, ret == kCVReturnSuccess {
            CVPixelBufferLockBaseAddress(pbuf, CVPixelBufferLockFlags(rawValue: 0))
            let data = Array(tuple: frame.data)
            let linesize = Array(tuple: frame.linesize)
            let heights = [frame.height, frame.height / 2, frame.height / 2]
            for i in 0 ..< pbuf.planeCount {
                let perRow = Int(linesize[i])
                pbuf.baseAddressOfPlane(at: i)?.copyMemory(from: data[i]!, byteCount: Int(heights[i]) * perRow)
            }
            CVPixelBufferUnlockBaseAddress(pbuf, CVPixelBufferLockFlags(rawValue: 0))
        }
        return pbuf
    }
}

extension UIImage {
    convenience init?(rgbData: UnsafePointer<UInt8>, linesize: Int, width: Int, height: Int, isAlpha: Bool = false) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = isAlpha ? CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue) : []
        guard let data = CFDataCreate(kCFAllocatorDefault, rgbData, linesize * height),
            let provider = CGDataProvider(data: data),
            // swiftlint:disable line_length
            let imageRef = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: isAlpha ? 32 : 24, bytesPerRow: linesize, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            // swiftlint:enable line_length
            return nil
        }
        self.init(cgImage: imageRef)
    }
}

typealias SwrContext = OpaquePointer

class AudioSwresample: Swresample {
    private var swrContext: SwrContext?
    private var descriptor: AudioDescriptor?
    private func setup(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let newDescriptor = AudioDescriptor(frame: frame)
        if let descriptor = descriptor, descriptor == newDescriptor {
            return true
        }
        let outChannel = av_get_default_channel_layout(Int32(KSPlayerManager.audioPlayerMaximumChannels))
        let inChannel = av_get_default_channel_layout(Int32(newDescriptor.inputNumberOfChannels))
        swrContext = swr_alloc_set_opts(nil, outChannel, AV_SAMPLE_FMT_FLTP, KSPlayerManager.audioPlayerSampleRate, inChannel, newDescriptor.inputFormat, newDescriptor.inputSampleRate, 0, nil)
        let result = swr_init(swrContext)
        if result < 0 {
            shutdown()
            return false
        } else {
            descriptor = newDescriptor
            return true
        }
    }

    func transfer(avframe: UnsafeMutablePointer<AVFrame>, timebase: Timebase) -> Frame {
        _ = setup(frame: avframe)
        var numberOfSamples = avframe.pointee.nb_samples
        let nbSamples = swr_get_out_samples(swrContext, numberOfSamples)
        var frameBuffer = Array(tuple: avframe.pointee.data).map { UnsafePointer<UInt8>($0) }
        var bufferSize = Int32(0)
        _ = av_samples_get_buffer_size(&bufferSize, Int32(KSPlayerManager.audioPlayerMaximumChannels), nbSamples, AV_SAMPLE_FMT_FLTP, 1)
        let frame = AudioFrame(bufferSize: bufferSize)
        numberOfSamples = swr_convert(swrContext, &frame.dataWrap.data, nbSamples, &frameBuffer, numberOfSamples)
        frame.timebase = timebase
        frame.numberOfSamples = Int(numberOfSamples)
        frame.duration = avframe.pointee.pkt_duration
        frame.size = Int64(avframe.pointee.pkt_size)
        if frame.duration == 0 {
            frame.duration = Int64(avframe.pointee.nb_samples) * Int64(frame.timebase.den) / (Int64(avframe.pointee.sample_rate) * Int64(frame.timebase.num))
        }
        return frame
    }

    func shutdown() {
        swr_free(&swrContext)
    }
}

class AudioDescriptor: Equatable {
    fileprivate let inputNumberOfChannels: AVAudioChannelCount
    fileprivate let inputSampleRate: Int32
    fileprivate let inputFormat: AVSampleFormat
    init(codecpar: UnsafeMutablePointer<AVCodecParameters>) {
        let channels = UInt32(codecpar.pointee.channels)
        inputNumberOfChannels = channels == 0 ? KSPlayerManager.audioPlayerMaximumChannels : channels
        let sampleRate = codecpar.pointee.sample_rate
        inputSampleRate = sampleRate == 0 ? KSPlayerManager.audioPlayerSampleRate : sampleRate
        inputFormat = AVSampleFormat(rawValue: codecpar.pointee.format)
    }

    init(frame: UnsafeMutablePointer<AVFrame>) {
        let channels = UInt32(frame.pointee.channels)
        inputNumberOfChannels = channels == 0 ? KSPlayerManager.audioPlayerMaximumChannels : channels
        let sampleRate = frame.pointee.sample_rate
        inputSampleRate = sampleRate == 0 ? KSPlayerManager.audioPlayerSampleRate : sampleRate
        inputFormat = AVSampleFormat(rawValue: frame.pointee.format)
    }

    static func == (lhs: AudioDescriptor, rhs: AudioDescriptor) -> Bool {
        lhs.inputFormat == rhs.inputFormat && lhs.inputSampleRate == rhs.inputSampleRate && lhs.inputNumberOfChannels == rhs.inputNumberOfChannels
    }

    static func == (lhs: AudioDescriptor, rhs: AVFrame) -> Bool {
        lhs.inputFormat.rawValue == rhs.format && lhs.inputSampleRate == rhs.sample_rate && lhs.inputNumberOfChannels == rhs.channels
    }
}
