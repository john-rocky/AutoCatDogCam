/*
 See LICENSE folder for this sample’s licensing information.
 
 Abstract:
 The app's primary view controller that presents the camera interface.
 */

import UIKit
import AVFoundation
import Photos
import Vision
import Accelerate

class CameraViewController: UIViewController, AVCaptureFileOutputRecordingDelegate, ItemSelectionViewControllerDelegate,AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private var spinner: UIActivityIndicatorView!
    
    var windowOrientation: UIInterfaceOrientation {
        return view.window?.windowScene?.interfaceOrientation ?? .unknown
    }
    
    // MARK: View Controller Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Disable the UI. Enable the UI later, if and only if the session starts running.
        CameraButton.isUserInteractionEnabled = false
        recordButton.isEnabled = false
        recordButton.isEnabled = false
        livePhotoModeButton.isEnabled = false
        depthDataDeliveryButton.isEnabled = false
        portraitEffectsMatteDeliveryButton.isEnabled = false
        semanticSegmentationMatteDeliveryButton.isEnabled = false
        photoQualityPrioritizationSegControl.isEnabled = false
        captureModeControl.isEnabled = false
        // Set up the video preview view.
        previewView.session = session
        /*
         Check the video authorization status. Video access is required and audio
         access is optional. If the user denies audio access, AVCam won't
         record audio during movie recording.
         */
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera.
            break
            
        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant
             video access. Suspend the session queue to delay session
             setup until the access request has completed.
             
             Note that audio access will be implicitly requested when we
             create an AVCaptureDeviceInput for audio during session setup.
             */
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })
            
        default:
            // The user has previously denied access.
            setupResult = .notAuthorized
        }
        setupVision()
        /*
         Setup the capture session.
         In general, it's not safe to mutate an AVCaptureSession or any of its
         inputs, outputs, or connections from multiple threads at the same time.
         
         Don't perform these tasks on the main queue because
         AVCaptureSession.startRunning() is a blocking call, which can
         take a long time. Dispatch session setup to the sessionQueue, so
         that the main queue isn't blocked, which keeps the UI responsive.
         */
        sessionQueue.async {
            self.configureSession()
        }
        DispatchQueue.main.async {
            self.spinner = UIActivityIndicatorView(style: .large)
            self.spinner.color = UIColor.yellow
            self.previewView.addSubview(self.spinner)
        }
        
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { (Timer) in
            
            self.miliScondTimer += 1
            if self.miliScondTimer == 5 {
                self.isRequest = true
                self.miliScondTimer = 0
            }
        }
    }
    //MARK: - Animal Detector
    private var isAuto = true
    private var miliScondTimer = 0
    private var isRequest = false
    private var requests = [VNRequest]()
    private var currentBuffer:CVImageBuffer?
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataOutputQueue = DispatchQueue(label: "VideoDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    var bufferSize: CGSize = .zero
    var objectBounds = CGRect.zero
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if isRequest {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            currentBuffer = pixelBuffer
            
            let exifOrientation = exifOrientationFromDeviceOrientation()
            let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: exifOrientation, options: [:])
            if isAuto {
                do {
                    try imageRequestHandler.perform(self.requests)
                } catch {
                    print(error)
                }
            }
            isRequest = false
        }
    }
    public func exifOrientationFromDeviceOrientation() -> CGImagePropertyOrientation {
        let curDeviceOrientation = UIDevice.current.orientation
        let exifOrientation: CGImagePropertyOrientation
        
        switch curDeviceOrientation {
        case UIDeviceOrientation.portraitUpsideDown:  // Device oriented vertically, home button on the top
            exifOrientation = .left
        case UIDeviceOrientation.landscapeLeft:       // Device oriented horizontally, home button on the right
            exifOrientation = .upMirrored
        case UIDeviceOrientation.landscapeRight:      // Device oriented horizontally, home button on the left
            exifOrientation = .down
        case UIDeviceOrientation.portrait:            // Device oriented vertically, home button on the bottom
            exifOrientation = .up
        default:
            exifOrientation = .up
        }
        return exifOrientation
    }
    
    @discardableResult
    func setupVision() -> NSError? {
        // Setup Vision parts
        let error: NSError! = nil
        do {
            
            let animalRequest:VNRecognizeAnimalsRequest = {
                let request = VNRecognizeAnimalsRequest(completionHandler: { (request, error) in
                    DispatchQueue.main.async(execute: {
                        // perform all the UI updates on the main queue
                        if let results = request.results {
                            self.drawVisionRequestResults(results)
                        }
                    })
                })
                request.revision = VNRecognizeAnimalsRequestRevision1
                return request
            }()
            
            self.requests = [animalRequest]
        } catch let error as NSError {
            print("Model loading went wrong: \(error)")
        }
        return error
    }
    
    func drawVisionRequestResults(_ results: [Any]) {
        //        for observation in results where observation is VNRecognizedObjectObservation {
        guard let objectObservation = results.first as? VNRecognizedObjectObservation else {
            return
        }
        if isFocus {
            let boundingBox = objectObservation.boundingBox
            //
            let animalPoint = CGPoint(x: boundingBox.minX + (boundingBox.width * 0.5), y: 1 - objectObservation.boundingBox.maxY + (boundingBox.height * 0.5))
            animalPointInView = CGPoint(x: previewView.bounds.width * animalPoint.x, y: previewView.bounds.height * animalPoint.y)
            //        }
            let devicePoint = previewView.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: animalPointInView)
            focus(with: .autoFocus, exposureMode: .autoExpose, at: devicePoint, monitorSubjectAreaChange: true)
        }
        
        capturePhoto()
        
        //
        //            objectBounds = VNImageRectForNormalizedRect(objectObservation.boundingBox, Int(bufferSize.width), Int(bufferSize.height))
        //            let faceRect = VNImageRectForNormalizedRect(observation.boundingBox,Int(image.extent.size.width), Int(image.extent.size.height))
        //            let faceImage = image.cropped(to: faceRect)
        //            //            let context = CIContext()
        //            //            let final = context.createCGImage(faceImage, from: faceImage.extent)
        //            let mlRequestHandler = VNImageRequestHandler(ciImage: faceImage, options: [:])
        //            do {
        //                try mlRequestHandler.perform(self.mlRequest)
        //            } catch {
        //                print(error)
        //            }
    }
    
    private var touchPoint = CGPoint.zero
    private var animalPointInView = CGPoint.zero
    private var isFocus = false
    
    private func animalFocus(_ gestureRecognizer: UITapGestureRecognizer) {
        let devicePoint = previewView.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: gestureRecognizer.location(in: gestureRecognizer.view))
        focus(with: .autoFocus, exposureMode: .autoExpose, at: devicePoint, monitorSubjectAreaChange: true)
    }
    //MARK: - Detector End
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        buttonAdding()
        buttonSetting()
        sessionQueue.async {
            switch self.setupResult {
            case .success:
                // Only setup observers and start the session if setup succeeded.
                self.addObservers()
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
                
            case .notAuthorized:
                DispatchQueue.main.async {
                    let changePrivacySetting = "AVCam doesn't have permission to use the camera, please change privacy settings"
                    let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                                            style: .`default`,
                                                            handler: { _ in
                                                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                                                          options: [:],
                                                                                          completionHandler: nil)
                    }))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
                
            case .configurationFailed:
                DispatchQueue.main.async {
                    let alertMsg = "Alert message when something goes wrong during capture session configuration"
                    let message = NSLocalizedString("Unable to capture media", comment: alertMsg)
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        sessionQueue.async {
            if self.setupResult == .success {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
                self.removeObservers()
            }
        }
        
        super.viewWillDisappear(animated)
    }
    
    override var shouldAutorotate: Bool {
        // Disable autorotation of the interface when recording is in progress.
        if let movieFileOutput = movieFileOutput {
            return !movieFileOutput.isRecording
        }
        return true
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        if let videoPreviewLayerConnection = previewView.videoPreviewLayer.connection {
            let deviceOrientation = UIDevice.current.orientation
            guard let newVideoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation),
                deviceOrientation.isPortrait || deviceOrientation.isLandscape else {
                    return
            }
            
            videoPreviewLayerConnection.videoOrientation = newVideoOrientation
        }
        buttonSetting()
    }
    
    // MARK: Session Management
    
    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    
    private let session = AVCaptureSession()
    private var isSessionRunning = false
    private var selectedSemanticSegmentationMatteTypes = [AVSemanticSegmentationMatte.MatteType]()
    
    // Communicate with the session and other session objects on this queue.
    private let sessionQueue = DispatchQueue(label: "session queue")
    
    private var setupResult: SessionSetupResult = .success
    
    @objc dynamic var videoDeviceInput: AVCaptureDeviceInput!
    
    @IBOutlet private weak var previewView: PreviewView!
    
    // Call this on the session queue.
    /// - Tag: ConfigureSession
    private func configureSession() {
        if setupResult != .success {
            return
        }
        
        session.beginConfiguration()
        
        /*
         Do not create an AVCaptureMovieFileOutput when setting up the session because
         Live Photo is not supported when AVCaptureMovieFileOutput is added to the session.
         */
        session.sessionPreset = .photo
        
        // Add video input.
        do {
            var defaultVideoDevice: AVCaptureDevice?
            
            // Choose the back dual camera, if available, otherwise default to a wide angle camera.
            
            if let dualCameraDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
                defaultVideoDevice = dualCameraDevice
            } else if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                // If a rear dual camera is not available, default to the rear wide angle camera.
                defaultVideoDevice = backCameraDevice
            } else if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                // If the rear wide angle camera isn't available, default to the front wide angle camera.
                defaultVideoDevice = frontCameraDevice
            }
            guard let videoDevice = defaultVideoDevice else {
                print("Default video device is unavailable.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
            
            do {
                try videoDevice.lockForConfiguration()
                let dimensions = CMVideoFormatDescriptionGetDimensions((videoDevice.activeFormat.formatDescription))
                bufferSize.width = CGFloat(dimensions.height)
                bufferSize.height = CGFloat(dimensions.width)
                videoDevice.unlockForConfiguration()
            } catch {
                print(error)
            }
            
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                
                DispatchQueue.main.async {
                    /*
                     Dispatch video streaming to the main queue because AVCaptureVideoPreviewLayer is the backing layer for PreviewView.
                     You can manipulate UIView only on the main thread.
                     Note: As an exception to the above rule, it's not necessary to serialize video orientation changes
                     on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
                     
                     Use the window scene's orientation as the initial video orientation. Subsequent orientation changes are
                     handled by CameraViewController.viewWillTransition(to:with:).
                     */
                    var initialVideoOrientation: AVCaptureVideoOrientation = .portrait
                    if self.windowOrientation != .unknown {
                        if let videoOrientation = AVCaptureVideoOrientation(interfaceOrientation: self.windowOrientation) {
                            initialVideoOrientation = videoOrientation
                        }
                    }
                    
                    self.previewView.videoPreviewLayer.connection?.videoOrientation = initialVideoOrientation
                }
            } else {
                print("Couldn't add video device input to the session.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
        } catch {
            print("Couldn't create video device input: \(error)")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        // Add an audio input device.
        do {
            let audioDevice = AVCaptureDevice.default(for: .audio)
            let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)
            
            if session.canAddInput(audioDeviceInput) {
                session.addInput(audioDeviceInput)
            } else {
                print("Could not add audio device input to the session")
            }
        } catch {
            print("Could not create audio device input: \(error)")
        }
        
        // Add the photo output.
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            
            photoOutput.isHighResolutionCaptureEnabled = true
            photoOutput.isLivePhotoCaptureEnabled = false
            photoOutput.isDepthDataDeliveryEnabled = false
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
            //            photoOutput.enabledSemanticSegmentationMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes
            //            selectedSemanticSegmentationMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes
            photoOutput.maxPhotoQualityPrioritization = .quality
            livePhotoMode = .off
            depthDataDeliveryMode = .off
            portraitEffectsMatteDeliveryMode = .off
            photoQualityPrioritizationMode = .balanced
            
        } else {
            print("Could not add photo output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        //MARK:- Video Output For Animal Detector
        if session.canAddOutput(videoDataOutput){
            session.addOutput(videoDataOutput)
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        } else {
            print("Could not add video data output to the session")
            session.commitConfiguration()
            return
        }
        
        let captureConnection = videoDataOutput.connection(with: .video)
        captureConnection?.videoOrientation = .portrait
        captureConnection?.isEnabled = true
        
        session.commitConfiguration()
    }
    
    @IBAction private func resumeInterruptedSession(_ resumeButton: UIButton) {
        sessionQueue.async {
            /*
             The session might fail to start running, for example, if a phone or FaceTime call is still
             using audio or video. This failure is communicated by the session posting a
             runtime error notification. To avoid repeatedly failing to start the session,
             only try to restart the session in the error handler if you aren't
             trying to resume the session.
             */
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
            if !self.session.isRunning {
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.present(alertController, animated: true, completion: nil)
                }
            } else {
                DispatchQueue.main.async {
                    self.resumeButton.isHidden = true
                }
            }
        }
    }
    
    private enum CaptureMode: Int {
        case photo = 0
        case movie = 1
    }
    
    @IBOutlet private weak var captureModeControl: UISegmentedControl!
    
    /// - Tag: EnableDisableModes
    @IBAction private func toggleCaptureMode(_ captureModeControl: UISegmentedControl) {
        captureModeControl.isEnabled = false
        
        if captureModeControl.selectedSegmentIndex == CaptureMode.photo.rawValue {
            sessionQueue.async {
                // Remove the AVCaptureMovieFileOutput from the session because it doesn't support capture of Live Photos.
                self.session.beginConfiguration()
                self.session.removeOutput(self.movieFileOutput!)
                self.session.sessionPreset = .photo
                
                DispatchQueue.main.async {
                    captureModeControl.isEnabled = true
                }
                
                self.movieFileOutput = nil
                
                DispatchQueue.main.async {
                    self.photoQualityPrioritizationSegControl.isHidden = false
                    self.photoQualityPrioritizationSegControl.isEnabled = true
                    self.recordingAnimationButton.layer.backgroundColor = UIColor.white.cgColor
                }
                self.session.commitConfiguration()
            }
        } else if captureModeControl.selectedSegmentIndex == CaptureMode.movie.rawValue {
            photoQualityPrioritizationSegControl.isHidden = true
            
            sessionQueue.async {
                let movieFileOutput = AVCaptureMovieFileOutput()
                
                if self.session.canAddOutput(movieFileOutput) {
                    self.session.beginConfiguration()
                    self.session.addOutput(movieFileOutput)
                    self.session.sessionPreset = .high
                    if let connection = movieFileOutput.connection(with: .video) {
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = .auto
                        }
                    }
                    self.session.commitConfiguration()
                    
                    DispatchQueue.main.async {
                        captureModeControl.isEnabled = true
                    }
                    
                    self.movieFileOutput = movieFileOutput
                    
                    DispatchQueue.main.async {
                        self.recordButton.isEnabled = true
                        
                        /*
                         For photo captures during movie recording, Speed quality photo processing is prioritized
                         to avoid frame drops during recording.
                         */
                        self.photoQualityPrioritizationSegControl.selectedSegmentIndex = 0
                        self.photoQualityPrioritizationSegControl.sendActions(for: UIControl.Event.valueChanged)
                        self.recordingAnimationButton.layer.backgroundColor = UIColor.darkGray.cgColor
                    }
                }
            }
        }
    }
    
    // MARK: Device Configuration
    
    @IBOutlet private weak var cameraUnavailableLabel: UILabel!
    
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera],
                                                                               mediaType: .video, position: .unspecified)
    
    /// - Tag: ChangeCamera
    @objc private func changeCamera() {
        CameraButton.isUserInteractionEnabled = false
        recordButton.isEnabled = false
        recordButton.isEnabled = false
        livePhotoModeButton.isEnabled = false
        captureModeControl.isEnabled = false
        depthDataDeliveryButton.isEnabled = false
        portraitEffectsMatteDeliveryButton.isEnabled = false
        semanticSegmentationMatteDeliveryButton.isEnabled = false
        photoQualityPrioritizationSegControl.isEnabled = false
        
        sessionQueue.async {
            let currentVideoDevice = self.videoDeviceInput.device
            let currentPosition = currentVideoDevice.position
            
            let preferredPosition: AVCaptureDevice.Position
            let preferredDeviceType: AVCaptureDevice.DeviceType
            
            switch currentPosition {
            case .unspecified, .front:
                preferredPosition = .back
                preferredDeviceType = .builtInDualCamera
                
            case .back:
                preferredPosition = .front
                preferredDeviceType = .builtInTrueDepthCamera
                
            @unknown default:
                print("Unknown capture position. Defaulting to back, dual-camera.")
                preferredPosition = .back
                preferredDeviceType = .builtInDualCamera
            }
            let devices = self.videoDeviceDiscoverySession.devices
            var newVideoDevice: AVCaptureDevice? = nil
            
            // First, seek a device with both the preferred position and device type. Otherwise, seek a device with only the preferred position.
            if let device = devices.first(where: { $0.position == preferredPosition && $0.deviceType == preferredDeviceType }) {
                newVideoDevice = device
            } else if let device = devices.first(where: { $0.position == preferredPosition }) {
                newVideoDevice = device
            }
            
            if let videoDevice = newVideoDevice {
                do {
                    let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
                    
                    self.session.beginConfiguration()
                    
                    // Remove the existing device input first, because AVCaptureSession doesn't support
                    // simultaneous use of the rear and front cameras.
                    self.session.removeInput(self.videoDeviceInput)
                    
                    if self.session.canAddInput(videoDeviceInput) {
                        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceSubjectAreaDidChange, object: currentVideoDevice)
                        NotificationCenter.default.addObserver(self, selector: #selector(self.subjectAreaDidChange), name: .AVCaptureDeviceSubjectAreaDidChange, object: videoDeviceInput.device)
                        
                        self.session.addInput(videoDeviceInput)
                        self.videoDeviceInput = videoDeviceInput
                    } else {
                        self.session.addInput(self.videoDeviceInput)
                    }
                    if let connection = self.movieFileOutput?.connection(with: .video) {
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = .auto
                        }
                    }
                    
                    /*
                     Set Live Photo capture and depth data delivery if it's supported. When changing cameras, the
                     `livePhotoCaptureEnabled` and `depthDataDeliveryEnabled` properties of the AVCapturePhotoOutput
                     get set to false when a video device is disconnected from the session. After the new video device is
                     added to the session, re-enable them on the AVCapturePhotoOutput, if supported.
                     */
                    self.photoOutput.isLivePhotoCaptureEnabled = false
                    self.photoOutput.isDepthDataDeliveryEnabled = false
                    self.photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                    
                    self.session.commitConfiguration()
                } catch {
                    print("Error occurred while creating video device input: \(error)")
                }
            }
            
            DispatchQueue.main.async {
                self.CameraButton.isUserInteractionEnabled = true
                self.recordButton.isEnabled = self.movieFileOutput != nil
                self.recordButton.isEnabled = true
                self.captureModeControl.isEnabled = true
                self.photoQualityPrioritizationSegControl.isEnabled = true
            }
        }
    }
    
    @IBAction private func focusAndExposeTap(_ gestureRecognizer: UITapGestureRecognizer) {
        let devicePoint = previewView.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: gestureRecognizer.location(in: gestureRecognizer.view))
        focus(with: .autoFocus, exposureMode: .autoExpose, at: devicePoint, monitorSubjectAreaChange: true)
        //        touchPoint = gestureRecognizer.location(in: gestureRecognizer.view)
        //        print("\ndiff",(floor(animalPointInView.x - touchPoint.x), floor(animalPointInView.y - touchPoint.y)))
    }
    
    private func focus(with focusMode: AVCaptureDevice.FocusMode,
                       exposureMode: AVCaptureDevice.ExposureMode,
                       at devicePoint: CGPoint,
                       monitorSubjectAreaChange: Bool) {
        
        sessionQueue.async {
            let device = self.videoDeviceInput.device
            do {
                try device.lockForConfiguration()
                
                /*
                 Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
                 Call set(Focus/Exposure)Mode() to apply the new point of interest.
                 */
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = focusMode
                }
                
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = exposureMode
                }
                
                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
            }
        }
    }
    
    // MARK: Capturing Photos
    
    private let photoOutput = AVCapturePhotoOutput()
    
    private var inProgressPhotoCaptureDelegates = [Int64: PhotoCaptureProcessor]()
    
    /// - Tag: CapturePhoto
    private func capturePhoto() {
        /*
         Retrieve the video preview layer's video orientation on the main queue before
         entering the session queue. Do this to ensure that UI elements are accessed on
         the main thread and session configuration is done on the session queue.
         */
        
        let videoPreviewLayerOrientation = previewView.videoPreviewLayer.connection?.videoOrientation
        
        sessionQueue.async {
            if let photoOutputConnection = self.photoOutput.connection(with: .video) {
                photoOutputConnection.videoOrientation = videoPreviewLayerOrientation!
            }
            var photoSettings = AVCapturePhotoSettings()
            
            // Capture HEIF photos when supported. Enable auto-flash and high-resolution photos.
            if  self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }
            
            if self.videoDeviceInput.device.isFlashAvailable {
                photoSettings.flashMode = .auto
            }
            
            photoSettings.isHighResolutionPhotoEnabled = true
            if !photoSettings.__availablePreviewPhotoPixelFormatTypes.isEmpty {
                photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: photoSettings.__availablePreviewPhotoPixelFormatTypes.first!]
            }
            photoSettings.photoQualityPrioritization = self.photoQualityPrioritizationMode
            
            let photoCaptureProcessor = PhotoCaptureProcessor(with: photoSettings, willCapturePhotoAnimation: {
                // Flash the screen to signal that AVCam took a photo.
                DispatchQueue.main.async {
                    self.previewView.videoPreviewLayer.opacity = 0
                    UIView.animate(withDuration: 0.25) {
                        self.previewView.videoPreviewLayer.opacity = 1
                    }
                }
            }, livePhotoCaptureHandler: { capturing in
                self.sessionQueue.async {
                    if capturing {
                        self.inProgressLivePhotoCapturesCount += 1
                    } else {
                        self.inProgressLivePhotoCapturesCount -= 1
                    }
                    
                    let inProgressLivePhotoCapturesCount = self.inProgressLivePhotoCapturesCount
                    DispatchQueue.main.async {
                        if inProgressLivePhotoCapturesCount > 0 {
                        } else if inProgressLivePhotoCapturesCount == 0 {
                        } else {
                            print("Error: In progress Live Photo capture count is less than 0.")
                        }
                    }
                }
            }, completionHandler: { photoCaptureProcessor in
                // When the capture is complete, remove a reference to the photo capture delegate so it can be deallocated.
                self.sessionQueue.async {
                    self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = nil
                }
            }, photoProcessingHandler: { animate in
                // Animates a spinner while photo is processing
                DispatchQueue.main.async {
                    if animate {
                        self.spinner.hidesWhenStopped = true
                        self.spinner.center = CGPoint(x: self.previewView.frame.size.width / 2.0, y: self.previewView.frame.size.height / 2.0)
                        self.spinner.startAnimating()
                    } else {
                        self.spinner.stopAnimating()
                    }
                }
            }, player: self.audioPlayer!,
               soundType: self.soundType
            )
            if self.isPortrait {
                photoCaptureProcessor.isPortrait = true
            } else {
                photoCaptureProcessor.isPortrait = false
            }
            // The photo output holds a weak reference to the photo capture delegate and stores it in an array to maintain a strong reference.
            self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = photoCaptureProcessor
            self.photoOutput.capturePhoto(with: photoSettings, delegate: photoCaptureProcessor)
        }
    }
    
    private enum LivePhotoMode {
        case on
        case off
    }
    
    private enum DepthDataDeliveryMode {
        case on
        case off
    }
    
    private enum PortraitEffectsMatteDeliveryMode {
        case on
        case off
    }
    
    private var livePhotoMode: LivePhotoMode = .off
    
    @IBOutlet private weak var livePhotoModeButton: UIButton!
    
    @IBAction private func toggleLivePhotoMode(_ livePhotoModeButton: UIButton) {
    }
    
    private var depthDataDeliveryMode: DepthDataDeliveryMode = .off
    
    @IBOutlet private weak var depthDataDeliveryButton: UIButton!
    
    @IBAction func toggleDepthDataDeliveryMode(_ depthDataDeliveryButton: UIButton) {
    }
    
    private var portraitEffectsMatteDeliveryMode: PortraitEffectsMatteDeliveryMode = .off
    
    @IBOutlet private weak var portraitEffectsMatteDeliveryButton: UIButton!
    
    @IBAction func togglePortraitEffectsMatteDeliveryMode(_ portraitEffectsMatteDeliveryButton: UIButton) {
    }
    
    private var photoQualityPrioritizationMode: AVCapturePhotoOutput.QualityPrioritization = .balanced
    
    @IBOutlet private weak var photoQualityPrioritizationSegControl: UISegmentedControl!
    
    @IBAction func togglePhotoQualityPrioritizationMode(_ photoQualityPrioritizationSegControl: UISegmentedControl) {
        let selectedQuality = photoQualityPrioritizationSegControl.selectedSegmentIndex
        sessionQueue.async {
            switch selectedQuality {
            case 0 :
                self.photoQualityPrioritizationMode = .speed
            case 1 :
                self.photoQualityPrioritizationMode = .balanced
            case 2 :
                self.photoQualityPrioritizationMode = .quality
            default:
                break
            }
        }
    }
    
    @IBOutlet weak var semanticSegmentationMatteDeliveryButton: UIButton!
    
    @IBAction func toggleSemanticSegmentationMatteDeliveryMode(_ semanticSegmentationMatteDeliveryButton: UIButton) {
    }
    
    // MARK: ItemSelectionViewControllerDelegate
    
    let semanticSegmentationTypeItemSelectionIdentifier = "SemanticSegmentationTypes"
    
    private func presentItemSelectionViewController(_ itemSelectionViewController: ItemSelectionViewController) {
        let navigationController = UINavigationController(rootViewController: itemSelectionViewController)
        navigationController.navigationBar.barTintColor = .black
        navigationController.navigationBar.tintColor = view.tintColor
        present(navigationController, animated: true, completion: nil)
    }
    
    func itemSelectionViewController(_ itemSelectionViewController: ItemSelectionViewController,
                                     didFinishSelectingItems selectedItems: [AVSemanticSegmentationMatte.MatteType]) {
        let identifier = itemSelectionViewController.identifier
        
        if identifier == semanticSegmentationTypeItemSelectionIdentifier {
            sessionQueue.async {
                self.selectedSemanticSegmentationMatteTypes = selectedItems
            }
        }
    }
    
    private var inProgressLivePhotoCapturesCount = 0
    
    // MARK: Recording Movies
    
    private var movieFileOutput: AVCaptureMovieFileOutput?
    
    private var backgroundRecordingID: UIBackgroundTaskIdentifier?
    
    //    @IBOutlet private weak var recordButton: UIButton!
    
    @IBOutlet private weak var resumeButton: UIButton!
    
    @objc func recordButtonTap(){
        if captureModeControl.selectedSegmentIndex == CaptureMode.photo.rawValue {
            capturePhoto()
        } else if captureModeControl.selectedSegmentIndex == CaptureMode.movie.rawValue {
            toggleMovieRecording()
        }
    }
    
    @objc private func toggleMovieRecording() {
        guard let movieFileOutput = self.movieFileOutput else {
            return
        }
        
        /*
         Disable the Camera button until recording finishes, and disable
         the Record button until recording starts or finishes.
         
         See the AVCaptureFileOutputRecordingDelegate methods.
         */
        CameraButton.isUserInteractionEnabled = false
        captureModeControl.isEnabled = false
        
        let videoPreviewLayerOrientation = previewView.videoPreviewLayer.connection?.videoOrientation
        
        sessionQueue.async {
            if !movieFileOutput.isRecording {
                DispatchQueue.main.async {
                    AudioServicesPlaySystemSound(1117)
                    self.isRecording = true
                    self.recordingButtonStyling()
                }
                
                if UIDevice.current.isMultitaskingSupported {
                    self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                }
                
                // Update the orientation on the movie file output video connection before recording.
                let movieFileOutputConnection = movieFileOutput.connection(with: .video)
                movieFileOutputConnection?.videoOrientation = videoPreviewLayerOrientation!
                
                let availableVideoCodecTypes = movieFileOutput.availableVideoCodecTypes
                
                if availableVideoCodecTypes.contains(.hevc) {
                    movieFileOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: movieFileOutputConnection!)
                }
                
                // Start recording video to a temporary file.
                let outputFileName = NSUUID().uuidString
                let outputFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent((outputFileName as NSString).appendingPathExtension("mov")!)
                movieFileOutput.startRecording(to: URL(fileURLWithPath: outputFilePath), recordingDelegate: self)
            } else {
                DispatchQueue.main.async {
                    AudioServicesPlaySystemSound(1118)
                    self.isRecording = false
                    self.recordingButtonStyling()
                }
                movieFileOutput.stopRecording()
            }
        }
    }
    
    /// - Tag: DidStartRecording
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        // Enable the Record button to let the user stop recording.
        
    }
    
    /// - Tag: DidFinishRecording
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        // Note: Because we use a unique file path for each recording, a new recording won't overwrite a recording mid-save.
        func cleanup() {
            let path = outputFileURL.path
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    print("Could not remove file at url: \(outputFileURL)")
                }
            }
            
            if let currentBackgroundRecordingID = backgroundRecordingID {
                backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
                
                if currentBackgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
                    UIApplication.shared.endBackgroundTask(currentBackgroundRecordingID)
                }
            }
        }
        
        var success = true
        
        if error != nil {
            print("Movie file finishing error: \(String(describing: error))")
            success = (((error! as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as AnyObject).boolValue)!
        }
        
        print("duration\(output.recordedDuration)\n")
        
        if success {
            // Check the authorization status.
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized {
                    // Save the movie file to the photo library and cleanup.
                    PHPhotoLibrary.shared().performChanges({
                        let options = PHAssetResourceCreationOptions()
                        options.shouldMoveFile = true
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        creationRequest.addResource(with: .video, fileURL: outputFileURL, options: options)
                    }, completionHandler: { success, error in
                        if !success {
                            print("AVCam couldn't save the movie to your photo library: \(String(describing: error))")
                        }
                        cleanup()
                    }
                    )
                } else {
                    cleanup()
                }
            }
        } else {
            cleanup()
        }
        
        // Enable the Camera and Record buttons to let the user switch camera and start another recording.
        DispatchQueue.main.async {
            // Only enable the ability to change camera if the device has more than one camera.
            self.CameraButton.isUserInteractionEnabled = self.videoDeviceDiscoverySession.uniqueDevicePositionsCount > 1
            self.recordButton.isEnabled = true
            self.captureModeControl.isEnabled = true
        }
    }
    
    // MARK: KVO and Notifications
    
    private var keyValueObservations = [NSKeyValueObservation]()
    /// - Tag: ObserveInterruption
    private func addObservers() {
        let keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
            guard let isSessionRunning = change.newValue else { return }
            let isLivePhotoCaptureEnabled = self.photoOutput.isLivePhotoCaptureEnabled
            let isDepthDeliveryDataEnabled = self.photoOutput.isDepthDataDeliveryEnabled
            let isPortraitEffectsMatteEnabled = self.photoOutput.isPortraitEffectsMatteDeliveryEnabled
            let isSemanticSegmentationMatteEnabled = !self.photoOutput.enabledSemanticSegmentationMatteTypes.isEmpty
            
            DispatchQueue.main.async {
                // Only enable the ability to change camera if the device has more than one camera.
                self.CameraButton.isUserInteractionEnabled = isSessionRunning && self.videoDeviceDiscoverySession.uniqueDevicePositionsCount > 1
                self.recordButton.isEnabled = isSessionRunning && self.movieFileOutput != nil
                self.recordButton.isEnabled = isSessionRunning
                self.captureModeControl.isEnabled = isSessionRunning
                self.livePhotoModeButton.isEnabled = isSessionRunning && isLivePhotoCaptureEnabled
                self.depthDataDeliveryButton.isEnabled = isSessionRunning && isDepthDeliveryDataEnabled
                self.portraitEffectsMatteDeliveryButton.isEnabled = isSessionRunning && isPortraitEffectsMatteEnabled
                self.semanticSegmentationMatteDeliveryButton.isEnabled = isSessionRunning && isSemanticSegmentationMatteEnabled
                self.photoQualityPrioritizationSegControl.isEnabled = isSessionRunning
            }
        }
        keyValueObservations.append(keyValueObservation)
        
        let systemPressureStateObservation = observe(\.videoDeviceInput.device.systemPressureState, options: .new) { _, change in
            guard let systemPressureState = change.newValue else { return }
            self.setRecommendedFrameRateRangeForPressureState(systemPressureState: systemPressureState)
        }
        keyValueObservations.append(systemPressureStateObservation)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(subjectAreaDidChange),
                                               name: .AVCaptureDeviceSubjectAreaDidChange,
                                               object: videoDeviceInput.device)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionRuntimeError),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: session)
        
        /*
         A session can only run when the app is full screen. It will be interrupted
         in a multi-app layout, introduced in iOS 9, see also the documentation of
         AVCaptureSessionInterruptionReason. Add observers to handle these session
         interruptions and show a preview is paused message. See the documentation
         of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
         */
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionWasInterrupted),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterruptionEnded),
                                               name: .AVCaptureSessionInterruptionEnded,
                                               object: session)
    }
    
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        
        for keyValueObservation in keyValueObservations {
            keyValueObservation.invalidate()
        }
        keyValueObservations.removeAll()
    }
    
    @objc
    func subjectAreaDidChange(notification: NSNotification) {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
    }
    
    /// - Tag: HandleRuntimeError
    @objc
    func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        
        print("Capture session runtime error: \(error)")
        // If media services were reset, and the last start succeeded, restart the session.
        if error.code == .mediaServicesWereReset {
            sessionQueue.async {
                if self.isSessionRunning {
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                } else {
                    DispatchQueue.main.async {
                        self.resumeButton.isHidden = false
                    }
                }
            }
        } else {
            resumeButton.isHidden = false
        }
    }
    
    /// - Tag: HandleSystemPressure
    private func setRecommendedFrameRateRangeForPressureState(systemPressureState: AVCaptureDevice.SystemPressureState) {
        /*
         The frame rates used here are only for demonstration purposes.
         Your frame rate throttling may be different depending on your app's camera configuration.
         */
        let pressureLevel = systemPressureState.level
        if pressureLevel == .serious || pressureLevel == .critical {
            if self.movieFileOutput == nil || self.movieFileOutput?.isRecording == false {
                do {
                    try self.videoDeviceInput.device.lockForConfiguration()
                    print("WARNING: Reached elevated system pressure level: \(pressureLevel). Throttling frame rate.")
                    self.videoDeviceInput.device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 20)
                    self.videoDeviceInput.device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
                    self.videoDeviceInput.device.unlockForConfiguration()
                } catch {
                    print("Could not lock device for configuration: \(error)")
                }
            }
        } else if pressureLevel == .shutdown {
            print("Session stopped running due to shutdown system pressure level.")
        }
    }
    
    /// - Tag: HandleInterruption
    @objc
    func sessionWasInterrupted(notification: NSNotification) {
        /*
         In some scenarios you want to enable the user to resume the session.
         For example, if music playback is initiated from Control Center while
         using AVCam, then the user can let AVCam resume
         the session running, which will stop music playback. Note that stopping
         music playback in Control Center will not automatically resume the session.
         Also note that it's not always possible to resume, see `resumeInterruptedSession(_:)`.
         */
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
            let reasonIntegerValue = userInfoValue.integerValue,
            let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            print("Capture session was interrupted with reason \(reason)")
            
            var showResumeButton = false
            if reason == .audioDeviceInUseByAnotherClient || reason == .videoDeviceInUseByAnotherClient {
                showResumeButton = true
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                // Fade-in a label to inform the user that the camera is unavailable.
                cameraUnavailableLabel.alpha = 0
                cameraUnavailableLabel.isHidden = false
                UIView.animate(withDuration: 0.25) {
                    self.cameraUnavailableLabel.alpha = 1
                }
            } else if reason == .videoDeviceNotAvailableDueToSystemPressure {
                print("Session stopped running due to shutdown system pressure level.")
            }
            if showResumeButton {
                // Fade-in a button to enable the user to try to resume the session running.
                resumeButton.alpha = 0
                resumeButton.isHidden = false
                UIView.animate(withDuration: 0.25) {
                    self.resumeButton.alpha = 1
                }
            }
        }
    }
    
    @objc
    func sessionInterruptionEnded(notification: NSNotification) {
        print("Capture session interruption ended")
        
        if !resumeButton.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.resumeButton.alpha = 0
            }, completion: { _ in
                self.resumeButton.isHidden = true
            })
        }
        if !cameraUnavailableLabel.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.cameraUnavailableLabel.alpha = 0
            }, completion: { _ in
                self.cameraUnavailableLabel.isHidden = true
            }
            )
        }
    }
    
    
    //MARK: - Buttons
    var CameraButton = UIImageView()
    var HelpButton = UIImageView()
    var recordingLabel = UILabel()
    var detectButton = UILabel()
    var detectLabel = UILabel()
    var recordButton = UILabel()
    var recordingAnimationButton = UILabel()
    var soundButton = UIImageView()
    var soundLabel = UILabel()
    var portraitButton = UIImageView()
    var portraitLabel = UILabel()
    
    private func buttonSetting() {
        print(view.bounds.width)
        if view.bounds.width > view.bounds.height {
            let buttonHeight:CGFloat = view.bounds.width * 0.083
            recordButton.frame = CGRect(x:view.bounds.maxX - (buttonHeight * 1.75) , y: view.center.y - (buttonHeight * 0.5), width: buttonHeight, height: buttonHeight)
            recordingAnimationButton.frame = CGRect(x: buttonHeight * 0.05, y: buttonHeight * 0.05, width: buttonHeight * 0.9, height: buttonHeight * 0.9)
            HelpButton.frame = CGRect(x:view.bounds.maxX - (buttonHeight * 1.75)  , y: view.bounds.maxY - (buttonHeight * 0.5), width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            soundButton.frame = CGRect(x: (buttonHeight), y: view.bounds.maxY - buttonHeight, width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            soundLabel.isHidden = true
            detectButton.frame = CGRect(x:view.bounds.maxX - (buttonHeight * 1.75), y: buttonHeight * 1.5, width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            detectLabel.frame = CGRect(x:view.bounds.maxX - buttonHeight * 1.3, y: buttonHeight * 1.5, width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            HelpButton.frame =  CGRect(x:  view.bounds.maxX - (buttonHeight * 1.75), y: view.bounds.maxY - (buttonHeight), width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            CameraButton.frame = CGRect(x: view.bounds.maxX - (buttonHeight * 1.75) , y: (buttonHeight * 0.5), width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            portraitButton.frame = CGRect(x: (buttonHeight), y: buttonHeight * 0.5, width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            recordButton.layer.cornerRadius = min(recordButton.frame.width, recordButton.frame.height) * 0.5
            recordingAnimationButton.layer.cornerRadius = min(recordingAnimationButton.frame.width, recordingAnimationButton.frame.height) * 0.5
            portraitLabel.isHidden = true
        } else {
            let buttonHeight:CGFloat = view.bounds.height * 0.083
            recordButton.frame = CGRect(x: view.center.x - (buttonHeight * 0.5), y: view.bounds.maxY - (buttonHeight * 1.75), width: buttonHeight, height: buttonHeight)
            recordingAnimationButton.frame = CGRect(x: buttonHeight * 0.05, y: buttonHeight * 0.05, width: buttonHeight * 0.9, height: buttonHeight * 0.9)
            detectButton.frame = CGRect(x: view.bounds.maxX - (buttonHeight * 2), y: view.bounds.maxY - (buttonHeight * 1.75), width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            detectLabel.frame = CGRect(x: view.bounds.maxX - (buttonHeight * 2), y: view.frame.maxY - (buttonHeight * 1.3) , width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            HelpButton.frame = CGRect(x: (buttonHeight * 0.5), y: view.bounds.maxY - (buttonHeight * 1.75), width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            soundButton.frame = CGRect(x:   (buttonHeight * 0.5), y: (buttonHeight), width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            soundLabel.frame = CGRect(x: (buttonHeight * 0.5), y: (buttonHeight * 1.3), width:  buttonHeight * 0.5, height:  buttonHeight * 0.5)
            CameraButton.frame = CGRect(x: view.bounds.maxX - (buttonHeight), y: view.bounds.maxY - (buttonHeight * 1.75), width: buttonHeight * 0.5, height: buttonHeight * 0.5)
            portraitButton.frame = CGRect(x: view.bounds.maxX - (buttonHeight), y: (buttonHeight), width:  buttonHeight * 0.5, height:  buttonHeight * 0.5)
            portraitLabel.frame = CGRect(x:  view.bounds.maxX - (buttonHeight), y: (buttonHeight * 1.5), width:  buttonHeight * 0.5, height:  buttonHeight * 0.5)
            portraitLabel.isHidden = false
            soundLabel.isHidden = false
        }
        recordButton.layer.cornerRadius = min(recordButton.frame.width, recordButton.frame.height) * 0.5
        recordingAnimationButton.layer.cornerRadius = min(recordingAnimationButton.frame.width, recordingAnimationButton.frame.height) * 0.5
    }
    
    var currentOrientation:UIDeviceOrientation?
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let orientation = UIDevice.current.orientation
        if orientation != currentOrientation {
            switch orientation {
            case .portrait:
                currentOrientation = .portrait
            case .landscapeLeft:
                currentOrientation = .landscapeLeft
            case .landscapeRight:
                currentOrientation = .landscapeRight
            default:
                currentOrientation = .portrait
            }
            buttonSetting()
        }
    }
    
    private func buttonAdding(){
        
        CameraButton.image = UIImage(systemName: "arrow.2.circlepath")
        HelpButton.image = UIImage(systemName: "questionmark.circle")
        soundButton.image = UIImage(systemName: "speaker")
        soundLabel.text = NSLocalizedString("Shutter", comment: "")
        portraitButton.image = UIImage(systemName: "viewfinder.circle")
        portraitLabel.text = NSLocalizedString("portrait\nOff", comment: "")
        detectButton.text =  "ω"
        detectButton.font = .systemFont(ofSize: 20, weight: .heavy)
        detectLabel.text =  NSLocalizedString("Detect\nOn", comment: "")
        detectLabel.numberOfLines = 2
        portraitLabel.numberOfLines = 2
        detectButton.textColor = .white
        detectButton.textAlignment = .center
        HelpButton.tintColor = UIColor.white
        CameraButton.tintColor = UIColor.white
        detectButton.tintColor = UIColor.white
        detectLabel.textColor = UIColor.white
        detectLabel.textAlignment = .center
        detectLabel.adjustsFontSizeToFitWidth = true
        portraitButton.tintColor = UIColor.white
        soundButton.tintColor = UIColor.white

        portraitLabel.textColor = UIColor.white
        portraitLabel.textAlignment = .center
        portraitLabel.adjustsFontSizeToFitWidth = true
        
        soundLabel.textColor = .white
        soundLabel.textAlignment = .center
        soundLabel.adjustsFontSizeToFitWidth = true

        recordingLabel.text = NSLocalizedString("Recording", comment: "")
        recordingLabel.textColor = UIColor.red
        recordingLabel.adjustsFontSizeToFitWidth = true
        
        recordButton.layer.backgroundColor = UIColor.clear.cgColor
        recordButton.layer.borderColor = UIColor.white.cgColor
        recordButton.layer.borderWidth = 4
        recordButton.clipsToBounds = true
        recordButton.layer.cornerRadius = min(recordButton.frame.width, recordButton.frame.height) * 0.5
        recordingAnimationButton.layer.cornerRadius = min(recordingAnimationButton.frame.width, recordingAnimationButton.frame.height) * 0.5
        
        recordingAnimationButton.layer.backgroundColor = UIColor.white.cgColor
        recordingAnimationButton.clipsToBounds = true
        recordingAnimationButton.layer.cornerRadius = min(recordingAnimationButton.frame.width, recordingAnimationButton.frame.height) * 0.5
        recordingAnimationButton.layer.borderWidth = 2
        recordingAnimationButton.layer.borderColor = UIColor.darkGray.cgColor
        
        let symbolConfig = UIImage.SymbolConfiguration(weight: .thin)
        
        CameraButton.preferredSymbolConfiguration = symbolConfig
        CameraButton.contentMode = .scaleAspectFill
        HelpButton.preferredSymbolConfiguration = symbolConfig
        HelpButton.contentMode = .scaleAspectFill
        portraitButton.contentMode = .scaleAspectFill
        portraitButton.preferredSymbolConfiguration = symbolConfig
        soundButton.contentMode = .scaleAspectFill
        soundButton.preferredSymbolConfiguration = symbolConfig

        detectButton.contentMode = .scaleAspectFill
        view.addSubview(CameraButton)
        view.addSubview(HelpButton)
        view.addSubview(detectButton)
        view.addSubview(detectLabel)
        view.bringSubviewToFront(recordingLabel)
        view.bringSubviewToFront(HelpButton)
        view.bringSubviewToFront(CameraButton)
        if #available(iOS 13, *) {
        view.addSubview(portraitButton)
        view.bringSubviewToFront(portraitButton)
        view.addSubview(portraitLabel)
        view.bringSubviewToFront(portraitLabel)
        view.addSubview(portraitButton)
        }
        view.bringSubviewToFront(soundButton)
        view.addSubview(soundButton)
        view.addSubview(soundLabel)
        view.bringSubviewToFront(soundLabel)
        view.bringSubviewToFront(detectLabel)
        view.addSubview(recordButton)
        view.bringSubviewToFront(recordButton)
        recordButton.addSubview(recordingAnimationButton)
        recordingLabel.isHidden = true
        
        recordButton.isUserInteractionEnabled = true
        recordingAnimationButton.isUserInteractionEnabled = true
        HelpButton.isUserInteractionEnabled = true
        CameraButton.isUserInteractionEnabled = true
        detectButton.isUserInteractionEnabled = true
        detectLabel.isUserInteractionEnabled = true
        portraitButton.isUserInteractionEnabled = true
        portraitLabel.isUserInteractionEnabled = true
        soundButton.isUserInteractionEnabled = true
        soundLabel.isUserInteractionEnabled = true
        let CameraButtonTap = UITapGestureRecognizer(target: self, action: #selector(changeCamera))
        CameraButton.addGestureRecognizer(CameraButtonTap)
        let helpTap = UITapGestureRecognizer(target: self, action: #selector(helpSegue))
        let toggleAutoTap = UITapGestureRecognizer(target: self, action: #selector(toggleAuto))
        detectButton.addGestureRecognizer(toggleAutoTap)
        let toggleAutoTap2 = UITapGestureRecognizer(target: self, action: #selector(toggleAuto))
        detectLabel.addGestureRecognizer(toggleAutoTap2)
        HelpButton.addGestureRecognizer(helpTap)
        let recordTap = UITapGestureRecognizer(target: self, action: #selector(recordButtonTap))
        recordButton.addGestureRecognizer(recordTap)
        let recordTap4Label = UITapGestureRecognizer(target: self, action: #selector(recordButtonTap))
        recordingAnimationButton.addGestureRecognizer(recordTap4Label)
        let portraitTapGesture = UITapGestureRecognizer(target: self, action: #selector(portraitTap))
        let portraitTapGesture2 = UITapGestureRecognizer(target: self, action: #selector(portraitTap))
        portraitButton.addGestureRecognizer(portraitTapGesture)
        portraitLabel.addGestureRecognizer(portraitTapGesture2)
        let soundTapGesture = UITapGestureRecognizer(target: self, action: #selector(sound))
        let soundTapGesture2 = UITapGestureRecognizer(target: self, action: #selector(sound))
        soundButton.addGestureRecognizer(soundTapGesture)
        soundLabel.addGestureRecognizer(soundTapGesture2)
        guard let path = Bundle.main.path(forResource: "meow", ofType: "mp3") else {
            print("音源ファイルが見つかりません")
            soundButton.removeFromSuperview()
            soundLabel.removeFromSuperview()
            return
        }
        do {
            try audioPlayer = AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        } catch {
            print("playererror")
            soundButton.isHidden = true
            soundLabel.isHidden = true
        }
    }
    //    MARK: - Movie Rec
    var isRecording = false
    func recordingButtonStyling(){
        let buttonHeight = recordButton.bounds.height
        var time = 0
        if isRecording {
            UIViewPropertyAnimator.runningPropertyAnimator(withDuration: 0.3, delay: 0, options: [], animations: {
                self.recordButton.layer.borderColor = UIColor.white.cgColor
                self.recordButton.alpha = 1
                
                self.recordingAnimationButton.frame = CGRect(x: buttonHeight * 0.25, y: buttonHeight * 0.25, width: buttonHeight * 0.5, height: buttonHeight * 0.5)
                self.recordingAnimationButton.layer.backgroundColor = UIColor.red.cgColor
                self.recordingAnimationButton.clipsToBounds = true
                self.recordingAnimationButton.layer.cornerRadius = min(self.recordingAnimationButton.frame.width, self.recordingAnimationButton.frame.height) * 0.1
                self.recordingAnimationButton.layer.borderColor = UIColor.red.cgColor
                self.recordingAnimationButton.alpha = 1
            }, completion: { comp in
                UIViewPropertyAnimator.runningPropertyAnimator(withDuration: 1.0, delay: 1.0, options: [], animations: {
                    self.recordingLabel.alpha = 0
                    time += 1
                },completion:  { (comp) in
                    UIViewPropertyAnimator.runningPropertyAnimator(withDuration: 1.0, delay: 1.0, options: [], animations: {
                        self.recordingLabel.alpha = 1
                    })
                })
            })
        } else {
            UIViewPropertyAnimator.runningPropertyAnimator(withDuration: 0.3, delay: 0, options: [], animations: {
                self.recordButton.layer.borderColor = UIColor.white.cgColor
                self.recordButton.alpha = 1.0
                
                self.recordingAnimationButton.frame = CGRect(x: buttonHeight * 0.05, y: buttonHeight * 0.05, width: buttonHeight * 0.9, height: buttonHeight * 0.9)
                self.recordingAnimationButton.layer.backgroundColor = UIColor.white.cgColor
                self.recordingAnimationButton.clipsToBounds = true
                self.recordingAnimationButton.layer.cornerRadius = min(self.recordingAnimationButton.frame.width, self.recordingAnimationButton.frame.height) * 0.5
                self.recordingAnimationButton.layer.borderColor = UIColor.darkGray.cgColor
                self.recordingAnimationButton.alpha = 1.0
            }, completion: nil)
        }
    }
    
    @objc private func helpSegue(){
        performSegue(withIdentifier: "ShowHelp", sender: nil)
    }
    
    @objc func toggleAuto(){
        isAuto.toggle()
        if isAuto {
            isPortrait = false
            detectButton.textColor = .white
            detectLabel.textColor = .white
            detectLabel.text = "Detect\nOn"
            portraitButton.tintColor = .gray
            portraitLabel.textColor = .gray
            portraitLabel.text = "Portrait\nOff"
        } else {
            detectButton.textColor = .gray
            detectLabel.textColor = .gray
            detectLabel.text = "Detect\nOff"
        }
    }
    
    var isPortrait = false
    
    @objc func portraitTap(){
        isPortrait.toggle()
        if isPortrait {
            isAuto = false
            detectButton.textColor = .gray
            detectLabel.textColor = .gray
            detectLabel.text = "Detect\nOff"
            portraitButton.tintColor = .white
            portraitLabel.textColor = .white
            portraitLabel.text = "Portrait\nOn"
        } else {
            portraitButton.tintColor = .gray
            portraitLabel.textColor = .gray
            portraitLabel.text = "Portrait\nOff"
        }
    }
    
    enum SoundMode {
        case shutter
        case silent
        case meow
        case bow
    }
    
    var soundMode:SoundMode = .shutter
    var soundType:String = "shutter"
    var audioPlayer:AVAudioPlayer?
    
    @objc func sound(){
        switch soundMode {
        case .shutter:
            soundLabel.text = "Silent"
            soundMode = .silent
            soundType = "silent"
            
        case .silent:
            soundLabel.text = "Meow"
            soundMode = .meow
            soundType = "audio"

            guard let path = Bundle.main.path(forResource: "meow", ofType: "mp3") else {
                print("音源ファイルが見つかりません")
                return
            }
            do {
                try audioPlayer = AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            } catch {
                print("playererror")
            }
        case .meow:
            soundLabel.text = "Bow"
            soundMode = .bow
            soundType = "audio"

            guard let path = Bundle.main.path(forResource: "puppy", ofType: "mp3") else {
                print("音源ファイルが見つかりません")
                return
            }
            do {
                try audioPlayer = AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            } catch {
                print("playererror")
            }
        case .bow:
            soundLabel.text = "Shutter"
            soundMode = .shutter
            soundType = "shutter"

        }
    }
    
  //MARK:- Blur
    
    let machToSeconds: Double = {
        var timebase: mach_timebase_info_data_t = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) * 1e-9
    }()
    
    var format: vImage_CGImageFormat?
    var sourceBuffer: vImage_Buffer?
}

extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeRight
        case .landscapeRight: self = .landscapeLeft
        default: return nil
        }
    }
    
    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }
}

extension AVCaptureDevice.DiscoverySession {
    var uniqueDevicePositionsCount: Int {
        
        var uniqueDevicePositions = [AVCaptureDevice.Position]()
        
        for device in devices where !uniqueDevicePositions.contains(device.position) {
            uniqueDevicePositions.append(device.position)
        }
        
        return uniqueDevicePositions.count
    }
}
