//
//  ViewController.swift
//  CaptureAndShazam
//
//  Created by user on 2022/10/21.
//

import Cocoa
import ShazamKit
import ScreenCaptureKit

class ViewController: NSViewController {

    @IBOutlet weak var selectAppButton: NSPopUpButton!
    @IBOutlet weak var volumeLevelIndicator: NSLevelIndicator!
    @IBOutlet weak var matchedSongCoverImageView: NSImageView!
    @IBOutlet weak var matchedSongTitleField: NSTextField!
    @IBOutlet weak var matchedSongArtistField: NSTextField!
    
    var session = SHSession()
    var latestSharableContent: SCShareableContent?
    var stream: SCStream?
    var previousURL: URL?
    var matched: Bool = false {
        didSet {
            DispatchQueue.main.async { [self] in
                matchedSongTitleField.layer?.opacity = matched ? 1 : 0.5
                matchedSongArtistField.layer?.opacity = matched ? 1 : 0.5
                matchedSongCoverImageView.layer?.opacity = matched ? 1 : 0.5
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
//        selectAppButton.menu?.delegate = self
        reloadCaptureList()
        matched = false
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    
    func reloadCaptureList() {
        SCShareableContent.getWithCompletionHandler { content, error in
            print(content, error)
        }
        Task {
            do {
                print("reloading...")
                let currentSharableContent = try await SCShareableContent.current
                print("!")
                await MainActor.run {
                    latestSharableContent = currentSharableContent
                    selectAppButton.menu!.items = currentSharableContent.applications.map { app in
                        let item = NSMenuItem(title: app.applicationName, action: nil, keyEquivalent: "")
                        item.image = NSRunningApplication(processIdentifier: app.processID)?.icon
                        item.identifier = .init(rawValue: app.bundleIdentifier)
                        if item.title.count == 0 {
                            item.title = app.bundleIdentifier
                        }
                        return item
                    }.sorted(by: { $0.title < $1.title })
                    print("reloaded!")
                }
            } catch {
                print(error)
            }
        }
    }
    
    @IBAction func reloadCaptureList(_ sender: Any) {
        reloadCaptureList()
    }
    
    @IBAction func startCapture(_ sender: Any) {
        guard let display = latestSharableContent?.displays.first else {
            return
        }
        guard let selectedAppID = selectAppButton.menu?.highlightedItem?.identifier?.rawValue else {
            return
        }
        guard let app = latestSharableContent?.applications.first(where: { $0.bundleIdentifier == selectedAppID }) else {
            return
        }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        var config = SCStreamConfiguration()
        // TODO: request Apple to add disable screen capture API
        config.minimumFrameInterval = .init(value: 60, timescale: 1)
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        stream?.stopCapture()
        stream = .init(filter: filter, configuration: config, delegate: self)
        try! stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
        try! stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
        session = .init()
        session.delegate = self
        print("starting...")
        stream?.startCapture() {
            print("startCapture: ", $0)
        }
        matched = false
    }
    
    @IBAction func stopCapture(_ sender: Any) {
        stream?.stopCapture { error in
            DispatchQueue.main.async { [self] in
                matched = false
                volumeLevelIndicator.doubleValue = 0
            }
        }
    }
}

extension ViewController: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("stopped", error)
        DispatchQueue.main.async { [self] in
            matched = false
            volumeLevelIndicator.doubleValue = 0
            let alert = NSAlert(error: error)
            if let window = view.window {
                alert.beginSheetModal(for: window)
            }
        }
    }
}

extension ViewController: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type != .audio {
            print("i got unwanted type sample...", type.rawValue)
            return
        }
//        print(sampleBuffer)
        guard let cmDesc = sampleBuffer.formatDescription else {
            return
        }
        let avFormat = AVAudioFormat(cmAudioFormatDescription: cmDesc)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: .init(sampleBuffer.numSamples)) else {
            print("FAIL: pcmBuffer is nil")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<(sampleBuffer.numSamples), into: pcmBuffer.mutableAudioBufferList)
        } catch {
            print(error, cmDesc)
            return
        }
        if let floatChannelData = pcmBuffer.floatChannelData {
            var maxValue: Float = 0
            for i in 0..<sampleBuffer.numSamples {
                let v = floatChannelData[0][i]
                if maxValue < v {
                    maxValue = v
                }
            }
            DispatchQueue.main.async {
                self.volumeLevelIndicator.doubleValue = Double(maxValue) * self.volumeLevelIndicator.maxValue
            }
        }
        session.matchStreamingBuffer(pcmBuffer, at: nil)
    }
}

extension ViewController: SHSessionDelegate {
    func session(_ session: SHSession, didFind match: SHMatch) {
        print("matched!", match)
        DispatchQueue.main.async { [self] in
            let mediaItem = match.mediaItems.first!
            print(mediaItem)
            matchedSongTitleField.stringValue = mediaItem.title ?? ""
            matchedSongArtistField.stringValue = mediaItem.artist ?? ""
            if let url = mediaItem.artworkURL {
                if url != previousURL {
                    matchedSongCoverImageView.image = nil
                    Task {
                        let (data, _) = try await URLSession.shared.data(for: .init(url: url))
                        await MainActor.run {
                            matchedSongCoverImageView.image = .init(data: data)
                            previousURL = url
                        }
                    }
                }
            } else {
                matchedSongCoverImageView.image = nil
                previousURL = nil
            }
            matched = true
        }
    }
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        print("didn't match...", error)
        matched = false
    }
}
