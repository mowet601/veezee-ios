//
//  AudioPlayer.swift
//  AudioPlayer
//
//  Created by Kevin DELANNOY on 26/04/15.
//  Copyright (c) 2015 Kevin Delannoy. All rights reserved.
//

import AVFoundation
import MediaPlayer
import CouchbaseLiteSwift
import Kingfisher

/// An `AudioPlayer` instance is used to play `AudioPlayerItem`. It's an easy to use AVPlayer with simple methods to
/// handle the whole playing audio process.
///
/// You can get events (such as state change or time observation) by registering a delegate.
final public class AudioPlayer: NSObject {
	
	public struct Notifications {
		static let willStartPlayingItem = "\(String(describing: Bundle.main.bundleIdentifier)).willStartPlayingItem";
		static let didChangeState = "\(String(describing: Bundle.main.bundleIdentifier)).didChangeState";
		static let didProgressTo = "\(String(describing: Bundle.main.bundleIdentifier)).didProgressTo";
	}
	
	static let shared = AudioPlayer();

    // MARK: Handlers

    /// The background handler.
    let backgroundHandler = BackgroundHandler()

    /// Reachability for network connection.
    let reachability = Reachability()

    // MARK: Event producers

    /// The network event producer.
    lazy var networkEventProducer: NetworkEventProducer = {
        NetworkEventProducer(reachability: self.reachability)
    }()

    /// The player event producer.
    let playerEventProducer = PlayerEventProducer()

    /// The seek event producer.
    let seekEventProducer = SeekEventProducer()

    /// The audio item event producer.
    var audioItemEventProducer = AudioItemEventProducer()

    /// The retry event producer.
    var retryEventProducer = RetryEventProducer()

    // MARK: Player

    /// The queue containing items to play.
    var queue: AudioItemQueue?

    /// The audio player.
    var player: AVPlayer? {
        didSet {
            player?.allowsExternalPlayback = false
            player?.volume = volume
			player?.rate = 1.0;
            updatePlayerForBufferingStrategy()

            if let player = player {
                playerEventProducer.player = player
                audioItemEventProducer.item = currentItem
                playerEventProducer.startProducingEvents()
                networkEventProducer.startProducingEvents()
                audioItemEventProducer.startProducingEvents()
            } else {
                playerEventProducer.player = nil
                audioItemEventProducer.item = nil
                playerEventProducer.stopProducingEvents()
                networkEventProducer.stopProducingEvents()
                audioItemEventProducer.stopProducingEvents()
            }
        }
    }

    /// The current item being played.
    public internal(set) var currentItem: PlayableItem? {
        didSet {
            if let currentItem = currentItem {
                //Stops the current player
				player?.rate = 0
                player = nil

                //Ensures the audio session got started
                setAudioSession(active: true)

                //Sets new state
                if reachability.isReachable() || currentItem.url.ap_isOfflineURL {
                    state = .buffering
                    backgroundHandler.beginBackgroundTask()
                } else {
                    stateWhenConnectionLost = .buffering
                    state = .waitingForConnection
                    backgroundHandler.beginBackgroundTask()
                    return
                }
                
                //Reset special state flags
                pausedForInterruption = false
                
                //Create new AVPlayerItem
				// iOS 12 simulator has some issues with CachingAVPlayerItem delegates not getting called
				let playerItem = CachingAVPlayerItem(url: currentItem.url!, playableItem: currentItem);
				playerItem.delegate = self
				playerItem.preferredForwardBufferDuration = self.preferredForwardBufferDuration
//				let playerItem = AVPlayerItem(url: currentItem.url!)

                //Creates new player
                player = AVPlayer(playerItem: playerItem)

                //Updates information on the lock screen
                updateNowPlayingInfoCenter()

                //Calls delegate
                if oldValue != currentItem {
                    delegate?.audioPlayer(self, willStartPlaying: currentItem)
					NotificationCenter.default.post(name: Notification.Name(rawValue: AudioPlayer.Notifications.willStartPlayingItem), object: nil)
                }
				player?.rate = 1.0
            } else {
                stop()
            }
        }
    }

    // MARK: Public properties

    /// The delegate that will be called upon events.
    public weak var delegate: AudioPlayerDelegate?

    /// Defines the maximum to wait after a connection loss before putting the player to Stopped mode and cancelling
    /// the resume. Default value is 60 seconds.
    public var maximumConnectionLossTime = TimeInterval(60)

    /// The maximum number of interruption before putting the player to Stopped mode. Default value is 10.
    public var maximumRetryCount: Int {
        get {
            return retryEventProducer.maximumRetryCount
        }
        set {
            retryEventProducer.maximumRetryCount = newValue
        }
    }

    /// The delay to wait before cancelling last retry and retrying. Default value is 10 seconds.
    public var retryTimeout: TimeInterval {
        get {
            return retryEventProducer.retryTimeout
        }
        set {
            retryEventProducer.retryTimeout = newValue
        }
    }

    /// Defines whether the player should resume after a system interruption or not. Default value is `true`.
    public var resumeAfterInterruption = true

    /// Defines whether the player should resume after a connection loss or not. Default value is `true`.
    public var resumeAfterConnectionLoss = true

    /// Defines the mode of the player. Default is `.Normal`.
    public var mode = AudioPlayerMode.normal {
        didSet {
            queue?.mode = mode
        }
    }

    /// Defines the volume of the player. `1.0` means 100% and `0.0` is 0%.
    public var volume = Float(1) {
        didSet {
            player?.volume = volume
        }
    }
    
    /// Defines the buffering strategy used to determine how much to buffer before starting playback
    public var bufferingStrategy: AudioPlayerBufferingStrategy = .defaultBuffering {
        didSet {
            updatePlayerForBufferingStrategy()
        }
    }
    
    /// Defines the preferred buffer duration in seconds before playback begins. Defaults to 60.
    /// Works on iOS/tvOS 10+ when `bufferingStrategy` is `.playWhenPreferredBufferDurationFull`.
    public var preferredBufferDurationBeforePlayback = TimeInterval(60)
    
    /// Defines the preferred size of the forward buffer for the underlying `AVPlayerItem`.
    /// Works on iOS/tvOS 10+, default is 0, which lets `AVPlayer` decide.
    public var preferredForwardBufferDuration = TimeInterval(0)

    /// Defines how to behave when the user is seeking through the lockscreen or the control center.
    ///
    /// - multiplyRate: Multiples the rate by a factor.
    /// - changeTime:   Changes the current position by adding/substracting a time interval.
    public enum SeekingBehavior {
        case multiplyRate(Float)
        case changeTime(every: TimeInterval, delta: TimeInterval)

        func handleSeekingStart(player: AudioPlayer, forward: Bool) {
			player.seekEventProducer.isBackward = !forward
			player.seekEventProducer.startProducingEvents()
        }

        func handleSeekingEnd(player: AudioPlayer, forward: Bool) {
			player.seekEventProducer.stopProducingEvents()
        }
    }

    /// Defines the rate behavior of the player when the backward/forward buttons are pressed. Default value
    /// is `multiplyRate(2)`.
    public var seekingBehavior = SeekingBehavior.multiplyRate(2) {
        didSet {
            if case .changeTime(let timerInterval, _) = seekingBehavior {
                seekEventProducer.intervalBetweenEvents = timerInterval
            }
        }
    }

    // MARK: Readonly properties

    /// The current state of the player.
    public internal(set) var state = AudioPlayerState.stopped {
        didSet {
			updateNowPlayingInfoCenter()

            if state != oldValue {
                if case .buffering = state {
                    backgroundHandler.beginBackgroundTask()
                } else if case .buffering = oldValue {
                    backgroundHandler.endBackgroundTask()
                }

                delegate?.audioPlayer(self, didChangeStateFrom: oldValue, to: state)
				NotificationCenter.default.post(name: Notification.Name(rawValue: AudioPlayer.Notifications.didChangeState), object: nil)
				
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
					self.updateNowPlayingInfoCenter()
				}
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
					self.updateNowPlayingInfoCenter()
				}
            }
        }
    }

    // MARK: Private properties

    /// A boolean value indicating whether the player has been paused because of a system interruption.
    var pausedForInterruption = false

    /// A boolean value indicating if quality is being changed. It's necessary for the interruption count to not be
    /// incremented while new quality is buffering.
    var qualityIsBeingChanged = false

    /// The state before the player went into .Buffering. It helps to know whether to restart or not the player.
    var stateBeforeBuffering: AudioPlayerState?

    /// The state of the player when the connection was lost
    var stateWhenConnectionLost: AudioPlayerState?

    // MARK: Initialization

    /// Initializes a new AudioPlayer.
    public override init() {
        super.init()

        playerEventProducer.eventListener = self
        networkEventProducer.eventListener = self
        audioItemEventProducer.eventListener = self
    }

    /// Deinitializes the AudioPlayer. On deinit, the player will simply stop playing anything it was previously
    /// playing.
    deinit {
        stop()
    }

    // MARK: Utility methods

    /// Updates the MPNowPlayingInfoCenter with current item's info.
    func updateNowPlayingInfoCenter() {
		if let item = currentItem {
			MPNowPlayingInfoCenter.default().updateNow(
				with: item,
				duration: currentItemDuration,
				progression: currentItemProgression,
				playbackRate: 1.0)
			//print("updateNowPlayingInfoCenter")
		} else {
			MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
		}
    }

    /// Enables or disables the `AVAudioSession` and sets the right category.
    ///
    /// - Parameter active: A boolean value indicating whether the audio session should be set to active or not.
    func setAudioSession(active: Bool) {
		_ = try? AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback)
		_ = try? AVAudioSession.sharedInstance().setActive(active)
    }

    // MARK: Public computed properties

    /// Boolean value indicating whether the player should resume playing (after buffering)
    var shouldResumePlaying: Bool {
        return !state.isPaused &&
            (stateWhenConnectionLost.map { !$0.isPaused } ?? true) &&
            (stateBeforeBuffering.map { !$0.isPaused } ?? true)
    }

    // MARK: Retrying

    /// This will retry to play current item and seek back at the correct position if possible (or enabled). If not,
    /// it'll just play the next item in queue.
    func retryOrPlayNext() {
        guard !state.isPlaying else {
            retryEventProducer.stopProducingEvents()
            return
        }

        let cip = currentItemProgression
        let ci = currentItem
        currentItem = ci
        if let cip = cip {
            //We can't call self.seek(to:) in here since the player is new
            //and `cip` is probably not in the seekableTimeRanges.
            player?.seek(to: CMTime(timeInterval: cip))
        }
    }
    
    /// Updates the current player based on the current buffering strategy.
    /// Only has an effect on iOS 10+, tvOS 10+ and macOS 10.12+
    func updatePlayerForBufferingStrategy() {
		player?.automaticallyWaitsToMinimizeStalling = self.bufferingStrategy != .playWhenBufferNotEmpty
    }
    
    /// Updates a given player item based on the `preferredForwardBufferDuration` set.
    /// Only has an effect on iOS 10+, tvOS 10+ and macOS 10.12+
    func updatePlayerItemForBufferingStrategy(_ playerItem: AVPlayerItem) {
        //Nothing strategy-specific yet
		playerItem.preferredForwardBufferDuration = self.preferredForwardBufferDuration
    }
}

extension AudioPlayer: EventListener {
    /// The implementation of `EventListener`. It handles network events, player events, audio item events, quality
    /// adjustment events, retry events and seek events.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - eventProducer: The producer of the event.
    func onEvent(_ event: Event, generetedBy eventProducer: EventProducer) {
        if let event = event as? NetworkEventProducer.NetworkEvent {
            handleNetworkEvent(from: eventProducer, with: event)
        } else if let event = event as? PlayerEventProducer.PlayerEvent {
            handlePlayerEvent(from: eventProducer, with: event)
        } else if let event = event as? AudioItemEventProducer.AudioItemEvent {
            handleAudioItemEvent(from: eventProducer, with: event)
        } else if let event = event as? RetryEventProducer.RetryEvent {
            handleRetryEvent(from: eventProducer, with: event)
        } else if let event = event as? SeekEventProducer.SeekEvent {
            handleSeekEvent(from: eventProducer, with: event)
        }
    }
}

extension AudioPlayer: CachingAVPlayerItemDelegate {
	func playerItem(_ playerItem: CachingAVPlayerItem, playableItem: PlayableItem, didFinishDownloadingData data: Data) {
		if(Constants.OFFLINE_ACCESS && !playableItem.isOffline) {
			let fileName = playableItem._id;
			let fileExtension = playableItem.url?.pathExtension;
			let fileNameWithExtension = "\(fileName!).\(fileExtension!)";
			let filePath = Constants.MUSIC_TRACKS_CACHE_FOLDER_PATH.appending("/\(fileNameWithExtension)");
			
			let cacheUrl = URL(fileURLWithPath: filePath);
			try! data.write(to: cacheUrl);
			
			playableItem.isOffline = true;
			playableItem.fileName = fileNameWithExtension;
			
			if playableItem.imageUrl != nil {
				var imageFileNameWithExtension: String? = nil;
				let imageUrl = URL(string: (playableItem.imageUrl)!);
				KingfisherManager.shared.retrieveImage(with: ImageResource(downloadURL: imageUrl!), options: nil, progressBlock: nil) {
					(image, error, cacheType, imageURL) -> () in
					var imagePath = Constants.MUSIC_IMAGES_CACHE_FOLDER_PATH.appending("/\(fileName!)");
					
					if(imageUrl?.pathExtension == "jpg") {
						if let data = image!.pngData() {
							imagePath = imagePath.appending(".jpg");
							imageFileNameWithExtension = "\(fileName!).jpg";
							let url = URL(fileURLWithPath: imagePath);
							try? data.write(to: url);
						}
					} else if(imageUrl?.pathExtension == "png") {
						if let data = image!.jpegData(compressionQuality: 1.0) {
							imagePath = imagePath.appending(".png");
							imageFileNameWithExtension = "\(fileName!).png";
							let url = URL(fileURLWithPath: imagePath);
							try? data.write(to: url);
						}
					}
					
					let originImageUrl = playableItem.imageUrl;
					// save the playableItem in the db
					playableItem.imageUrl = imageFileNameWithExtension;
					
					let playableItemEncoded = playableItem.dictionary;
					let offlineDocument = MutableDocument(id: playableItem._id!, data: playableItemEncoded);
					try! OfflineAccessDatabase.sharedInstance.database?.saveDocument(offlineDocument);
					
					playableItem.imageUrl = originImageUrl;
					
					playableItem.url = cacheUrl;
				};
			} else {
				let playableItemEncoded = playableItem.dictionary;
				let offlineDocument = MutableDocument(id: playableItem._id!, data: playableItemEncoded);
				try! OfflineAccessDatabase.sharedInstance.database?.saveDocument(offlineDocument);
				
				playableItem.url = cacheUrl;
			}
		}
	}
}

