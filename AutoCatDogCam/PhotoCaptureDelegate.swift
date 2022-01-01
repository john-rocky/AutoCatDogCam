/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The app's photo capture delegate object.
*/

import AVFoundation
import Photos
import Vision
import Accelerate
import UIKit
let kernelLength = 51

class PhotoCaptureProcessor: NSObject {

    let machToSeconds: Double = {
        var timebase: mach_timebase_info_data_t = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) * 1e-9
    }()
    
    var format: vImage_CGImageFormat?
    var sourceBuffer: vImage_Buffer?
    
    private(set) var requestedPhotoSettings: AVCapturePhotoSettings
    
    private let willCapturePhotoAnimation: () -> Void
    
    private let livePhotoCaptureHandler: (Bool) -> Void
    
    lazy var context = CIContext()
    
    private let completionHandler: (PhotoCaptureProcessor) -> Void
    
    private let photoProcessingHandler: (Bool) -> Void
    
    private var photoData: Data?
    
    private var livePhotoCompanionMovieURL: URL?
    
    private var portraitEffectsMatteData: Data?
    
    private var semanticSegmentationMatteDataArray = [Data]()
    
    private var maxPhotoProcessingTime: CMTime?
    
    var portraitMatteImage:CIImage?
    
    var isPortrait = false
    var originalImage:CIImage?
    var originalCGImage:CGImage?
    var maskImage:CIImage?
    var rotatedImage:CIImage?
    var photoOriention:UInt32?
    
    init(with requestedPhotoSettings:
        AVCapturePhotoSettings,
         willCapturePhotoAnimation: @escaping () -> Void,
         livePhotoCaptureHandler: @escaping (Bool) -> Void,
         completionHandler: @escaping (PhotoCaptureProcessor) -> Void,
         photoProcessingHandler: @escaping (Bool) -> Void,
         player:AVAudioPlayer,
         soundType:String) {
        self.requestedPhotoSettings = requestedPhotoSettings
        self.willCapturePhotoAnimation = willCapturePhotoAnimation
        self.livePhotoCaptureHandler = livePhotoCaptureHandler
        self.completionHandler = completionHandler
        self.photoProcessingHandler = photoProcessingHandler
        self.audioPlayer = player
        self.soundType = soundType
        print(soundType)
    }
    
    private func didFinish() {
        if let livePhotoCompanionMoviePath = livePhotoCompanionMovieURL?.path {
            if FileManager.default.fileExists(atPath: livePhotoCompanionMoviePath) {
                do {
                    try FileManager.default.removeItem(atPath: livePhotoCompanionMoviePath)
                } catch {
                    print("Could not remove file at url: \(livePhotoCompanionMoviePath)")
                }
            }
        }
        
        completionHandler(self)
    }
    
    func prepareBlur(){
               guard
                   let formatLocal = vImage_CGImageFormat(cgImage: originalCGImage!) else {
                       fatalError("Unable to get color space")
               }
               format = formatLocal
           
           guard
               var sourceImageBuffer = try? vImage_Buffer(cgImage: originalCGImage!),
                      
                      var scaledBuffer = try? vImage_Buffer(width: Int(sourceImageBuffer.width / 4),
                                                            height: Int(sourceImageBuffer.height / 4),
                                                            bitsPerPixel: format!.bitsPerPixel) else {
                                                              fatalError("Can't create source buffer.")
           }
           vImageScale_ARGB8888(&sourceImageBuffer,
           &scaledBuffer,
           nil,
           vImage_Flags(kvImageNoFlags))
           sourceBuffer = scaledBuffer
           
           applyBlur()
       }
    
    let hannWindow: [Float] = {
         return vDSP.window(ofType: Float.self,
                            usingSequence: .hanningDenormalized,
                            count: kernelLength ,
                            isHalfWindow: false)
     }()
    
    lazy var kernel1D: [Int16] = {
          let stride = vDSP_Stride(1)
          var multiplier = pow(Float(Int16.max), 0.25)
          
          let hannWindow1D = vDSP.multiply(multiplier, hannWindow)
          
          return vDSP.floatingPointToInteger(hannWindow1D,
                                             integerType: Int16.self,
                                             rounding: vDSP.RoundingMode.towardNearestInteger)
      }()
      lazy var kernel2D: [Int16] = {
             let stride = vDSP_Stride(1)
             
             var hannWindow2D = [Float](repeating: 0,
                                        count: kernelLength * kernelLength)
             
             cblas_sger(CblasRowMajor,
                        Int32(kernelLength), Int32(kernelLength),
                        1, kernel1D.map { return Float($0) },
                        1, kernel1D.map { return Float($0) },
                        1,
                        &hannWindow2D,
                        Int32(kernelLength))
             
             return vDSP.floatingPointToInteger(hannWindow2D,
                                                integerType: Int16.self,
                                                rounding: vDSP.RoundingMode.towardNearestInteger)
         }()
      var destinationBuffer = vImage_Buffer()
     func applyBlur() {
            do {
                destinationBuffer = try vImage_Buffer(width: Int(sourceBuffer!.width),
                                                      height: Int(sourceBuffer!.height),
                                                      bitsPerPixel: format!.bitsPerPixel)
            } catch {
                return
            }

                hann2D()
            
            if let result = try? destinationBuffer.createCGImage(format: format!) {
                let ciimage = CIImage(cgImage: result).resizeToSameSize(as: originalImage!)
                let filter = CIFilter(name: "CIBlendWithMask", parameters: [
                           kCIInputImageKey: originalImage,
                           kCIInputBackgroundImageKey:ciimage,
                           kCIInputMaskImageKey:maskImage])
                       let outputImage = filter?.outputImage
                switch photoOriention {
                case 6:
                    rotatedImage = outputImage?.oriented(.right)
                case 1:
                    rotatedImage = outputImage
                case 3:
                    rotatedImage = outputImage?.oriented(.down)
                default:
                    rotatedImage = outputImage?.oriented(.right)
                }
                let context = CIContext()
                let cgImage = context.createCGImage(rotatedImage!, from: rotatedImage!.extent)
                let uiimage = UIImage(cgImage: cgImage!)
                let data = uiimage.jpegData(compressionQuality: 1)
                //            let rotate = ciimage.oriented(.right)
                        PHPhotoLibrary.requestAuthorization { status in
                                  if status == .authorized {
                                      PHPhotoLibrary.shared().performChanges({
                                          let options = PHAssetResourceCreationOptions()
                                          let creationRequest = PHAssetCreationRequest.forAsset()
                                          options.uniformTypeIdentifier = self.requestedPhotoSettings.processedFileType.map { $0.rawValue }
                                        creationRequest.addResource(with: .photo, data: data!, options: options)
                                      }, completionHandler: { _, error in
                                          if let error = error {
                                              print("Error occurred while saving photo to photo library: \(error)")
                                          }
                                          
                                          self.didFinish()
                                      }
                                      )
                                  } else {
                                      self.didFinish()
                                  }
                              }
            }
            
            destinationBuffer.free()
        }
    
      func coreMLCompletionHandler0(request:VNRequest?,error:Error?) {
           let result = request?.results?.first as! VNSaliencyImageObservation
           let pixelBuffer = result.pixelBuffer
           maskImage = CIImage(cvPixelBuffer: pixelBuffer).resizeToSameSize(as: originalImage!)
          
    prepareBlur()
           //
           
       }
    
    var soundType = "shutter"
    var audioPlayer:AVAudioPlayer?
    func shutterSound(){
        switch soundType {
        case "shutter":
            print("")
        case "silent":
            AudioServicesDisposeSystemSoundID(1108)
        case "audio":
            AudioServicesDisposeSystemSoundID(1108)
            self.audioPlayer?.play()
        default:
            break
        }
        
    }
}

extension PhotoCaptureProcessor: AVCapturePhotoCaptureDelegate {
    /*
     This extension adopts all of the AVCapturePhotoCaptureDelegate protocol methods.
     */
    
    /// - Tag: WillBeginCapture
    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        print("photoCapture!")
        if resolvedSettings.livePhotoMovieDimensions.width > 0 && resolvedSettings.livePhotoMovieDimensions.height > 0 {
            livePhotoCaptureHandler(true)
        }
        maxPhotoProcessingTime = resolvedSettings.photoProcessingTimeRange.start + resolvedSettings.photoProcessingTimeRange.duration
    }
    
    /// - Tag: WillCapturePhoto
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapturePhotoAnimation()
        shutterSound()
        
        guard let maxPhotoProcessingTime = maxPhotoProcessingTime else {
            return
        }
        
        // Show a spinner if processing time exceeds one second.
        let oneSecond = CMTime(seconds: 1, preferredTimescale: 1)
        if maxPhotoProcessingTime > oneSecond {
            photoProcessingHandler(true)
        }
    }
    
    func handleMatteData(_ photo: AVCapturePhoto, ssmType: AVSemanticSegmentationMatte.MatteType) {

        // Find the semantic segmentation matte image for the specified type.
        guard var segmentationMatte = photo.semanticSegmentationMatte(for: ssmType) else { return }
        
        // Retrieve the photo orientation and apply it to the matte image.
        if let orientation = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32,
            let exifOrientation = CGImagePropertyOrientation(rawValue: orientation) {
            // Apply the Exif orientation to the matte image.
            segmentationMatte = segmentationMatte.applyingExifOrientation(exifOrientation)
        }
        
        var imageOption: CIImageOption!
        
        // Switch on the AVSemanticSegmentationMatteType value.
        switch ssmType {
        case .hair:
            imageOption = .auxiliarySemanticSegmentationHairMatte
        case .skin:
            imageOption = .auxiliarySemanticSegmentationSkinMatte
        case .teeth:
            imageOption = .auxiliarySemanticSegmentationTeethMatte
        default:
            print("This semantic segmentation type is not supported!")
            return
        }
        
        guard let perceptualColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        
        // Create a new CIImage from the matte's underlying CVPixelBuffer.
        let ciImage = CIImage( cvImageBuffer: segmentationMatte.mattingImage,
                               options: [imageOption: true,
                                         .colorSpace: perceptualColorSpace])
        
        // Get the HEIF representation of this image.
        guard let imageData = context.heifRepresentation(of: ciImage,
                                                         format: .RGBA8,
                                                         colorSpace: perceptualColorSpace,
                                                         options: [.depthImage: ciImage]) else { return }
        
        // Add the image data to the SSM data array for writing to the photo library.
        semanticSegmentationMatteDataArray.append(imageData)
    }
    
    /// - Tag: DidFinishProcessingPhoto
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        photoProcessingHandler(false)
        
        if let error = error {
            print("Error capturing photo: \(error)")
        } else {
            photoData = photo.fileDataRepresentation()
        }
        print(photo.metadata[String(kCGImagePropertyOrientation)])

        //
       if self.isPortrait {
        photoOriention = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32
                  originalImage = CIImage(data: photoData!)
        let context = CIContext()
        originalCGImage = context.createCGImage(originalImage!, from: originalImage!.extent)
                  let request = VNGenerateObjectnessBasedSaliencyImageRequest(completionHandler: coreMLCompletionHandler0(request:error:))

                  let handler = VNImageRequestHandler(ciImage: originalImage!, options: [:])
                            DispatchQueue.global(qos: .userInitiated).async {
                                try? handler.perform([request])
                            }
              }
        
        // A portrait effects matte gets generated only if AVFoundation detects a face.
        if var portraitEffectsMatte = photo.portraitEffectsMatte {
            if let orientation = photo.metadata[ String(kCGImagePropertyOrientation) ] as? UInt32 {
                portraitEffectsMatte = portraitEffectsMatte.applyingExifOrientation(CGImagePropertyOrientation(rawValue: orientation)!)
            }
            let portraitEffectsMattePixelBuffer = portraitEffectsMatte.mattingImage
            let portraitEffectsMatteImage = CIImage( cvImageBuffer: portraitEffectsMattePixelBuffer, options: [ .auxiliaryPortraitEffectsMatte: true ] )
            
            guard let perceptualColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                portraitEffectsMatteData = nil
                return
            }
            portraitEffectsMatteData = context.heifRepresentation(of: portraitEffectsMatteImage,
                                                                  format: .RGBA8,
                                                                  colorSpace: perceptualColorSpace,
                                                                  options: [.portraitEffectsMatteImage: portraitEffectsMatteImage])
        } else {
            portraitEffectsMatteData = nil
        }
        
        for semanticSegmentationType in output.enabledSemanticSegmentationMatteTypes {
            handleMatteData(photo, ssmType: semanticSegmentationType)
        }
    }
    
    /// - Tag: DidFinishRecordingLive
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL, resolvedSettings: AVCaptureResolvedPhotoSettings) {
        livePhotoCaptureHandler(false)
    }
    
    /// - Tag: DidFinishProcessingLive
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if error != nil {
            print("Error processing Live Photo companion movie: \(String(describing: error))")
            return
        }
        livePhotoCompanionMovieURL = outputFileURL
    }
    
    /// - Tag: DidFinishCapture
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error)")
            didFinish()
            return
        }
        
        guard let photoData = photoData else {
            print("No photo data resource")
            didFinish()
            return
        }
        
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized {
                PHPhotoLibrary.shared().performChanges({
                    let options = PHAssetResourceCreationOptions()
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    options.uniformTypeIdentifier = self.requestedPhotoSettings.processedFileType.map { $0.rawValue }
                    creationRequest.addResource(with: .photo, data: photoData, options: options)
                    
                    if let livePhotoCompanionMovieURL = self.livePhotoCompanionMovieURL {
                        let livePhotoCompanionMovieFileOptions = PHAssetResourceCreationOptions()
                        livePhotoCompanionMovieFileOptions.shouldMoveFile = true
                        creationRequest.addResource(with: .pairedVideo,
                                                    fileURL: livePhotoCompanionMovieURL,
                                                    options: livePhotoCompanionMovieFileOptions)
                    }
                    
                    // Save Portrait Effects Matte to Photos Library only if it was generated
                    if let portraitEffectsMatteData = self.portraitEffectsMatteData {
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        creationRequest.addResource(with: .photo,
                                                    data: portraitEffectsMatteData,
                                                    options: nil)
                    }
                    // Save Portrait Effects Matte to Photos Library only if it was generated
                    for semanticSegmentationMatteData in self.semanticSegmentationMatteDataArray {
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        creationRequest.addResource(with: .photo,
                                                    data: semanticSegmentationMatteData,
                                                    options: nil)
                    }
                    
                }, completionHandler: { _, error in
                    if let error = error {
                        print("Error occurred while saving photo to photo library: \(error)")
                    }
                    
                    self.didFinish()
                }
                )
            } else {
                self.didFinish()
            }
        }
    }
    

}
extension CIImage {
func resizeToSameSize(as anotherImage: CIImage) -> CIImage {
    let size1 = extent.size
    let size2 = anotherImage.extent.size
    let transform = CGAffineTransform(scaleX: size2.width / size1.width, y: size2.height / size1.height)
    return transformed(by: transform)
}
}
