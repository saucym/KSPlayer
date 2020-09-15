//
//  MetalRenderer.swift
//  KSPlayer-iOS
//
//  Created by wangjinbian on 2020/1/11.
//
import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd
import VideoToolbox
class MetalRender {
    static let share = MetalRender()
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let library: MTLLibrary
    private lazy var yuv = YUVMetalRenderPipeline(device: device, library: library)
    private lazy var nv12 = NV12MetalRenderPipeline(device: device, library: library)
    private lazy var bgra = BGRAMetalRenderPipeline(device: device, library: library)
    private lazy var samplerState: MTLSamplerState? = {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.mipFilter = .nearest
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.rAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        return device.makeSamplerState(descriptor: samplerDescriptor)
    }()

    private lazy var colorConversion601VideoRangeMatrixBuffer: MTLBuffer? = {
        var matrix = simd_float3x3([1.164, 1.164, 1.164], [0, -0.392, 2.017], [1.596, -0.813, 0])
        let buffer = device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size, options: .storageModeShared)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }()

    private lazy var colorConversion601FullRangeMatrixBuffer: MTLBuffer? = {
        var matrix = simd_float3x3([1.0, 1.0, 1.0], [0.0, -0.343, 1.765], [1.4, -0.711, 0.0])
        let buffer = device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size, options: .storageModeShared)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }()

    private lazy var colorConversion709VideoRangeMatrixBuffer: MTLBuffer? = {
        var matrix = simd_float3x3([1.164, 1.164, 1.164], [0.0, -0.213, 2.112], [1.793, -0.533, 0.0])
        let buffer = device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size, options: .storageModeShared)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }()

    private lazy var colorConversion709FullRangeMatrixBuffer: MTLBuffer? = {
        var matrix = simd_float3x3([1, 1, 1], [0.0, -0.187, 1.856], [1.570, -0.467, 0.0])
        let buffer = device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size, options: .storageModeShared)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }()

    private lazy var colorOffsetVideoRangeMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<Float>(-(16.0 / 255.0), -0.5, -0.5)
        let buffer = device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<Float>>.size, options: .storageModeShared)
        buffer?.label = "colorOffset"
        return buffer
    }()

    private lazy var colorOffsetFullRangeMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<Float>(0, -0.5, -0.5)
        let buffer = device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<Float>>.size, options: .storageModeShared)
        buffer?.label = "colorOffset"
        return buffer
    }()

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        var library: MTLLibrary!
        library = device.makeDefaultLibrary()
        if library == nil, let path = Bundle(for: type(of: self)).path(forResource: "Metal", ofType: "bundle"), let bundle = Bundle(path: path) {
            library = try? device.makeDefaultLibrary(bundle: bundle)
        }
        self.library = library
        commandQueue = device.makeCommandQueue()
    }

    func clear(drawable: CAMetalDrawable, renderPassDescriptor: MTLRenderPassDescriptor) {
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func draw(pixelBuffer: BufferProtocol, display: DisplayEnum = .plane, inputTextures: [MTLTexture], drawable: CAMetalDrawable, renderPassDescriptor: MTLRenderPassDescriptor) {
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        guard inputTextures.count > 0, let commandBuffer = commandQueue?.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        encoder.pushDebugGroup("RenderFrame")
        encoder.setRenderPipelineState(pipeline(pixelBuffer: pixelBuffer).state)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        for (index, texture) in inputTextures.enumerated() {
            texture.label = "texture\(index)"
            encoder.setFragmentTexture(texture, index: index)
        }
        setFragmentBuffer(pixelBuffer: pixelBuffer, encoder: encoder)
        display.set(encoder: encoder)
        encoder.popDebugGroup()
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func pipeline(pixelBuffer: BufferProtocol) -> MetalRenderPipeline {
        switch pixelBuffer.planeCount {
        case 3:
            return yuv
        case 2:
            return nv12
        case 1:
            return bgra
        default:
            return bgra
        }
    }

    private func setFragmentBuffer(pixelBuffer: BufferProtocol, encoder: MTLRenderCommandEncoder) {
        let pixelFormatType = pixelBuffer.format
        if pixelFormatType != kCVPixelFormatType_32BGRA {
            var buffer = colorConversion601FullRangeMatrixBuffer
            let isFullRangeVideo = pixelBuffer.isFullRangeVideo
            let colorAttachments = pixelBuffer.colorAttachments
            if colorAttachments == kCVImageBufferYCbCrMatrix_ITU_R_601_4 {
                buffer = isFullRangeVideo ? colorConversion601FullRangeMatrixBuffer : colorConversion601VideoRangeMatrixBuffer
            } else if colorAttachments == kCVImageBufferYCbCrMatrix_ITU_R_709_2 {
                buffer = isFullRangeVideo ? colorConversion709FullRangeMatrixBuffer : colorConversion709VideoRangeMatrixBuffer
            }
            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            let colorOffset = isFullRangeVideo ? colorOffsetFullRangeMatrixBuffer : colorOffsetVideoRangeMatrixBuffer
            encoder.setFragmentBuffer(colorOffset, offset: 0, index: 1)
        }
    }
}
