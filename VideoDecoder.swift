//
//  VideoDecoder.swift
//  VideoDecode
//
//  Created by Ramsundar Shandilya on 1/3/18.
//  Copyright © 2018 Ramsundar Shandilya. All rights reserved.
//

import Foundation
import CoreMedia
import VideoToolbox

protocol VideoDecoderDelegate: class {
    func videoDecoderDidDecode(buffer: CVImageBuffer)
    func videoDecoderDidFailToDecode(error: VideoDecoderError)
}

class VideoDecoder {
    
    weak var delegate: VideoDecoderDelegate?
    
    //MARK: - Private properties
    private let nalUnitHeaderLength = 4
    private var data: UnsafePointer<UInt8>?
    private var spsData: NSData?
    private var ppsData: NSData?
    private var videoFormatDescription: CMVideoFormatDescription?
    private var videoDecompressionSession : VTDecompressionSession?
    
    private var dirtySPSData: NSData?
    private var dirtyPPSData: NSData?
    
    func parseNALU(nalu: NSData) {
        guard let type = naluType(from: nalu) else {
            return
        }
        
        print("NALU Type: \(type.description)")
        
        switch type {
        case .CodedSlice, .IDR:
            handleFrame(nalu: nalu)
        case .PPS:
            dirtyPPSData = nalu.copy() as? NSData
            updateFormatDescription()
        case .SPS:
            dirtySPSData = nalu.copy() as? NSData
            updateFormatDescription()
        default:
            break
        }
    }
    
    private func naluType(from nalu: NSData) -> NALUType? {
        let count = nalu.length/MemoryLayout<UInt8>.size
        var bytes = [UInt8](repeating: 0, count: count)
        (nalu as NSData).getBytes(&bytes, length: nalu.length)
        
        let type = bytes[nalUnitHeaderLength] & 0x1F
        return NALUType(rawValue: type)
    }
    
    private func updateFormatDescription() {
        guard let dirtySPS = dirtySPSData,
            let dirtyPPS = dirtyPPSData else {
                return
        }
        
        guard spsData == nil || ppsData == nil || spsData!.isEqual(to: dirtySPS as Data) || ppsData!.isEqual(to: dirtyPPS as Data) else {
            return
        }
        
        spsData = dirtySPS.copy() as? NSData
        ppsData = dirtyPPS.copy() as? NSData
        
        guard let spsData = spsData,
            let ppsData = ppsData else {
                return
        }
        
        var spsArray = [UInt8](repeating: 0, count: spsData.length/MemoryLayout<UInt8>.size)
        spsData.getBytes(&spsArray, length: spsData.length)
        spsArray = Array(spsArray[nalUnitHeaderLength ..< spsArray.count])
        let pointerSPS = UnsafePointer<UInt8>(spsArray)
        
        var ppsArray = [UInt8](repeating: 0, count: ppsData.length/MemoryLayout<UInt8>.size)
        ppsData.getBytes(&ppsArray, length: ppsData.length)
        ppsArray = Array(ppsArray[nalUnitHeaderLength ..< ppsArray.count])
        
        let pointerPPS = UnsafePointer<UInt8>(ppsArray)
        
        let dataParameterArray = [pointerSPS, pointerPPS]
        let parameterSetPointers = UnsafePointer<UnsafePointer<UInt8>>(dataParameterArray)
        let sizeParamArray = [spsArray.count, ppsArray.count]
        
        let parameterSetSizes = UnsafePointer<Int>(sizeParamArray)
        
        if videoFormatDescription != nil {
            videoFormatDescription = nil
        }
        
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, Int32(nalUnitHeaderLength), &videoFormatDescription)
        
        if status == noErr {
            print("Updated video format Description")
        } else {
            delegate?.videoDecoderDidFailToDecode(error: .CMVideoFormatDescriptionCreateFromH264ParameterSets(status))
        }
        
        if let videoDecompressionSession = videoDecompressionSession {
            guard let videoFormatDescription = videoFormatDescription else {
                return
            }
            if !VTDecompressionSessionCanAcceptFormatDescription(videoDecompressionSession, videoFormatDescription) {
                createVideoDecompressionSession()
            } else {
                print("$$ New decompression session not required")
            }
        } else {
            createVideoDecompressionSession()
        }
    }
    
    private func handleFrame(nalu: NSData) {
        guard let videoFormatDescription = videoFormatDescription,
         let videoDecompressionSession = videoDecompressionSession else {
            return
        }
        
        var nalulengthInBigEndian = CFSwapInt32HostToBig(UInt32(nalu.length - nalUnitHeaderLength))
        var lengthBytes = [UInt8](repeating: 0, count: 8)
        
        memcpy(&lengthBytes, &nalulengthInBigEndian, nalUnitHeaderLength)
        
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(nil, &lengthBytes, nalUnitHeaderLength, kCFAllocatorNull, nil, 0, nalUnitHeaderLength, 0, &blockBuffer)
        
        if status != noErr {
            delegate?.videoDecoderDidFailToDecode(error: .CMBlockBufferCreateWithMemoryBlock(status))
        }
        
        var naluArray = [UInt8](repeating: 0, count: nalu.length/MemoryLayout<UInt8>.size)
        nalu.getBytes(&naluArray, length: nalu.length)
        naluArray = Array(naluArray[nalUnitHeaderLength ..< naluArray.count])
        let pointerNalu = UnsafePointer<UInt8>(naluArray)
        let bufferPointer = UnsafeBufferPointer(start: pointerNalu, count: naluArray.count)
        
        var frameBlockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(nil, UnsafeMutablePointer<UInt8>(mutating: bufferPointer.baseAddress), bufferPointer.count, kCFAllocatorNull, nil, 0, bufferPointer.count, 0, &frameBlockBuffer)
        
        if status != noErr {
            delegate?.videoDecoderDidFailToDecode(error: .CMBlockBufferCreateWithMemoryBlock(status))
        }
        
        status = CMBlockBufferAppendBufferReference(blockBuffer!, frameBlockBuffer!, 0, bufferPointer.count, 0)
        if status != noErr {
            delegate?.videoDecoderDidFailToDecode(error: .CMBlockBufferAppendBufferReference(status))
        }
        
        var sampleBuffer: CMSampleBuffer?
        
        var timingInfo = CMSampleTimingInfo()
        timingInfo.decodeTimeStamp = kCMTimeInvalid
        timingInfo.presentationTimeStamp = kCMTimeZero
        timingInfo.duration = kCMTimeInvalid
        
        status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, videoFormatDescription, 1, 1, &timingInfo, 0, nil, &sampleBuffer)
        
        guard status == noErr else {
            delegate?.videoDecoderDidFailToDecode(error: .CMSampleBufferCreateReady(status))
            return
        }
        
        var infoFlags = VTDecodeInfoFlags(rawValue: 0)
        var outputBuffer = UnsafeMutablePointer<CVPixelBuffer>.allocate(capacity: 1)
        let decodestatus = VTDecompressionSessionDecodeFrame(videoDecompressionSession, sampleBuffer!, [._EnableAsynchronousDecompression], &outputBuffer, &infoFlags)
        
        if decodestatus != noErr {
            delegate?.videoDecoderDidFailToDecode(error: .VTDecompressionSessionDecodeFrame(decodestatus))
        }
    }
    
    private func createVideoDecompressionSession() {
        if videoDecompressionSession != nil {
            VTDecompressionSessionInvalidate(videoDecompressionSession!)
            videoDecompressionSession = nil
        }
        
        let decoderParameters = NSMutableDictionary()
        let destinationPixelBufferAttributes = NSMutableDictionary()
        destinationPixelBufferAttributes.setValue(NSNumber(value: kCVPixelFormatType_32BGRA), forKey: kCVPixelBufferPixelFormatTypeKey as String)
        
        var outputCallback = VTDecompressionOutputCallbackRecord()
        outputCallback.decompressionOutputCallback = callback
        outputCallback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()
        
        var videoSession : VTDecompressionSession?
        let status = VTDecompressionSessionCreate(nil, videoFormatDescription!, decoderParameters, destinationPixelBufferAttributes, &outputCallback, &videoSession)
        
        guard status == noErr else {
            delegate?.videoDecoderDidFailToDecode(error: .VTDecompressionSessionCreate(status))
            return
        }
        
        videoDecompressionSession = videoSession
    }
    
    fileprivate func decompressionOutputCallback(status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, presentationTimeStamp: CMTime, presentationDuration: CMTime) {
        
        guard status == noErr else {
            delegate?.videoDecoderDidFailToDecode(error: .VTDecompressionSessionDecodeFrame(status))
            return
        }
        
        guard let imageBuffer = imageBuffer else {
            delegate?.videoDecoderDidFailToDecode(error: .invalidImageBuffer)
            return
        }
        
        delegate?.videoDecoderDidDecode(buffer: imageBuffer)
    }
}

private func callback(decompressionOutputRefCon: UnsafeMutableRawPointer?, sourceFrameRefCon: UnsafeMutableRawPointer?, status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, presentationTimeStamp: CMTime, presentationDuration: CMTime){
    
    unsafeBitCast(decompressionOutputRefCon, to: VideoDecoder.self).decompressionOutputCallback(status: status, infoFlags: infoFlags, imageBuffer: imageBuffer, presentationTimeStamp: presentationTimeStamp, presentationDuration: presentationDuration)
}

enum NALUType : UInt8, CustomStringConvertible {
    case Undefined = 0
    case CodedSlice = 1
    case DataPartitionA = 2
    case DataPartitionB = 3
    case DataPartitionC = 4
    case IDR = 5 // (Instantaneous Decoding Refresh) Picture
    case SEI = 6 // (Supplemental Enhancement Information)
    case SPS = 7 // (Sequence Parameter Set)
    case PPS = 8 // (Picture Parameter Set)
    case AccessUnitDelimiter = 9
    case EndOfSequence = 10
    case EndOfStream = 11
    case FilterData = 12
    // 13-23 [extended]
    // 24-31 [unspecified]
    
    public var description : String {
        switch self {
        case .CodedSlice: return "CodedSlice"
        case .DataPartitionA: return "DataPartitionA"
        case .DataPartitionB: return "DataPartitionB"
        case .DataPartitionC: return "DataPartitionC"
        case .IDR: return "IDR"
        case .SEI: return "SEI"
        case .SPS: return "SPS"
        case .PPS: return "PPS"
        case .AccessUnitDelimiter: return "AccessUnitDelimiter"
        case .EndOfSequence: return "EndOfSequence"
        case .EndOfStream: return "EndOfStream"
        case .FilterData: return "FilterData"
        default: return "Undefined"
        }
    }
}

enum VideoDecoderError: Error, CustomStringConvertible {
    case CMBlockBufferCreateWithMemoryBlock(OSStatus)
    case CMBlockBufferAppendBufferReference(OSStatus)
    case CMSampleBufferCreateReady(OSStatus)
    case VTDecompressionSessionDecodeFrame(OSStatus)
    case CMVideoFormatDescriptionCreateFromH264ParameterSets(OSStatus)
    case VTDecompressionSessionCreate(OSStatus)
    case invalidImageBuffer
    
    var description: String {
        switch self {
        case let .CMBlockBufferCreateWithMemoryBlock(status):
            return "VideoDecoderError.CMBlockBufferCreateWithMemoryBlock(\(status))"
        case let .CMBlockBufferAppendBufferReference(status):
            return "VideoDecoderError.CMBlockBufferAppendBufferReference(\(status))"
        case let .CMSampleBufferCreateReady(status):
            return "VideoDecoderError.CMSampleBufferCreateReady(\(status))"
        case let .VTDecompressionSessionDecodeFrame(status):
            return "VideoDecoderError.VTDecompressionSessionDecodeFrame(\(status))"
        case let .CMVideoFormatDescriptionCreateFromH264ParameterSets(status):
            return "VideoDecoderError.CMVideoFormatDescriptionCreateFromH264ParameterSets(\(status))"
        case let .VTDecompressionSessionCreate(status):
            return "VideoDecoderError.VTDecompressionSessionCreate(\(status))"
        case .invalidImageBuffer:
            return "Invalid Image buffer"
        }
    }
}
