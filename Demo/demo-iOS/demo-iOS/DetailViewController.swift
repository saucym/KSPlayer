//
//  DetailViewController.swift
//  Demo
//
//  Created by kintan on 2018/4/15.
//  Copyright © 2018年 kintan. All rights reserved.
//

import CoreServices
import KSPlayer
import UIKit
protocol DetailProtocol: UIViewController {
    var resource: KSPlayerResource? { get set }
}

class DetailViewController: UIViewController, DetailProtocol {
    #if os(iOS)
    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }

    private let playerView = IOSVideoPlayerView()
    #else
    private let playerView = CustomVideoPlayerView()
    #endif
    var resource: KSPlayerResource? {
        didSet {
            if let resource = resource {
                playerView.set(resource: resource)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(playerView)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        #if os(iOS)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.readableContentGuide.topAnchor),
            playerView.leftAnchor.constraint(equalTo: view.leftAnchor),
            playerView.rightAnchor.constraint(equalTo: view.rightAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #else
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.leftAnchor.constraint(equalTo: view.leftAnchor),
            playerView.rightAnchor.constraint(equalTo: view.rightAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #endif
        view.layoutIfNeeded()
        playerView.backBlock = { [unowned self] in
            #if os(iOS)
            if UIApplication.shared.statusBarOrientation.isLandscape {
                self.playerView.updateUI(isLandscape: false)
            } else {
                self.navigationController?.popViewController(animated: true)
            }
            #else
            self.navigationController?.popViewController(animated: true)
            #endif
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if UIDevice.current.userInterfaceIdiom == .phone {
            navigationController?.setNavigationBarHidden(true, animated: true)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: true)
    }

    override open var canBecomeFirstResponder: Bool {
        true
    }

    // The responder chain is asking us which commands you support.
    // Enable/disable certain Edit menu commands.
    override open func canPerformAction(_ action: Selector, withSender _: Any?) -> Bool {
        if action == #selector(openAction(_:)) {
            // User wants to perform a "New" operation.
            return true
        }
        return false
    }

    /// User chose "Open" from the File menu.
    @objc public func openAction(_: AnyObject) {
        #if os(iOS)
        let documentPicker = UIDocumentPickerViewController(documentTypes: [kUTTypeMPEG4 as String], in: .open)
        documentPicker.delegate = self
        present(documentPicker, animated: true, completion: nil)
        #endif
    }
}

#if os(iOS)

extension DetailViewController: UIDocumentPickerDelegate {
    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let first = urls.first {
            resource = KSPlayerResource(url: first)
        }
    }
}
#endif

class CustomVideoPlayerView: VideoPlayerView {
    override func customizeUIComponents() {
        super.customizeUIComponents()
        toolBar.isHidden = true
        toolBar.timeSlider.isHidden = true
    }

    override open func player(layer: KSPlayerLayer, state: KSPlayerState) {
        super.player(layer: layer, state: state)
        if state == .readyToPlay, let player = layer.player {
            print(player.naturalSize)
            // list the all subtitles
            let subtitleInfos = srtControl.filterInfos { _ in true }
            subtitleInfos.forEach {
                print($0.name)
            }
            subtitleInfos.first?.makeSubtitle { result in
                self.resource?.subtitle = try? result.get()
            }
            for track in player.tracks(mediaType: .audio) {
                print("audio name: \(track.name) language: \(track.language ?? "")")
            }
        }
    }

    override func onButtonPressed(type: PlayerButtonType, button: UIButton) {
        if type == .landscape {
            // xx
        } else {
            super.onButtonPressed(type: type, button: button)
        }
    }
}
