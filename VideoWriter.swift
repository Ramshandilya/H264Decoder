//
//  VideoWriter.swift
//  Drone
//
//  Created by Ramsundar Shandilya on 1/10/18.
//  Copyright © 2018 Ramsundar Shandilya. All rights reserved.
//

import Foundation
import AVFoundation
import AVKit

class VideoWriter {
    
    private static let videoCacheFileName = "VideoCache.h264"
    
    var isWriting = false
    var outputURL: URL
    
    private var videoDecoder = VideoDecoder()
    private var frameCount = 0
    
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var avAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    private var elementaryStreamData: Data?
    
    init(url: URL) {
        outputURL = url
    }
    
    func prepareToWrite() {
        videoDecoder.delegate = self
        elementaryStreamData = Data()
    }
    
    func write(videoData: Data) {
        if !isWriting {
            isWriting = true
        }
        elementaryStreamData?.append(videoData)
    }
    
    func finishWriting(completion: @escaping () -> Void) {
        isWriting = false
        guard let cacheURL = saveElementaryStreamData() else {
            return
        }
        saveVideoToMp4(source: cacheURL, completion: completion)
    }
    
    private func saveElementaryStreamData() -> URL? {
        
        guard let documentDirectory = AssetFileManager.documentDirectory() else { return nil }
        do {
            let fileURL = documentDirectory.fileURL().appendingPathComponent(VideoWriter.videoCacheFileName)
            let fileManager = AssetFileManager.fileManager()
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(atPath: fileURL.path)
            }
            
            try elementaryStreamData?.write(to: fileURL)
            return fileURL
            
        } catch {
            Log.print("No such directory")
        }
        
        return nil
    }
    
    private func saveVideoToMp4(source: URL, completion: @escaping () -> Void) {
        setupAssetWriter()
        
        parse(fileURL: source, completion: completion)
        
        videoWriterInput?.markAsFinished()
        assetWriter?.finishWriting {
            let path = self.assetWriter?.outputURL.path ?? ""
            print("Finshed writing file at \(path)")
            completion()
        }
    }
    
    private func setupAssetWriter() {
        let fileManager = AssetFileManager.fileManager()
        if fileManager.fileExists(atPath: outputURL.path) {
            do {
                try fileManager.removeItem(atPath: outputURL.path)
            } catch {
                Log.print("Error deleting existing file: \(error)")
            }
        }
        
        assetWriter = try? AVAssetWriter(url: outputURL, fileType: AVFileType.mp4)
        
        let outputSettings: [String : Any] = [AVVideoCodecKey : AVVideoCodecType.h264, AVVideoWidthKey : NSNumber(value: 640), AVVideoHeightKey : NSNumber(value: 480)]
        
        guard let canApply = assetWriter?.canApply(outputSettings: outputSettings, forMediaType: AVMediaType.video), canApply else {
            fatalError("Negative : Can't apply the Output settings...")
        }
        
        videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: outputSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true
        
        if let videoWriterInput = videoWriterInput,
            let canAdd = assetWriter?.canAdd(videoWriterInput),
            canAdd {
            avAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput, sourcePixelBufferAttributes: nil)
            assetWriter?.add(videoWriterInput)
        }
        
        assetWriter?.startWriting()
        assetWriter?.startSession(atSourceTime: kCMTimeZero)
    }
    
    func parse(fileURL: URL, completion: @escaping () -> Void) {
        guard let fileStream = InputStream(fileAtPath: fileURL.path) else {
            return
        }
        
        fileStream.open()
        let bufferCap = 921600 //720 * 1280
        
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferCap)
        while fileStream.hasBytesAvailable {
            let read = fileStream.read(buffer, maxLength: bufferCap)
            
            guard read > 4 else {
                break
            }
            
            var startCodeIndices: [Int] = []
            
            for i in 0 ..< read-4 {
                if buffer[i] == UInt8(0) &&
                    buffer[i+1] == UInt8(0) &&
                    buffer[i+2] == UInt8(0) &&
                    buffer[i+3] == UInt8(1) {
                    startCodeIndices.append(i)
                }
            }
            
            for i in 0 ..< startCodeIndices.count - 1 {
                let startCodeIndex = startCodeIndices[i]
                let nextStartCodeIndex = startCodeIndices[i+1]
                let distance = nextStartCodeIndex - startCodeIndex
                
                let nalu = UnsafeMutablePointer<UInt8>.allocate(capacity: distance)
                nalu.initialize(from: buffer.advanced(by: startCodeIndex), count: distance)
                
                let naluData = NSData(bytesNoCopy: nalu, length: distance, freeWhenDone: false)
                videoDecoder.parseNALU(nalu: naluData)
            }
        }
    }
    
}

extension VideoWriter: VideoDecoderDelegate {
    func videoDecoderDidDecode(buffer: CVImageBuffer) {
        var didAppendBuffer = false
        while !didAppendBuffer {
            if videoWriterInput!.isReadyForMoreMediaData {
                avAdaptor?.append(buffer, withPresentationTime: CMTimeMake(Int64(frameCount * 10), 300))
                frameCount += 1
                didAppendBuffer = true
            } else {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    
    func videoDecoderDidFailToDecode(error: VideoDecoderError) {
        print(error.description)
    }
}
